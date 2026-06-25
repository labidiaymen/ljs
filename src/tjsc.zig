//! TypeScript-syntax -> Zig -> native compiler seed.
//!
//! NOT part of the ECMAScript engine or the Test262 path. A SEPARATE,
//! self-contained front-end that takes a small statically-typed TypeScript
//! syntax subset and lowers it to Zig source, which `zig build-exe` then turns
//! into a native binary. Using Zig as the backend means we write the front-end
//! and lowering first; optimization, native codegen, and cross-compilation come
//! from Zig/LLVM.
//!
//! Current seed: typed `const`/`let`(immutable) and `var`(mutable) declarations
//! (`int`/`i64`, `number`/`f64`, `bool`), arithmetic (`+ - * / %`, precedence + parens + unary `-`),
//! comparisons (`< > <= >= == !=`), `while` loops + assignment, typed objects (`type T = {…}` →
//! struct, object literals, field access), and `console.log`.
const std = @import("std");

pub const CompileError = error{ ParseError, OutOfMemory };

/// A compile-time diagnostic, located in the .ts source.
pub const Diag = struct { line: u32 = 0, col: u32 = 0, msg: []const u8 = "syntax error" };

// ── AST ──────────────────────────────────────────────────────────────────────
const FieldInit = struct { name: []const u8, value: *Expr };

const Expr = union(enum) {
    num: i64,
    str: []const u8,
    var_ref: []const u8,
    neg: *Expr,
    bin: struct { op: u8, l: *Expr, r: *Expr }, // + - * / %
    cmp: struct { op: []const u8, l: *Expr, r: *Expr }, // < > <= >= == !=
    obj: []FieldInit,
    field: struct { obj: *Expr, name: []const u8 },
    call: struct { name: []const u8, args: []*Expr }, // builtin call, e.g. httpGet(url) / serve(port, body)
};

/// Builtins that lower to a Zig std wrapper (need __io/__alloc threaded in).
fn isBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "httpGet") or std.mem.eql(u8, name, "serve");
}

/// Map a source type name to its Zig type. Accepts TS-ish aliases; unknown names pass through (a
/// struct type declared with `type`).
fn mapType(name: []const u8) ?[]const u8 {
    const eq = std.mem.eql;
    if (eq(u8, name, "int") or eq(u8, name, "i32")) return "i32";
    if (eq(u8, name, "i64")) return "i64";
    if (eq(u8, name, "number") or eq(u8, name, "float") or eq(u8, name, "f64")) return "f64";
    if (eq(u8, name, "bool") or eq(u8, name, "boolean")) return "bool";
    if (eq(u8, name, "string")) return "[]const u8";
    return null;
}

// ── lexer ────────────────────────────────────────────────────────────────────
const Tok = union(enum) {
    num: i64,
    str: []const u8, // string literal content (raw, between quotes)
    op: u8, // + - * / % ( ) { } ; , . : =
    cmp: []const u8, // < > <= >= == !=
    ident: []const u8,
    eof,
};

const Lexer = struct {
    src: []const u8,
    i: usize = 0,
    line: u32 = 1, // current source line
    line_start: usize = 0, // byte index where the current line begins (for column math)
    tok_line: u32 = 1, // line where the most-recently-returned token starts
    tok_col: u32 = 1, // column where that token starts (1-based)

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
    }
    fn isIdentPart(c: u8) bool {
        return isIdentStart(c) or (c >= '0' and c <= '9');
    }

    fn next(self: *Lexer) CompileError!Tok {
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == '\n') {
                self.line += 1;
                self.i += 1;
                self.line_start = self.i;
                continue;
            }
            if (c == ' ' or c == '\t' or c == '\r') {
                self.i += 1;
                continue;
            }
            if (c == '/' and self.i + 1 < self.src.len and self.src[self.i + 1] == '/') {
                while (self.i < self.src.len and self.src[self.i] != '\n') self.i += 1;
                continue;
            }
            break;
        }
        self.tok_line = self.line;
        self.tok_col = @intCast(self.i - self.line_start + 1);
        if (self.i >= self.src.len) return .eof;
        const c = self.src[self.i];

        // comparison / assignment: < > = !  (with optional trailing '=')
        if (c == '<' or c == '>' or c == '=' or c == '!') {
            const two = self.i + 1 < self.src.len and self.src[self.i + 1] == '=';
            if (c == '=' and !two) {
                self.i += 1;
                return .{ .op = '=' };
            }
            if (c == '!' and !two) return error.ParseError; // bare '!' unsupported
            if (two) {
                const s = self.src[self.i .. self.i + 2];
                self.i += 2;
                return .{ .cmp = s };
            }
            const s = self.src[self.i .. self.i + 1]; // '<' or '>'
            self.i += 1;
            return .{ .cmp = s };
        }
        if (c == '"') {
            self.i += 1;
            const start = self.i;
            while (self.i < self.src.len and self.src[self.i] != '"') {
                if (self.src[self.i] == '\\' and self.i + 1 < self.src.len) self.i += 1;
                self.i += 1;
            }
            const s = self.src[start..self.i];
            if (self.i < self.src.len) self.i += 1; // consume closing quote
            return .{ .str = s };
        }
        switch (c) {
            '+', '-', '*', '/', '%', '(', ')', ';', ',', '.', ':', '{', '}' => {
                self.i += 1;
                return .{ .op = c };
            },
            else => {},
        }
        if (c >= '0' and c <= '9') {
            var v: i64 = 0;
            while (self.i < self.src.len and self.src[self.i] >= '0' and self.src[self.i] <= '9') {
                v = v * 10 + @as(i64, self.src[self.i] - '0');
                self.i += 1;
            }
            return .{ .num = v };
        }
        if (isIdentStart(c)) {
            const start = self.i;
            while (self.i < self.src.len and isIdentPart(self.src[self.i])) self.i += 1;
            return .{ .ident = self.src[start..self.i] };
        }
        return error.ParseError;
    }
};

