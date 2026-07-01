//! TypeScript-syntax -> Zig -> native compiler seed.
//!
//! NOT part of the ECMAScript engine or the Test262 path. A SEPARATE,
//! self-contained front-end that takes a small statically-typed TypeScript
//! syntax subset and lowers it to Zig source, which `zig build-exe` then turns
//! into a native binary. Using Zig as the backend means we write the front-end
//! and lowering first; optimization, native codegen, and cross-compilation come
//! from Zig/LLVM.
//!
//! ## What lives in this (large) file
//! Three stages share it; this is the biggest source file and the main candidate
//! for further splitting:
//!   * `Parser` -- turns the lexer's tokens into the AST (`parsePrimary`,
//!     `parseExpr`, `parseStmt`, and friends).
//!   * Codegen -- `emitProgram` / `emitStmt` / `emitExpr` walk the *typed* AST and
//!     append Zig source text to a buffer. There is no separate IR: we emit Zig
//!     directly, then `lumen.zig` shells out to `zig build-exe`.
//!   * Optimization passes over the AST (string-builder accumulators,
//!     destination-passing into a caller's buffer, chained-concat flattening) that
//!     exist purely to allocate less in the generated program.
//!
//! Generated programs allocate from a single never-freed arena (`__sa_arena`), so
//! the passes above are about avoiding allocations rather than freeing them. When
//! emitting character comparisons we use raw byte values (`== 46`) to sidestep Zig
//! char-literal escaping. Splitting this file into parser/codegen/passes modules is
//! an ongoing, conformance-guarded effort -- `regex_specialize.zig` was the first
//! seam pulled out (see the `.method_call` regex case in `emitExpr`).
const std = @import("std");

// The regex runtime engine, embedded verbatim into programs that use regex.
const REGEX_RT = @embedFile("regex_rt.zig");
// Compile-time regex specialization (Plan B): parses a literal pattern at build
// time and emits a pattern-specific straight-line matcher. See regex_specialize.zig.
const regex_specialize = @import("regex_specialize.zig");
const lumen_opt = @import("lumen_opt.zig");
const lumen_emit = @import("lumen_emit.zig");
pub const CompileOptions = lumen_emit.CompileOptions;
const emitProgram = lumen_emit.emitProgram;
const collectDestPassable = lumen_opt.collectDestPassable;
const markBuilderParts = lumen_opt.markBuilderParts;
const markAccumulators = lumen_opt.markAccumulators;
const lumen_parser = @import("lumen_parser.zig");
const Parser = lumen_parser.Parser;
const ast = @import("lumen_ast.zig");
const check = @import("lumen_check.zig");
const diag_mod = @import("lumen_diag.zig");
const lexer = @import("lumen_lexer.zig");
const types = @import("lumen_types.zig");

pub const CompileError = diag_mod.CompileError;
pub const Diag = diag_mod.Diag;

const Lexer = lexer.Lexer;

/// Builtins that lower to a Zig std wrapper (need __io/__alloc threaded in).
fn setDiag(diag: *Diag, line: u32, col: u32, msg: []const u8) CompileError {
    diag.* = .{ .line = line, .col = col, .msg = msg };
    return error.ParseError;
}

fn rejectUnsupportedDynamic(source: []const u8, diag: *Diag) CompileError!void {
    const eq = std.mem.eql;
    var lex = Lexer{ .src = source };
    var prev_was_dot = false;
    var prev_was_ident = false;
    var pending_dynamic_write_line: u32 = 0;
    var pending_dynamic_write_col: u32 = 0;
    var bracket_depth: u32 = 0;
    var bracket_candidate_line: u32 = 0;
    var bracket_candidate_col: u32 = 0;
    var bracket_has_content = false;

    while (true) {
        const tok = lex.next() catch {
            return setDiag(diag, lex.tok_line, lex.tok_col, lex.err_code orelse "syntax error");
        };
        switch (tok) {
            .eof => return,
            .ident => |name| {
                if (bracket_depth > 0) bracket_has_content = true;
                if (pending_dynamic_write_line != 0) {
                    pending_dynamic_write_line = 0;
                    pending_dynamic_write_col = 0;
                }
                if (eq(u8, name, "eval")) {
                    return setDiag(diag, lex.tok_line, lex.tok_col, "E_UNSUPPORTED_EVAL");
                }
                if (eq(u8, name, "require")) {
                    return setDiag(diag, lex.tok_line, lex.tok_col, "E_UNSUPPORTED_COMMONJS");
                }
                if (prev_was_dot and eq(u8, name, "prototype")) {
                    return setDiag(diag, lex.tok_line, lex.tok_col, "E_UNSUPPORTED_PROTOTYPE");
                }
                // Dotted property writes are validated precisely by the checker
                // (class fields, statics, and setters are allowed; record-shape
                // mutation is rejected there as E_DYNAMIC_PROPERTY_WRITE). Only
                // bracket-indexed writes (`obj["k"] = ...`) are flagged here.
                prev_was_dot = false;
                // A declaration keyword before `[` is array destructuring, not an
                // indexed dynamic write, so it must not start a write candidate.
                prev_was_ident = !(eq(u8, name, "let") or eq(u8, name, "const") or eq(u8, name, "var"));
            },
            .op => |ch| {
                if (bracket_depth > 0 and ch != '[' and ch != ']') bracket_has_content = true;
                if (ch == '=' and pending_dynamic_write_line != 0) {
                    return setDiag(diag, pending_dynamic_write_line, pending_dynamic_write_col, "E_DYNAMIC_PROPERTY_WRITE");
                }
                if (ch == '[' and prev_was_ident and bracket_depth == 0) {
                    bracket_candidate_line = lex.tok_line;
                    bracket_candidate_col = lex.tok_col;
                    bracket_depth = 1;
                    bracket_has_content = false;
                } else if (ch == '[' and bracket_depth > 0) {
                    bracket_depth += 1;
                } else if (ch == ']' and bracket_depth > 0) {
                    bracket_depth -= 1;
                    if (bracket_depth == 0 and bracket_has_content) {
                        pending_dynamic_write_line = bracket_candidate_line;
                        pending_dynamic_write_col = bracket_candidate_col;
                    }
                } else if (pending_dynamic_write_line != 0 and ch != '=') {
                    pending_dynamic_write_line = 0;
                    pending_dynamic_write_col = 0;
                }
                prev_was_dot = ch == '.';
                prev_was_ident = false;
            },
            else => {
                if (bracket_depth > 0) bracket_has_content = true;
                if (pending_dynamic_write_line != 0) {
                    pending_dynamic_write_line = 0;
                    pending_dynamic_write_col = 0;
                }
                prev_was_dot = false;
                prev_was_ident = false;
            },
        }
    }
}

// ── parser ───────────────────────────────────────────────────────────────────

// ── emit ─────────────────────────────────────────────────────────────────────

