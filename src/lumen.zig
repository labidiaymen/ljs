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

/// A parsed `import ... from "..."` clause. A module may be pulled in either by
/// its default export (`import name from "..."`) or by a list of named exports
/// (`import { a, b } from "..."`).
const ImportSpec = struct {
    kind: Kind,
    spec: []const u8,

    const Kind = union(enum) {
        /// `import <binding> from "..."` — binds the module's default export.
        default: []const u8,
        /// `import { a, b as c } from "..."` — binds the listed named exports,
        /// optionally renamed (`as`). The module is inlined and each aliased
        /// export is renamed to its alias.
        named: []const NamedBinding,
        /// `import * as ns from "..."` — binds every export under a namespace; the
        /// module is inlined and `ns.member` accesses are rewritten to `member`.
        namespace: []const u8,
    };
};

/// One `{ name }` or `{ name as alias }` entry of a named import.
const NamedBinding = struct { name: []const u8, alias: []const u8 };

/// Splits a comma-separated `{ a, b as c }` binding list into name/alias pairs.
/// Each entry is `name` (alias == name) or `name as alias`. Rejects empty entries
/// and stray punctuation so the import surface stays the TypeScript named form.
fn parseNamedBindings(arena: std.mem.Allocator, inner: []const u8) ![]const NamedBinding {
    var binds: std.ArrayListUnmanaged(NamedBinding) = .empty;
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t");
        if (entry.len == 0) return error.InvalidImport;
        if (std.mem.indexOf(u8, entry, " as ")) |pos| {
            const name = std.mem.trim(u8, entry[0..pos], " \t");
            const alias = std.mem.trim(u8, entry[pos + 4 ..], " \t");
            if (name.len == 0 or alias.len == 0) return error.InvalidImport;
            if (std.mem.indexOfAny(u8, name, " \t{}*,.") != null or std.mem.indexOfAny(u8, alias, " \t{}*,.") != null) return error.InvalidImport;
            try binds.append(arena, .{ .name = name, .alias = alias });
        } else {
            if (std.mem.indexOfAny(u8, entry, " \t{}*") != null) return error.InvalidImport;
            try binds.append(arena, .{ .name = entry, .alias = entry });
        }
    }
    if (binds.items.len == 0) return error.InvalidImport;
    return binds.items;
}

fn parseImportSpec(arena: std.mem.Allocator, line: []const u8) !?ImportSpec {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "import ")) return null;
    const marker = " from \"";
    const marker_pos = std.mem.indexOf(u8, trimmed, marker) orelse return error.InvalidImport;
    const clause = std.mem.trim(u8, trimmed["import ".len..marker_pos], " \t");
    const spec_start = marker_pos + marker.len;
    const spec_end = std.mem.indexOfScalarPos(u8, trimmed, spec_start, '"') orelse return error.InvalidImport;
    const spec = trimmed[spec_start..spec_end];
    const is_local = std.mem.startsWith(u8, spec, "./") or std.mem.startsWith(u8, spec, "../");
    const is_url = std.mem.startsWith(u8, spec, "https://");
    // Local relative or https URL only; reject http://, bare, and others.
    if (!is_local and !is_url) return error.InvalidImport;
    if (!std.mem.endsWith(u8, spec, ".ts")) return error.InvalidImport;

    if (std.mem.startsWith(u8, clause, "{")) {
        if (!std.mem.endsWith(u8, clause, "}")) return error.InvalidImport;
        const inner = clause[1 .. clause.len - 1];
        const names = try parseNamedBindings(arena, inner);
        return .{ .kind = .{ .named = names }, .spec = spec };
    }

    // `import * as ns from "..."` — namespace import.
    if (std.mem.startsWith(u8, clause, "* as ")) {
        const ns = std.mem.trim(u8, clause["* as ".len..], " \t");
        if (ns.len == 0 or std.mem.indexOfAny(u8, ns, " \t{},.*") != null) return error.InvalidImport;
        return .{ .kind = .{ .namespace = ns }, .spec = spec };
    }

    if (clause.len == 0 or std.mem.indexOfAny(u8, clause, " \t{},*") != null) return error.InvalidImport;
    return .{ .kind = .{ .default = clause }, .spec = spec };
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

/// Reads the symbol name introduced by a `export function NAME` / `export const
/// NAME` declaration, returning the name and the keyword (`function`/`const`).
const NamedExport = struct {
    name: []const u8,
    /// The declaration with the leading `export ` removed.
    decl: []const u8,
};

fn parseNamedExportDecl(trimmed: []const u8) ?NamedExport {
    const decls = [_]struct { prefix: []const u8 }{
        .{ .prefix = "export function " },
        .{ .prefix = "export const " },
        .{ .prefix = "export let " },
    };
    for (decls) |d| {
        if (!std.mem.startsWith(u8, trimmed, d.prefix)) continue;
        const decl = trimmed["export ".len..];
        const rest = trimmed[d.prefix.len..];
        // Name runs up to the first `(`, `:`, `=`, or whitespace.
        const end = std.mem.indexOfAny(u8, rest, "(:= \t") orelse rest.len;
        const name = std.mem.trim(u8, rest[0..end], " \t");
        if (name.len == 0) return null;
        return .{ .name = name, .decl = decl };
    }
    return null;
}