fn setDiag(diag: *Diag, line: u32, col: u32, msg: []const u8) CompileError {
    diag.* = .{ .line = line, .col = col, .msg = msg };
    return error.ParseError;
}

fn rejectUnsupportedDynamic(source: []const u8, diag: *Diag) CompileError!void {
    const eq = std.mem.eql;
    var lex = Lexer{ .src = source };
    var prev_was_dot = false;

    while (true) {
        const tok = lex.next() catch {
            return setDiag(diag, lex.tok_line, lex.tok_col, "syntax error");
        };
        switch (tok) {
            .eof => return,
            .ident => |name| {
                if (eq(u8, name, "eval")) {
                    return setDiag(diag, lex.tok_line, lex.tok_col, "E_UNSUPPORTED_EVAL");
                }
                if (eq(u8, name, "require")) {
                    return setDiag(diag, lex.tok_line, lex.tok_col, "E_UNSUPPORTED_COMMONJS");
                }
                if (prev_was_dot and eq(u8, name, "prototype")) {
                    return setDiag(diag, lex.tok_line, lex.tok_col, "E_UNSUPPORTED_PROTOTYPE");
                }
                prev_was_dot = false;
            },
            .op => |ch| prev_was_dot = ch == '.',
            else => prev_was_dot = false,
        }
    }
}

