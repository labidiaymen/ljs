const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "lumen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lumen.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the Lumen compiler");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run compiler tests");
    test_step.dependOn(&run_exe_tests.step);

    const fmt_targets = [_][]const u8{
        "build.zig",
        "src/lumen.zig",
        "src/lumen_ast.zig",
        "src/lumen_diag.zig",
        "src/lumen_lexer.zig",
        "src/lumen_types.zig",
        "src/lumen_compiler.zig",
    };

    const fmt = b.addSystemCommand(&[_][]const u8{ "zig", "fmt" });
    fmt.addArgs(&fmt_targets);
    const fmt_step = b.step("fmt", "Format compiler sources with zig fmt");
    fmt_step.dependOn(&fmt.step);

    const fmt_check = b.addSystemCommand(&[_][]const u8{ "zig", "fmt", "--check" });
    fmt_check.addArgs(&fmt_targets);
    const fmt_check_step = b.step("fmt-check", "Verify compiler source formatting");
    fmt_check_step.dependOn(&fmt_check.step);

    const lint_step = b.step("lint", "Run compiler lint checks");
    lint_step.dependOn(&fmt_check.step);
}