/// Parses an `export { a, b }` re-export list into its names. Returns null when
/// the line is not such a statement.
fn parseExportList(arena: std.mem.Allocator, trimmed: []const u8) !?[]const NamedBinding {
    if (!std.mem.startsWith(u8, trimmed, "export {")) return null;
    const close = std.mem.indexOfScalar(u8, trimmed, '}') orelse return error.InvalidImport;
    const inner = trimmed["export {".len..close];
    return try parseNamedBindings(arena, inner);
}

/// Collects every symbol a module exports: default-function name (if any),
/// `export function/const/let NAME` declarations, and `export { a, b }` lists.
/// Used to validate that named imports refer to real exports.
fn collectExports(arena: std.mem.Allocator, source: []const u8, set: *std.StringHashMapUnmanaged(void)) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (parseNamedExportDecl(trimmed)) |ne| {
            try set.put(arena, ne.name, {});
        } else if (try parseExportList(arena, trimmed)) |binds| {
            for (binds) |b| try set.put(arena, b.alias, {});
        }
    }
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

/// Validates a named import against an already-inlined module by re-reading its
/// source and checking each requested binding is exported. (Default imports and
/// the entry module need no check.)
fn validateNamedImport(
    arena: std.mem.Allocator,
    io: std.Io,
    is_url: bool,
    path: []const u8,
    key: []const u8,
    import_kind: ?ImportSpec.Kind,
) !void {
    const kind = import_kind orelse return;
    const binds = switch (kind) {
        .named => |b| b,
        .default => return,
        .namespace => return,
    };
    const source = if (is_url)
        fetchUrl(arena, io, path) catch return error.ImportReadFailed
    else
        std.Io.Dir.cwd().readFileAlloc(io, key, arena, .limited(16 * 1024 * 1024)) catch return error.ImportReadFailed;
    var exports: std.StringHashMapUnmanaged(void) = .empty;
    try collectExports(arena, source, &exports);
    for (binds) |b| if (exports.get(b.name) == null) return error.MissingExport;
}

fn isIdentCh(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '$';
}
fn isIdentStartCh(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}

/// Appends `line` to `out`, identifier-aware (skips string literals and line
/// comments): rewrites `ns.member` -> `member` for each namespace alias, and
/// renames any bare identifier matching a `renames` entry to its alias (used to
/// rename an aliased named import in the inlined module).
fn appendTransformed(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), line: []const u8, namespaces: []const []const u8, renames: []const NamedBinding) !void {
    if (namespaces.len == 0 and renames.len == 0) return out.appendSlice(arena, line);
    var i: usize = 0;
    var in_str: u8 = 0;
    while (i < line.len) {
        const c = line[i];
        if (in_str != 0) {
            try out.append(arena, c);
            if (c == '\\' and i + 1 < line.len) {
                try out.append(arena, line[i + 1]);
                i += 2;
                continue;
            }
            if (c == in_str) in_str = 0;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'' or c == '`') {
            in_str = c;
            try out.append(arena, c);
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < line.len and line[i + 1] == '/') return out.appendSlice(arena, line[i..]);
        const boundary = i == 0 or !isIdentCh(line[i - 1]);
        if (boundary and isIdentStartCh(c)) {
            var j = i;
            while (j < line.len and isIdentCh(line[j])) j += 1;
            const ident = line[i..j];
            if (j < line.len and line[j] == '.') {
                var is_ns = false;
                for (namespaces) |ns| if (std.mem.eql(u8, ns, ident)) {
                    is_ns = true;
                    break;
                };
                if (is_ns) {
                    i = j + 1; // drop `ns.`
                    continue;
                }
            }
            var renamed: ?[]const u8 = null;
            for (renames) |r| if (std.mem.eql(u8, r.name, ident)) {
                renamed = r.alias;
                break;
            };
            try out.appendSlice(arena, renamed orelse ident);
            i = j;
            continue;
        }
        try out.append(arena, c);
        i += 1;
    }
}