// ── parser ───────────────────────────────────────────────────────────────────
const Parser = struct {
    arena: std.mem.Allocator,
    lex: Lexer,
    cur: Tok,
    cur_line: u32 = 1, // source line of `cur`
    cur_col: u32 = 1, // source column of `cur`
    vars: std.StringHashMapUnmanaged(void) = .empty, // declared variable names (for undefined-var checks)
    last_err: []const u8 = "syntax error", // message for the next diagnostic
    uses_io: bool = false, // any io builtin used → emit the std.process.Init main (io + allocator)
    needs_httpget: bool = false, // emit the __httpGet wrapper
    needs_serve: bool = false, // emit the __serve wrapper

    fn declare(self: *Parser, name: []const u8) CompileError!void {
        self.vars.put(self.arena, name, {}) catch return error.OutOfMemory;
    }
    fn undefined_(self: *Parser, name: []const u8) CompileError {
        self.last_err = std.fmt.allocPrint(self.arena, "undefined variable '{s}'", .{name}) catch "undefined variable";
        return error.ParseError;
    }

    fn init(arena: std.mem.Allocator, src: []const u8) CompileError!Parser {
        var lex = Lexer{ .src = src };
        const first = try lex.next();
        return .{ .arena = arena, .lex = lex, .cur = first, .cur_line = lex.tok_line, .cur_col = lex.tok_col };
    }
    fn advance(self: *Parser) CompileError!void {
        self.cur = try self.lex.next();
        self.cur_line = self.lex.tok_line;
        self.cur_col = self.lex.tok_col;
    }
    fn isOp(self: *Parser, ch: u8) bool {
        return self.cur == .op and self.cur.op == ch;
    }
    fn expectOp(self: *Parser, ch: u8) CompileError!void {
        if (!self.isOp(ch)) return error.ParseError;
        try self.advance();
    }
    fn isKw(self: *Parser, kw: []const u8) bool {
        return self.cur == .ident and std.mem.eql(u8, self.cur.ident, kw);
    }
    fn node(self: *Parser, e: Expr) CompileError!*Expr {
        const p = try self.arena.create(Expr);
        p.* = e;
        return p;
    }

    fn parseExpr(self: *Parser) CompileError!*Expr {
        return self.parseCmp();
    }
    fn parseCmp(self: *Parser) CompileError!*Expr {
        var left = try self.parseAdd();
        if (self.cur == .cmp) {
            const op = self.cur.cmp;
            try self.advance();
            const right = try self.parseAdd();
            left = try self.node(.{ .cmp = .{ .op = op, .l = left, .r = right } });
        }
        return left;
    }
    fn parseAdd(self: *Parser) CompileError!*Expr {
        var left = try self.parseMul();
        while (self.isOp('+') or self.isOp('-')) {
            const op = self.cur.op;
            try self.advance();
            const right = try self.parseMul();
            left = try self.node(.{ .bin = .{ .op = op, .l = left, .r = right } });
        }
        return left;
    }
    fn parseMul(self: *Parser) CompileError!*Expr {
        var left = try self.parseUnary();
        while (self.isOp('*') or self.isOp('/') or self.isOp('%')) {
            const op = self.cur.op;
            try self.advance();
            const right = try self.parseUnary();
            left = try self.node(.{ .bin = .{ .op = op, .l = left, .r = right } });
        }
        return left;
    }
    fn parseUnary(self: *Parser) CompileError!*Expr {
        if (self.isOp('-')) {
            try self.advance();
            return self.node(.{ .neg = try self.parseUnary() });
        }
        return self.parsePostfix();
    }
    fn parsePostfix(self: *Parser) CompileError!*Expr {
        var e = try self.parsePrimary();
        while (self.isOp('.')) {
            try self.advance();
            if (self.cur != .ident) return error.ParseError;
            const name = self.cur.ident;
            try self.advance();
            e = try self.node(.{ .field = .{ .obj = e, .name = name } });
        }
        return e;
    }
    fn parsePrimary(self: *Parser) CompileError!*Expr {
        if (self.cur == .num) {
            const v = self.cur.num;
            try self.advance();
            return self.node(.{ .num = v });
        }
        if (self.cur == .str) {
            const s = self.cur.str;
            try self.advance();
            return self.node(.{ .str = s });
        }
        if (self.cur == .ident) {
            const name = self.cur.ident;
            if (isBuiltin(name)) {
                try self.advance();
                try self.expectOp('(');
                var args: std.ArrayListUnmanaged(*Expr) = .empty;
                while (!self.isOp(')')) {
                    try args.append(self.arena, try self.parseExpr());
                    if (self.isOp(',')) try self.advance() else break;
                }
                try self.expectOp(')');
                self.uses_io = true;
                if (std.mem.eql(u8, name, "httpGet")) self.needs_httpget = true;
                if (std.mem.eql(u8, name, "serve")) self.needs_serve = true;
                return self.node(.{ .call = .{ .name = name, .args = try args.toOwnedSlice(self.arena) } });
            }
            if (!self.vars.contains(name)) return self.undefined_(name);
            try self.advance();
            return self.node(.{ .var_ref = name });
        }
        if (self.isOp('(')) {
            try self.advance();
            const e = try self.parseExpr();
            try self.expectOp(')');
            return e;
        }
        if (self.isOp('{')) {
            try self.advance();
            var fields: std.ArrayListUnmanaged(FieldInit) = .empty;
            while (!self.isOp('}')) {
                if (self.cur != .ident) return error.ParseError;
                const fname = self.cur.ident;
                try self.advance();
                try self.expectOp(':');
                const v = try self.parseExpr();
                try fields.append(self.arena, .{ .name = fname, .value = v });
                if (self.isOp(',')) try self.advance() else break;
            }
            try self.expectOp('}');
            return self.node(.{ .obj = try fields.toOwnedSlice(self.arena) });
        }
        return error.ParseError;
    }
};

