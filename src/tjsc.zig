//! tjsc — a Typed-JS → Zig → native compiler (proof of concept).
//!
//! NOT part of the ECMAScript engine or the Test262 path. A SEPARATE, self-contained front-end that
//! takes a small statically-typed JS-like language and lowers it to **Zig source**, which `zig
//! build-exe` then turns into a native binary. Using Zig (LLVM) as the codegen backend means we only
//! write the front-end + lowering; optimization, native codegen and cross-compilation come free.
//!
//! Supported (spec 142): typed `const`/`let`(immutable) and `var`(mutable) declarations
//! (`int`/`i64`, `number`/`f64`, `bool`), arithmetic (`+ - * / %`, precedence + parens + unary `-`),
//! comparisons (`< > <= >= == !=`), `while` loops + assignment, typed objects (`type T = {…}` →
//! struct, object literals, field access), and `console.log`.
const std = @import("std");

pub const CompileError = error{ ParseError, OutOfMemory };

// ── AST ──────────────────────────────────────────────────────────────────────
const FieldInit = struct { name: []const u8, value: *Expr };

const Expr = union(enum) {
    num: i64,
    var_ref: []const u8,
    neg: *Expr,
    bin: struct { op: u8, l: *Expr, r: *Expr }, // + - * / %
    cmp: struct { op: []const u8, l: *Expr, r: *Expr }, // < > <= >= == !=
    obj: []FieldInit,
    field: struct { obj: *Expr, name: []const u8 },
};

/// Map a typed-JS type name to its Zig type. Accepts TS-ish aliases; unknown names pass through (a
/// struct type declared with `type`).
fn mapType(name: []const u8) ?[]const u8 {
    const eq = std.mem.eql;
    if (eq(u8, name, "int") or eq(u8, name, "i64")) return "i64";
    if (eq(u8, name, "number") or eq(u8, name, "float") or eq(u8, name, "f64")) return "f64";
    if (eq(u8, name, "bool") or eq(u8, name, "boolean")) return "bool";
    return null;
}

// ── lexer ────────────────────────────────────────────────────────────────────
const Tok = union(enum) {
    num: i64,
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

// ── parser ───────────────────────────────────────────────────────────────────
const Parser = struct {
    arena: std.mem.Allocator,
    lex: Lexer,
    cur: Tok,
    cur_line: u32 = 1, // source line of `cur`
    cur_col: u32 = 1, // source column of `cur`

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
        if (self.cur == .ident) {
            const name = self.cur.ident;
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
    // Track the source line+col so a runtime panic can report the .tjs location (Zig has no #line).
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
    } else {
        // assignment: <name> = <expr> ;
        const name = kw;
        try p.advance();
        try p.expectOp('=');
        const e = try p.parseExpr();
        try p.expectOp(';');
        try out.print(arena, "    {s} = ", .{name});
        try emitExpr(e, out, arena);
        try out.appendSlice(arena, ";\n");
    }
}

/// Compile typed-JS `source` (from `filename`) to Zig source text. `filename` is embedded so a
/// runtime panic reports the .tjs location.
pub fn compileToZig(arena: std.mem.Allocator, source: []const u8, filename: []const u8) CompileError![]const u8 {
    var p = try Parser.init(arena, source);
    var decls: std.ArrayListUnmanaged(u8) = .empty; // top-level struct type definitions
    var body: std.ArrayListUnmanaged(u8) = .empty;

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
            try emitStmt(&p, &body, arena);
        }
    }

    // Sanitize the filename for a Zig string literal (backslashes/quotes break it).
    const safe_name = try arena.dupe(u8, filename);
    for (safe_name) |*ch| if (ch.* == '\\' or ch.* == '"') {
        ch.* = '/';
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(arena, "const std = @import(\"std\");\n");
    try out.print(arena, "const __tjs_file = \"{s}\";\n", .{safe_name});
    try out.appendSlice(arena, "var __tjs_line: u32 = 0;\nvar __tjs_col: u32 = 0;\n");
    // Embed the .tjs source as a multiline string (no escaping needed) so the handler can show the line.
    try out.appendSlice(arena, "const __tjs_src =\n");
    {
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |l| {
            const t = std.mem.trimEnd(u8, l, "\r");
            try out.print(arena, "    \\\\{s}\n", .{t});
        }
    }
    try out.appendSlice(arena, ";\n");
    // Custom panic handler → map the native runtime error back to the .tjs source: file:line:col +
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
    try out.appendSlice(arena, "pub fn main() void {\n");
    try out.appendSlice(arena, body.items);
    try out.appendSlice(arena, "}\n");
    return out.items;
}
