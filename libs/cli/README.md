# Cli

Command line arguments and environment variables parsed into a struct, by its type. Fields are flags, positional arguments, groups and subcommands. Their types decide what they accept, and help and error messages are written from the same struct.

Latest docs are published to https://qayasoftware.github.io/sdk/cli/

```zig
const cli = @import("cli");

const Options = struct {
    port: u16 = 8080,
    log: enum { quiet, info, debug } = .info,
    verbose: u8 = 0,
    workers: ?u32 = null,
    allow: []const []const u8 = &.{},
    token: []const u8,
    root: []const u8 = ".",

    pub const description = "Serves a directory over HTTP.";
    pub const meta = .{
        .port = .{ .short = 'p', .help = "Port to listen on" },
        .verbose = .{ .short = 'v', .count = true, .help = "Log more, more for each" },
        .allow = .{ .short = 'a', .value_name = "ORIGIN", .help = "Origins allowed to fetch" },
        .token = .{ .help = "Secret that requests must carry", .env = "SERVE_TOKEN" },
        .root = .{ .positional = true, .help = "The directory to serve" },
    };
};

pub fn main(init: std.process.Init) !void {
    const options = cli.parseProcess(Options, init, .{ .env_prefix = "SERVE_" });
    // serve -vv --port 9000 -a example.com public
}
```

```
$ serve --help
Serves a directory over HTTP.

Usage: serve [options] [<root>]

Arguments:
  <root>  The directory to serve [default: .] [env: SERVE_ROOT]

Options:
  -p, --port <PORT>        Port to listen on [default: 8080] [env: SERVE_PORT]
      --log <LOG>          [possible: quiet, info, debug] [default: info] [env: SERVE_LOG]
  -v, --verbose            Log more, more for each [env: SERVE_VERBOSE]
      --workers <WORKERS>  [env: SERVE_WORKERS]
  -a, --allow <ORIGIN>...  Origins allowed to fetch [env: SERVE_ALLOW]
      --token <TOKEN>      Secret that requests must carry [env: SERVE_TOKEN]
  -h, --help               Show this help

$ serve --prot 1
error: unknown flag '--prot'; did you mean '--port'?

Usage: serve [options] [<root>]

For more, try '--help'.
```

## Fields

A field is a flag named after it: `max_connections` is `--max-connections`. Its type decides what it takes.

| Type | Given as |
|---|---|
| `bool` | `--verbose` sets it; `--no-verbose` or `--verbose=false` clears it |
| integers | `--port 80`, `--port=80`, `-p 80`, `-p80`; `0x`, `0o` and `0b` work too |
| floats | `--ratio 0.5` |
| enums | `--log debug`; a tag `very_loud` is written `very-loud` |
| `[]const u8` | `--name text` |
| `?T` | as `T`, and null when not given |
| `[]const T` | the flag given any number of times: `-a x -a y` |
| a struct | a group: its fields are flags that start with its name, as `--tls-cert` |
| a tagged union | subcommands; see below |
| a type with `parseCli` | whatever `pub fn parseCli(arena: Allocator, text: []const u8) !T` accepts |

A field with a default can be left out, as can an optional one. A field with neither must be given, or parsing fails naming the flag and any environment variable that could give it. Short flags cluster (`-vqp80`), `--` ends the flags, and an argument like `-5` is a value rather than a flag.

## `meta`

A struct says more about its fields in `pub const meta`, and about itself in `pub const description`. Each field's entry can set:

| Option | |
|---|---|
| `help` | what the field is for, in help |
| `short` | a one-letter flag, as `'p'` for `-p` |
| `long` | the flag's name instead of the field's |
| `positional` | taken by position rather than by flag; a slice takes every one left |
| `count` | for an integer: how many times the flag is given, as `-vvv` |
| `env` | a variable's name to read; `false` for none; `true` to read the variable named after the field even without a prefix |
| `value_name` | what help calls the value, as `<ORIGIN>` |
| `separator` | what separates a list's values in a variable; `,` unless set |
| `hidden` | left out of help |

A misspelled option or field in `meta` is a compile error, as are two fields with the same flag, and a field type that can't be parsed from text.

## The environment

The command line wins over the environment, which wins over defaults. With `env_prefix = "SERVE_"`, every field reads the variable named after it: `--port` reads `SERVE_PORT` and `--tls-cert` reads `SERVE_TLS_CERT`. A list reads separated values, as `SERVE_ALLOW=a.com,b.com`.

Without a prefix, only variables named in `meta` are read. That way a field called `path` never picks up `PATH`.

## Subcommands

A tagged union field makes subcommands. Each tag is a command. Its payload struct parses the arguments after the command's name, and an empty payload makes a bare command. `--help` after a command writes that command's help.

```zig
const Tool = struct {
    verbose: bool = false,
    command: union(enum) {
        build: struct {
            release: bool = false,
            pub const description = "Builds the project.";
        },
        add: struct {
            name: []const u8,
            pub const meta = .{ .name = .{ .positional = true } };
        },
        clean,
    },
};

// tool --verbose build --release
// tool add zig
// tool clean
```

Flags before a command's name are the parent's, and flags after it are the command's.

## Parsing

- **`parseProcess(T, init, options)`** reads the process's arguments and environment into a `T` that lives as long as the process. `--help` prints the help and exits with 0. An error prints the message and the usage line, then exits with 2.
- **`parse(T, gpa, args, options)`** returns a `Parsed(T)` whose arena holds its strings and slices; free it with `deinit`.
- **`parseLeaky(T, arena, args, options)`** allocates in an arena you give it.
- **Errors:** both `parse` and `parseLeaky` return an error. `Diagnostics` explains it, and its `writeHelp` and `writeUsage` write the help for whichever command the error happened in.
- **`writeHelp(T, writer, target)`** and **`writeUsage(T, writer, target)`** write help without parsing.

## Examples

```sh
zig build cli-server -- --help    # flags, groups, counts, lists and the environment
zig build cli-tool -- --help      # subcommands, as `tool build`, `tool run`, `tool add`
```
