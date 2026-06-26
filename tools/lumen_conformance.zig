const std = @import("std");

const Manifest = struct {
    feature: []const u8,
    cases: []Case,
};

const Case = struct {
    id: []const u8,
    source: []const u8,
    phase: []const u8,
    expect: Expect,
};

const Expect = struct {
    stdout: ?[]const u8 = null,
    diagnostic: ?[]const u8 = null,
    inferredTypes: ?std.json.Value = null,
    acceptedTypes: ?[]const []const u8 = null,
};

const Stats = struct {
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
};

fn usage() void {
    std.debug.print("usage: lumen-conformance <manifest.json> <lumen-binary>\n", .{});
}

fn manifestDir(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}

fn resolveSource(arena: std.mem.Allocator, manifest_path: []const u8, source: []const u8) ![]const u8 {
    return std.fs.path.resolve(arena, &.{ manifestDir(manifest_path), source });
}

fn trimTrailingNewlines(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\r\n");
}

fn exeNameForSource(arena: std.mem.Allocator, source_path: []const u8) ![]const u8 {
    const stem = std.fs.path.stem(source_path);
    if (@import("builtin").os.tag == .windows) {
        return std.fmt.allocPrint(arena, "{s}.exe", .{stem});
    }
    return arena.dupe(u8, stem);
}

fn removeGenerated(io: std.Io, source_path: []const u8, exe_name: []const u8) void {
    const stem = std.fs.path.stem(source_path);
    var zig_name_buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&zig_name_buf, "{s}.zig", .{stem})) |zig_name| {
        std.Io.Dir.cwd().deleteFile(io, zig_name) catch {};
    } else |_| {}
    std.Io.Dir.cwd().deleteFile(io, exe_name) catch {};
}

fn termSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn runProcess(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .reserve_amount = 4096,
    });
}

fn checkCompileRun(arena: std.mem.Allocator, io: std.Io, case: Case, source_path: []const u8, lumen_bin: []const u8) !bool {
    const compile = try runProcess(arena, io, &.{ lumen_bin, "compile", source_path });
    if (!termSucceeded(compile.term)) {
        std.debug.print("FAIL {s}: compile failed\n{s}\n", .{ case.id, compile.stderr });
        return false;
    }

    const exe_name = try exeNameForSource(arena, source_path);
    defer removeGenerated(io, source_path, exe_name);

    const exe_path = try std.fmt.allocPrint(arena, "./{s}", .{exe_name});
    const run = try runProcess(arena, io, &.{exe_path});
    if (!termSucceeded(run.term)) {
        std.debug.print("FAIL {s}: executable failed\n{s}\n", .{ case.id, run.stderr });
        return false;
    }

    const expected = case.expect.stdout orelse "";
    const actual = trimTrailingNewlines(run.stderr);
    if (!std.mem.eql(u8, actual, expected)) {
        std.debug.print("FAIL {s}: stdout mismatch\nexpected:\n{s}\nactual:\n{s}\n", .{ case.id, expected, actual });
        return false;
    }
    return true;
}

fn checkDiagnostics(arena: std.mem.Allocator, io: std.Io, case: Case, source_path: []const u8, lumen_bin: []const u8) !bool {
    const compile = try runProcess(arena, io, &.{ lumen_bin, "compile", source_path });
    const exe_name = try exeNameForSource(arena, source_path);
    defer removeGenerated(io, source_path, exe_name);

    if (termSucceeded(compile.term)) {
        std.debug.print("FAIL {s}: expected diagnostic but compile succeeded\n", .{case.id});
        return false;
    }
    const expected = case.expect.diagnostic orelse {
        std.debug.print("FAIL {s}: diagnostics case missing expected diagnostic\n", .{case.id});
        return false;
    };
    if (std.mem.indexOf(u8, compile.stderr, expected) == null) {
        std.debug.print("FAIL {s}: diagnostic mismatch, expected {s}\nactual:\n{s}\n", .{ case.id, expected, compile.stderr });
        return false;
    }
    return true;
}

fn checkStatic(arena: std.mem.Allocator, io: std.Io, case: Case, source_path: []const u8, lumen_bin: []const u8) !bool {
    const compile = try runProcess(arena, io, &.{ lumen_bin, "compile", source_path });
    const exe_name = try exeNameForSource(arena, source_path);
    defer removeGenerated(io, source_path, exe_name);

    if (!termSucceeded(compile.term)) {
        std.debug.print("FAIL {s}: static compile failed\n{s}\n", .{ case.id, compile.stderr });
        return false;
    }
    return true;
}

fn runCase(arena: std.mem.Allocator, io: std.Io, manifest_path: []const u8, case: Case, lumen_bin: []const u8) !?bool {
    const source_path = try resolveSource(arena, manifest_path, case.source);
    if (std.mem.eql(u8, case.phase, "compile-run")) {
        return try checkCompileRun(arena, io, case, source_path, lumen_bin);
    }
    if (std.mem.eql(u8, case.phase, "diagnostics")) {
        return try checkDiagnostics(arena, io, case, source_path, lumen_bin);
    }
    if (std.mem.eql(u8, case.phase, "static")) {
        return try checkStatic(arena, io, case, source_path, lumen_bin);
    }
    std.debug.print("SKIP {s}: unsupported phase {s}\n", .{ case.id, case.phase });
    return null;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        usage();
        std.process.exit(2);
    }

    const manifest_path = args[1];
    const lumen_bin = args[2];
    const manifest_json = try std.Io.Dir.cwd().readFileAlloc(init.io, manifest_path, arena, .limited(4 * 1024 * 1024));
    const manifest = try std.json.parseFromSliceLeaky(Manifest, arena, manifest_json, .{ .ignore_unknown_fields = true });

    var stats: Stats = .{};
    std.debug.print("conformance: {s} ({d} cases)\n", .{ manifest.feature, manifest.cases.len });
    for (manifest.cases) |case| {
        const result = runCase(arena, init.io, manifest_path, case, lumen_bin) catch |err| {
            stats.failed += 1;
            std.debug.print("FAIL {s}: {s}\n", .{ case.id, @errorName(err) });
            continue;
        };
        if (result) |passed| {
            if (passed) {
                stats.passed += 1;
                std.debug.print("PASS {s}\n", .{case.id});
            } else {
                stats.failed += 1;
            }
        } else {
            stats.skipped += 1;
        }
    }

    std.debug.print("conformance result: {d} passed, {d} failed, {d} skipped\n", .{ stats.passed, stats.failed, stats.skipped });
    if (stats.failed != 0) std.process.exit(1);
}