fn appendExpandedSource(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    out: *std.ArrayListUnmanaged(u8),
    visiting: *std.StringHashMapUnmanaged(void),
    emitted: *std.StringHashMapUnmanaged(void),
    import_kind: ?ImportSpec.Kind,
    depth: u8,
) !void {
    if (depth > 16) return error.InvalidImport;
    const is_url = std.mem.startsWith(u8, path, "https://");
    // Cycle/dedup key: the URL itself for remote modules, the resolved path otherwise.
    const key = if (is_url) path else try std.fs.path.resolve(arena, &.{path});
    if (visiting.get(key) != null) return error.ImportCycle;
    if (emitted.get(key) != null) {
        // The module is already inlined, but a fresh importer may still request
        // named bindings: validate them against what the module exports.
        try validateNamedImport(arena, io, is_url, path, key, import_kind);
        return;
    }
    try visiting.put(arena, key, {});
    defer _ = visiting.remove(key);

    const source = if (is_url)
        fetchUrl(arena, io, path) catch return error.ImportReadFailed
    else
        std.Io.Dir.cwd().readFileAlloc(io, key, arena, .limited(16 * 1024 * 1024)) catch return error.ImportReadFailed;

    // Named imports must name real exports. Default import of the module's
    // default export needs no name check (the rename happens during emit).
    if (import_kind) |kind| switch (kind) {
        .named => |binds| {
            var exports: std.StringHashMapUnmanaged(void) = .empty;
            try collectExports(arena, source, &exports);
            for (binds) |b| if (exports.get(b.name) == null) return error.MissingExport;
        },
        .default => {},
        .namespace => {}, // binds all exports; nothing to validate
    };
    // Renames from aliased named imports (`a as b`) -> rename `a` to `b` in this
    // inlined module so importer references to `b` resolve and clashing names from
    // different modules can coexist.
    var renames: std.ArrayListUnmanaged(NamedBinding) = .empty;
    if (import_kind) |kind| switch (kind) {
        .named => |binds| for (binds) |b| {
            if (!std.mem.eql(u8, b.name, b.alias)) try renames.append(arena, b);
        },
        else => {},
    };
    const default_name: ?[]const u8 = if (import_kind) |kind| switch (kind) {
        .default => |b| b,
        .named => null,
        .namespace => null,
    } else null;
    // Base directory for resolving relative child imports: for a URL it is the
    // URL up to its last `/`; for a local file it is the file's directory.
    const dir = if (is_url) blk: {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidImport;
        break :blk path[0..slash];
    } else (std.fs.path.dirname(key) orelse ".");

    var local_imports: std.StringHashMapUnmanaged(void) = .empty;
    var file_namespaces: std.ArrayListUnmanaged([]const u8) = .empty; // `import * as ns` aliases in this file
    // Tests belong to the module under test, not to importers: strip `test "…"`
    // blocks from imported modules (depth > 0) so they don't leak into the build.
    var test_skip: i32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (test_skip > 0) {
            test_skip += braceDelta(line);
            continue;
        }
        if (try parseImportSpec(arena, line)) |import_spec| {
            if (local_imports.get(import_spec.spec) != null) return error.DuplicateImport;
            try local_imports.put(arena, import_spec.spec, {});
            if (import_spec.kind == .namespace) try file_namespaces.append(arena, import_spec.kind.namespace);
            const child_is_url = std.mem.startsWith(u8, import_spec.spec, "https://");
            // Resolve relative imports against the base dir — a URL base for a
            // remote module (recursive remote packages), a local path otherwise.
            const imported_path = if (child_is_url)
                import_spec.spec
            else if (is_url)
                try joinUrl(arena, dir, import_spec.spec)
            else
                try std.fs.path.join(arena, &.{ dir, import_spec.spec });
            try appendExpandedSource(arena, io, imported_path, out, visiting, emitted, import_spec.kind, depth + 1);
            continue;
        }
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (depth > 0 and std.mem.startsWith(u8, trimmed, "test \"")) {
            test_skip = braceDelta(line);
            continue;
        }
        if (try appendExportDefaultFunction(arena, out, trimmed, default_name)) continue;
        // `export { a, b }` re-export lists carry no declaration of their own:
        // the underlying functions/consts are emitted from their own lines.
        if (try parseExportList(arena, trimmed)) |_| continue;
        // `export function/const/let NAME` declarations: drop the `export `
        // keyword and emit the plain declaration into the shared program.
        if (parseNamedExportDecl(trimmed)) |ne| {
            // Preserve original indentation by emitting onto its own line.
            try appendTransformed(arena, out, ne.decl, file_namespaces.items, renames.items);
            try out.append(arena, '\n');
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "export ")) return error.InvalidImport;
        try appendTransformed(arena, out, line, file_namespaces.items, renames.items);
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

/// Walks the LOCAL import closure of `path`, appending each resolved local file
/// path to `set` (deduplicated). `https://` URL imports are build-time/remote and
/// are deliberately skipped — the watcher only observes files on disk. Malformed
/// imports or missing files are tolerated: the rebuild itself will surface the
/// real diagnostic; the watch set just falls back to whatever resolved cleanly.
fn collectWatchPaths(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    set: *std.StringArrayHashMapUnmanaged(void),
    depth: u8,
) void {
    if (depth > 16) return;
    if (std.mem.startsWith(u8, path, "https://")) return;
    const key = std.fs.path.resolve(arena, &.{path}) catch return;
    if (set.contains(key)) return;
    set.put(arena, key, {}) catch return;

    const source = std.Io.Dir.cwd().readFileAlloc(io, key, arena, .limited(16 * 1024 * 1024)) catch return;
    const dir = std.fs.path.dirname(key) orelse ".";
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const import_spec = (parseImportSpec(arena, line) catch continue) orelse continue;
        if (std.mem.startsWith(u8, import_spec.spec, "https://")) continue;
        const child = std.fs.path.join(arena, &.{ dir, import_spec.spec }) catch continue;
        collectWatchPaths(arena, io, child, set, depth + 1);
    }
}

