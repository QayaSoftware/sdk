# Qaya SDK

Libraries for making games and applications in Zig. Each one is small, takes
on as few dependencies as it can, and can be used without the rest.

| Library               | What it is                                                   |
| --------------------- | ------------------------------------------------------------ |
| [`limn`](libs/limn)   | Physically based realtime renderer on Vulkan 1.3             |
| [`slime`](libs/slime) | Entity component system with prefabs and parallel scheduling |

Examples for limn are in [QayaSoftware/limn-examples](https://github.com/QayaSoftware/limn-examples).

## Using it

```sh
zig fetch --save git+https://github.com/QayaSoftware/sdk
```

```zig
const qaya = b.dependency("qaya", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("limn", qaya.module("limn"));
exe.root_module.addImport("slime", qaya.module("slime"));
```

Every library is on by default. Turn off the ones you do not use, and their
dependencies are never fetched: `b.dependency("qaya", .{ .limn = false })`.

A library's own build functions, such as limn's `addShaders`, come from its
`build.zig` through the SDK's, with the library built from your build's
options:

```zig
const qaya_build = @import("qaya");

pub fn build(b: *std.Build) void {
    const limn_build = b.lazyImport(qaya_build, "limn") orelse return;
    const qaya = b.dependency("qaya", .{ .limn = false, .slime = false });
    const limn = qaya.builder.lazyDependency("limn", .{ .target = target, .optimize = optimize }) orelse return;
    exe.root_module.addImport("limn", limn.module("limn"));
    limn_build.addShaders(b, limn, exe.root_module, &.{ ... });
}
```

## Layout

Each library under `libs/` is a package of its own, with its own `build.zig`
and `build.zig.zon`, and is built and tested on its own:

```sh
cd libs/limn && zig build test
```

From the root, `zig build test` and `zig build check` run every library's.

## License

Apache-2.0; see [`LICENSE`](LICENSE). Bundled third-party work keeps its own
terms, listed in each library's README.
