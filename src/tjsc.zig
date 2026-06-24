//! tjsc — a Typed-JS → Zig → native compiler (proof of concept).
//!
//! NOT part of the ECMAScript engine or the Test262 path. A SEPARATE, self-contained front-end that
//! takes a small statically-typed JS-like language and lowers it to **Zig source**, which `zig
//! build-exe` then turns into a native binary. Using Zig (LLVM) as the codegen backend means we only
//! write the front-end + lowering; optimization, native codegen and cross-compilation come free.
//!
//! Cycle 1 (spec 142): the end-to-end skeleton — integer arithmetic + `print(expr);` → a Zig program
//! that prints each result. Proves the parse → emit-Zig → native pipeline. Later cycles add typed
//! variables/functions, control flow + a type checker, and composite types.
const std = @import("std");

pub const CompileError = error{ ParseError, OutOfMemory };

// ── AST ──────────────────────────────────────────────────────────────────────
const Expr = union(enum) {
    num: i64,
    var_ref: []const u8,
    neg: *Expr,
    bin: struct { op: u8, l: *Expr, r: *Expr },
};

/// Map a typed-JS type name to its Zig type. Accepts TS-ish aliases.
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
    op: u8, // + - * / ( ) ; ,
    ident: []const u8,
    eof,
};

const Lexer = struct {
    src: []const u8,
    i: usize = 0,

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
    }
    fn isIdentPart(c: u8) bool {
        return isIdentStart(c) or (c >= '0' and c <= '9');
    }

    fn next(self: *Lexer) CompileError!Tok {
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.i += 1;
                continue;
            }
            // line comment
            if (c == '/' and self.i + 1 < self.src.len and self.src[self.i + 1] == '/') {
                while (self.i < self.src.len and self.src[self.i] != '\n') self.i += 1;
                continue;
            }
            break;
        }
        if (self.i >= self.src.len) return .eof;
        const c = self.src[self.i];
        switch (c) {
            '+', '-', '*', '/', '(', ')', ';', ',', '.', ':', '=' => {
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

    fn init(arena: std.mem.Allocator, src: []const u8) CompileError!Parser {
        var lex = Lexer{ .src = src };
        const first = try lex.next();
        return .{ .arena = arena, .lex = lex, .cur = first };
    }
    fn advance(self: *Parser) CompileError!void {
        self.cur = try self.lex.next();
    }
    fn isOp(self: *Parser, ch: u8) bool {
        return self.cur == .op and self.cur.op == ch;
    }
    fn expectOp(self: *Parser, ch: u8) CompileError!void {
        if (!self.isOp(ch)) return error.ParseError;
        try self.advance();
    }
    fn node(self: *Parser, e: Expr) CompileError!*Expr {
        const p = try self.arena.create(Expr);
        p.* = e;
        return p;
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
        while (self.isOp('*') or self.isOp('/')) {
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
        return self.parsePrimary();
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
            const e = try self.parseAdd();
            try self.expectOp(')');
            return e;
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
            try w.append(arena, '(');
            try emitExpr(b.l, w, arena);
            try w.print(arena, " {c} ", .{b.op});
            try emitExpr(b.r, w, arena);
            try w.append(arena, ')');
        },
    }
}

/// Compile typed-JS `source` to Zig source text. Cycle 1: a sequence of `print(<int expr>);`.
pub fn compileToZig(arena: std.mem.Allocator, source: []const u8) CompileError![]const u8 {
    var p = try Parser.init(arena, source);
    var body: std.ArrayListUnmanaged(u8) = .empty;

    while (p.cur != .eof) {
        if (p.cur != .ident) return error.ParseError;
        const kw = p.cur.ident;
        if (std.mem.eql(u8, kw, "let")) {
            // let <name> : <type> = <expr> ;
            try p.advance();
            if (p.cur != .ident) return error.ParseError;
            const name = p.cur.ident;
            try p.advance();
            try p.expectOp(':');
            if (p.cur != .ident) return error.ParseError;
            const zty = mapType(p.cur.ident) orelse return error.ParseError;
            try p.advance();
            try p.expectOp('=');
            const e = try p.parseAdd();
            try p.expectOp(';');
            try body.print(arena, "    const {s}: {s} = ", .{ name, zty });
            try emitExpr(e, &body, arena);
            try body.appendSlice(arena, ";\n");
        } else if (std.mem.eql(u8, kw, "console")) {
            // console . log ( <expr> ) ;
            try p.advance();
            try p.expectOp('.');
            if (p.cur != .ident or !std.mem.eql(u8, p.cur.ident, "log")) return error.ParseError;
            try p.advance();
            try p.expectOp('(');
            const e = try p.parseAdd();
            try p.expectOp(')');
            try p.expectOp(';');
            try body.appendSlice(arena, "    std.debug.print(\"{d}\\n\", .{");
            try emitExpr(e, &body, arena);
            try body.appendSlice(arena, "});\n");
        } else return error.ParseError;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(arena, "const std = @import(\"std\");\npub fn main() void {\n");
    try out.appendSlice(arena, body.items);
    try out.appendSlice(arena, "}\n");
    return out.items;
}