/// Process-global SIGINT state for `lumen watch`. A signal handler cannot take
/// arguments or touch the arena, so the watch loop publishes the running child's
/// process id here; the handler kills it and flips `interrupted` so the poll loop
/// exits cleanly. On platforms without POSIX signals this stays inert and the
/// watcher is stopped the usual way (the child is still killed between rebuilds).
const WatchSignal = struct {
    var interrupted: std.atomic.Value(bool) = .init(false);
    var child_id: std.atomic.Value(i64) = .init(0);

    fn handle(_: std.posix.SIG) callconv(.c) void {
        const id = child_id.load(.seq_cst);
        if (id != 0) {
            std.posix.kill(@intCast(id), std.posix.SIG.TERM) catch {};
        }
        interrupted.store(true, .seq_cst);
    }
};

/// Builds (and optionally runs) `path` once, returning the freshly spawned child
/// on success when running is enabled. Reuses the exact compile path so build
/// errors print byte-for-byte like `lumen compile`. A previous run, if any, is
/// killed before the new binary is spawned.
fn watchRebuild(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    mode: CompileMode,
    run: bool,
    prev: *?std.process.Child,
    err: *std.Io.Writer,
) !void {
    // Reuse the standard compile path so diagnostics are identical to `lumen
    // compile`. compileFile prints either the diagnostic or the success line.
    const code = compileFile(arena, io, path, mode, .build_exe, &.{}, false, false, err) catch |e| {
        try err.print("watch: rebuild error: {s}\n", .{@errorName(e)});
        try err.flush();
        return;
    };
    if (code != 0) {
        // Keep the last good run alive: a failed build leaves `prev` untouched.
        try err.writeAll("watch: build failed; keeping previous run\n");
        try err.flush();
        return;
    }
    if (!run) {
        try err.flush();
        return;
    }

    // Stop the previous run before launching the rebuilt binary.
    if (prev.*) |*child| {
        WatchSignal.child_id.store(0, .seq_cst);
        child.kill(io);
        prev.* = null;
    }

    const base = std.fs.path.stem(path);
    const exe_name = if (@import("builtin").os.tag == .windows)
        try std.fmt.allocPrint(arena, "{s}.exe", .{base})
    else
        try arena.dupe(u8, base);
    // Spawn via an explicit relative path so it resolves in cwd, not PATH.
    const exe_rel = try std.fmt.allocPrint(arena, "./{s}", .{exe_name});

    const child = std.process.spawn(io, .{
        .argv = &.{exe_rel},
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch {
        try err.print("watch: could not run {s}\n", .{exe_name});
        try err.flush();
        return;
    };
    if (child.id) |id| WatchSignal.child_id.store(@intCast(id), .seq_cst);
    prev.* = child;
    try err.print("watch: running {s}\n", .{exe_rel});
    try err.flush();
}

/// `lumen watch <file.ts>`: rebuild whenever the entry file or any of its local
/// imports changes, re-running the produced binary unless `run` is false.
/// Watching is mtime polling at ~150 ms; the watch set is recomputed each rebuild
/// so newly added/removed local imports are picked up.
fn watchProject(arena: std.mem.Allocator, io: std.Io, path: []const u8, mode: CompileMode, run: bool, err: *std.Io.Writer) !u8 {
    if (!std.mem.endsWith(u8, path, ".ts")) {
        try err.print("error: expected a .ts source file, got {s}\n", .{path});
        return 2;
    }

    // Install a SIGINT/SIGTERM handler so Ctrl-C stops the watcher and kills the
    // running child. Best-effort: only meaningful on POSIX targets.
    if (@import("builtin").os.tag != .windows) {
        var act: std.posix.Sigaction = .{
            .handler = .{ .handler = WatchSignal.handle },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
        std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    }

    var prev: ?std.process.Child = null;
    // A per-poll scratch arena keeps long-running watches from leaking the
    // memory allocated by each rebuild (source reads, watch sets, hashing).
    var poll_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer poll_arena.deinit();

    // Snapshot of (path -> content hash) for the current watch set. Content
    // hashing is used instead of mtime because the file-stat path returns stale
    // modification times after a `zig build-exe` child runs under this I/O, while
    // file reads stay fresh; a 64-bit content hash is a reliable change signal.
    var prev_hashes: std.StringArrayHashMapUnmanaged(u64) = .empty;

    // Initial build.
    try watchRebuild(arena, io, path, mode, run, &prev, err);
    snapshotWatchSet(arena, io, path, &prev_hashes);
    try err.print("watching {d} files (Ctrl-C to stop)\n", .{prev_hashes.count()});
    try err.flush();

    while (!WatchSignal.interrupted.load(.seq_cst)) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(150), .awake) catch break;
        if (WatchSignal.interrupted.load(.seq_cst)) break;

        // Recompute the watch set every poll so import changes are tracked.
        _ = poll_arena.reset(.retain_capacity);
        const pa = poll_arena.allocator();
        var cur: std.StringArrayHashMapUnmanaged(u64) = .empty;
        snapshotWatchSet(pa, io, path, &cur);

        var changed = false;
        // A file appeared/disappeared from the set, or its contents changed.
        if (cur.count() != prev_hashes.count()) changed = true;
        var it = cur.iterator();
        while (it.next()) |entry| {
            if (prev_hashes.get(entry.key_ptr.*)) |old| {
                if (old != entry.value_ptr.*) changed = true;
            } else changed = true;
        }

        if (!changed) continue;

        // Rebuild, then refresh the content snapshot against the new set.
        try watchRebuild(arena, io, path, mode, run, &prev, err);
        prev_hashes.clearRetainingCapacity();
        snapshotWatchSet(arena, io, path, &prev_hashes);
    }

    if (prev) |*child| {
        WatchSignal.child_id.store(0, .seq_cst);
        child.kill(io);
    }
    try err.writeAll("\nwatch: stopped\n");
    try err.flush();
    return 0;
}

/// Fills `out` with (resolved local path -> content hash) for the entry file and
/// its local import closure. A file that cannot be read hashes to 0 so its later
/// appearance registers as a change.
fn snapshotWatchSet(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    out: *std.StringArrayHashMapUnmanaged(u64),
) void {
    var set: std.StringArrayHashMapUnmanaged(void) = .empty;
    collectWatchPaths(arena, io, path, &set, 0);
    for (set.keys()) |k| {
        out.put(arena, k, fileHash(arena, io, k)) catch {};
    }
}

/// 64-bit hash of a file's contents (0 when unreadable). File reads stay fresh
/// under this I/O even after a build child runs, making content hashing a
/// reliable change signal for the watch poll loop.
fn fileHash(arena: std.mem.Allocator, io: std.Io, path: []const u8) u64 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch return 0;
    return std.hash.Wyhash.hash(0, data);
}

