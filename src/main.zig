//! ljs command-line interface. See specs/001-test262-harness/contracts/cli.md.
//!   ljs eval "<source>"   evaluate a source string
//!   ljs run <file>        evaluate a source file
const std = @import("std");
const Io = std.Io;
const ljs = @import("ljs");
const tjsc = @import("tjsc.zig");

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

/// Heuristic ESM-entry detection for a `.js`/extension-less file: does the source have a TOP-LEVEL
/// static `import`/`export` statement? A dynamic `import(...)` is valid in CommonJS and does NOT count
/// (it has no space/brace after `import`). Line-based + trim-left, so it ignores indentation and skips
/// `//` comments, `module.exports`, `exports.x`, `import_foo`, etc.
fn looksLikeEsm(source: []const u8) bool {
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimStart(u8, raw, " \t");
        if (std.mem.startsWith(u8, line, "export ") or std.mem.startsWith(u8, line, "export{") or std.mem.startsWith(u8, line, "export*")) return true;
        if (std.mem.startsWith(u8, line, "import ") or std.mem.startsWith(u8, line, "import{") or std.mem.startsWith(u8, line, "import*")) return true;
    }
    return false;
}

/// `ljs compile <file>`: lower a typed-JS file to Zig and compile it to a native binary via
/// `zig build-exe`. POC (spec 142) — not part of the engine.
fn compileCmd(arena: std.mem.Allocator, io: std.Io, path: []const u8, err: *std.Io.Writer) !void {
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch {
        try err.print("error: cannot read file {s}\n", .{path});
        return;
    };
    const zig_src = tjsc.compileToZig(arena, source) catch {
        try err.print("error: parse error in {s}\n", .{path});
        return;
    };
    const base = std.fs.path.stem(path);
    const zig_path = try std.fmt.allocPrint(arena, "{s}.zig", .{base});
    const exe_name = if (@import("builtin").os.tag == .windows)
        try std.fmt.allocPrint(arena, "{s}.exe", .{base})
    else
        try arena.dupe(u8, base);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = zig_path, .data = zig_src });

    const emit = try std.fmt.allocPrint(arena, "-femit-bin={s}", .{exe_name});
    var child = std.process.spawn(io, .{
        .argv = &.{ "zig", "build-exe", zig_path, "-O", "ReleaseFast", emit },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit, // zig's own diagnostics pass straight through
    }) catch |e| {
        try err.print("error: could not invoke zig ({s}); is zig on PATH?\n", .{@errorName(e)});
        return;
    };
    const term = child.wait(io) catch |e| {
        try err.print("error: waiting on zig failed ({s})\n", .{@errorName(e)});
        return;
    };
    switch (term) {
        .exited => |code| if (code == 0)
            try err.print("compiled {s} -> {s}\n", .{ path, exe_name })
        else
            try err.print("zig build-exe failed (exit {d})\n", .{code}),
        else => try err.print("zig build-exe terminated abnormally\n", .{}),
    }
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    // PERF (spec 111): opt into the bytecode-VM fast path with `LJS_VM=1`.
    if (init.environ_map.get("LJS_VM")) |v| if (std.mem.eql(u8, v, "1")) ljs.setVmEnabled(true);
    // PERF (spec 112): opt into the native JIT with `LJS_JIT=1`.
    if (init.environ_map.get("LJS_JIT")) |v| if (std.mem.eql(u8, v, "1")) ljs.setJitEnabled(true);

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

    // `ljs compile <file>` — the Typed-JS → Zig → native compiler (POC, spec 142). Separate from the
    // engine; lowers a typed-JS subset to Zig and invokes `zig build-exe` to produce a native binary.
    if (std.mem.eql(u8, cmd, "compile")) {
        compileCmd(arena, io, arg, err) catch |e| try err.print("compile error: {s}\n", .{@errorName(e)});
        try err.flush();
        return;
    }

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
            // On Windows, Node reports `__filename`/`__dirname` with the platform separator (`\`).
            // The CLI arg may carry `/`; normalize so `path.dirname(__filename)` matches Node.
            if (@import("builtin").os.tag == .windows and script_path.len > 0) {
                const buf = try arena.alloc(u8, script_path.len);
                for (script_path, 0..) |ch, i| buf[i] = if (ch == '/') '\\' else ch;
                script_path = buf;
            }
            script_dir = std.fs.path.dirname(script_path) orelse cwd;
        }
        break :blk ljs.HostCtx{ .argv = argv.items, .env_pairs = env_pairs.items, .cwd = cwd, .pid = hostPid(), .script_path = script_path, .script_dir = script_dir };
    };

    // ESM entry detection: a `.mjs` file, or a `.js`/extension-less file whose source uses top-level
    // `import`/`export` syntax, runs as an ES MODULE (top-level import/export work). Everything else
    // runs as a CommonJS script (the default — `require`/`module.exports`).
    const run_as_esm = is_run and (std.mem.endsWith(u8, arg, ".mjs") or looksLikeEsm(source));
    const result = if (is_run and run_as_esm)
        try ljs.runHostModule(arena, source, ctx, out, err)
    else if (is_run)
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
        .thrown_reported => {
            // runHost already printed the V8 stack trace to stderr; just exit non-zero (spec 119).
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
