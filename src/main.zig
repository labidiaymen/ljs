//! ljs command-line interface. See specs/001-test262-harness/contracts/cli.md.
//!   ljs eval "<source>"   evaluate a source string
//!   ljs run <file>        evaluate a source file
const std = @import("std");
const Io = std.Io;
const ljs = @import("ljs");

/// HOST (spec 100): the OS process id, best-effort per platform (0 if unavailable). The branch is
/// chosen at comptime (`builtin.os.tag` is comptime-known) so only the matching platform call is
/// analyzed — `std.os.linux.getpid` is never compiled on Windows.
fn hostPid() i64 {
    const tag = @import("builtin").os.tag;
    if (tag == .windows) return @intCast(std.os.windows.GetCurrentProcessId());
    if (tag == .linux) return @intCast(std.os.linux.getpid());
    if (tag.isDarwin() or tag == .freebsd or tag == .openbsd or tag == .netbsd or tag == .dragonfly)
        return @intCast(std.c.getpid());
    return 0;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var out_fw: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_fw.interface;

    var err_buf: [4096]u8 = undefined;
    var err_fw: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const err = &err_fw.interface;

    if (args.len < 3) {
        try err.writeAll("usage: ljs <eval|run> <source|file>\n");
        try err.flush();
        std.process.exit(2);
    }

    const cmd = args[1];
    const arg = args[2];

    const source: []const u8 = if (std.mem.eql(u8, cmd, "eval"))
        arg
    else if (std.mem.eql(u8, cmd, "run"))
        std.Io.Dir.cwd().readFileAlloc(io, arg, arena, .limited(16 * 1024 * 1024)) catch {
            try err.print("error: cannot read file {s}\n", .{arg});
            try err.flush();
            std.process.exit(2);
        }
    else {
        try err.print("unknown command: {s}\n", .{cmd});
        try err.flush();
        std.process.exit(2);
    };

    // HOST (spec 100): build the `process` context — argv = [execPath, scriptPath, ...extra]; env = a
    // snapshot of the OS environment; cwd via the std Io API; pid best-effort. Both `run` and `eval`
    // install the host globals (so `console.log`/`process` work in either); only `run` runs the loop.
    const is_run = std.mem.eql(u8, cmd, "run");
    const ctx = blk: {
        // argv0 = the ljs executable name (args[0]); the "script" slot is the file path for `run`, or
        // the exe name again for `eval` (no script file). Extra args (args[3..]) trail.
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        const exe0: []const u8 = if (args.len > 0) args[0] else "ljs";
        try argv.append(arena, exe0);
        if (is_run) try argv.append(arena, arg) else try argv.append(arena, exe0);
        if (args.len > 3) for (args[3..]) |a| try argv.append(arena, a);

        var env_pairs: std.ArrayListUnmanaged([2][]const u8) = .empty;
        var it = init.environ_map.iterator();
        while (it.next()) |entry| try env_pairs.append(arena, .{ entry.key_ptr.*, entry.value_ptr.* });

        const cwd = std.process.currentPathAlloc(io, arena) catch "";
        // HOST (spec 102): the entry script's absolute path + directory (for `require`/`__filename`/
        // `__dirname`). Only meaningful for `run` (a real file); `eval` has no script file.
        var script_path: []const u8 = "";
        var script_dir: []const u8 = "";
        if (is_run) {
            script_path = if (std.fs.path.isAbsolute(arg))
                arg
            else if (cwd.len > 0)
                (std.fs.path.resolve(arena, &.{ cwd, arg }) catch arg)
            else
                arg;
            script_dir = std.fs.path.dirname(script_path) orelse cwd;
        }
        break :blk ljs.HostCtx{ .argv = argv.items, .env_pairs = env_pairs.items, .cwd = cwd, .pid = hostPid(), .script_path = script_path, .script_dir = script_dir };
    };

    const result = if (is_run)
        try ljs.runHost(arena, source, .sloppy, ctx, out, err)
    else
        try ljs.evalHost(arena, source, .sloppy, ctx, out, err);
    switch (result) {
        .normal => |v| {
            // `run` is for side effects (console.log) — don't echo the script's completion value;
            // `eval` echoes it (REPL-style).
            if (!is_run) {
                try v.writeDisplay(out);
                try out.writeAll("\n");
            }
            try out.flush();
        },
        .thrown => |v| {
            try err.writeAll("Uncaught ");
            try v.writeDisplay(err);
            try err.writeAll("\n");
            try err.flush();
            std.process.exit(1);
        },
        .syntax_error => |m| {
            try err.print("SyntaxError: {s}\n", .{m});
            try err.flush();
            std.process.exit(1);
        },
        .step_limit => {
            try err.writeAll("RangeError: step limit exceeded\n");
            try err.flush();
            std.process.exit(1);
        },
    }
}
