//! Lumen compiler CLI: TypeScript syntax -> generated Zig -> native binary.

const std = @import("std");
const tjsc = @import("tjsc.zig");

fn printDiag(err: *std.Io.Writer, source: []const u8, file: []const u8, diag: tjsc.Diag) !void {
    try err.print("{s}:{d}:{d}: error: {s}\n", .{ file, diag.line, diag.col, diag.msg });
    var it = std.mem.splitScalar(u8, source, '\n');
    var n: u32 = 1;
    while (it.next()) |line| : (n += 1) {
        if (n == diag.line) {
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            try err.print("  {d} | {s}\n    | ", .{ diag.line, trimmed });
            var col: u32 = 1;
            while (col < diag.col) : (col += 1) try err.writeByte(' ');
            try err.writeAll("^\n");
            break;
        }
    }
}

fn compileFile(arena: std.mem.Allocator, io: std.Io, path: []const u8, err: *std.Io.Writer) !u8 {
    if (!std.mem.endsWith(u8, path, ".ts")) {
        try err.print("error: expected a .ts source file, got {s}\n", .{path});
        return 2;
    }

    const source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch {
        try err.print("error: cannot read file {s}\n", .{path});
        return 2;
    };

    var diag: tjsc.Diag = .{};
    const zig_src = tjsc.compileToZig(arena, source, path, &diag) catch {
        try printDiag(err, source, path, diag);
        return 1;
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
        .argv = &.{ "zig", "build-exe", zig_path, "-O", "ReleaseSafe", emit },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |e| {
        try err.print("error: could not invoke zig ({s}); is zig on PATH?\n", .{@errorName(e)});
        return 2;
    };

    const term = child.wait(io) catch |e| {
        try err.print("error: waiting on zig failed ({s})\n", .{@errorName(e)});
        return 2;
    };

    switch (term) {
        .exited => |code| {
            if (code == 0) {
                try err.print("compiled {s} -> {s}\n", .{ path, exe_name });
                return 0;
            }
            try err.print("zig build-exe failed (exit {d})\n", .{code});
            return 1;
        },
        else => {
            try err.writeAll("zig build-exe terminated abnormally\n");
            return 1;
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var err_buf: [4096]u8 = undefined;
    var err_fw: std.Io.File.Writer = .init(.stderr(), io, &err_buf);
    const err = &err_fw.interface;

    if (args.len < 2) {
        try err.writeAll("usage: lumen compile <file.ts>\n");
        try err.flush();
        std.process.exit(2);
    }

    const code = if (std.mem.eql(u8, args[1], "compile")) blk: {
        if (args.len < 3) {
            try err.writeAll("usage: lumen compile <file.ts>\n");
            break :blk 2;
        }
        break :blk try compileFile(arena, io, args[2], err);
    } else blk: {
        break :blk try compileFile(arena, io, args[1], err);
    };

    try err.flush();
    if (code != 0) std.process.exit(code);
}
