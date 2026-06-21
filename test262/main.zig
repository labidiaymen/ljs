//! `ljs-test262` — the Test262 conformance harness CLI (run via `zig build test262 -- ...`).
//! See specs/001-test262-harness/contracts/cli.md.
const std = @import("std");
const Io = std.Io;
const ljs = @import("ljs");
const runner = @import("runner.zig");
const rep = @import("report.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    // PERF (spec 111): differential-test the bytecode VM by running the suite with `LJS_VM=1`.
    if (init.environ_map.get("LJS_VM")) |v| if (std.mem.eql(u8, v, "1")) ljs.setVmEnabled(true);
    // PERF (spec 112): differential-test the native JIT by running the suite with `LJS_JIT=1`.
    if (init.environ_map.get("LJS_JIT")) |v| if (std.mem.eql(u8, v, "1")) ljs.setJitEnabled(true);

    var out_buf: [8192]u8 = undefined;
    var out_fw: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_fw.interface;
    var err_buf: [2048]u8 = undefined;
    var err_fw: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const err = &err_fw.interface;

    var opts: runner.Options = .{ .path = "" };
    var baseline_path: ?[]const u8 = null;
    var update_baseline_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--path")) {
            i += 1;
            if (i < args.len) opts.path = args[i];
        } else if (std.mem.eql(u8, a, "--harness-dir")) {
            i += 1;
            if (i < args.len) opts.harness_dir = args[i];
        } else if (std.mem.eql(u8, a, "--mode")) {
            i += 1;
            if (i < args.len) opts.mode_filter = parseMode(args[i]);
        } else if (std.mem.eql(u8, a, "--step-limit")) {
            i += 1;
            if (i < args.len) opts.step_limit = std.fmt.parseInt(u64, args[i], 10) catch opts.step_limit;
        } else if (std.mem.eql(u8, a, "--baseline")) {
            i += 1;
            if (i < args.len) baseline_path = args[i];
        } else if (std.mem.eql(u8, a, "--update-baseline")) {
            i += 1;
            if (i < args.len) update_baseline_path = args[i];
        }
    }

    if (opts.path.len == 0) {
        try err.writeAll("usage: ljs-test262 --path <dir> [--mode strict|sloppy] [--harness-dir <dir>] [--step-limit N] [--baseline <file>] [--update-baseline <file>]\n");
        try err.flush();
        std.process.exit(2);
    }

    var report: rep.Report = .{ .arena = arena };
    runner.run(io, arena, opts, &report) catch |e| switch (e) {
        error.OpenFailed => {
            try err.print("setup error: cannot open path '{s}'\n", .{opts.path});
            try err.print("hint: the Test262 corpus is gitignored — fetch it first with `zig build vendor`\n", .{});
            try err.print("      (or `./scripts/vendor-test262.sh test/language`), then re-run.\n", .{});
            try err.flush();
            std.process.exit(2);
        },
        error.OutOfMemory => return e,
    };

    try report.writeSummary(out, opts.path);
    try report.writeDetail(out);

    if (update_baseline_path) |bp| {
        const bytes = try report.baselineBytes(arena);
        Io.Dir.cwd().writeFile(io, .{ .sub_path = bp, .data = bytes }) catch {
            try err.print("setup error: cannot write baseline '{s}'\n", .{bp});
            try err.flush();
            std.process.exit(2);
        };
        try out.print("  baseline written: {s}\n", .{bp});
        try out.flush();
        return;
    }

    if (baseline_path) |bp| {
        const bytes = Io.Dir.cwd().readFileAlloc(io, bp, arena, .limited(8 << 20)) catch {
            try err.print("setup error: cannot read baseline '{s}'\n", .{bp});
            try err.flush();
            std.process.exit(2);
        };
        const base_ids = try rep.parseIds(arena, bytes);
        const regs = try report.regressionsVs(arena, base_ids);
        if (regs.len > 0) {
            try out.print("  REGRESSION: {d} test(s) no longer pass:\n", .{regs.len});
            for (regs) |id| try out.print("    {s}\n", .{id});
            try out.flush();
            std.process.exit(1);
        }
        try out.writeAll("  conformance: ok (no regression vs baseline)\n");
    }

    try out.flush();
}

fn parseMode(s: []const u8) ?rep.Mode {
    if (std.mem.eql(u8, s, "strict")) return .strict;
    if (std.mem.eql(u8, s, "sloppy")) return .sloppy;
    return null; // "both"/unknown → run both applicable modes
}

test {
    _ = @import("metadata.zig");
    _ = @import("report.zig");
    _ = @import("runner.zig");
}
