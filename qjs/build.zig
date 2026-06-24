const std = @import("std");

// Build the QuickJS-embedded runtime: compile the quickjs-ng C engine with Zig's C compiler and
// link it into a Zig executable (the future host/runtime layer). See README.md.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // libxev — the I/O event loop (same pin as the ljs root package).
    const xev = b.dependency("xev", .{ .target = target, .optimize = optimize });
    mod.addImport("xev", xev.module("xev"));

    const cflags = [_][]const u8{
        "-std=c11",
        "-D_GNU_SOURCE",
        "-Wno-implicit-fallthrough",
        "-Wno-sign-compare",
        "-Wno-unused-parameter",
        "-Wno-unused-variable",
        "-Wno-unused-function",
        "-Wno-unused-but-set-variable",
    };
    // quickjs-ng engine: 4 core C files + headers (fetched by fetch.sh).
    mod.addIncludePath(b.path("vendor/quickjs-ng"));
    mod.addIncludePath(b.path("src"));
    mod.addCSourceFiles(.{
        .root = b.path("vendor/quickjs-ng"),
        .files = &.{ "quickjs.c", "libregexp.c", "libunicode.c", "dtoa.c" },
        .flags = &cflags,
    });
    // Our shim (value-macro wrappers).
    mod.addCSourceFile(.{ .file = b.path("src/qjs_shim.c"), .flags = &cflags });
    const exe = b.addExecutable(.{ .name = "qjs-run", .root_module = mod });

    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Build + run the QuickJS embed demo").dependOn(&run.step);
}
