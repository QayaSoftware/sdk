//! Writes the libc file for an Android target from the NDK's Bionic sysroot.
//!
//!   android_libc <sysroot> <triple> <api level> <libc file>
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var arguments = try init.minimal.args.iterateAllocator(arena);
    _ = arguments.next();
    const given = arguments.next() orelse return error.MissingArgument;
    const triple = arguments.next() orelse return error.MissingArgument;
    const api = arguments.next() orelse return error.MissingArgument;
    const output = arguments.next() orelse return error.MissingArgument;

    const sysroot = try std.Io.Dir.cwd().realPathFileAlloc(init.io, given, arena);
    const crt = try arena.print("{s}/usr/lib/{s}/{s}", .{ sysroot, triple, api });
    const text = try arena.print("include_dir={s}/usr/include\nsys_include_dir={s}/usr/include/{s}\ncrt_dir={s}\nmsvc_lib_dir=\nkernel32_lib_dir=\ncc_dir={s}\ndarwin_sdk_dir=\n", .{ sysroot, sysroot, triple, crt, crt });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output, .data = text });
}
