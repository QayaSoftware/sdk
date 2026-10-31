# Commands

A command parser and dispatcher in the manner of [Brigadier](https://github.com/Mojang/brigadier), written in Zig. Commands are a graph of literal words and typed arguments that chain into each other, as `execute as @a run give @s diamond 5` does. Parsing never allocates and never locks, so once your commands are registered any number of threads can parse and run them at once.

Latest docs are published to https://qayasoftware.github.io/sdk/commands/

```zig
const commands = @import("commands");

const Dispatcher = commands.Dispatcher(*Player);

fn teleport(ctx: *const Dispatcher.Context) !void {
    const player = ctx.source;
    player.position = .{ ctx.argument(f64, "x"), ctx.argument(f64, "y"), ctx.argument(f64, "z") };
}

var dispatcher = Dispatcher.init(gpa);
defer dispatcher.deinit();

const tp = try dispatcher.literal(.root, "tp", .{ .requires = isOp });
const x = try dispatcher.argument(tp, "x", f64, .{});
const y = try dispatcher.argument(x, "y", f64, .{});
_ = try dispatcher.argument(y, "z", f64, .{ .executes = teleport });

var diagnostics: commands.Diagnostics = .{};
_ = dispatcher.execute("tp 10 64 -3.5", player, &diagnostics) catch |err| switch (err) {
    error.UnknownCommand, error.UnknownArgument, error.InvalidArgument, error.IncompleteCommand => {
        std.debug.print("{f}\n", .{diagnostics});
    },
    else => return err,
};
```

## The graph

A `Dispatcher(Source)` holds the graph. `Source` is whatever a command runs for: a player, the console, a script. It is handed to every parse and every command.

- `literal(parent, name, options)` adds a word, and `argument(parent, name, kind, options)` adds a typed value. Adding a node that is already there merges the options into it.
- `options.executes` is the command that runs when the input ends at that node.
- `options.requires` decides whether a source can use the node at all. A node it can't use is simply not there for it: it won't parse, suggest or appear in usage.
- `options.suggests` replaces an argument type's own suggestions, with the arguments parsed so far at hand.
- `options.redirect` continues parsing among another node's children, which is how commands chain:
  - `.to(node)` keeps the source as it is.
  - `.map(node, modifier)` gives the rest of the command another source.
  - `.fork(node, each)` runs the rest of the command once for every source `each` hands it. Errors after a fork are dropped and only the runs that succeeded are counted, as in Brigadier.

```zig
const execute = try dispatcher.literal(.root, "execute", .{});
_ = try dispatcher.literal(execute, "run", .{ .redirect = .to(.root) });
const as = try dispatcher.literal(execute, "as", .{});
_ = try dispatcher.argument(as, "targets", Targets{}, .{ .redirect = .fork(execute, asTargets) });
```

A command reads its arguments with `ctx.argument(T, "name")`, or `ctx.optional(T, "name")` for one that may not have been given. In safe builds, asking for the wrong type panics with a message naming both types. A context only holds the arguments parsed since the last redirect.

## Argument types

| Kind | Value | Reads |
|---|---|---|
| any integer type, or `commands.integer(T, .{ .min, .max })` | `T` | `42`, `-7` |
| any float type, or `commands.float(T, .{ .min, .max })` | `T` | `1.5`, `-2`, `.5` |
| `bool`, or `commands.boolean` | `bool` | `true`, `false` |
| any enum type, or `commands.choice(E)` | `E` | one of its tags |
| `commands.word` | `[]const u8` | everything up to the next space |
| `commands.string` | `[]const u8` | a word, or `"text in quotes"` with `\"` and `\\` escapes |
| `commands.greedy` | `[]const u8` | the rest of the input |

An argument type of your own is any value with a `Value` type and a `parse` function. The `parse` function can also take the source, so it can check the text against the world, such as whether a player with that name exists. A type can add `suggest` to offer completions, and `describe` to explain its own errors.

```zig
const Targets = struct {
    pub const Value = Selector;

    pub fn parse(_: *const Targets, reader: *commands.Reader, source: *Player) !Selector {
        const start = reader.cursor;
        const name = reader.readWord();
        if (std.mem.eql(u8, name, "@a")) return .all;
        if (source.server.find(name) != null) return .{ .name = name };
        reader.cursor = start;
        return error.UnknownPlayer;
    }
};
```

## Errors, suggestions and usage

- **Errors:** a parse that fails returns a small error set, and `Diagnostics` says where and why in Brigadier's format, such as `Integer must not be more than 64 at position 9: give bob <--[HERE]`.
- **Suggestions:** `suggest(gpa, input, source)` completes the word at the end of the input. It considers every way the input can be read, includes tooltips, and leaves out what the source can't use.
- **Usage:**
  - `usage` writes the short form, such as `give <targets> [<count>]`, `tp (<targets>|<x>)` or `run ...`.
  - `allUsage` writes every command in full.
- **Inspecting the graph:** `find`, `child`, `children` and `info` walk and describe it, for tools or for sending the graph to a client.

## Threads

Registering needs the dispatcher to itself. Everything else only reads it: `parse`, `execute`, `suggest`, `usage`.

All per-call state lives on the caller's stack or in a buffer the caller passes in. Share a `*const Dispatcher` with as many threads as you like, with no locks.

A `Parse` can also be made on one thread and run on another. That suits checking a command where it arrives and running it later at a safe point in the frame. `examples/parallel.zig` shows both.

## Performance

`zig build commands-performance -Doptimize=fast`, on an Intel i7 12700F:

```
parse tp <x> <y> <z>                       1000000       58.1 ns/op     17212343 ops/s
parse give <target> <item> <count>         1000000       55.5 ns/op     18032768 ops/s
parse one of 512 literals                  1000000       53.3 ns/op     18745172 ops/s
parse two redirects                        1000000      232.4 ns/op      4302723 ops/s
parse after three arguments fail           1000000       55.4 ns/op     18057371 ops/s
execute tp <x> <y> <z>                     1000000       73.5 ns/op     13603091 ops/s
execute two redirects                      1000000      281.7 ns/op      3550105 ops/s
reject a bad argument                      1000000       50.9 ns/op     19653451 ops/s
suggest among 512 literals (100 found)       10000     5868.7 ns/op       170396 ops/s

execute tp, 1 tasks at once                1000000       74.2 ns/op     13476298 ops/s
execute tp, 4 tasks at once                1000000       22.3 ns/op     44743114 ops/s
execute tp, 16 tasks at once               1000000       10.8 ns/op     92311666 ops/s
```

## Where it differs from Brigadier

- Commands return `!void`. `execute` returns how many times the command ran instead of an integer result.
- Of the ways to read the input, the first that ends at a command wins. If none does, the error reported is the one that got furthest.
- Arguments are tried in the order they were added, not sorted by name.
- `word` takes anything up to the next space, not a restricted set of characters.

## Examples

```sh
zig build commands-basic         # a small server console: tp, give, execute as/run, help, suggestions
zig build commands-parallel      # many threads running commands at once, and parsing on one thread to run on another
zig build commands-performance -Doptimize=fast
```