const Action = enum { build_exe, run_test };

/// The ambient declarations that make Lumen `.ts` sources type-check under plain
/// tsc/editors. Embedded from the repo's canonical `/lumen.d.ts` so `lumen init`
/// and the editor experience stay in sync with a single source of truth.
const lumen_dts = @embedFile("lumen.d.ts");

/// Minimal tsconfig that keeps a fresh project tsc-clean: ESNext target/lib (so
/// Math/Array resolve but no DOM globals collide with our ambient `console`),
/// lenient checking, and `noEmit` since Lumen — not tsc — produces the binary.
const tsconfig_json =
    \\{
    \\  "compilerOptions": {
    \\    "target": "ESNext",
    \\    "lib": ["ESNext"],
    \\    "module": "ESNext",
    \\    "moduleResolution": "Bundler",
    \\    "strict": false,
    \\    "noEmit": true,
    \\    "skipLibCheck": true
    \\  },
    \\  "include": ["**/*.ts"]
    \\}
    \\
;

/// Starter program. Compiles and runs with Lumen and type-checks under tsc with
/// the generated `lumen.d.ts`/`tsconfig.json`.
const main_ts =
    \\// A fresh Lumen project. Build and run it with:
    \\//
    \\//   lumen compile main.ts && ./main
    \\//
    \\// This file also type-checks under plain tsc (see lumen.d.ts / tsconfig.json).
    \\
    \\function greet(name: string): string {
    \\  return `Hello, ${name}!`;
    \\}
    \\
    \\const who: string = "Lumen";
    \\console.log(greet(who));
    \\
;

const gitignore_txt =
    \\# Native binaries produced by `lumen compile`
    \\main
    \\*.exe
    \\.lumen-*.zig
    \\
;

const InitFile = struct {
    name: []const u8,
    contents: []const u8,
};

const init_files = [_]InitFile{
    .{ .name = "lumen.d.ts", .contents = lumen_dts },
    .{ .name = "tsconfig.json", .contents = tsconfig_json },
    .{ .name = "main.ts", .contents = main_ts },
    .{ .name = ".gitignore", .contents = gitignore_txt },
};

/// Scaffolds a ready-to-edit Lumen project under `dir` (the current directory
/// when null). Existing files are never overwritten: each is skipped with a
/// notice. Prints a summary and a next-steps line.
fn initProject(io: std.Io, dir: ?[]const u8, out: *std.Io.Writer) !u8 {
    const cwd = std.Io.Dir.cwd();
    if (dir) |d| {
        cwd.createDirPath(io, d) catch {
            try out.print("error: could not create directory {s}\n", .{d});
            return 2;
        };
    }
    var target = if (dir) |d|
        cwd.openDir(io, d, .{}) catch {
            try out.print("error: could not open directory {s}\n", .{d});
            return 2;
        }
    else
        cwd;
    defer if (dir != null) target.close(io);

    const where = dir orelse ".";
    var created: usize = 0;
    var skipped: usize = 0;
    for (init_files) |f| {
        // Skip without clobbering when the file already exists.
        if (target.access(io, f.name, .{})) |_| {
            try out.print("skip {s} (exists)\n", .{f.name});
            skipped += 1;
            continue;
        } else |_| {}
        target.writeFile(io, .{ .sub_path = f.name, .data = f.contents }) catch {
            try out.print("error: could not write {s}\n", .{f.name});
            return 2;
        };
        try out.print("create {s}\n", .{f.name});
        created += 1;
    }

    try out.print("\nInitialized Lumen project in {s} ({d} created, {d} skipped).\n", .{ where, created, skipped });
    if (dir) |d| {
        try out.print("Next: cd {s} && lumen compile main.ts && ./main\n", .{d});
    } else {
        try out.writeAll("Next: lumen compile main.ts && ./main\n");
    }
    return 0;
}

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