// ── emit ─────────────────────────────────────────────────────────────────────
fn emitExpr(e: *const Expr, w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    switch (e.*) {
        .num => |v| try w.print(arena, "{d}", .{v}),
        .str => |s| {
            try w.append(arena, '"');
            for (s) |ch| {
                if (ch == '"' or ch == '\\') try w.append(arena, '\\');
                try w.append(arena, ch);
            }
            try w.append(arena, '"');
        },
        .call => |cl| {
            // builtins lower to a Zig std wrapper taking (__io, __alloc, args...).
            if (std.mem.eql(u8, cl.name, "httpGet")) {
                try w.appendSlice(arena, "__httpGet(__io, __alloc, ");
                if (cl.args.len > 0) try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.name, "serve")) {
                try w.appendSlice(arena, "__serve(__io, __alloc, ");
                if (cl.args.len > 0) try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                if (cl.args.len > 1) try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            }
        },
        .var_ref => |name| try w.appendSlice(arena, name),
        .neg => |inner| {
            try w.appendSlice(arena, "-(");
            try emitExpr(inner, w, arena);
            try w.append(arena, ')');
        },
        .bin => |b| {
            if (b.op == '%') {
                // Zig's `%` rejects signed operands → use @rem (operands are non-negative here).
                try w.appendSlice(arena, "@rem(");
                try emitExpr(b.l, w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(b.r, w, arena);
                try w.append(arena, ')');
            } else {
                try w.append(arena, '(');
                try emitExpr(b.l, w, arena);
                try w.print(arena, " {c} ", .{b.op});
                try emitExpr(b.r, w, arena);
                try w.append(arena, ')');
            }
        },
        .cmp => |b| {
            try w.append(arena, '(');
            try emitExpr(b.l, w, arena);
            try w.print(arena, " {s} ", .{b.op});
            try emitExpr(b.r, w, arena);
            try w.append(arena, ')');
        },
        .obj => |fields| {
            try w.appendSlice(arena, ".{ ");
            for (fields, 0..) |f, i| {
                if (i > 0) try w.appendSlice(arena, ", ");
                try w.print(arena, ".{s} = ", .{f.name});
                try emitExpr(f.value, w, arena);
            }
            try w.appendSlice(arena, " }");
        },
        .field => |fa| {
            try emitExpr(fa.obj, w, arena);
            try w.print(arena, ".{s}", .{fa.name});
        },
    }
}

/// Emit one executable statement (recurses for `while` bodies).
fn emitStmt(p: *Parser, out: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    const eq = std.mem.eql;
    if (p.cur != .ident) return error.ParseError;
    const kw = p.cur.ident;
    // Track the source line+col so a runtime panic can report the .ts location (Zig has no #line).
    try out.print(arena, "    __tjs_line = {d}; __tjs_col = {d};\n", .{ p.cur_line, p.cur_col });

    if (eq(u8, kw, "let") or eq(u8, kw, "const") or eq(u8, kw, "var")) {
        const mutable = eq(u8, kw, "var");
        try p.advance();
        if (p.cur != .ident) return error.ParseError;
        const name = p.cur.ident;
        try p.advance();
        try p.expectOp(':');
        if (p.cur != .ident) return error.ParseError;
        const zty = mapType(p.cur.ident) orelse p.cur.ident;
        try p.advance();
        try p.expectOp('=');
        const e = try p.parseExpr();
        try p.expectOp(';');
        try p.declare(name); // in scope after its initializer (so `let x = x` is undefined)
        try out.print(arena, "    {s} {s}: {s} = ", .{ if (mutable) "var" else "const", name, zty });
        try emitExpr(e, out, arena);
        try out.appendSlice(arena, ";\n");
    } else if (eq(u8, kw, "console")) {
        try p.advance();
        try p.expectOp('.');
        if (!p.isKw("log")) return error.ParseError;
        try p.advance();
        try p.expectOp('(');
        const e = try p.parseExpr();
        try p.expectOp(')');
        try p.expectOp(';');
        try out.appendSlice(arena, "    std.debug.print(\"{d}\\n\", .{");
        try emitExpr(e, out, arena);
        try out.appendSlice(arena, "});\n");
    } else if (eq(u8, kw, "while")) {
        try p.advance();
        try p.expectOp('(');
        const cond = try p.parseExpr();
        try p.expectOp(')');
        try p.expectOp('{');
        try out.appendSlice(arena, "    while (");
        try emitExpr(cond, out, arena);
        try out.appendSlice(arena, ") {\n");
        while (!p.isOp('}')) try emitStmt(p, out, arena);
        try p.expectOp('}');
        try out.appendSlice(arena, "    }\n");
    } else if (isBuiltin(kw)) {
        // expression statement: a builtin call, e.g. serve(8080, "hi");
        const e = try p.parseExpr();
        try p.expectOp(';');
        // `serve` is noreturn; other builtins return a value that must be discarded.
        try out.appendSlice(arena, if (std.mem.eql(u8, kw, "serve")) "    " else "    _ = ");
        try emitExpr(e, out, arena);
        try out.appendSlice(arena, ";\n");
    } else {
        // assignment: <name> = <expr> ;
        const name = kw;
        if (!p.vars.contains(name)) return p.undefined_(name);
        try p.advance();
        try p.expectOp('=');
        const e = try p.parseExpr();
        try p.expectOp(';');
        try out.print(arena, "    {s} = ", .{name});
        try emitExpr(e, out, arena);
        try out.appendSlice(arena, ";\n");
    }
}