/// Zig type for an extern (C-ABI) signature slot. Identical to `types.zigName`
/// except a Lumen `string` maps to `[*:0]const u8` (a NUL-terminated C string)
/// rather than the slice `[]const u8`.
pub fn compileToZig(arena: std.mem.Allocator, source: []const u8, filename: []const u8, diag: *Diag) CompileError![]const u8 {
    return compileToZigWithOptions(arena, source, filename, diag, .{});
}

pub fn compileToZigWithOptions(arena: std.mem.Allocator, source: []const u8, filename: []const u8, diag: *Diag, options: CompileOptions) CompileError![]const u8 {
    try rejectUnsupportedDynamic(source, diag);

    var p = try Parser.init(arena, source);
    var program = p.parseProgram() catch |e| {
        diag.* = .{ .line = p.cur_line, .col = p.cur_col, .msg = p.last_err };
        return e;
    };

    try check.checkProgram(arena, &program, diag);

    // Compile append-only string locals into growable buffers (O(n) builds).
    try markAccumulators(program.stmts, &.{}, arena);

    // Destination-passing: builder functions also get an `f__into(dest,…)` form;
    // mark builder calls appended into accumulators so they call it directly.
    var dest_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    try collectDestPassable(program.stmts, &dest_map, arena);
    try markBuilderParts(program.stmts, &dest_map, arena);
    lumen_emit.g_dest_acc = &dest_map;
    defer lumen_emit.g_dest_acc = null;

    var decls: std.ArrayListUnmanaged(u8) = .empty; // top-level struct type definitions
    var body: std.ArrayListUnmanaged(u8) = .empty;

    // Collect function-value signatures used during emission so we can emit one
    // fat-pointer struct definition per distinct signature.
    var sig_list: std.ArrayListUnmanaged(types.SigEntry) = .empty;
    types.g_sig_registry = &sig_list;
    types.g_sig_arena = arena;
    var tuple_list: std.ArrayListUnmanaged(types.TupleEntry) = .empty;
    types.g_tuple_registry = &tuple_list;
    defer {
        types.g_sig_registry = null;
        types.g_sig_arena = null;
        types.g_tuple_registry = null;
    }

    try emitProgram(&program, &decls, &body, arena, options);

    // The async event loop reads `__io`/`__alloc`, so async programs use I/O
    // plumbing and the `main(__init)` shape even if they never touch other I/O.
    if (program.needs_async) program.uses_io = true;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(arena, "const std = @import(\"std\");\n");
    try out.appendSlice(arena, "var __sa_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);\nfn __sa() std.mem.Allocator { return __sa_arena.allocator(); }\n");
    // Regex literal value: the source/flags strings. Matching methods are added in
    // later cycles; for now it carries `.source` and `.flags`.
    try out.appendSlice(arena, "const __LumenRegExp = struct { source: []const u8, flags: []const u8 };\n");
    try out.appendSlice(arena, REGEX_RT);
    try out.appendSlice(arena, "\n");
    // Async programs run their event loop on libxev (a pure-Zig dependency: no
    // system install, unlike the libuv this replaced). The CLI auto-fetches it
    // and injects `-Mxev=...` into the native build whenever a program uses
    // async, so this import resolves without any user configuration.
    if (program.needs_async) {
        try out.appendSlice(arena, "const xev = @import(\"xev\");\n");
    }

    // I/O plumbing is hoisted to file scope so builtins (arg, fs, httpGet, …)
    // work inside functions, not just at the top level. `main` assigns these.
    if (program.uses_io) {
        try out.appendSlice(arena, "var __io: std.Io = undefined;\n");
        try out.appendSlice(arena, "var __alloc: std.mem.Allocator = std.heap.page_allocator;\n");
    }
    if (program.needs_args) {
        try out.appendSlice(arena, "var __args: []const []const u8 = &.{};\n");
    }
    if (program.needs_process_api) {
        try out.appendSlice(arena, "var __environ: std.process.Environ = .empty;\n");
    }

    if (options.runtime_locations) {
        // Sanitize the filename for a Zig string literal (backslashes/quotes break it).
        const safe_name = try arena.dupe(u8, filename);
        for (safe_name) |*ch| if (ch.* == '\\' or ch.* == '"') {
            ch.* = '/';
        };

        try out.print(arena, "const __lumen_file = \"{s}\";\n", .{safe_name});
        try out.appendSlice(arena, "var __lumen_line: u32 = 0;\nvar __lumen_col: u32 = 0;\n");
        // Embed the .ts source as a multiline string (no escaping needed) so the handler can show the line.
        try out.appendSlice(arena, "const __lumen_src =\n");
        {
            var lines = std.mem.splitScalar(u8, source, '\n');
            while (lines.next()) |l| {
                const t = std.mem.trimEnd(u8, l, "\r");
                try out.print(arena, "    \\\\{s}\n", .{t});
            }
        }
        try out.appendSlice(arena, ";\n");
        // Custom panic handler -> map the native runtime error back to the .ts source: file:line:col +
        // the offending source line + a caret.
        try out.appendSlice(arena,
            \\fn __lumenPanic(msg: []const u8, _: ?usize) noreturn {
            \\    std.debug.print("\n{s}:{d}:{d}: runtime error: {s}\n", .{ __lumen_file, __lumen_line, __lumen_col, msg });
            \\    var __it = std.mem.splitScalar(u8, __lumen_src, '\n');
            \\    var __n: u32 = 1;
            \\    while (__it.next()) |__l| : (__n += 1) {
            \\        if (__n == __lumen_line) {
            \\            std.debug.print("  {d} | {s}\n    | ", .{ __lumen_line, __l });
            \\            var __k: u32 = 1;
            \\            while (__k < __lumen_col) : (__k += 1) std.debug.print(" ", .{});
            \\            std.debug.print("^\n", .{});
            \\            break;
            \\        }
            \\    }
            \\    std.process.exit(1);
            \\}
            \\pub const panic = std.debug.FullPanic(__lumenPanic);
            \\
        );
    }
    // Emit a fat-pointer struct per function-value signature. Iterate by index
    // because emitting a signature's param/return types can register more.
    {
        var i: usize = 0;
        while (i < sig_list.items.len) : (i += 1) {
            const entry = sig_list.items[i];
            try out.print(arena, "const {s} = struct {{ ctx: *const anyopaque, call: *const fn (*const anyopaque", .{entry.name});
            for (entry.sig.params) |param_ty| try out.print(arena, ", {s}", .{try types.zigName(arena, param_ty)});
            try out.print(arena, ") {s} }};\n", .{try types.zigName(arena, entry.sig.ret.*)});
        }
    }
    // Emit one nominal struct per distinct tuple shape. Iterate by index because
    // emitting an element type can register a nested tuple shape.
    {
        var i: usize = 0;
        while (i < tuple_list.items.len) : (i += 1) {
            const entry = tuple_list.items[i];
            try out.print(arena, "const {s} = struct {{ ", .{entry.name});
            for (entry.elems, 0..) |el, j| {
                try out.print(arena, "@\"{d}\": {s}, ", .{ j, try types.zigName(arena, el) });
            }
            try out.appendSlice(arena, "};\n");
        }
    }
    if (program.needs_map or program.needs_set) {
        // Value equality that treats `[]const u8` (strings) specially.
        try out.appendSlice(arena,
            \\fn __lumenEql(comptime T: type, a: T, b: T) bool {
            \\    if (T == []const u8) return std.mem.eql(u8, a, b);
            \\    return a == b;
            \\}
            \\
        );
    }
    if (program.needs_map) {
        // Insertion-ordered Map<K, V>: linear-probe over parallel key/value lists
        // so keys()/values()/forEach iterate in insertion order deterministically.
        try out.appendSlice(arena,
            \\fn LumenMap(comptime K: type, comptime V: type) type {
            \\    return struct {
            \\        const Self = @This();
            \\        keys_: std.ArrayListUnmanaged(K) = .empty,
            \\        values_: std.ArrayListUnmanaged(V) = .empty,
            \\        fn __init() *Self {
            \\            const p = __sa().create(Self) catch unreachable;
            \\            p.* = .{};
            \\            return p;
            \\        }
            \\        fn __find(self: *Self, key: K) ?usize {
            \\            for (self.keys_.items, 0..) |k, i| { if (__lumenEql(K, k, key)) return i; }
            \\            return null;
            \\        }
            \\        fn set(self: *Self, key: K, value: V) void {
            \\            if (self.__find(key)) |i| { self.values_.items[i] = value; return; }
            \\            self.keys_.append(__sa(), key) catch unreachable;
            \\            self.values_.append(__sa(), value) catch unreachable;
            \\        }
            \\        fn get(self: *Self, key: K) ?V {
            \\            if (self.__find(key)) |i| return self.values_.items[i];
            \\            return null;
            \\        }
            \\        fn has(self: *Self, key: K) bool { return self.__find(key) != null; }
            \\        fn delete(self: *Self, key: K) bool {
            \\            if (self.__find(key)) |i| {
            \\                _ = self.keys_.orderedRemove(i);
            \\                _ = self.values_.orderedRemove(i);
            \\                return true;
            \\            }
            \\            return false;
            \\        }
            \\        fn size(self: *Self) i32 { return @intCast(self.keys_.items.len); }
            \\        fn keys(self: *Self) []const K { return self.keys_.items; }
            \\        fn values(self: *Self) []const V { return self.values_.items; }
            \\        fn forEach(self: *Self, cb: anytype) void {
            \\            for (self.keys_.items, 0..) |k, i| { _ = cb.call(cb.ctx, self.values_.items[i], k); }
            \\        }
            \\    };
            \\}
            \\
        );
    }
    if (program.needs_set) {
        // Insertion-ordered Set<T>.
        try out.appendSlice(arena,
            \\fn LumenSet(comptime T: type) type {
            \\    return struct {
            \\        const Self = @This();
            \\        items_: std.ArrayListUnmanaged(T) = .empty,
            \\        fn __init() *Self {
            \\            const p = __sa().create(Self) catch unreachable;
            \\            p.* = .{};
            \\            return p;
            \\        }
            \\        fn __find(self: *Self, value: T) ?usize {
            \\            for (self.items_.items, 0..) |v, i| { if (__lumenEql(T, v, value)) return i; }
            \\            return null;
            \\        }
            \\        fn add(self: *Self, value: T) void {
            \\            if (self.__find(value) != null) return;
            \\            self.items_.append(__sa(), value) catch unreachable;
            \\        }
            \\        fn has(self: *Self, value: T) bool { return self.__find(value) != null; }
            \\        fn delete(self: *Self, value: T) bool {
            \\            if (self.__find(value)) |i| { _ = self.items_.orderedRemove(i); return true; }
            \\            return false;
            \\        }
            \\        fn size(self: *Self) i32 { return @intCast(self.items_.items.len); }
            \\        fn values(self: *Self) []const T { return self.items_.items; }
            \\        fn forEach(self: *Self, cb: anytype) void {
            \\            for (self.items_.items) |v| { _ = cb.call(cb.ctx, v); }
            \\        }
            \\    };
            \\}
            \\
        );
    }
    if (program.needs_async) {
        // The event loop is libxev. `setTimeout` schedules an `xev.Timer`;
        // `await` drives the loop one event at a time (`loop.run(.once)`) until
        // the awaited promise resolves, then reads its value; the program ends by
        // draining remaining work with `loop.run(.until_done)`. This is sound for
        // the supported subset (already-resolved and timer-resolved promises) and
        // keeps timer ordering deterministic (libxev, like libuv, fires
        // equal-deadline timers in start order).
        try out.appendSlice(arena,
            \\var __xev_loop: xev.Loop = undefined;
            \\const LumenLoop = struct {
            \\    fn init() void { __xev_loop = xev.Loop.init(.{}) catch unreachable; }
            \\    fn driveUntil(ctx: *const anyopaque, done: *const fn (*const anyopaque) bool) void {
            \\        while (!done(ctx)) {
            \\            __xev_loop.run(.once) catch break;
            \\        }
            \\    }
            \\    fn drain() void { __xev_loop.run(.until_done) catch {}; }
            \\};
            \\fn LumenPromise(comptime T: type) type {
            \\    return struct {
            \\        const Self = @This();
            \\        resolved: bool = false,
            \\        value: T = undefined,
            \\        fn create() *Self {
            \\            const p = __alloc.create(Self) catch unreachable;
            \\            p.* = .{};
            \\            return p;
            \\        }
            \\        fn resolve(self: *Self, v: T) void { self.resolved = true; self.value = v; }
            \\        fn isResolved(ctx: *const anyopaque) bool {
            \\            const self: *const Self = @ptrCast(@alignCast(ctx));
            \\            return self.resolved;
            \\        }
            \\        fn await_(self: *Self) T {
            \\            LumenLoop.driveUntil(self, isResolved);
            \\            return self.value;
            \\        }
            \\    };
            \\}
            \\fn __promiseResolved(comptime T: type, v: T) *LumenPromise(T) {
            \\    const p = LumenPromise(T).create();
            \\    p.resolve(v);
            \\    return p;
            \\}
            \\fn __setTimeout(cb: anytype, ms: i64) void {
            \\    const Cb = @TypeOf(cb);
            \\    const Holder = struct {
            \\        f: Cb,
            \\        timer: xev.Timer,
            \\        completion: xev.Completion = undefined,
            \\        fn onTimer(ud: ?*@This(), loop: *xev.Loop, c: *xev.Completion, result: xev.Timer.RunError!void) xev.CallbackAction {
            \\            _ = loop;
            \\            _ = c;
            \\            _ = result catch {};
            \\            ud.?.f.call(ud.?.f.ctx);
            \\            return .disarm;
            \\        }
            \\    };
            \\    const h = __alloc.create(Holder) catch unreachable;
            \\    h.* = .{ .f = cb, .timer = xev.Timer.init() catch unreachable };
            \\    const delay: u64 = if (ms > 0) @intCast(ms) else 0;
            \\    h.timer.run(&__xev_loop, &h.completion, delay, Holder, h, Holder.onTimer);
            \\}
            \\
        );
    }
    if (program.needs_async_read_file) {
        // `fs.readFile` -- true async read on libxev's io_uring backend (no
        // thread pool, unlike fs.readFileSync's synchronous std.Io.Dir call or
        // Node's libuv-backed fs.readFile, which is always thread-pool-based).
        // The open is synchronous (a fast metadata-only syscall); the read loop
        // (pread at increasing offsets into a fixed chunk, accumulating into a
        // growable buffer until a zero-length read) is fully async, resolving
        // the returned Promise<string> on completion.
        try out.appendSlice(arena,
            \\const __ReadFileChunk = 65536;
            \\const __ReadFileState = struct {
            \\    file: xev.File,
            \\    promise: *LumenPromise([]const u8),
            \\    buf: std.ArrayListUnmanaged(u8) = .empty,
            \\    chunk: [__ReadFileChunk]u8 = undefined,
            \\    offset: u64 = 0,
            \\    completion: xev.Completion = undefined,
            \\    close_completion: xev.Completion = undefined,
            \\    fn onRead(ud: ?*__ReadFileState, loop: *xev.Loop, c: *xev.Completion, file: xev.File, rb: xev.ReadBuffer, result: xev.ReadError!usize) xev.CallbackAction {
            \\        _ = loop;
            \\        _ = c;
            \\        _ = rb;
            \\        const st = ud.?;
            \\        const n = result catch 0;
            \\        if (n == 0) {
            \\            st.promise.resolve(st.buf.toOwnedSlice(__alloc) catch "");
            \\            file.close(&__xev_loop, &st.close_completion, void, null, struct {
            \\                fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: xev.File, _: xev.CloseError!void) xev.CallbackAction {
            \\                    return .disarm;
            \\                }
            \\            }.cb);
            \\            return .disarm;
            \\        }
            \\        st.buf.appendSlice(__alloc, st.chunk[0..n]) catch {};
            \\        st.offset += n;
            \\        st.file.pread(&__xev_loop, &st.completion, .{ .slice = &st.chunk }, st.offset, __ReadFileState, st, onRead);
            \\        return .disarm;
            \\    }
            \\};
            \\fn __readFileAsync(path: []const u8) *LumenPromise([]const u8) {
            \\    const p = LumenPromise([]const u8).create();
            \\    const sync_file = std.Io.Dir.cwd().openFile(__io, path, .{ .mode = .read_only }) catch {
            \\        p.resolve("");
            \\        return p;
            \\    };
            \\    const xf = xev.File.init(sync_file) catch {
            \\        p.resolve("");
            \\        return p;
            \\    };
            \\    const st = __alloc.create(__ReadFileState) catch unreachable;
            \\    st.* = .{ .file = xf, .promise = p };
            \\    st.file.pread(&__xev_loop, &st.completion, .{ .slice = &st.chunk }, 0, __ReadFileState, st, __ReadFileState.onRead);
            \\    return p;
            \\}
            \\
        );
    }
    if (program.needs_async_write_file) {
        // `fs.writeFile` -- the async counterpart to `fs.readFile`. The open
        // (create/truncate) is a fast synchronous metadata call; the write
        // loop (pwrite at increasing offsets, looping on a short write) is
        // fully async, resolving the returned Promise<void> on completion.
        try out.appendSlice(arena,
            \\const __WriteFileState = struct {
            \\    file: xev.File,
            \\    promise: *LumenPromise(void),
            \\    data: []const u8,
            \\    offset: u64 = 0,
            \\    completion: xev.Completion = undefined,
            \\    close_completion: xev.Completion = undefined,
            \\    fn onWrite(ud: ?*__WriteFileState, loop: *xev.Loop, c: *xev.Completion, file: xev.File, wb: xev.WriteBuffer, result: xev.WriteError!usize) xev.CallbackAction {
            \\        _ = loop;
            \\        _ = c;
            \\        _ = wb;
            \\        const st = ud.?;
            \\        const n = result catch 0;
            \\        st.offset += n;
            \\        if (n == 0 or st.offset >= st.data.len) {
            \\            st.promise.resolve({});
            \\            file.close(&__xev_loop, &st.close_completion, void, null, struct {
            \\                fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: xev.File, _: xev.CloseError!void) xev.CallbackAction {
            \\                    return .disarm;
            \\                }
            \\            }.cb);
            \\            return .disarm;
            \\        }
            \\        st.file.pwrite(&__xev_loop, &st.completion, .{ .slice = st.data[st.offset..] }, st.offset, __WriteFileState, st, onWrite);
            \\        return .disarm;
            \\    }
            \\};
            \\fn __writeFileAsync(path: []const u8, data: []const u8) *LumenPromise(void) {
            \\    const p = LumenPromise(void).create();
            \\    const sync_file = std.Io.Dir.cwd().createFile(__io, path, .{}) catch {
            \\        p.resolve({});
            \\        return p;
            \\    };
            \\    const xf = xev.File.init(sync_file) catch {
            \\        p.resolve({});
            \\        return p;
            \\    };
            \\    if (data.len == 0) {
            \\        p.resolve({});
            \\        xf.close(&__xev_loop, &(__alloc.create(xev.Completion) catch unreachable).*, void, null, struct {
            \\            fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: xev.File, _: xev.CloseError!void) xev.CallbackAction {
            \\                return .disarm;
            \\            }
            \\        }.cb);
            \\        return p;
            \\    }
            \\    const st = __alloc.create(__WriteFileState) catch unreachable;
            \\    st.* = .{ .file = xf, .promise = p, .data = data };
            \\    st.file.pwrite(&__xev_loop, &st.completion, .{ .slice = data }, 0, __WriteFileState, st, __WriteFileState.onWrite);
            \\    return p;
            \\}
            \\
        );
    }
    try out.appendSlice(arena, decls.items);

    if (program.needs_read_file_sync) {
        try out.appendSlice(arena,
            \\fn __readFileSync(io: std.Io, alloc: std.mem.Allocator, path: []const u8) []const u8 {
            \\    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(16 * 1024 * 1024)) catch "";
            \\}
            \\
        );
    }
    if (program.needs_exists_sync) {
        try out.appendSlice(arena,
            \\fn __existsSync(io: std.Io, path: []const u8) bool {
            \\    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
            \\    return true;
            \\}
            \\
        );
    }
    if (program.needs_write_file_sync) {
        try out.appendSlice(arena,
            \\fn __writeFileSync(io: std.Io, path: []const u8, data: []const u8) void {
            \\    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch {};
            \\}
            \\
        );
    }
    if (program.needs_append_file_sync) {
        // No direct append API on this std.Io.Dir; read the existing content (if
        // any), concatenate, and rewrite. Fine for sync, single-writer use.
        try out.appendSlice(arena,
            \\fn __appendFileSync(io: std.Io, alloc: std.mem.Allocator, path: []const u8, data: []const u8) void {
            \\    const existing = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024 * 1024)) catch "";
            \\    const combined = std.mem.concat(alloc, u8, &.{ existing, data }) catch return;
            \\    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = combined }) catch {};
            \\}
            \\
        );
    }
    if (program.needs_mkdir_sync) {
        try out.appendSlice(arena,
            \\fn __mkdirSync(io: std.Io, path: []const u8, recursive: bool) void {
            \\    if (recursive) {
            \\        std.Io.Dir.cwd().createDirPath(io, path) catch {};
            \\    } else {
            \\        std.Io.Dir.cwd().createDir(io, path, std.Io.File.Permissions.default_dir) catch {};
            \\    }
            \\}
            \\
        );
    }
    if (program.needs_unlink_sync) {
        try out.appendSlice(arena,
            \\fn __unlinkSync(io: std.Io, path: []const u8) void {
            \\    std.Io.Dir.cwd().deleteFile(io, path) catch {};
            \\}
            \\
        );
    }
    if (program.needs_rename_sync) {
        try out.appendSlice(arena,
            \\fn __renameSync(io: std.Io, old_path: []const u8, new_path: []const u8) void {
            \\    std.Io.Dir.rename(std.Io.Dir.cwd(), old_path, std.Io.Dir.cwd(), new_path, io) catch {};
            \\}
            \\
        );
    }
    if (program.needs_copy_file_sync) {
        try out.appendSlice(arena,
            \\fn __copyFileSync(io: std.Io, src_path: []const u8, dest_path: []const u8) void {
            \\    std.Io.Dir.copyFile(std.Io.Dir.cwd(), src_path, std.Io.Dir.cwd(), dest_path, io, .{}) catch {};
            \\}
            \\
        );
    }
    if (program.needs_cp_sync) {
        // Composed from the same primitives as copyFileSync/mkdirSync/iterate:
        // if `src_path` opens as an iterable directory, recurse into it (only
        // when `recursive` is true); otherwise treat it as a single file.
        try out.appendSlice(arena,
            \\fn __cpSync(io: std.Io, alloc: std.mem.Allocator, src_path: []const u8, dest_path: []const u8, recursive: bool) void {
            \\    if (recursive) {
            \\        if (std.Io.Dir.cwd().openDir(io, src_path, .{ .iterate = true })) |src_dir_const| {
            \\            var src_dir = src_dir_const;
            \\            defer src_dir.close(io);
            \\            std.Io.Dir.cwd().createDirPath(io, dest_path) catch {};
            \\            var it = src_dir.iterate();
            \\            while (it.next(io) catch null) |entry| {
            \\                const sub_src = std.fmt.allocPrint(alloc, "{s}/{s}", .{ src_path, entry.name }) catch continue;
            \\                const sub_dest = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dest_path, entry.name }) catch continue;
            \\                __cpSync(io, alloc, sub_src, sub_dest, true);
            \\            }
            \\            return;
            \\        } else |_| {}
            \\    }
            \\    std.Io.Dir.copyFile(std.Io.Dir.cwd(), src_path, std.Io.Dir.cwd(), dest_path, io, .{}) catch {};
            \\}
            \\
        );
    }
    if (program.needs_mkdtemp_sync) {
        // Not Node's mkdtempSync exactly: the suffix is a timestamp mixed with a
        // per-process counter, not cryptographic randomness (no clear
        // std.crypto.random source in this Zig version) -- adequate for a unique
        // scratch directory name, not for anything security-sensitive.
        try out.appendSlice(arena,
            \\var __mkdtemp_counter: u64 = 0;
            \\fn __mkdtempSync(io: std.Io, alloc: std.mem.Allocator, prefix: []const u8) []const u8 {
            \\    const ts = std.Io.Clock.now(.real, io).nanoseconds;
            \\    __mkdtemp_counter +%= 1;
            \\    const mixed: u32 = @as(u32, @truncate(@as(u96, @bitCast(ts)))) ^ @as(u32, @truncate(__mkdtemp_counter *% 2654435761));
            \\    const path = std.fmt.allocPrint(alloc, "{s}{x:0>8}", .{ prefix, mixed }) catch return "";
            \\    std.Io.Dir.cwd().createDir(io, path, std.Io.File.Permissions.default_dir) catch return "";
            \\    return path;
            \\}
            \\
        );
    }
    if (program.needs_stat_sync) {
        // Backs the synthetic `__LumenStat` record type the checker registers
        // for fs.statSync (lumen_check_stdlib.zig): isFile/isDirectory are plain
        // bool fields here, not methods, since builtins can't have methods yet.
        try out.appendSlice(arena,
            \\pub const __LumenStat = struct { size: i32, isFile: bool, isDirectory: bool, mtimeMs: i32 };
            \\fn __statSync(io: std.Io, path: []const u8) __LumenStat {
            \\    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return .{ .size = 0, .isFile = false, .isDirectory = false, .mtimeMs = 0 };
            \\    return .{
            \\        .size = @truncate(@as(i64, @intCast(st.size))),
            \\        .isFile = st.kind == .file,
            \\        .isDirectory = st.kind == .directory,
            \\        .mtimeMs = @truncate(@divTrunc(@as(i96, st.mtime.nanoseconds), 1_000_000)),
            \\    };
            \\}
            \\
        );
    }
    if (program.needs_fd_api) {
        // A Lumen "fd" is an index into this table, not a raw OS handle (so the
        // type stays a plain `int`). openSync supports only "r" (read, must
        // exist) and "w" (write, create/truncate) -- "a" (append) needs a seek
        // primitive not available in this Zig version's std.Io.File, so it is
        // deferred. readSync/writeSync work on `string`, not a Buffer type
        // (Lumen has none yet), and are sequential (advance the OS file
        // position), matching Node's positionless readSync/writeSync.
        try out.appendSlice(arena,
            \\var __fd_table: std.ArrayListUnmanaged(std.Io.File) = .empty;
            \\fn __openSync(io: std.Io, alloc: std.mem.Allocator, path: []const u8, flags: []const u8) i32 {
            \\    const file = if (std.mem.eql(u8, flags, "w"))
            \\        std.Io.Dir.cwd().createFile(io, path, .{}) catch return -1
            \\    else
            \\        std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return -1;
            \\    __fd_table.append(alloc, file) catch return -1;
            \\    return @intCast(__fd_table.items.len - 1);
            \\}
            \\fn __closeSync(io: std.Io, fd: i32) void {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return;
            \\    __fd_table.items[@intCast(fd)].close(io);
            \\}
            \\fn __readSync(io: std.Io, alloc: std.mem.Allocator, fd: i32, len: i32) []const u8 {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len or len <= 0) return "";
            \\    const buf = alloc.alloc(u8, @intCast(len)) catch return "";
            \\    const n = __fd_table.items[@intCast(fd)].readStreaming(io, &.{buf}) catch return "";
            \\    return buf[0..n];
            \\}
            \\fn __writeSync(io: std.Io, fd: i32, data: []const u8) i32 {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return 0;
            \\    __fd_table.items[@intCast(fd)].writeStreamingAll(io, data) catch return 0;
            \\    return @intCast(data.len);
            \\}
            \\
        );
    }
    if (program.needs_rmdir_sync) {
        try out.appendSlice(arena,
            \\fn __rmdirSync(io: std.Io, path: []const u8) void {
            \\    std.Io.Dir.cwd().deleteDir(io, path) catch {};
            \\}
            \\
        );
    }
    if (program.needs_rm_sync) {
        try out.appendSlice(arena,
            \\fn __rmSync(io: std.Io, path: []const u8, recursive: bool) void {
            \\    if (recursive) {
            \\        std.Io.Dir.cwd().deleteTree(io, path) catch {};
            \\    } else {
            \\        std.Io.Dir.cwd().deleteFile(io, path) catch {
            \\            std.Io.Dir.cwd().deleteDir(io, path) catch {};
            \\        };
            \\    }
            \\}
            \\
        );
    }
    if (program.needs_truncate_sync) {
        try out.appendSlice(arena,
            \\fn __truncateSync(io: std.Io, path: []const u8, len: i64) void {
            \\    var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch return;
            \\    defer file.close(io);
            \\    file.setLength(io, @intCast(len)) catch {};
            \\}
            \\
        );
    }
    if (program.needs_link_sync) {
        try out.appendSlice(arena,
            \\fn __linkSync(io: std.Io, existing_path: []const u8, new_path: []const u8) void {
            \\    std.Io.Dir.hardLink(std.Io.Dir.cwd(), existing_path, std.Io.Dir.cwd(), new_path, io, .{}) catch {};
            \\}
            \\
        );
    }
    if (program.needs_symlink_sync) {
        try out.appendSlice(arena,
            \\fn __symlinkSync(io: std.Io, target: []const u8, path: []const u8) void {
            \\    std.Io.Dir.cwd().symLink(io, target, path, .{}) catch {};
            \\}
            \\
        );
    }
    if (program.needs_readlink_sync) {
        try out.appendSlice(arena,
            \\fn __readlinkSync(io: std.Io, alloc: std.mem.Allocator, path: []const u8) []const u8 {
            \\    var buf: [4096]u8 = undefined;
            \\    const n = std.Io.Dir.cwd().readLink(io, path, &buf) catch return "";
            \\    return alloc.dupe(u8, buf[0..n]) catch "";
            \\}
            \\
        );
    }
    if (program.needs_chmod_sync) {
        try out.appendSlice(arena,
            \\fn __chmodSync(io: std.Io, path: []const u8, mode: i64) void {
            \\    var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return;
            \\    defer file.close(io);
            \\    file.setPermissions(io, std.Io.File.Permissions.fromMode(@intCast(mode))) catch {};
            \\}
            \\
        );
    }
    if (program.needs_access_sync) {
        try out.appendSlice(arena,
            \\fn __accessSync(io: std.Io, path: []const u8, mode: i64) bool {
            \\    const m: u32 = @intCast(mode);
            \\    const opts: std.Io.Dir.AccessOptions = .{
            \\        .read = (m & 4) != 0,
            \\        .write = (m & 2) != 0,
            \\        .execute = (m & 1) != 0,
            \\    };
            \\    std.Io.Dir.cwd().access(io, path, opts) catch return false;
            \\    return true;
            \\}
            \\
        );
    }
    if (program.needs_lstat_sync) {
        // Same `__LumenStat` record as statSync, but `follow_symlinks = false`
        // so a symlink itself is stat'd rather than its target.
        try out.appendSlice(arena,
            \\fn __lstatSync(io: std.Io, path: []const u8) __LumenStat {
            \\    const st = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return .{ .size = 0, .isFile = false, .isDirectory = false, .mtimeMs = 0 };
            \\    return .{
            \\        .size = @truncate(@as(i64, @intCast(st.size))),
            \\        .isFile = st.kind == .file,
            \\        .isDirectory = st.kind == .directory,
            \\        .mtimeMs = @truncate(@divTrunc(@as(i96, st.mtime.nanoseconds), 1_000_000)),
            \\    };
            \\}
            \\
        );
    }
    if (program.needs_fstat_sync) {
        // fd-based variant of statSync: stats the already-open file in
        // __fd_table rather than re-resolving a path.
        try out.appendSlice(arena,
            \\fn __fstatSync(io: std.Io, fd: i32) __LumenStat {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return .{ .size = 0, .isFile = false, .isDirectory = false, .mtimeMs = 0 };
            \\    const st = __fd_table.items[@intCast(fd)].stat(io) catch return .{ .size = 0, .isFile = false, .isDirectory = false, .mtimeMs = 0 };
            \\    return .{
            \\        .size = @truncate(@as(i64, @intCast(st.size))),
            \\        .isFile = st.kind == .file,
            \\        .isDirectory = st.kind == .directory,
            \\        .mtimeMs = @truncate(@divTrunc(@as(i96, st.mtime.nanoseconds), 1_000_000)),
            \\    };
            \\}
            \\
        );
    }
    if (program.needs_fchmod_sync) {
        try out.appendSlice(arena,
            \\fn __fchmodSync(io: std.Io, fd: i32, mode: i64) void {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return;
            \\    __fd_table.items[@intCast(fd)].setPermissions(io, std.Io.File.Permissions.fromMode(@intCast(mode))) catch {};
            \\}
            \\
        );
    }
    if (program.needs_lchmod_sync) {
        // Best effort: not every OS lets you chmod a symlink directly: this
        // opens without following the symlink, then sets permissions on
        // whatever that resolves to.
        try out.appendSlice(arena,
            \\fn __lchmodSync(io: std.Io, path: []const u8, mode: i64) void {
            \\    var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only, .follow_symlinks = false }) catch return;
            \\    defer file.close(io);
            \\    file.setPermissions(io, std.Io.File.Permissions.fromMode(@intCast(mode))) catch {};
            \\}
            \\
        );
    }
    if (program.needs_fchown_sync) {
        try out.appendSlice(arena,
            \\fn __fchownSync(io: std.Io, fd: i32, uid: i64, gid: i64) void {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return;
            \\    const u: ?std.posix.uid_t = if (uid < 0) null else @intCast(uid);
            \\    const g: ?std.posix.gid_t = if (gid < 0) null else @intCast(gid);
            \\    __fd_table.items[@intCast(fd)].setOwner(io, u, g) catch {};
            \\}
            \\
        );
    }
    if (program.needs_fsync_sync) {
        // Backs both fsyncSync and fdatasyncSync: Zig's std.Io.File has no
        // data-only sync, so fdatasyncSync is treated as a full sync.
        try out.appendSlice(arena,
            \\fn __fsyncSync(io: std.Io, fd: i32) void {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return;
            \\    __fd_table.items[@intCast(fd)].sync(io) catch {};
            \\}
            \\
        );
    }
    if (program.needs_ftruncate_sync) {
        try out.appendSlice(arena,
            \\fn __ftruncateSync(io: std.Io, fd: i32, len: i64) void {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return;
            \\    __fd_table.items[@intCast(fd)].setLength(io, @intCast(len)) catch {};
            \\}
            \\
        );
    }
    if (program.needs_futimes_sync) {
        try out.appendSlice(arena,
            \\fn __futimesSync(io: std.Io, fd: i32, atime_ms: i64, mtime_ms: i64) void {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return;
            \\    __fd_table.items[@intCast(fd)].setTimestamps(io, .{
            \\        .access_timestamp = .{ .new = .{ .nanoseconds = @as(i96, atime_ms) * 1_000_000 } },
            \\        .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, mtime_ms) * 1_000_000 } },
            \\    }) catch {};
            \\}
            \\
        );
    }
    if (program.needs_utimes_sync) {
        // Backs both utimesSync (follow_symlinks=true) and lutimesSync (false).
        try out.appendSlice(arena,
            \\fn __utimesSync(io: std.Io, path: []const u8, atime_ms: i64, mtime_ms: i64, follow_symlinks: bool) void {
            \\    std.Io.Dir.cwd().setTimestamps(io, path, .{
            \\        .follow_symlinks = follow_symlinks,
            \\        .access_timestamp = .{ .new = .{ .nanoseconds = @as(i96, atime_ms) * 1_000_000 } },
            \\        .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, mtime_ms) * 1_000_000 } },
            \\    }) catch {};
            \\}
            \\
        );
    }
    if (program.needs_readdir_sync) {
        // string[] is already a plain []const []const u8 slice (not a
        // growable list), so this is a two-pass count-then-fill: no
        // Array.push language feature needed.
        try out.appendSlice(arena,
            \\fn __readdirSync(io: std.Io, alloc: std.mem.Allocator, path: []const u8) []const []const u8 {
            \\    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return &.{};
            \\    defer dir.close(io);
            \\    var count: usize = 0;
            \\    {
            \\        var it = dir.iterate();
            \\        while (it.next(io) catch null) |_| count += 1;
            \\    }
            \\    const names = alloc.alloc([]const u8, count) catch return &.{};
            \\    var it2 = dir.iterate();
            \\    var i: usize = 0;
            \\    while (i < count) {
            \\        const entry = (it2.next(io) catch null) orelse break;
            \\        names[i] = alloc.dupe(u8, entry.name) catch entry.name;
            \\        i += 1;
            \\    }
            \\    return names[0..i];
            \\}
            \\
        );
    }
    if (program.needs_path_api) {
        // path.* (spec 032): pure string manipulation, no Io parameter at all
        // -- the one stdlib namespace that doesn't thread `io` through.
        // __pathJoin/__pathResolve/normalize all reduce to std.fs.path.resolve:
        // its "cd"-chaining behavior (an absolute segment resets the result,
        // "." and ".." collapse without ever consulting a real working
        // directory) is exactly Node's path.resolve semantics, *except* Node
        // implicitly anchors a fully-relative input to process.cwd() and Zig
        // does not (this Zig version has no working Io.Dir.realpath to get a
        // real cwd string from, the same gap documented for fs.realpathSync).
        try out.appendSlice(arena,
            \\pub const __LumenPathParts = struct { root: []const u8, dir: []const u8, base: []const u8, name: []const u8, ext: []const u8 };
            \\fn __pathBasename(path: []const u8, suffix: []const u8) []const u8 {
            \\    const base = std.fs.path.basename(path);
            \\    if (suffix.len > 0 and base.len > suffix.len and std.mem.endsWith(u8, base, suffix)) {
            \\        return base[0 .. base.len - suffix.len];
            \\    }
            \\    return base;
            \\}
            \\fn __pathDirname(path: []const u8) []const u8 {
            \\    return std.fs.path.dirname(path) orelse ".";
            \\}
            \\fn __pathResolve(alloc: std.mem.Allocator, paths: []const []const u8) []const u8 {
            \\    return std.fs.path.resolve(alloc, paths) catch "";
            \\}
            \\fn __pathJoin(alloc: std.mem.Allocator, paths: []const []const u8) []const u8 {
            \\    const naive = std.fs.path.join(alloc, paths) catch return "";
            \\    return std.fs.path.resolve(alloc, &.{naive}) catch naive;
            \\}
            \\fn __pathParse(path: []const u8) __LumenPathParts {
            \\    const ext = std.fs.path.extension(path);
            \\    const base = std.fs.path.basename(path);
            \\    return .{
            \\        .root = if (std.fs.path.isAbsolute(path)) "/" else "",
            \\        .dir = std.fs.path.dirname(path) orelse "",
            \\        .base = base,
            \\        .name = base[0 .. base.len - ext.len],
            \\        .ext = ext,
            \\    };
            \\}
            \\fn __pathFormat(alloc: std.mem.Allocator, parts: __LumenPathParts) []const u8 {
            \\    const dir = if (parts.dir.len > 0) parts.dir else parts.root;
            \\    const base = if (parts.base.len > 0) parts.base else std.fmt.allocPrint(alloc, "{s}{s}", .{ parts.name, parts.ext }) catch "";
            \\    if (dir.len == 0) return base;
            \\    if (dir[dir.len - 1] == '/') return std.fmt.allocPrint(alloc, "{s}{s}", .{ dir, base }) catch base;
            \\    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, base }) catch base;
            \\}
            \\
        );
    }
    if (program.needs_process_api) {
        // cwd/chdir/env go through Io-abstracted (cwd/chdir) or entry-captured
        // (env, same mechanism as __args) primitives -- none of these need
        // libc linking. platform/arch are resolved at compile time.
        try out.appendSlice(arena,
            \\fn __processCwd(io: std.Io, alloc: std.mem.Allocator) []const u8 {
            \\    var buf: [std.fs.max_path_bytes]u8 = undefined;
            \\    const n = std.process.currentPath(io, &buf) catch return "";
            \\    return alloc.dupe(u8, buf[0..n]) catch "";
            \\}
            \\fn __processChdir(io: std.Io, path: []const u8) void {
            \\    std.process.setCurrentPath(io, path) catch {};
            \\}
            \\fn __processEnv(key: []const u8) ?[]const u8 {
            \\    const v = std.process.Environ.getPosix(__environ, key) orelse return null;
            \\    return v;
            \\}
            \\fn __processPlatform() []const u8 {
            \\    return switch (@import("builtin").os.tag) {
            \\        .linux => "linux",
            \\        .macos => "darwin",
            \\        .windows => "win32",
            \\        .freebsd => "freebsd",
            \\        .openbsd => "openbsd",
            \\        else => "unknown",
            \\    };
            \\}
            \\fn __processArch() []const u8 {
            \\    return switch (@import("builtin").cpu.arch) {
            \\        .x86_64 => "x64",
            \\        .x86 => "ia32",
            \\        .aarch64 => "arm64",
            \\        .arm => "arm",
            \\        .riscv64 => "riscv64",
            \\        else => "unknown",
            \\    };
            \\}
            \\fn __processPid() i32 {
            \\    if (@import("builtin").os.tag != .linux) return 0;
            \\    return @intCast(std.os.linux.getpid());
            \\}
            \\
        );
    }
    if (program.needs_os_api) {
        // Two raw Linux syscalls cover almost this whole namespace: uname()
        // (sysname/nodename/release/version/machine in one call) and
        // sysinfo() (uptime/loads/totalram/freeram in one call). No libc.
        // __osTmpdir/__osHomedir below reference __processEnv, only emitted
        // when program.needs_process_api is set -- safe because Zig only
        // semantically analyzes a function body when it's actually called,
        // and the checker sets needs_process_api whenever tmpdir/homedir
        // (the only functions here that call __processEnv) are used.
        try out.appendSlice(arena,
            \\fn __osUname() std.os.linux.utsname {
            \\    var uts: std.os.linux.utsname = std.mem.zeroes(std.os.linux.utsname);
            \\    if (@import("builtin").os.tag == .linux) _ = std.os.linux.uname(&uts);
            \\    return uts;
            \\}
            \\fn __osUnameField(comptime field: []const u8) []const u8 {
            \\    const uts = __osUname();
            \\    const s = std.mem.sliceTo(&@field(uts, field), 0);
            \\    return __alloc.dupe(u8, s) catch "";
            \\}
            \\fn __osEndianness() []const u8 {
            \\    return switch (@import("builtin").cpu.arch.endian()) {
            \\        .little => "LE",
            \\        .big => "BE",
            \\    };
            \\}
            \\fn __osTmpdir() []const u8 {
            \\    if (__processEnv("TMPDIR")) |v| return v;
            \\    if (__processEnv("TMP")) |v| return v;
            \\    if (__processEnv("TEMP")) |v| return v;
            \\    return "/tmp";
            \\}
            \\fn __osSysinfo() std.os.linux.Sysinfo {
            \\    var info: std.os.linux.Sysinfo = std.mem.zeroes(std.os.linux.Sysinfo);
            \\    if (@import("builtin").os.tag == .linux) _ = std.os.linux.sysinfo(&info);
            \\    return info;
            \\}
            \\fn __osMemBytes(total: bool) i32 {
            \\    const info = __osSysinfo();
            \\    const raw: u64 = if (total) @intCast(info.totalram) else @intCast(info.freeram);
            \\    const bytes: u64 = raw * @as(u64, @intCast(info.mem_unit));
            \\    return @truncate(@as(i64, @intCast(bytes)));
            \\}
            \\fn __osLoadavg(alloc: std.mem.Allocator) []const f64 {
            \\    const info = __osSysinfo();
            \\    const out = alloc.alloc(f64, 3) catch return &.{};
            \\    out[0] = @as(f64, @floatFromInt(info.loads[0])) / 65536.0;
            \\    out[1] = @as(f64, @floatFromInt(info.loads[1])) / 65536.0;
            \\    out[2] = @as(f64, @floatFromInt(info.loads[2])) / 65536.0;
            \\    return out;
            \\}
            \\
        );
    }
    if (program.needs_httpget) {
        // A real std.http one-shot GET, wrapped to a Lumen-friendly `i64` (status code, or -1 on error).
        try out.appendSlice(arena,
            \\fn __httpGet(io: std.Io, alloc: std.mem.Allocator, url: []const u8) i64 {
            \\    var client: std.http.Client = .{ .allocator = alloc, .io = io };
            \\    defer client.deinit();
            \\    client.ca_bundle.rescan(alloc, io, std.Io.Clock.now(.real, io)) catch return -1;
            \\    const res = client.fetch(.{ .location = .{ .url = url } }) catch return -1;
            \\    return @intFromEnum(res.status);
            \\}
            \\
        );
    }
    if (program.needs_serve) {
        // A real (blocking) HTTP server on std.Io.net — returns the same body to every request.
        try out.appendSlice(arena,
            \\fn __serve(io: std.Io, alloc: std.mem.Allocator, port: i64, body: []const u8) noreturn {
            \\    _ = alloc;
            \\    const addr = std.Io.net.IpAddress.parse("0.0.0.0", @intCast(port)) catch std.process.exit(1);
            \\    var server = addr.listen(io, .{ .reuse_address = true }) catch std.process.exit(1);
            \\    var hbuf: [256]u8 = undefined;
            \\    const head = std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch std.process.exit(1);
            \\    while (true) {
            \\        const stream = server.accept(io) catch continue;
            \\        var wbuf: [2048]u8 = undefined;
            \\        var w = stream.writer(io, &wbuf);
            \\        w.interface.writeAll(head) catch {};
            \\        w.interface.writeAll(body) catch {};
            \\        w.interface.flush() catch {};
            \\        stream.close(io);
            \\    }
            \\}
            \\
        );
    }
    if (program.uses_io) {
        try out.appendSlice(arena, "pub fn main(__init: std.process.Init) !void {\n");
        try out.appendSlice(arena, "    __io = __init.io;\n    __alloc = __init.arena.allocator();\n");
        if (program.needs_args) {
            try out.appendSlice(arena, "    __args = __init.minimal.args.toSlice(__alloc) catch std.process.exit(1);\n");
        }
        if (program.needs_process_api) {
            try out.appendSlice(arena, "    __environ = __init.minimal.environ;\n");
        }
        if (program.needs_async) {
            try out.appendSlice(arena, "    LumenLoop.init();\n");
        }
    } else {
        try out.appendSlice(arena, "pub fn main() void {\n");
    }
    try out.appendSlice(arena, body.items);
    // Drain any remaining timers/microtasks so fire-and-forget setTimeout
    // callbacks run before the program exits.
    if (program.needs_async) try out.appendSlice(arena, "    LumenLoop.drain();\n");
    try out.appendSlice(arena, "}\n");
    return out.items;
}