/// Auto-links libuv when a program uses async/await. libuv is the async event
/// loop, so it is a built-in language dependency rather than a user `// @link`.
/// Flags are discovered with `pkg-config --cflags --libs libuv`; if pkg-config
/// is unavailable we fall back to the conventional Homebrew install location.
/// Each whitespace-separated token (e.g. `-I/...`, `-L/...`, `-luv`) becomes its
/// own argv element, and `zig build-exe` is told to link libc so libuv resolves.
fn collectAsyncRuntimeLibs(arena: std.mem.Allocator, io: std.Io, argv: *std.ArrayListUnmanaged([]const u8)) !void {
    try argv.append(arena, "-lc");
    if (pkgConfigFlags(arena, io)) |flags| {
        var it = std.mem.tokenizeAny(u8, flags, " \t\r\n");
        while (it.next()) |tok| try argv.append(arena, try arena.dupe(u8, tok));
        return;
    }
    // Fallback: the documented Homebrew libuv prefix on this platform.
    const prefix = "/opt/homebrew/opt/libuv";
    try argv.append(arena, try std.fmt.allocPrint(arena, "-I{s}/include", .{prefix}));
    try argv.append(arena, try std.fmt.allocPrint(arena, "-L{s}/lib", .{prefix}));
    try argv.append(arena, "-luv");
}

/// Runs `pkg-config --cflags --libs libuv` and returns its trimmed stdout, or
/// null if pkg-config is missing or reports failure.
fn pkgConfigFlags(arena: std.mem.Allocator, io: std.Io) ?[]const u8 {
    const res = std.process.run(arena, io, .{
        .argv = &.{ "pkg-config", "--cflags", "--libs", "libuv" },
    }) catch return null;
    switch (res.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const out = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (out.len == 0) return null;
    return out;
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

/// Writes the lowercase hex SHA-256 of `bytes` into `out`, returning the slice.
fn sha256Hex(out: *[64]u8, bytes: []const u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
    return out[0..64];
}

/// Fetches a prebuilt wasm archive named by a `// @wasm-link <url>` pragma and
/// returns a local path to it, caching by spec in the compile working directory
/// so the (multi-MB) archive is downloaded once per process, not per compile.
/// An optional `#sha256=<hex>` fragment pins the archive: the bytes are verified
/// against it (on download and on cache reuse), so a tampered or swapped artifact
/// is rejected rather than linked.
fn fetchWasmLib(arena: std.mem.Allocator, io: std.Io, spec: []const u8) ![]const u8 {
    var url = spec;
    var want_hash: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, spec, '#')) |hp| {
        url = spec[0..hp];
        const frag = spec[hp + 1 ..];
        const pfx = "sha256=";
        if (std.mem.startsWith(u8, frag, pfx)) want_hash = frag[pfx.len..];
    }

    var h = std.hash.Wyhash.init(0);
    h.update(spec);
    const cache = try std.fmt.allocPrint(arena, ".lumen-wasmlink-{x}.a", .{h.final()});
    var hexbuf: [64]u8 = undefined;

    // Reuse a cached copy, re-verifying its hash when pinned (guards the cache).
    if (std.Io.Dir.cwd().readFileAlloc(io, cache, arena, .limited(256 * 1024 * 1024))) |cached| {
        if (want_hash) |wh| {
            if (std.ascii.eqlIgnoreCase(sha256Hex(&hexbuf, cached), wh)) return cache;
        } else return cache;
    } else |_| {}

    const bytes = try fetchUrl(arena, io, url);
    if (want_hash) |wh| {
        if (!std.ascii.eqlIgnoreCase(sha256Hex(&hexbuf, bytes), wh)) return error.WasmLinkHashMismatch;
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cache, .data = bytes });
    return cache;
}

/// Links prebuilt wasm archives named by `// @wasm-link <spec>` pragmas into a
/// wasm build. An `https://` spec is fetched (and cached) and linked as a local
/// archive; any other spec passes through `appendLink` (a local path or `-l`
/// name). Linking these archives resolves the program's `extern` (FFI) symbols
/// *inside* the module, so the result is a single self-contained wasm whose only
/// imports are WASI — no host-supplied engine. Returns true if any were linked.
fn collectWasmLinks(arena: std.mem.Allocator, io: std.Io, source: []const u8, argv: *std.ArrayListUnmanaged([]const u8)) !bool {
    const marker = "// @wasm-link ";
    var any = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, marker)) continue;
        const spec = std.mem.trim(u8, trimmed[marker.len..], " \t");
        if (spec.len == 0) continue;
        if (std.mem.startsWith(u8, spec, "https://")) {
            const local = try fetchWasmLib(arena, io, spec);
            try argv.append(arena, local);
        } else {
            try appendLink(arena, argv, spec);
        }
        any = true;
    }
    return any;
}