/// Parse every top-level construct, emitting struct defs into `decls` and statements into `body`.
fn lower(p: *Parser, decls: *std.ArrayListUnmanaged(u8), body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    while (p.cur != .eof) {
        if (p.isKw("type")) {
            // type <Name> = { field: type, ... } ;   →   const Name = struct { field: ztype, ... };
            try p.advance();
            if (p.cur != .ident) return error.ParseError;
            const tname = p.cur.ident;
            try p.advance();
            try p.expectOp('=');
            try p.expectOp('{');
            try decls.print(arena, "const {s} = struct {{\n", .{tname});
            while (!p.isOp('}')) {
                if (p.cur != .ident) return error.ParseError;
                const fname = p.cur.ident;
                try p.advance();
                try p.expectOp(':');
                if (p.cur != .ident) return error.ParseError;
                const fty = mapType(p.cur.ident) orelse p.cur.ident;
                try p.advance();
                try decls.print(arena, "    {s}: {s},\n", .{ fname, fty });
                if (p.isOp(',')) try p.advance() else break;
            }
            try p.expectOp('}');
            if (p.isOp(';')) try p.advance();
            try decls.appendSlice(arena, "};\n");
        } else {
            try emitStmt(p, body, arena);
        }
    }
}

/// Compile TypeScript-syntax `source` (from `filename`) to Zig source text. On a compile-time error,
/// `diag` is filled (located in the .ts source) and `error.ParseError` returned. `filename` is also
/// embedded so a runtime panic reports the .ts location.
pub fn compileToZig(arena: std.mem.Allocator, source: []const u8, filename: []const u8, diag: *Diag) CompileError![]const u8 {
    try rejectUnsupportedDynamic(source, diag);

    var p = try Parser.init(arena, source);
    var decls: std.ArrayListUnmanaged(u8) = .empty; // top-level struct type definitions
    var body: std.ArrayListUnmanaged(u8) = .empty;

    lower(&p, &decls, &body, arena) catch |e| {
        diag.* = .{ .line = p.cur_line, .col = p.cur_col, .msg = p.last_err };
        return e;
    };

    // Sanitize the filename for a Zig string literal (backslashes/quotes break it).
    const safe_name = try arena.dupe(u8, filename);
    for (safe_name) |*ch| if (ch.* == '\\' or ch.* == '"') {
        ch.* = '/';
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(arena, "const std = @import(\"std\");\n");
    try out.print(arena, "const __tjs_file = \"{s}\";\n", .{safe_name});
    try out.appendSlice(arena, "var __tjs_line: u32 = 0;\nvar __tjs_col: u32 = 0;\n");
    // Embed the .ts source as a multiline string (no escaping needed) so the handler can show the line.
    try out.appendSlice(arena, "const __tjs_src =\n");
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
        \\fn __tjsPanic(msg: []const u8, _: ?usize) noreturn {
        \\    std.debug.print("\n{s}:{d}:{d}: runtime error: {s}\n", .{ __tjs_file, __tjs_line, __tjs_col, msg });
        \\    var __it = std.mem.splitScalar(u8, __tjs_src, '\n');
        \\    var __n: u32 = 1;
        \\    while (__it.next()) |__l| : (__n += 1) {
        \\        if (__n == __tjs_line) {
        \\            std.debug.print("  {d} | {s}\n    | ", .{ __tjs_line, __l });
        \\            var __k: u32 = 1;
        \\            while (__k < __tjs_col) : (__k += 1) std.debug.print(" ", .{});
        \\            std.debug.print("^\n", .{});
        \\            break;
        \\        }
        \\    }
        \\    std.process.exit(1);
        \\}
        \\pub const panic = std.debug.FullPanic(__tjsPanic);
        \\
    );
    try out.appendSlice(arena, decls.items);

    if (p.needs_httpget) {
        // A real std.http one-shot GET, wrapped to a tjs-friendly `i64` (status code, or -1 on error).
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
    if (p.needs_serve) {
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
    if (p.uses_io) {
        try out.appendSlice(arena, "pub fn main(__init: std.process.Init) !void {\n");
        try out.appendSlice(arena, "    const __io = __init.io;\n    const __alloc = __init.arena.allocator();\n");
    } else {
        try out.appendSlice(arena, "pub fn main() void {\n");
    }
    try out.appendSlice(arena, body.items);
    try out.appendSlice(arena, "}\n");
    return out.items;
}
