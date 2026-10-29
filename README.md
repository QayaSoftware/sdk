# Qaya SDK

Libraries for making games and applications in Zig. Each one is small, takes
on as few dependencies as it can, and can be used without the rest.

| Library                   | What it is                                                     | Mirror                                            |
| ------------------------- | -------------------------------------------------------------- | ------------------------------------------------- |
| [`limn`](libs/limn)       | Physically based realtime renderer on Vulkan 1.3               | [Tofaa2/limn](https://github.com/Tofaa2/limn)     |
| [`slime`](libs/slime)     | Entity component system with prefabs and parallel scheduling   | [Tofaa2/slime](https://github.com/Tofaa2/slime)   |

Examples for limn are in [QayaSoftware/limn-examples](https://github.com/QayaSoftware/limn-examples).

## Using it

All of the SDK, as one package:

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

Or one library alone, from its mirror:

```sh
zig fetch --save git+https://github.com/Tofaa2/slime
```

## Layout

Each library under `libs/` is a package of its own, with its own `build.zig`
and `build.zig.zon`, and is built and tested on its own:

```sh
cd libs/limn && zig build test
```

From the root, `zig build test` and `zig build check` run every library's.

## Mirrors

Development happens here. Every push to `master` splits each `libs/<name>`
out with `git subtree split` and pushes it to that library's mirror, which
is read-only: open issues and pull requests here.

A tag `<name>-v<version>`, such as `limn-v0.1.5`, is pushed to the mirror as
`v<version>`.

## License

Apache-2.0; see [`LICENSE`](LICENSE). Bundled third-party work keeps its own
terms, listed in each library's README.