/// Names of `export function NAME(...)` declarations in the entry file — the
/// functions surfaced as callable wasm exports in `--reactor` mode.
fn collectReactorExports(arena: std.mem.Allocator, source: []const u8) ![]const []const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    const pfx = "export function ";
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, t, pfx)) continue;
        const rest = t[pfx.len..];
        const paren = std.mem.indexOfScalar(u8, rest, '(') orelse continue;
        const name = std.mem.trim(u8, rest[0..paren], " \t");
        if (name.len > 0) try names.append(arena, name);
    }
    return names.items;
}

/// Reactor glue appended to the generated Zig: a fixed input buffer the embedder
/// writes into, and per export a `__lumen_call_<name>(ptr, len) -> result_ptr`
/// that runs the `string -> string` function and reports the length via
/// `__lumen_out_len()`. The string arena is reset at each call (the previous
/// result has been read by then), giving repeated calls constant memory.
fn reactorWrappers(arena: std.mem.Allocator, names: []const []const u8) ![]const u8 {
    var w: std.ArrayListUnmanaged(u8) = .empty;
    try w.appendSlice(arena,
        \\
        \\// --- reactor exports (callable string-in / string-out) ---
        \\var __lumen_in_buf: [1 << 20]u8 = undefined;
        \\var __lumen_out_len_val: u32 = 0;
        \\export fn __lumen_in_ptr() u32 { return @intCast(@intFromPtr(&__lumen_in_buf)); }
        \\export fn __lumen_in_cap() u32 { return @intCast(__lumen_in_buf.len); }
        \\export fn __lumen_out_len() u32 { return __lumen_out_len_val; }
        \\
    );
    for (names) |n| {
        try w.print(arena,
            "export fn __lumen_call_{s}(__p: u32, __n: u32) u32 {{\n" ++
                "    _ = __sa_arena.reset(.retain_capacity);\n" ++
                "    const __r = {s}(@as([*]const u8, @ptrFromInt(@as(usize, __p)))[0..@as(usize, __n)]);\n" ++
                "    __lumen_out_len_val = @intCast(__r.len);\n" ++
                "    return @intCast(@intFromPtr(__r.ptr));\n" ++
                "}}\n",
            .{ n, n },
        );
    }
    return w.items;
}

