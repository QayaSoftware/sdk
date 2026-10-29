# Qaya SDK

Low-dependency Zig libraries for games and applications.

![Sponza, path traced](.github/images/rtx_path.png)

| ![meadow](.github/images/meadow.png) | ![world](.github/images/world.png) | ![water](.github/images/water.png) |
| :-: | :-: | :-: |

| Library | |
| --- | --- |
| [limn](libs/limn) | A high performance physically based renderer written in Zig using Vulkan |
| [slime](libs/slime) | An entity component system in Zig |

Requires Zig 0.16.

```sh
zig fetch --save git+https://github.com/QayaSoftware/sdk
```

```zig
const qaya = b.dependency("qaya", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("limn", qaya.module("limn"));
exe.root_module.addImport("slime", qaya.module("slime"));
```

limn's examples are in [limn-examples](https://github.com/QayaSoftware/limn-examples).

Apache-2.0; see [LICENSE](LICENSE).
