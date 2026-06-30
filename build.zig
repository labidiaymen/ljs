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
    // The canonical ambient declarations live at the repo root (`/lumen.d.ts`)
    // so editors/tsc pick them up. `lumen init` embeds them via this anonymous
    // import, keeping a single source of truth (the file is outside `src/`, so a
    // bare `@embedFile("../lumen.d.ts")` is rejected by the package boundary).
    exe.root_module.addAnonymousImport("lumen.d.ts", .{
        .root_source_file = b.path("lumen.d.ts"),
    });
    b.installArtifact(exe);

    const conformance_runner = b.addExecutable(.{
        .name = "lumen-conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/lumen_conformance.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

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
        "src/lumen_check.zig",
        "src/lumen_diag.zig",
        "src/lumen_lexer.zig",
        "src/lumen_types.zig",
        "src/lumen_compiler.zig",
        "src/lumen_parser.zig",
        "src/lumen_opt.zig",
        "src/regex_rt.zig",
        "src/regex_specialize.zig",
        "tools/lumen_conformance.zig",
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

    const conformance_cmd = b.addRunArtifact(conformance_runner);
    conformance_cmd.step.dependOn(b.getInstallStep());
    conformance_cmd.addArg("specs/001-typescript-to-zig-native/conformance/manifest.json");
    conformance_cmd.addArg("zig-out/bin/lumen");

    const conformance_cmd_002 = b.addRunArtifact(conformance_runner);
    conformance_cmd_002.step.dependOn(b.getInstallStep());
    conformance_cmd_002.addArg("specs/002-numeric-literals-lexer/conformance/manifest.json");
    conformance_cmd_002.addArg("zig-out/bin/lumen");

    const conformance_cmd_003 = b.addRunArtifact(conformance_runner);
    conformance_cmd_003.step.dependOn(b.getInstallStep());
    conformance_cmd_003.addArg("specs/003-iteration-enums-ops/conformance/manifest.json");
    conformance_cmd_003.addArg("zig-out/bin/lumen");

    const conformance_cmd_004 = b.addRunArtifact(conformance_runner);
    conformance_cmd_004.step.dependOn(b.getInstallStep());
    conformance_cmd_004.addArg("specs/004-nullability/conformance/manifest.json");
    conformance_cmd_004.addArg("zig-out/bin/lumen");

    const conformance_cmd_005 = b.addRunArtifact(conformance_runner);
    conformance_cmd_005.step.dependOn(b.getInstallStep());
    conformance_cmd_005.addArg("specs/005-unions-destructuring-templates/conformance/manifest.json");
    conformance_cmd_005.addArg("zig-out/bin/lumen");

    const conformance_cmd_006 = b.addRunArtifact(conformance_runner);
    conformance_cmd_006.step.dependOn(b.getInstallStep());
    conformance_cmd_006.addArg("specs/006-functions-closures/conformance/manifest.json");
    conformance_cmd_006.addArg("zig-out/bin/lumen");

    const conformance_cmd_007 = b.addRunArtifact(conformance_runner);
    conformance_cmd_007.step.dependOn(b.getInstallStep());
    conformance_cmd_007.addArg("specs/007-defer/conformance/manifest.json");
    conformance_cmd_007.addArg("zig-out/bin/lumen");

    const conformance_cmd_008 = b.addRunArtifact(conformance_runner);
    conformance_cmd_008.step.dependOn(b.getInstallStep());
    conformance_cmd_008.addArg("specs/008-test/conformance/manifest.json");
    conformance_cmd_008.addArg("zig-out/bin/lumen");

    const conformance_cmd_009 = b.addRunArtifact(conformance_runner);
    conformance_cmd_009.step.dependOn(b.getInstallStep());
    conformance_cmd_009.addArg("specs/009-ffi/conformance/manifest.json");
    conformance_cmd_009.addArg("zig-out/bin/lumen");

    const conformance_cmd_010 = b.addRunArtifact(conformance_runner);
    conformance_cmd_010.step.dependOn(b.getInstallStep());
    conformance_cmd_010.addArg("specs/010-classes/conformance/manifest.json");
    conformance_cmd_010.addArg("zig-out/bin/lumen");

    const conformance_cmd_013 = b.addRunArtifact(conformance_runner);
    conformance_cmd_013.step.dependOn(b.getInstallStep());
    conformance_cmd_013.addArg("specs/013-array-methods/conformance/manifest.json");
    conformance_cmd_013.addArg("zig-out/bin/lumen");

    const conformance_cmd_014 = b.addRunArtifact(conformance_runner);
    conformance_cmd_014.step.dependOn(b.getInstallStep());
    conformance_cmd_014.addArg("specs/014-string-methods/conformance/manifest.json");
    conformance_cmd_014.addArg("zig-out/bin/lumen");

    const conformance_cmd_015 = b.addRunArtifact(conformance_runner);
    conformance_cmd_015.step.dependOn(b.getInstallStep());
    conformance_cmd_015.addArg("specs/015-multi-symbol-modules/conformance/manifest.json");
    conformance_cmd_015.addArg("zig-out/bin/lumen");

    const conformance_cmd_016 = b.addRunArtifact(conformance_runner);
    conformance_cmd_016.step.dependOn(b.getInstallStep());
    conformance_cmd_016.addArg("specs/016-generics/conformance/manifest.json");
    conformance_cmd_016.addArg("zig-out/bin/lumen");

    const conformance_cmd_017 = b.addRunArtifact(conformance_runner);
    conformance_cmd_017.step.dependOn(b.getInstallStep());
    conformance_cmd_017.addArg("specs/017-type-aliases-unions/conformance/manifest.json");
    conformance_cmd_017.addArg("zig-out/bin/lumen");

    const conformance_cmd_018 = b.addRunArtifact(conformance_runner);
    conformance_cmd_018.step.dependOn(b.getInstallStep());
    conformance_cmd_018.addArg("specs/018-class-inheritance-members/conformance/manifest.json");
    conformance_cmd_018.addArg("zig-out/bin/lumen");

    const conformance_cmd_019 = b.addRunArtifact(conformance_runner);
    conformance_cmd_019.step.dependOn(b.getInstallStep());
    conformance_cmd_019.addArg("specs/019-error-handling/conformance/manifest.json");
    conformance_cmd_019.addArg("zig-out/bin/lumen");

    const conformance_cmd_020 = b.addRunArtifact(conformance_runner);
    conformance_cmd_020.step.dependOn(b.getInstallStep());
    conformance_cmd_020.addArg("specs/020-map-set-tuples/conformance/manifest.json");
    conformance_cmd_020.addArg("zig-out/bin/lumen");

    const conformance_cmd_021 = b.addRunArtifact(conformance_runner);
    conformance_cmd_021.step.dependOn(b.getInstallStep());
    conformance_cmd_021.addArg("specs/021-spread-rest-defaults/conformance/manifest.json");
    conformance_cmd_021.addArg("zig-out/bin/lumen");

    const conformance_cmd_022 = b.addRunArtifact(conformance_runner);
    conformance_cmd_022.step.dependOn(b.getInstallStep());
    conformance_cmd_022.addArg("specs/022-async-await/conformance/manifest.json");
    conformance_cmd_022.addArg("zig-out/bin/lumen");

    const conformance_cmd_023 = b.addRunArtifact(conformance_runner);
    conformance_cmd_023.step.dependOn(b.getInstallStep());
    conformance_cmd_023.addArg("specs/023-ffi-strings/conformance/manifest.json");
    conformance_cmd_023.addArg("zig-out/bin/lumen");

    const conformance_cmd_024 = b.addRunArtifact(conformance_runner);
    conformance_cmd_024.step.dependOn(b.getInstallStep());
    conformance_cmd_024.addArg("specs/024-ref-params/conformance/manifest.json");
    conformance_cmd_024.addArg("zig-out/bin/lumen");

    const conformance_cmd_025 = b.addRunArtifact(conformance_runner);
    conformance_cmd_025.step.dependOn(b.getInstallStep());
    conformance_cmd_025.addArg("specs/025-declare-ffi/conformance/manifest.json");
    conformance_cmd_025.addArg("zig-out/bin/lumen");

    const conformance_cmd_027 = b.addRunArtifact(conformance_runner);
    conformance_cmd_027.step.dependOn(b.getInstallStep());
    conformance_cmd_027.addArg("specs/027-using-disposables/conformance/manifest.json");
    conformance_cmd_027.addArg("zig-out/bin/lumen");

    const conformance_cmd_028 = b.addRunArtifact(conformance_runner);
    conformance_cmd_028.step.dependOn(b.getInstallStep());
    conformance_cmd_028.addArg("specs/028-test-fn/conformance/manifest.json");
    conformance_cmd_028.addArg("zig-out/bin/lumen");

    const conformance_step = b.step("conformance", "Run Lumen manifest conformance cases");
    conformance_step.dependOn(&conformance_cmd.step);
    conformance_step.dependOn(&conformance_cmd_010.step);
    conformance_step.dependOn(&conformance_cmd_013.step);
    conformance_step.dependOn(&conformance_cmd_014.step);
    conformance_step.dependOn(&conformance_cmd_015.step);
    conformance_step.dependOn(&conformance_cmd_016.step);
    conformance_step.dependOn(&conformance_cmd_017.step);
    conformance_step.dependOn(&conformance_cmd_018.step);
    conformance_step.dependOn(&conformance_cmd_019.step);
    conformance_step.dependOn(&conformance_cmd_020.step);
    conformance_step.dependOn(&conformance_cmd_021.step);
    conformance_step.dependOn(&conformance_cmd_022.step);
    conformance_step.dependOn(&conformance_cmd_023.step);
    conformance_step.dependOn(&conformance_cmd_024.step);
    conformance_step.dependOn(&conformance_cmd_025.step);
    conformance_step.dependOn(&conformance_cmd_027.step);
    conformance_step.dependOn(&conformance_cmd_028.step);
    conformance_step.dependOn(&conformance_cmd_002.step);
    conformance_step.dependOn(&conformance_cmd_003.step);
    conformance_step.dependOn(&conformance_cmd_004.step);
    conformance_step.dependOn(&conformance_cmd_005.step);
    conformance_step.dependOn(&conformance_cmd_006.step);
    conformance_step.dependOn(&conformance_cmd_007.step);
    conformance_step.dependOn(&conformance_cmd_008.step);
    conformance_step.dependOn(&conformance_cmd_009.step);
}
