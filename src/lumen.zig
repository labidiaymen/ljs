//! Lumen compiler CLI: TypeScript syntax -> generated Zig -> native binary.

const std = @import("std");
const compiler = @import("lumen_compiler.zig");

const CompileMode = enum {
    release_safe,
    release_fast,

    fn zigName(self: CompileMode) []const u8 {
        return switch (self) {
            .release_safe => "ReleaseSafe",
            .release_fast => "ReleaseFast",
        };
    }

    fn runtimeLocations(self: CompileMode) bool {
        return switch (self) {
            .release_safe => true,
            .release_fast => false,
        };
    }
};

fn printDiag(err: *std.Io.Writer, source: []const u8, file: []const u8, diag: compiler.Diag) !void {
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

const ImportSpec = struct {
    binding: []const u8,
    spec: []const u8,
};

fn parseImportSpec(line: []const u8) !?ImportSpec {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "import ")) return null;
    if (std.mem.startsWith(u8, trimmed, "import {")) return error.InvalidImport;
    const marker = " from \"";
    const marker_pos = std.mem.indexOf(u8, trimmed, marker) orelse return error.InvalidImport;
    const binding = std.mem.trim(u8, trimmed["import ".len..marker_pos], " \t");
    if (binding.len == 0 or std.mem.indexOfAny(u8, binding, " \t{},*") != null) return error.InvalidImport;
    const spec_start = marker_pos + marker.len;
    const spec_end = std.mem.indexOfScalarPos(u8, trimmed, spec_start, '"') orelse return error.InvalidImport;
    const spec = trimmed[spec_start..spec_end];
    if (!(std.mem.startsWith(u8, spec, "./") or std.mem.startsWith(u8, spec, "../"))) return error.InvalidImport;
    if (!std.mem.endsWith(u8, spec, ".ts")) return error.InvalidImport;
    return .{ .binding = binding, .spec = spec };
}

fn appendExportDefaultFunction(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), trimmed: []const u8, default_name: ?[]const u8) !bool {
    const prefix = "export default function ";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return false;
    const rest = trimmed[prefix.len..];
    const paren = std.mem.indexOfScalar(u8, rest, '(') orelse return error.InvalidImport;
    const original_name = std.mem.trim(u8, rest[0..paren], " \t");
    if (original_name.len == 0 and default_name == null) return error.InvalidImport;
    const emit_name = default_name orelse original_name;
    try out.print(arena, "function {s}{s}\n", .{ emit_name, rest[paren..] });
    return true;
}

fn appendExpandedSource(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    out: *std.ArrayListUnmanaged(u8),
    visiting: *std.StringHashMapUnmanaged(void),
    emitted: *std.StringHashMapUnmanaged(void),
    default_name: ?[]const u8,
    depth: u8,
) !void {
    if (depth > 16) return error.InvalidImport;
    const resolved_path = try std.fs.path.resolve(arena, &.{path});
    if (visiting.get(resolved_path) != null) return error.ImportCycle;
    if (emitted.get(resolved_path) != null) return;
    try visiting.put(arena, resolved_path, {});
    defer _ = visiting.remove(resolved_path);

    const source = std.Io.Dir.cwd().readFileAlloc(io, resolved_path, arena, .limited(16 * 1024 * 1024)) catch return error.ImportReadFailed;
    const dir = std.fs.path.dirname(resolved_path) orelse ".";

    var local_imports: std.StringHashMapUnmanaged(void) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (try parseImportSpec(line)) |import_spec| {
            if (local_imports.get(import_spec.spec) != null) return error.DuplicateImport;
            try local_imports.put(arena, import_spec.spec, {});
            const imported_path = try std.fs.path.join(arena, &.{ dir, import_spec.spec });
            try appendExpandedSource(arena, io, imported_path, out, visiting, emitted, import_spec.binding, depth + 1);
            continue;
        }
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (try appendExportDefaultFunction(arena, out, trimmed, default_name)) continue;
        if (std.mem.startsWith(u8, trimmed, "export ")) return error.InvalidImport;
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    try emitted.put(arena, resolved_path, {});
}

fn readSourceWithImports(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var visiting: std.StringHashMapUnmanaged(void) = .empty;
    var emitted: std.StringHashMapUnmanaged(void) = .empty;
    try appendExpandedSource(arena, io, path, &out, &visiting, &emitted, null, 0);
    return out.items;
}

fn compileFile(arena: std.mem.Allocator, io: std.Io, path: []const u8, mode: CompileMode, err: *std.Io.Writer) !u8 {
    if (!std.mem.endsWith(u8, path, ".ts")) {
        try err.print("error: expected a .ts source file, got {s}\n", .{path});
        return 2;
    }

    const source = readSourceWithImports(arena, io, path) catch |e| {
        switch (e) {
            error.InvalidImport => try err.print("{s}:1:1: error: E_UNSUPPORTED_IMPORT\n", .{path}),
            error.ImportReadFailed => try err.print("{s}:1:1: error: E_IMPORT_NOT_FOUND\n", .{path}),
            error.ImportCycle => try err.print("{s}:1:1: error: E_IMPORT_CYCLE\n", .{path}),
            error.DuplicateImport => try err.print("{s}:1:1: error: E_DUPLICATE_IMPORT\n", .{path}),
            else => try err.print("error: cannot read file {s}\n", .{path}),
        }
        return 2;
    };

    var diag: compiler.Diag = .{};
    const zig_src = compiler.compileToZigWithOptions(arena, source, path, &diag, .{
        .runtime_locations = mode.runtimeLocations(),
    }) catch {
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
        .argv = &.{ "zig", "build-exe", zig_path, "-O", mode.zigName(), emit },
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
        try err.writeAll("usage: lumen compile [--release-fast] <file.ts>\n");
        try err.flush();
        std.process.exit(2);
    }

    const code = if (std.mem.eql(u8, args[1], "compile")) blk: {
        if (args.len < 3) {
            try err.writeAll("usage: lumen compile [--release-fast] <file.ts>\n");
            break :blk 2;
        }
        var mode: CompileMode = .release_safe;
        var source_arg: ?[]const u8 = null;
        for (args[2..]) |arg| {
            if (std.mem.eql(u8, arg, "--release-fast")) {
                mode = .release_fast;
            } else if (std.mem.eql(u8, arg, "--release-safe")) {
                mode = .release_safe;
            } else if (source_arg == null) {
                source_arg = arg;
            } else {
                try err.writeAll("usage: lumen compile [--release-fast] <file.ts>\n");
                break :blk 2;
            }
        }
        break :blk try compileFile(arena, io, source_arg orelse {
            try err.writeAll("usage: lumen compile [--release-fast] <file.ts>\n");
            break :blk 2;
        }, mode, err);
    } else blk: {
        break :blk try compileFile(arena, io, args[1], .release_safe, err);
    };

    try err.flush();
    if (code != 0) std.process.exit(code);
}
