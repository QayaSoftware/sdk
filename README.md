# Qaya SDK

Low-dependency Zig libraries for games and applications.

| Library | |
| --- | --- |
| [limn](libs/limn) | A high performance physically based renderer written in Zig using Vulkan |
| [slime](libs/slime) | An entity component system in Zig |
| [commands](libs/commands) | A Brigadier-style command graph, parsed without allocating or locking |
| [cli](libs/cli) | Command line arguments and environment variables parsed into a struct |
| [logging](libs/logging) | A `std.log` backend for terminals, log files and engines |
| [keybinds](libs/keybinds) | Virtual keybindings: chords, sequences, gestures, axes and rebinding |

Requires Zig 0.17.

```sh
zig fetch --save git+https://github.com/QayaSoftware/sdk
```

Each library is a module named after it:

```zig
const qaya = b.dependency("qaya", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("slime", qaya.module("slime"));
exe.root_module.addImport("logging", qaya.module("logging"));
```

Examples run with `zig build <library>-<example>`, such as `zig build keybinds-game`; each library's README lists its own. limn's examples are in [limn-examples](https://github.com/QayaSoftware/limn-examples).

Apache-2.0; see [LICENSE](LICENSE).