fn compileFile(arena: std.mem.Allocator, io: std.Io, path: []const u8, mode: CompileMode, action: Action, cli_libs: []const []const u8, wasm: bool, reactor: bool, err: *std.Io.Writer) !u8 {
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
            error.MissingExport => try err.print("{s}:1:1: error: E_MISSING_EXPORT\n", .{path}),
            else => try err.print("error: cannot read file {s}\n", .{path}),
        }
        return 2;
    };

    var diag: compiler.Diag = .{};
    var zig_src = compiler.compileToZigWithOptions(arena, source, path, &diag, .{
        .runtime_locations = mode.runtimeLocations(),
    }) catch {
        try printDiag(err, source, path, diag);
        return 1;
    };

    // `--reactor`: surface the entry file's `export function`s as callable wasm
    // exports (string in/out via linear memory) so an embedder instantiates once
    // and calls them repeatedly, instead of re-running the program per call.
    var reactor_exports: []const []const u8 = &.{};
    if (reactor and wasm) {
        const entry_src = if (std.mem.startsWith(u8, path, "https://"))
            fetchUrl(arena, io, path) catch return error.FetchFailed
        else
            std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch return error.ImportReadFailed;
        reactor_exports = try collectReactorExports(arena, entry_src);
        if (reactor_exports.len > 0) {
            zig_src = try std.mem.concat(arena, u8, &.{ zig_src, try reactorWrappers(arena, reactor_exports) });
        }
    }

    // The wasm target has no event loop, so async is still unavailable there.
    if (wasm and std.mem.indexOf(u8, zig_src, "@cInclude(\"uv.h\")") != null) {
        try err.print("{s}:1:1: error: the wasm target does not support async yet\n", .{path});
        return 1;
    }

    // C FFI on wasm: an `extern fn` is resolved by linking a prebuilt wasm
    // archive named by a `// @wasm-link <url>` pragma (the wasm analogue of the
    // native `// @link`). The compiler fetches the archive and links it into the
    // module, so the FFI symbols resolve internally and the output is a single
    // self-contained wasm whose only imports are WASI.
    const wasm_ffi = wasm and std.mem.indexOf(u8, zig_src, "extern fn ") != null;

    const base = std.fs.path.stem(path);
    // The generated backend source is an internal artifact: write it to a hidden
    // temp file and remove it after building, so the user never sees it.
    const gen_path = try std.fmt.allocPrint(arena, ".lumen-{s}.zig", .{base});
    const exe_name = if (wasm)
        try std.fmt.allocPrint(arena, "{s}.wasm", .{base})
    else if (@import("builtin").os.tag == .windows)
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
        .build_exe => if (wasm)
            try argv.appendSlice(arena, &.{ "zig", "build-exe", gen_path, "-target", "wasm32-wasi", "-O", "ReleaseSmall", emit })
        else
            try argv.appendSlice(arena, &.{ "zig", "build-exe", gen_path, "-O", mode.zigName(), emit }),
        .run_test => try argv.appendSlice(arena, &.{ "zig", "test", gen_path }),
    }
    if (wasm) {
        // wasm C FFI: link the prebuilt archive(s) named by `// @wasm-link`, plus
        // the wasi-libc support libraries they reference (math, and the emulated
        // clock/signal shims QuickJS-style libraries use). The archive carries the
        // FFI implementation, so the program needs no host engine.
        if (wasm_ffi) {
            const linked = collectWasmLinks(arena, io, source, &argv) catch |e| {
                try err.print("{s}:1:1: error: could not fetch a // @wasm-link archive: {s}\n", .{ path, @errorName(e) });
                return 1;
            };
            if (!linked) {
                try err.print("{s}:1:1: error: wasm C FFI requires a // @wasm-link <url> archive to link\n", .{path});
                return 1;
            }
            try argv.appendSlice(arena, &.{ "-lc", "-lwasi-emulated-process-clocks", "-lwasi-emulated-signal", "-lm" });
        }
        // Surface the reactor exports (a wasm exe exports only `_start` by default).
        if (reactor_exports.len > 0) {
            try argv.appendSlice(arena, &.{ "--export=__lumen_in_ptr", "--export=__lumen_in_cap", "--export=__lumen_out_len" });
            for (reactor_exports) |n| try argv.append(arena, try std.fmt.allocPrint(arena, "--export=__lumen_call_{s}", .{n}));
        }
    } else {
        // The async event loop is libuv: when the program uses async/await, the
        // generated backend imports `uv.h`, so auto-inject libuv's include/link
        // flags (this is a language feature, not a user `// @link`).
        if (std.mem.indexOf(u8, zig_src, "@cInclude(\"uv.h\")") != null) {
            try collectAsyncRuntimeLibs(arena, io, &argv);
        }
        // Link C libraries: from `// @link <lib>` source pragmas and `--link` flags.
        try collectLinkLibs(arena, source, &argv);
        for (cli_libs) |lib| try appendLink(arena, &argv, lib);
    }
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
        try err.writeAll("usage: lumen init [dir]\n       lumen compile [--release-fast] <file.ts>\n       lumen watch [--no-run] <file.ts>\n       lumen test <file.ts>\n");
        try err.flush();
        std.process.exit(2);
    }

    const usage = "usage: lumen init [dir]\n       lumen compile [--release-fast] [--wasm] [--reactor] [--link <lib>] <file.ts>\n       lumen watch [--no-run] [--release-fast] <file.ts>\n       lumen test <file.ts>\n";
    const code = if (std.mem.eql(u8, args[1], "init")) blk: {
        if (args.len > 3) {
            try err.writeAll(usage);
            break :blk 2;
        }
        const dir: ?[]const u8 = if (args.len == 3) args[2] else null;
        break :blk try initProject(io, dir, err);
    } else if (std.mem.eql(u8, args[1], "test")) blk: {
        if (args.len < 3) {
            try err.writeAll("usage: lumen test <file.ts>\n");
            break :blk 2;
        }
        break :blk try compileFile(arena, io, args[2], .release_safe, .run_test, &.{}, false, false, err);
    } else if (std.mem.eql(u8, args[1], "watch")) blk: {
        if (args.len < 3) {
            try err.writeAll("usage: lumen watch [--no-run] [--release-fast] <file.ts>\n");
            break :blk 2;
        }
        var mode: CompileMode = .release_safe;
        var run = true;
        var source_arg: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--no-run")) {
                run = false;
            } else if (std.mem.eql(u8, arg, "--release-fast")) {
                mode = .release_fast;
            } else if (std.mem.eql(u8, arg, "--release-safe")) {
                mode = .release_safe;
            } else if (source_arg == null) {
                source_arg = arg;
            } else {
                try err.writeAll("usage: lumen watch [--no-run] [--release-fast] <file.ts>\n");
                break :blk 2;
            }
        }
        break :blk try watchProject(arena, io, source_arg orelse {
            try err.writeAll("usage: lumen watch [--no-run] [--release-fast] <file.ts>\n");
            break :blk 2;
        }, mode, run, err);
    } else if (std.mem.eql(u8, args[1], "compile")) blk: {
        if (args.len < 3) {
            try err.writeAll(usage);
            break :blk 2;
        }
        var mode: CompileMode = .release_safe;
        var source_arg: ?[]const u8 = null;
        var libs: std.ArrayListUnmanaged([]const u8) = .empty;
        var wasm = false;
        var reactor = false;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--release-fast")) {
                mode = .release_fast;
            } else if (std.mem.eql(u8, arg, "--release-safe")) {
                mode = .release_safe;
            } else if (std.mem.eql(u8, arg, "--wasm")) {
                wasm = true;
            } else if (std.mem.eql(u8, arg, "--reactor")) {
                reactor = true;
                wasm = true; // reactor implies the wasm target
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
        }, mode, .build_exe, libs.items, wasm, reactor, err);
    } else blk: {
        break :blk try compileFile(arena, io, args[1], .release_safe, .build_exe, &.{}, false, false, err);
    };

    try err.flush();
    if (code != 0) std.process.exit(code);
}
