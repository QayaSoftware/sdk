# Logging

Logging for `std.log`. `logging.logFn(config)` makes the function for `std_options.logFn`, and from then on every `std.log` call in your program and its libraries goes to the terminal, a file or a directory of files, and memory, decorated as you asked. It needs no setup, holds no allocator and writes through std.debug's Io, so it works from the first line of `main` until a panic.

Latest docs are published to https://qayasoftware.github.io/sdk/logging/

```zig
const std = @import("std");
const logging = @import("logging");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logging.logFn(.{
        .level = .info,
        .file = .{ .target = .{ .directory = "logs" }, .keep = 10 },
        .memory = 16 * 1024,
    }),
};

pub const panic = std.debug.FullPanic(logging.panic);

const render = std.log.scoped(.render);

pub fn main() !void {
    render.info("loaded {d} meshes", .{12});
    logging.setLevel(.render, .debug);
    render.debug("shown now", .{});
}
```

```
+   0.000s INF render: loaded 12 meshes
+   0.000s DBG render: shown now
```

## Sinks

Each is configured at compile time, in `Config`:

| Sink | | Default |
|---|---|---|
| `terminal` | stderr, a line at a time, coordinated with `std.debug.print`. Colored when stderr shows colors and `NO_COLOR` is unset; `.color = .always` or `.never` decides instead | on, `.pretty` |
| `file` | `.target = .{ .path = "game.log" }` for one file, or `.{ .directory = "logs" }` for a file each run, named by the date and time in UTC | off, `.detailed` |
| `memory` | a ring of recent lines, for `writeRecent` in a crash report or console | off |

A file sink writes through its own buffer, 64 KiB unless `buffer` says otherwise. The buffer is written out:
- at once for records at or above `flush_level` (warnings and errors),
- otherwise once `flush_interval_ms` has passed (a second),
- when it fills,
- and on `flush()` or a panic.

With `max_bytes` set, the file is rotated once it gets that big. A path rotates to `game.log.1`, `game.log.2` and so on, and a directory starts a new file. Either way, only the newest `keep` files are kept.

Leave the target out and call `setFile` when the place for logs is known at runtime, such as a per-user data directory. What was logged before is kept in the buffer and written there.

Every sink takes a `Format`:
- **`.text`**, with `Decorations`.
- **`.json`**: one object per line, with every field of the record and strings escaped.
- **`.custom`**: your own function that writes a `Record`.

## Decorations

A text line is the message after the parts you ask for, in this order:

| Part | Options |
|---|---|
| `time` | `.none`, `.elapsed` (`+   1.234s`), `.clock` (`14:03:22.123` UTC), `.date_time` (`2026-10-30 14:03:22.123` UTC), `.unix` |
| `level` | `.none`, `.word` (`warning`, padded), `.short` (`WRN`), `.letter` (`W`) |
| `thread` | the name from `nameThread`, or the thread's number: `[render]`, `[#3]` |
| `frame` | the frame from `setFrame`: `f1234` |
| `scope` | `render:`; std.log's default scope is left out |

Presets are `.pretty` (time since start, short level, scope), `.compact` (letter and scope), `.detailed` (date and time, level, thread, frame, scope) and `.plain` (the message alone). A terminal's `Theme` gives each level a color and dims the rest.

## Levels

`std_options.log_level` and `log_scope_levels` still decide what is compiled in. Within that, the levels can change at runtime:
- **Default level:** starts at `Config.level`; `setDefaultLevel` changes it.
- **One scope:** `setLevel(.render, .debug)`.
- **By name:** `setLevelByName("render", .debug)`, as a console command would. A scope named before it has logged gets its level when it first does.
- **Listing scopes:** `scopeNames` lists the scopes seen so far, for completing names in a console.

## For engines

- **Frames and threads:** `setFrame(n)` stamps records with the frame, and `nameThread("render")` names the calling thread.
- **Collapsing repeats:** a record identical to the one before it is counted rather than written. The count comes out as one line, `(repeated 59 more times)`, when something else is logged, once a second for a message that never stops, and on `flush()`.
- **Spam control:** `logging.once(.warn, .audio, "no device", .{})` logs the first time only. `logging.throttled(1000, .warn, .render, "slow frame {d}", .{n})` logs at most once a second and says how many it left out.
- **Timers:** `const timer = logging.Timer.start();` and later `timer.log(.info, .loader, "loaded {s}", .{name})` logs `loaded level.zon (12.3 ms)`.
- **Listeners:**
  - A `Listener` hears every record, for an in-game console or an editor's log panel. Embed it in your own struct and find that again with `@fieldParentPtr`.
  - Listeners are called with the lock held, so keep them quick.
  - What a listener logs reaches the sinks but no listener.
- **Recent lines:** `writeRecent(writer, 50)` writes the last lines kept in memory.
- **Panics:** `logging.panic`, used as `pub const panic = std.debug.FullPanic(logging.panic)`, writes the panic to the file and to listeners, writes every buffer out, then panics as std.debug does.
- **Stats:** `stats()` counts the records written and collapsed, the bytes dropped, and the writes that failed. Logging never stops your program over a failed write.

## Threads and speed

The message is formatted once, into a buffer on the logging thread's stack (`message_buffer`, 2 KiB), before the lock is taken. The lock only covers writing the record to the sinks; a thread that finds it taken spins briefly before sleeping.

A message longer than the buffer is formatted again under the lock, into `overflow_buffer` (64 KiB). Anything beyond that is cut off and marked `... [truncated]`.

A record that the runtime level leaves out costs about a nanosecond: a few relaxed atomic loads.

The logger takes its lock and then stderr's, so don't log while holding `std.debug.lockStderr`: a thread doing that can deadlock with another one that is logging.

`zig build logging-performance -Doptimize=ReleaseFast`, on an Intel i7 12700F:

```
left out by the runtime level                  1000000       0.9 ns/record   1109053201 records/s
memory ring, compact                           1000000     127.3 ns/record      7855202 records/s
memory ring, detailed (date, thread, frame)    1000000     175.4 ns/record      5700927 records/s
the same record again, collapsed               1000000      38.0 ns/record     26291564 records/s
file, detailed text, 64 KiB buffer             1000000     197.5 ns/record      5062044 records/s
file, json                                     1000000     317.2 ns/record      3152244 records/s
listener only                                  1000000      90.6 ns/record     11031483 records/s

memory ring, 1 tasks at once                   1000000      76.6 ns/record     13063120 records/s
memory ring, 2 tasks at once                   1000000     171.5 ns/record      5831434 records/s
memory ring, 4 tasks at once                   1000000     216.5 ns/record      4618560 records/s
memory ring, 8 tasks at once                   1000000     352.0 ns/record      2841187 records/s
```

The benchmarks log `frame {d} drew {d} meshes in {d:.2} ms`. The multi-task rows log a shorter message, and their throughput is shared by every task writing through the one lock.

## More than one logger

`logFn(config)` is `Logger(config).log`. A program can make other loggers too, such as a JSON one for a tool, and call their `log` directly. Each has its own `flush`, `writeRecent`, `setFile`, `once` and `throttled`. The module-level `flush`, `writeRecent` and `setFile` reach every logger that has logged.

## Examples

```sh
zig build logging-basic          # scopes, styles, runtime levels, repeats, JSON
zig build logging-engine         # frames, thread names, a console listener, once/throttled, a timer, a log directory, recent lines
zig build logging-performance -Doptimize=ReleaseFast
```
