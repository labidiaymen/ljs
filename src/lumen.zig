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
    const is_local = std.mem.startsWith(u8, spec, "./") or std.mem.startsWith(u8, spec, "../");
    const is_url = std.mem.startsWith(u8, spec, "https://");
    // Local relative or https URL only; reject http://, bare, and others.
    if (!is_local and !is_url) return error.InvalidImport;
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

/// Resolves a relative specifier (`./x.ts`, `../y/z.ts`) against a remote
/// module's base directory URL (the URL up to its last `/`). `..` pops a path
/// segment but never past the host.
fn joinUrl(arena: std.mem.Allocator, base_dir: []const u8, rel: []const u8) ![]const u8 {
    const scheme = "https://";
    var dir = base_dir;
    var r = rel;
    while (true) {
        if (std.mem.startsWith(u8, r, "./")) {
            r = r[2..];
        } else if (std.mem.startsWith(u8, r, "../")) {
            r = r[3..];
            const slash = std.mem.lastIndexOfScalar(u8, dir, '/') orelse return error.InvalidImport;
            if (slash < scheme.len) return error.InvalidImport;
            dir = dir[0..slash];
        } else break;
    }
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, r });
}

/// Net `{`/`}` balance on a line, skipping string literals and line comments so
/// braces inside `"…{…"` or after `//` don't throw off block tracking.
fn braceDelta(line: []const u8) i32 {
    var depth: i32 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        switch (c) {
            '"', '\'', '`' => {
                i += 1;
                while (i < line.len and line[i] != c) : (i += 1) {
                    if (line[i] == '\\') i += 1;
                }
            },
            '/' => if (i + 1 < line.len and line[i + 1] == '/') return depth,
            '{' => depth += 1,
            '}' => depth -= 1,
            else => {},
        }
    }
    return depth;
}

/// Fetches a module's source over HTTPS at build time.
fn fetchUrl(arena: std.mem.Allocator, io: std.Io, url: []const u8) ![]const u8 {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    client.ca_bundle.rescan(arena, io, std.Io.Clock.now(.real, io)) catch return error.FetchFailed;
    var aw: std.Io.Writer.Allocating = .init(arena);
    const res = client.fetch(.{ .location = .{ .url = url }, .response_writer = &aw.writer }) catch return error.FetchFailed;
    if (@intFromEnum(res.status) != 200) return error.FetchFailed;
    return aw.toArrayList().items;
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
    const is_url = std.mem.startsWith(u8, path, "https://");
    // Cycle/dedup key: the URL itself for remote modules, the resolved path otherwise.
    const key = if (is_url) path else try std.fs.path.resolve(arena, &.{path});
    if (visiting.get(key) != null) return error.ImportCycle;
    if (emitted.get(key) != null) return;
    try visiting.put(arena, key, {});
    defer _ = visiting.remove(key);

    const source = if (is_url)
        fetchUrl(arena, io, path) catch return error.ImportReadFailed
    else
        std.Io.Dir.cwd().readFileAlloc(io, key, arena, .limited(16 * 1024 * 1024)) catch return error.ImportReadFailed;
    // Base directory for resolving relative child imports: for a URL it is the
    // URL up to its last `/`; for a local file it is the file's directory.
    const dir = if (is_url) blk: {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidImport;
        break :blk path[0..slash];
    } else (std.fs.path.dirname(key) orelse ".");

    var local_imports: std.StringHashMapUnmanaged(void) = .empty;
    // Tests belong to the module under test, not to importers: strip `test "…"`
    // blocks from imported modules (depth > 0) so they don't leak into the build.
    var test_skip: i32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (test_skip > 0) {
            test_skip += braceDelta(line);
            continue;
        }
        if (try parseImportSpec(line)) |import_spec| {
            if (local_imports.get(import_spec.spec) != null) return error.DuplicateImport;
            try local_imports.put(arena, import_spec.spec, {});
            const child_is_url = std.mem.startsWith(u8, import_spec.spec, "https://");
            // Resolve relative imports against the base dir — a URL base for a
            // remote module (recursive remote packages), a local path otherwise.
            const imported_path = if (child_is_url)
                import_spec.spec
            else if (is_url)
                try joinUrl(arena, dir, import_spec.spec)
            else
                try std.fs.path.join(arena, &.{ dir, import_spec.spec });
            try appendExpandedSource(arena, io, imported_path, out, visiting, emitted, import_spec.binding, depth + 1);
            continue;
        }
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (depth > 0 and std.mem.startsWith(u8, trimmed, "test \"")) {
            test_skip = braceDelta(line);
            continue;
        }
        if (try appendExportDefaultFunction(arena, out, trimmed, default_name)) continue;
        if (std.mem.startsWith(u8, trimmed, "export ")) return error.InvalidImport;
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    try emitted.put(arena, key, {});
}

fn readSourceWithImports(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var visiting: std.StringHashMapUnmanaged(void) = .empty;
    var emitted: std.StringHashMapUnmanaged(void) = .empty;
    try appendExpandedSource(arena, io, path, &out, &visiting, &emitted, null, 0);
    return out.items;
}

const Action = enum { build_exe, run_test };

