//! `ljs-test262` — the Test262 conformance harness CLI (run via `zig build test262 -- ...`).
//! See specs/001-test262-harness/contracts/cli.md.
const std = @import("std");
const Io = std.Io;
const runner = @import("runner.zig");
const rep = @import("report.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var out_buf: [8192]u8 = undefined;
    var out_fw: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_fw.interface;
    var err_buf: [2048]u8 = undefined;
    var err_fw: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const err = &err_fw.interface;

    var opts: runner.Options = .{ .path = "" };
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
        }
    }

    if (opts.path.len == 0) {
        try err.writeAll("usage: ljs-test262 --path <dir> [--mode strict|sloppy] [--harness-dir <dir>] [--step-limit N]\n");
        try err.flush();
        std.process.exit(2);
    }

    var report: rep.Report = .{ .arena = arena };
    runner.run(io, arena, opts, &report) catch |e| switch (e) {
        error.OpenFailed => {
            try err.print("setup error: cannot open path '{s}'\n", .{opts.path});
            try err.flush();
            std.process.exit(2);
        },
        error.OutOfMemory => return e,
    };

    try report.writeSummary(out, opts.path);
    try report.writeDetail(out);
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