/// Turns a link token into a zig build-exe argument: a bare name `m` becomes
/// `-lm`; a path-like token (`./libfoo.a`, `foo.o`) is passed through verbatim
/// so custom C/C++ objects and archives can be linked.
fn appendLink(arena: std.mem.Allocator, argv: *std.ArrayListUnmanaged([]const u8), token: []const u8) !void {
    if (std.mem.indexOfScalar(u8, token, '/') != null or std.mem.indexOfScalar(u8, token, '.') != null) {
        try argv.append(arena, try arena.dupe(u8, token));
    } else {
        try argv.append(arena, try std.fmt.allocPrint(arena, "-l{s}", .{token}));
    }
}

/// Links from each `// @link <lib>` pragma line in the source.
fn collectLinkLibs(arena: std.mem.Allocator, source: []const u8, argv: *std.ArrayListUnmanaged([]const u8)) !void {
    const marker = "// @link ";
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, marker)) continue;
        const lib = std.mem.trim(u8, trimmed[marker.len..], " \t");
        if (lib.len == 0) continue;
        try appendLink(arena, argv, lib);
    }
}

fn compileFile(arena: std.mem.Allocator, io: std.Io, path: []const u8, mode: CompileMode, action: Action, cli_libs: []const []const u8, err: *std.Io.Writer) !u8 {
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
    // The generated backend source is an internal artifact: write it to a hidden
    // temp file and remove it after building, so the user never sees it.
    const gen_path = try std.fmt.allocPrint(arena, ".lumen-{s}.zig", .{base});
    const exe_name = if (@import("builtin").os.tag == .windows)
        try std.fmt.allocPrint(arena, "{s}.exe", .{base})
    else
        try arena.dupe(u8, base);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = gen_path, .data = zig_src });
    defer std.Io.Dir.cwd().deleteFile(io, gen_path) catch {};

    const emit = try std.fmt.allocPrint(arena, "-femit-bin={s}", .{exe_name});
    // The native backend is invoked as `zig` from PATH. Release archives bundle
    // a private toolchain that the `lumen` launcher injects into PATH, so a
    // downloaded build is self-contained without exposing zig in the user's shell.
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    switch (action) {
        .build_exe => try argv.appendSlice(arena, &.{ "zig", "build-exe", gen_path, "-O", mode.zigName(), emit }),
        .run_test => try argv.appendSlice(arena, &.{ "zig", "test", gen_path }),
    }
    // Link C libraries: from `// @link <lib>` source pragmas and `--link` flags.
    try collectLinkLibs(arena, source, &argv);
    for (cli_libs) |lib| try appendLink(arena, &argv, lib);
    // Build mode: hide the backend's output entirely (a backend failure on valid
    // Lumen is an internal error). Test mode: show test results.
    const show_backend = action == .run_test;
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = if (show_backend) .inherit else .ignore,
        .stderr = if (show_backend) .inherit else .ignore,
    }) catch {
        try err.print("error: could not run the native backend\n", .{});
        return 2;
    };

    const term = child.wait(io) catch {
        try err.print("error: native build was interrupted\n", .{});
        return 2;
    };

    switch (term) {
        .exited => |code| {
            if (code == 0) {
                switch (action) {
                    .build_exe => try err.print("compiled {s} -> {s}\n", .{ path, exe_name }),
                    .run_test => try err.print("tests passed: {s}\n", .{path}),
                }
                return 0;
            }
            switch (action) {
                .build_exe => try err.print("error: failed to build native binary for {s}\n", .{path}),
                .run_test => try err.print("tests failed: {s}\n", .{path}),
            }
            return 1;
        },
        else => {
            try err.print("error: native build terminated abnormally\n", .{});
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
        try err.writeAll("usage: lumen compile [--release-fast] <file.ts>\n       lumen test <file.ts>\n");
        try err.flush();
        std.process.exit(2);
    }

    const usage = "usage: lumen compile [--release-fast] [--link <lib>] <file.ts>\n       lumen test <file.ts>\n";
    const code = if (std.mem.eql(u8, args[1], "test")) blk: {
        if (args.len < 3) {
            try err.writeAll("usage: lumen test <file.ts>\n");
            break :blk 2;
        }
        break :blk try compileFile(arena, io, args[2], .release_safe, .run_test, &.{}, err);
    } else if (std.mem.eql(u8, args[1], "compile")) blk: {
        if (args.len < 3) {
            try err.writeAll(usage);
            break :blk 2;
        }
        var mode: CompileMode = .release_safe;
        var source_arg: ?[]const u8 = null;
        var libs: std.ArrayListUnmanaged([]const u8) = .empty;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--release-fast")) {
                mode = .release_fast;
            } else if (std.mem.eql(u8, arg, "--release-safe")) {
                mode = .release_safe;
            } else if (std.mem.eql(u8, arg, "--link")) {
                i += 1;
                if (i >= args.len) {
                    try err.writeAll(usage);
                    break :blk 2;
                }
                try libs.append(arena, args[i]);
            } else if (source_arg == null) {
                source_arg = arg;
            } else {
                try err.writeAll(usage);
                break :blk 2;
            }
        }
        break :blk try compileFile(arena, io, source_arg orelse {
            try err.writeAll(usage);
            break :blk 2;
        }, mode, .build_exe, libs.items, err);
    } else blk: {
        break :blk try compileFile(arena, io, args[1], .release_safe, .build_exe, &.{}, err);
    };

    try err.flush();
    if (code != 0) std.process.exit(code);
}
