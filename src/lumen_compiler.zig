//! TypeScript-syntax -> Zig -> native compiler seed.
//!
//! NOT part of the ECMAScript engine or the Test262 path. A SEPARATE,
//! self-contained front-end that takes a small statically-typed TypeScript
//! syntax subset and lowers it to Zig source, which `zig build-exe` then turns
//! into a native binary. Using Zig as the backend means we write the front-end
//! and lowering first; optimization, native codegen, and cross-compilation come
//! from Zig/LLVM.
//!
//! Current seed: inferred and typed `let`(mutable), `const`(immutable), and `var` declarations
//! (`int`/`i32`/`i64`, `number`/`f64`, `bool`), arithmetic (`+ - * / %`, precedence + parens + unary `-`),
//! comparisons (`< > <= >= == !=`), `while` loops + assignment, typed objects (`type T = {…}` →
//! struct, object literals, field access), and `console.log`.
const std = @import("std");
const ast = @import("lumen_ast.zig");
const check = @import("lumen_check.zig");
const diag_mod = @import("lumen_diag.zig");
const lexer = @import("lumen_lexer.zig");
const types = @import("lumen_types.zig");

pub const CompileError = diag_mod.CompileError;
pub const Diag = diag_mod.Diag;

const Expr = ast.Expr;
const FieldInit = ast.FieldInit;
const Lexer = lexer.Lexer;
const Program = ast.Program;
const Stmt = ast.Stmt;
const Tok = lexer.Tok;

const SourceLoc = struct { line: u32, col: u32 };

/// Builtins that lower to a Zig std wrapper (need __io/__alloc threaded in).
fn isBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "httpGet") or std.mem.eql(u8, name, "serve");
}

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
const Parser = struct {
    arena: std.mem.Allocator,
    lex: Lexer,
    cur: Tok,
    cur_line: u32 = 1, // source line of `cur`
    cur_col: u32 = 1, // source column of `cur`
    last_err: []const u8 = "syntax error", // message for the next diagnostic

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
    fn isOp2(self: *Parser, op: []const u8) bool {
        return self.cur == .op2 and std.mem.eql(u8, self.cur.op2, op);
    }
    fn isSpread(self: *Parser) bool {
        return self.cur == .op3 and std.mem.eql(u8, self.cur.op3, "...");
    }
    fn oneExpr(self: *Parser, value: i64) CompileError!*Expr {
        return self.node(.{ .num = value });
    }
    fn expectOp(self: *Parser, ch: u8) CompileError!void {
        if (!self.isOp(ch)) return error.ParseError;
        try self.advance();
    }
    fn isKw(self: *Parser, kw: []const u8) bool {
        return self.cur == .ident and std.mem.eql(u8, self.cur.ident, kw);
    }
    /// True when the token after `cur` is `(`. Restores parser state afterwards.
    fn peekIsOpenParen(self: *Parser) bool {
        const save_lex = self.lex;
        const save_cur = self.cur;
        const save_line = self.cur_line;
        const save_col = self.cur_col;
        self.advance() catch {};
        const result = self.isOp('(');
        self.lex = save_lex;
        self.cur = save_cur;
        self.cur_line = save_line;
        self.cur_col = save_col;
        return result;
    }
    fn node(self: *Parser, e: Expr) CompileError!*Expr {
        const p = try self.arena.create(Expr);
        p.* = e;
        return p;
    }
    fn isStdNamespace(name: []const u8) bool {
        return std.mem.eql(u8, name, "Math") or std.mem.eql(u8, name, "String") or std.mem.eql(u8, name, "Array") or std.mem.eql(u8, name, "fs") or std.mem.eql(u8, name, "Promise");
    }
    fn parseTypeMember(self: *Parser) CompileError![]const u8 {
        // A string-literal member type, e.g. a discriminant field `kind: "circle"`.
        // The annotation is recorded with quotes preserved so the checker can
        // recognize and compare the literal value.
        if (self.cur == .str) {
            const lit = std.fmt.allocPrint(self.arena, "\"{s}\"", .{self.cur.str}) catch return error.OutOfMemory;
            try self.advance();
            return lit;
        }
        if (self.cur != .ident) return error.ParseError;
        var base = self.cur.ident;
        try self.advance();
        // Generic type reference `Name<arg, ...>`. `Array<X>` is sugar for `X[]`;
        // any other `Name<...>` is recorded canonically for the checker to
        // specialize. (Nested `Name<Inner<...>>` is supported via recursion.)
        if (self.isCmp("<")) {
            try self.advance(); // '<'
            var args: std.ArrayListUnmanaged([]const u8) = .empty;
            while (!self.isCmp(">")) {
                try args.append(self.arena, try self.parseTypeAnnotation());
                if (self.isOp(',')) try self.advance() else break;
            }
            try self.consumeTypeArgClose();
            if (std.mem.eql(u8, base, "Array")) {
                if (args.items.len != 1) return error.ParseError;
                base = std.fmt.allocPrint(self.arena, "{s}[]", .{args.items[0]}) catch return error.OutOfMemory;
            } else {
                var buf: std.ArrayListUnmanaged(u8) = .empty;
                try buf.appendSlice(self.arena, base);
                try buf.append(self.arena, '<');
                for (args.items, 0..) |a, i| {
                    if (i > 0) try buf.append(self.arena, ',');
                    try buf.appendSlice(self.arena, a);
                }
                try buf.append(self.arena, '>');
                base = buf.items;
            }
        }
        if (self.isOp('[')) {
            try self.advance();
            try self.expectOp(']');
            return std.fmt.allocPrint(self.arena, "{s}[]", .{base}) catch error.OutOfMemory;
        }
        return base;
    }

    /// Consumes the `>` (or one level of a `>>` produced by nested type args)
    /// that closes a type-argument list inside an annotation.
    fn consumeTypeArgClose(self: *Parser) CompileError!void {
        if (self.isCmp(">")) {
            try self.advance();
            return;
        }
        // A trailing `>>` from `Outer<Inner<X>>` lexes as one op2 token; rewrite
        // it to a single `>` so the enclosing level can consume its own close.
        if (self.isOp2(">>")) {
            self.cur = .{ .cmp = ">" };
            return;
        }
        return error.ParseError;
    }

    /// Parses a type annotation. `T | null` / `T | undefined` (in either order)
    /// produce the canonical optional spelling `T?`; other `|` unions are
    /// deferred to a later milestone.
    /// Function type annotation `(name: T, ...) => R`, encoded canonically as
    /// `(T,...)=>R` for the checker to parse.
    fn parseFunctionType(self: *Parser) CompileError![]const u8 {
        try self.expectOp('(');
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        try buf.append(self.arena, '(');
        var first = true;
        while (!self.isOp(')')) {
            if (self.cur != .ident) return error.ParseError;
            try self.advance(); // param name
            try self.expectOp(':');
            const pty = try self.parseTypeAnnotation();
            if (!first) try buf.append(self.arena, ',');
            try buf.appendSlice(self.arena, pty);
            first = false;
            if (self.isOp(',')) try self.advance() else break;
        }
        try self.expectOp(')');
        if (!self.isOp2("=>")) return error.ParseError;
        try self.advance();
        const ret = try self.parseTypeAnnotation();
        try buf.appendSlice(self.arena, ")=>");
        try buf.appendSlice(self.arena, ret);
        return buf.items;
    }

    /// Tuple type annotation `[A, B, ...]`, encoded canonically as `[A,B,...]`
    /// for the checker to parse.
    fn parseTupleType(self: *Parser) CompileError![]const u8 {
        try self.expectOp('[');
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        try buf.append(self.arena, '[');
        var first = true;
        while (!self.isOp(']')) {
            const elem = try self.parseTypeAnnotation();
            if (!first) try buf.append(self.arena, ',');
            try buf.appendSlice(self.arena, elem);
            first = false;
            if (self.isOp(',')) try self.advance() else break;
        }
        try self.expectOp(']');
        if (first) return error.ParseError; // `[]` is not a tuple
        try buf.append(self.arena, ']');
        return buf.items;
    }

    fn parseTypeAnnotation(self: *Parser) CompileError![]const u8 {
        const eq = std.mem.eql;
        if (self.isOp('(')) return self.parseFunctionType();
        if (self.isOp('[')) return self.parseTupleType();
        var base = try self.parseTypeMember();
        var optional = false;
        while (self.isCmp("|")) {
            try self.advance();
            const member = try self.parseTypeMember();
            if (eq(u8, member, "null") or eq(u8, member, "undefined")) {
                optional = true;
            } else if (eq(u8, base, "null") or eq(u8, base, "undefined")) {
                base = member;
                optional = true;
            } else {
                return error.ParseError; // general unions: feature 005
            }
        }
        if (optional) return std.fmt.allocPrint(self.arena, "{s}?", .{base}) catch error.OutOfMemory;
        return base;
    }

    fn parseExpr(self: *Parser) CompileError!*Expr {
        return self.parseTernary();
    }

    /// Parses one array-literal element or call argument, recognizing a leading
    /// `...` spread (`...expr`) and wrapping it in a `spread` node.
    fn parseSpreadOrExpr(self: *Parser) CompileError!*Expr {
        if (self.isSpread()) {
            try self.advance();
            const inner = try self.parseExpr();
            return self.node(.{ .spread = inner });
        }
        return self.parseExpr();
    }

    /// Splits a template literal's raw inner text into literal-text and `${expr}`
    /// parts, sub-parsing each hole as an expression.
    fn parseTemplateParts(self: *Parser, raw: []const u8) CompileError![]ast.TemplatePart {
        var parts: std.ArrayListUnmanaged(ast.TemplatePart) = .empty;
        var i: usize = 0;
        var text_start: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                i += 2;
                continue;
            }
            if (raw[i] == '$' and i + 1 < raw.len and raw[i + 1] == '{') {
                if (i > text_start) try parts.append(self.arena, .{ .text = raw[text_start..i] });
                i += 2;
                const hole_start = i;
                var depth: u32 = 1;
                while (i < raw.len and depth > 0) {
                    if (raw[i] == '{') {
                        depth += 1;
                    } else if (raw[i] == '}') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                    i += 1;
                }
                const hole = raw[hole_start..i];
                if (i < raw.len) i += 1; // skip closing '}'
                text_start = i;
                var sub = try Parser.init(self.arena, hole);
                const e = try sub.parseExpr();
                try parts.append(self.arena, .{ .expr = e });
            } else {
                i += 1;
            }
        }
        if (raw.len > text_start) try parts.append(self.arena, .{ .text = raw[text_start..] });
        return parts.toOwnedSlice(self.arena);
    }
    fn parseTernary(self: *Parser) CompileError!*Expr {
        const cond = try self.parseCoalesce();
        if (!self.isOp('?')) return cond;
        try self.advance();
        const then_expr = try self.parseExpr();
        try self.expectOp(':');
        const else_expr = try self.parseExpr();
        return self.node(.{ .ternary = .{ .cond = cond, .then_expr = then_expr, .else_expr = else_expr } });
    }
    fn parseCoalesce(self: *Parser) CompileError!*Expr {
        var left = try self.parseOr();
        while (self.isOp2("??")) {
            try self.advance();
            const right = try self.parseOr();
            left = try self.node(.{ .coalesce = .{ .l = left, .r = right } });
        }
        return left;
    }
    fn isCmp(self: *Parser, op: []const u8) bool {
        return self.cur == .cmp and std.mem.eql(u8, self.cur.cmp, op);
    }
    fn isComparison(self: *Parser) bool {
        if (self.cur != .cmp) return false;
        const op = self.cur.cmp;
        return std.mem.eql(u8, op, "<") or
            std.mem.eql(u8, op, ">") or
            std.mem.eql(u8, op, "<=") or
            std.mem.eql(u8, op, ">=") or
            std.mem.eql(u8, op, "==") or
            std.mem.eql(u8, op, "!=");
    }
    fn parseOr(self: *Parser) CompileError!*Expr {
        var left = try self.parseAnd();
        while (self.isCmp("||")) {
            const op = self.cur.cmp;
            try self.advance();
            const right = try self.parseAnd();
            left = try self.node(.{ .bool_bin = .{ .op = op, .l = left, .r = right } });
        }
        return left;
    }
    fn parseAnd(self: *Parser) CompileError!*Expr {
        var left = try self.parseBitOr();
        while (self.isCmp("&&")) {
            const op = self.cur.cmp;
            try self.advance();
            const right = try self.parseBitOr();
            left = try self.node(.{ .bool_bin = .{ .op = op, .l = left, .r = right } });
        }
        return left;
    }
    fn parseBitOr(self: *Parser) CompileError!*Expr {
        var left = try self.parseBitXor();
        while (self.isCmp("|")) {
            try self.advance();
            const right = try self.parseBitXor();
            left = try self.node(.{ .bin = .{ .op = '|', .l = left, .r = right } });
        }
        return left;
    }
    fn parseBitXor(self: *Parser) CompileError!*Expr {
        var left = try self.parseBitAnd();
        while (self.isOp('^')) {
            try self.advance();
            const right = try self.parseBitAnd();
            left = try self.node(.{ .bin = .{ .op = '^', .l = left, .r = right } });
        }
        return left;
    }
    fn parseBitAnd(self: *Parser) CompileError!*Expr {
        var left = try self.parseCmp();
        while (self.isOp('&')) {
            try self.advance();
            const right = try self.parseCmp();
            left = try self.node(.{ .bin = .{ .op = '&', .l = left, .r = right } });
        }
        return left;
    }
    fn parseCmp(self: *Parser) CompileError!*Expr {
        var left = try self.parseShift();
        if (self.isComparison()) {
            const op = self.cur.cmp;
            try self.advance();
            const right = try self.parseShift();
            left = try self.node(.{ .cmp = .{ .op = op, .l = left, .r = right } });
        }
        return left;
    }
    fn parseShift(self: *Parser) CompileError!*Expr {
        var left = try self.parseAdd();
        while (self.isOp2("<<") or self.isOp2(">>")) {
            const op: u8 = if (self.isOp2("<<")) 'L' else 'R';
            try self.advance();
            const right = try self.parseAdd();
            left = try self.node(.{ .bin = .{ .op = op, .l = left, .r = right } });
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
        var left = try self.parseExp();
        while (self.isOp('*') or self.isOp('/') or self.isOp('%')) {
            const op = self.cur.op;
            try self.advance();
            const right = try self.parseExp();
            left = try self.node(.{ .bin = .{ .op = op, .l = left, .r = right } });
        }
        return left;
    }
    fn parseExp(self: *Parser) CompileError!*Expr {
        const left = try self.parseUnary();
        if (self.isOp2("**")) {
            try self.advance();
            const right = try self.parseExp(); // right-associative
            return self.node(.{ .bin = .{ .op = 'P', .l = left, .r = right } });
        }
        return left;
    }
    fn parseUnary(self: *Parser) CompileError!*Expr {
        // `await <expr>` — the operand is a Promise; yields the resolved value.
        if (self.isKw("await")) {
            try self.advance();
            return self.node(.{ .await_expr = try self.parseUnary() });
        }
        if (self.isOp('-')) {
            try self.advance();
            return self.node(.{ .neg = try self.parseUnary() });
        }
        if (self.isOp('!')) {
            try self.advance();
            return self.node(.{ .not = try self.parseUnary() });
        }
        if (self.isOp('~')) {
            try self.advance();
            return self.node(.{ .bnot = try self.parseUnary() });
        }
        var e = try self.parsePostfix();
        // Postfix `as T` type assertion (erased at emit; checked for safety).
        while (self.isKw("as")) {
            try self.advance();
            const annotation = try self.parseTypeAnnotation();
            e = try self.node(.{ .cast = .{ .inner = e, .annotation = annotation } });
        }
        return e;
    }
    fn parsePostfix(self: *Parser) CompileError!*Expr {
        return self.parsePostfixFrom(try self.parsePrimary());
    }
    fn parsePostfixFrom(self: *Parser, base: *Expr) CompileError!*Expr {
        var e = base;
        while (self.isOp('.') or self.isOp('[') or self.isOp2("?.")) {
            if (self.isOp2("?.")) {
                try self.advance();
                if (self.cur != .ident) return error.ParseError;
                const name = self.cur.ident;
                try self.advance();
                e = try self.node(.{ .field = .{ .obj = e, .name = name, .optional_chain = true } });
            } else if (self.isOp('.')) {
                try self.advance();
                if (self.cur != .ident) return error.ParseError;
                const name = self.cur.ident;
                try self.advance();
                if (self.isOp('(')) {
                    try self.expectOp('(');
                    var args: std.ArrayListUnmanaged(*Expr) = .empty;
                    while (!self.isOp(')')) {
                        try args.append(self.arena, try self.parseSpreadOrExpr());
                        if (self.isOp(',')) try self.advance() else break;
                    }
                    try self.expectOp(')');
                    if (e.* == .var_ref and isStdNamespace(e.var_ref.name)) {
                        e = try self.node(.{ .static_call = .{ .namespace = e.var_ref.name, .name = name, .args = try args.toOwnedSlice(self.arena) } });
                    } else {
                        // instance method call: obj.method(args)
                        e = try self.node(.{ .method_call = .{ .obj = e, .name = name, .args = try args.toOwnedSlice(self.arena) } });
                    }
                } else {
                    e = try self.node(.{ .field = .{ .obj = e, .name = name } });
                }
            } else {
                try self.advance();
                const index_value = try self.parseExpr();
                try self.expectOp(']');
                e = try self.node(.{ .index = .{ .obj = e, .value = index_value } });
            }
        }
        return e;
    }
    /// Lookahead: is the `(` at `cur` the start of an arrow function? Scans to
    /// the matching `)` and checks for a following `=>`, restoring parser state.
    fn looksLikeArrow(self: *Parser) bool {
        const save_lex = self.lex;
        const save_cur = self.cur;
        const save_line = self.cur_line;
        const save_col = self.cur_col;
        defer {
            self.lex = save_lex;
            self.cur = save_cur;
            self.cur_line = save_line;
            self.cur_col = save_col;
        }
        self.advance() catch return false; // consume '('
        var depth: u32 = 1;
        while (depth > 0) {
            if (self.cur == .eof) return false;
            if (self.isOp('(')) depth += 1;
            if (self.isOp(')')) depth -= 1;
            self.advance() catch return false;
        }
        return self.isOp2("=>");
    }

    /// `(x: T, ...) [: R] => expr` — typed params, expression body, no capture.
    fn parseArrow(self: *Parser) CompileError!*Expr {
        try self.expectOp('(');
        var params: std.ArrayListUnmanaged(ast.FunctionParam) = .empty;
        while (!self.isOp(')')) {
            if (self.cur != .ident) return error.ParseError;
            const pname = self.cur.ident;
            try self.advance();
            try self.expectOp(':');
            const annotation = try self.parseTypeAnnotation();
            try params.append(self.arena, .{ .name = pname, .annotation = annotation });
            if (self.isOp(',')) try self.advance() else break;
        }
        try self.expectOp(')');
        var ret_annotation: []const u8 = "";
        if (self.isOp(':')) {
            try self.advance();
            ret_annotation = try self.parseTypeAnnotation();
        }
        if (!self.isOp2("=>")) return error.ParseError;
        try self.advance();
        const body_expr = try self.parseExpr();
        const arrow = try self.arena.create(ast.ArrowExpr);
        arrow.* = .{ .params = try params.toOwnedSlice(self.arena), .return_annotation = ret_annotation, .body_expr = body_expr };
        return self.node(.{ .arrow = arrow });
    }

    /// Parse the single-expression body of a `defer(() => BODY)` helper. Unlike a
    /// normal statement, the body is followed by `)` (not `;`), so no trailing
    /// semicolon is consumed. `console.log(...)`/`console.error(...)` are
    /// recognized as console_log statements (they have no expression form); any
    /// other expression becomes an expression statement.
    fn parseDeferHelperBodyStmt(self: *Parser) CompileError!Stmt {
        const line = self.cur_line;
        const col = self.cur_col;
        if (self.isKw("console")) {
            try self.advance();
            try self.expectOp('.');
            if (self.cur != .ident) return error.ParseError;
            const method = self.cur.ident;
            if (!std.mem.eql(u8, method, "log") and !std.mem.eql(u8, method, "error")) {
                self.last_err = "E_UNSUPPORTED_STD";
                return error.ParseError;
            }
            try self.advance();
            try self.expectOp('(');
            const value = try self.parseExpr();
            try self.expectOp(')');
            return .{ .console_log = .{ .method = method, .value = value, .line = line, .col = col } };
        }
        const value = try self.parseExpr();
        return .{ .expr_stmt = .{ .value = value, .line = line, .col = col } };
    }

    fn parsePrimary(self: *Parser) CompileError!*Expr {
        if (self.cur == .num) {
            const v = self.cur.num;
            try self.advance();
            return self.node(.{ .num = v });
        }
        if (self.cur == .flt) {
            const v = self.cur.flt;
            try self.advance();
            return self.node(.{ .float = v });
        }
        if (self.isKw("true") or self.isKw("false")) {
            const v = self.isKw("true");
            try self.advance();
            return self.node(.{ .bool = v });
        }
        if (self.isKw("null") or self.isKw("undefined")) {
            try self.advance();
            return self.node(.null_lit);
        }
        if (self.isKw("this")) {
            try self.advance();
            return self.node(.this_expr);
        }
        if (self.isKw("super")) {
            try self.advance();
            try self.expectOp('.');
            if (self.cur != .ident) return error.ParseError;
            const member = self.cur.ident;
            try self.advance();
            try self.expectOp('(');
            var args: std.ArrayListUnmanaged(*Expr) = .empty;
            while (!self.isOp(')')) {
                try args.append(self.arena, try self.parseExpr());
                if (self.isOp(',')) try self.advance() else break;
            }
            try self.expectOp(')');
            return self.node(.{ .super_call = .{ .name = member, .args = try args.toOwnedSlice(self.arena) } });
        }
        if (self.isKw("new")) {
            try self.advance();
            if (self.cur != .ident) return error.ParseError;
            const class_name = self.cur.ident;
            try self.advance();
            var type_args: [][]const u8 = &.{};
            if (self.isCmp("<")) type_args = try self.parseTypeArgs();
            try self.expectOp('(');
            var args: std.ArrayListUnmanaged(*Expr) = .empty;
            while (!self.isOp(')')) {
                try args.append(self.arena, try self.parseSpreadOrExpr());
                if (self.isOp(',')) try self.advance() else break;
            }
            try self.expectOp(')');
            return self.node(.{ .new_expr = .{ .class_name = class_name, .args = try args.toOwnedSlice(self.arena), .type_args = type_args } });
        }
        if (self.cur == .template) {
            const raw = self.cur.template;
            try self.advance();
            return self.node(.{ .template = try self.parseTemplateParts(raw) });
        }
        if (self.cur == .str) {
            const s = self.cur.str;
            try self.advance();
            return self.node(.{ .str = s });
        }
        if (self.cur == .ident) {
            const name = self.cur.ident;
            try self.advance();
            // Explicit generic call `f<T, ...>(...)`. Only treated as type
            // arguments when a `(` provably follows the matching `>`.
            var type_args: [][]const u8 = &.{};
            if (self.isCmp("<") and self.looksLikeTypeArgs()) {
                type_args = try self.parseTypeArgs();
            }
            if (self.isOp('(')) {
                try self.expectOp('(');
                var args: std.ArrayListUnmanaged(*Expr) = .empty;
                while (!self.isOp(')')) {
                    try args.append(self.arena, try self.parseSpreadOrExpr());
                    if (self.isOp(',')) try self.advance() else break;
                }
                try self.expectOp(')');
                return self.node(.{ .call = .{ .name = name, .args = try args.toOwnedSlice(self.arena), .type_args = type_args } });
            }
            return self.node(.{ .var_ref = .{ .name = name } });
        }
        if (self.isOp('(') and self.looksLikeArrow()) {
            return self.parseArrow();
        }
        if (self.isOp('(')) {
            try self.advance();
            const e = try self.parseExpr();
            try self.expectOp(')');
            return e;
        }
        if (self.isOp('[')) {
            try self.advance();
            var items: std.ArrayListUnmanaged(*Expr) = .empty;
            while (!self.isOp(']')) {
                try items.append(self.arena, try self.parseSpreadOrExpr());
                if (self.isOp(',')) try self.advance() else break;
            }
            try self.expectOp(']');
            return self.node(.{ .array = .{ .items = try items.toOwnedSlice(self.arena) } });
        }
        if (self.isOp('{')) {
            try self.advance();
            var fields: std.ArrayListUnmanaged(FieldInit) = .empty;
            while (!self.isOp('}')) {
                // Object spread `...src` copies fields from another record.
                if (self.isSpread()) {
                    try self.advance();
                    const src = try self.parseExpr();
                    try fields.append(self.arena, .{ .name = "", .value = src, .is_spread = true });
                    if (self.isOp(',')) try self.advance() else break;
                    continue;
                }
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

    fn parseAssignmentTail(self: *Parser, name: []const u8, line: u32, col: u32, needs_semicolon: bool) CompileError!ast.Assign {
        if (self.isOp('=')) {
            try self.advance();
            const value = try self.parseExpr();
            if (needs_semicolon) try self.expectOp(';');
            return .{ .name = name, .op = "=", .value = value, .line = line, .col = col };
        }
        if (self.isOp2("+=") or self.isOp2("-=") or self.isOp2("*=") or self.isOp2("/=") or self.isOp2("%=")) {
            const op = self.cur.op2;
            try self.advance();
            const value = try self.parseExpr();
            if (needs_semicolon) try self.expectOp(';');
            return .{ .name = name, .op = op, .value = value, .line = line, .col = col };
        }
        if (self.isOp2("++") or self.isOp2("--")) {
            const op = self.cur.op2;
            try self.advance();
            if (needs_semicolon) try self.expectOp(';');
            return .{ .name = name, .op = if (std.mem.eql(u8, op, "++")) "+=" else "-=", .value = try self.oneExpr(1), .line = line, .col = col };
        }
        return error.ParseError;
    }

    fn parsePrefixUpdate(self: *Parser, op: []const u8, line: u32, col: u32, needs_semicolon: bool) CompileError!ast.Assign {
        try self.advance();
        if (self.cur != .ident) return error.ParseError;
        const name = self.cur.ident;
        try self.advance();
        if (needs_semicolon) try self.expectOp(';');
        return .{ .name = name, .op = if (std.mem.eql(u8, op, "++")) "+=" else "-=", .value = try self.oneExpr(1), .line = line, .col = col };
    }

    fn parseTypeDecl(self: *Parser, line: u32, col: u32) CompileError!Stmt {
        try self.advance();
        if (self.cur != .ident) return error.ParseError;
        const tname = self.cur.ident;
        try self.advance();
        try self.expectOp('=');
        if (self.cur == .str) {
            var literals: std.ArrayListUnmanaged([]const u8) = .empty;
            while (true) {
                if (self.cur != .str) return error.ParseError;
                try literals.append(self.arena, self.cur.str);
                try self.advance();
                if (self.isOp(';')) break;
                if (self.cur != .cmp or !std.mem.eql(u8, self.cur.cmp, "|")) return error.ParseError;
                try self.advance();
            }
            try self.expectOp(';');
            return .{ .type_decl = .{ .name = tname, .string_literals = try literals.toOwnedSlice(self.arena), .line = line, .col = col } };
        }
        if (self.cur == .num) {
            var int_literals: std.ArrayListUnmanaged(i64) = .empty;
            while (true) {
                if (self.cur != .num) return error.ParseError;
                try int_literals.append(self.arena, self.cur.num);
                try self.advance();
                if (self.isOp(';')) break;
                if (self.cur != .cmp or !std.mem.eql(u8, self.cur.cmp, "|")) return error.ParseError;
                try self.advance();
            }
            try self.expectOp(';');
            return .{ .type_decl = .{ .name = tname, .int_literals = try int_literals.toOwnedSlice(self.arena), .line = line, .col = col } };
        }
        // Object record body: `type T = { ... }`.
        if (self.isOp('{')) {
            try self.advance();
            var fields: std.ArrayListUnmanaged(ast.TypeField) = .empty;
            while (!self.isOp('}')) {
                if (self.cur != .ident) return error.ParseError;
                const fname = self.cur.ident;
                try self.advance();
                const annotation = try self.parseOptionalMember();
                try fields.append(self.arena, .{ .name = fname, .annotation = annotation });
                if (self.isOp(',')) try self.advance() else break;
            }
            try self.expectOp('}');
            if (self.isOp(';')) try self.advance();
            return .{ .type_decl = .{ .name = tname, .fields = try fields.toOwnedSlice(self.arena), .line = line, .col = col } };
        }
        // A function-type alias `type F = (a: T) => R;`.
        if (self.isOp('(')) {
            const fn_ann = try self.parseFunctionType();
            try self.expectOp(';');
            return .{ .type_decl = .{ .name = tname, .alias = fn_ann, .line = line, .col = col } };
        }
        // Otherwise an alias `type X = <member>;`, an optional alias
        // `type X = T | null;`, or a discriminated union `type U = A | B | C;`
        // over named record variants. Collect `|`-separated members first.
        var members: std.ArrayListUnmanaged([]const u8) = .empty;
        try members.append(self.arena, try self.parseTypeMember());
        while (self.isCmp("|")) {
            try self.advance();
            try members.append(self.arena, try self.parseTypeMember());
        }
        try self.expectOp(';');
        const items = try members.toOwnedSlice(self.arena);
        if (items.len == 1) {
            return .{ .type_decl = .{ .name = tname, .alias = items[0], .line = line, .col = col } };
        }
        // `T | null` / `T | undefined` -> optional alias.
        var nulls: usize = 0;
        var non_null: ?[]const u8 = null;
        for (items) |m| {
            if (std.mem.eql(u8, m, "null") or std.mem.eql(u8, m, "undefined")) {
                nulls += 1;
            } else {
                non_null = m;
            }
        }
        if (items.len == 2 and nulls == 1) {
            const opt = std.fmt.allocPrint(self.arena, "{s}?", .{non_null.?}) catch return error.OutOfMemory;
            return .{ .type_decl = .{ .name = tname, .alias = opt, .line = line, .col = col } };
        }
        return .{ .type_decl = .{ .name = tname, .union_variants = items, .line = line, .col = col } };
    }

    /// Parses `[?] : Type` after a field/param name, returning the annotation with
    /// an optional `?` suffix when the member is marked optional.
    fn parseOptionalMember(self: *Parser) CompileError![]const u8 {
        var opt = false;
        if (self.isOp('?')) {
            try self.advance();
            opt = true;
        }
        try self.expectOp(':');
        const annotation = try self.parseTypeAnnotation();
        if (opt and !std.mem.endsWith(u8, annotation, "?")) {
            return std.fmt.allocPrint(self.arena, "{s}?", .{annotation}) catch error.OutOfMemory;
        }
        return annotation;
    }

    /// An external C-ABI function declaration. Two spellings are accepted and
    /// lower identically: the TypeScript-valid `declare function name(...): R;`
    /// (the preferred form, since it parses under `tsc` as an ambient
    /// declaration) and the legacy `extern function name(...): R;` alias.
    fn parseExternDecl(self: *Parser, line: u32, col: u32) CompileError!Stmt {
        try self.advance(); // 'extern' or 'declare'
        if (!self.isKw("function")) return error.ParseError;
        try self.advance(); // 'function'
        if (self.cur != .ident) return error.ParseError;
        const name = self.cur.ident;
        try self.advance();
        try self.expectOp('(');
        var params: std.ArrayListUnmanaged(ast.FunctionParam) = .empty;
        while (!self.isOp(')')) {
            if (self.cur != .ident) return error.ParseError;
            const pname = self.cur.ident;
            try self.advance();
            try self.expectOp(':');
            const annotation = try self.parseTypeAnnotation();
            try params.append(self.arena, .{ .name = pname, .annotation = annotation });
            if (self.isOp(',')) try self.advance() else break;
        }
        try self.expectOp(')');
        try self.expectOp(':');
        const return_annotation = try self.parseTypeAnnotation();
        try self.expectOp(';');
        return .{ .extern_decl = .{ .name = name, .params = try params.toOwnedSlice(self.arena), .return_annotation = return_annotation, .line = line, .col = col } };
    }

    /// `interface Name { field: T; field2: U }` — a synonym for an object `type`.
    /// Accepts `;` or `,` (or newline) between members.
    fn parseInterfaceDecl(self: *Parser, line: u32, col: u32) CompileError!Stmt {
        try self.advance(); // 'interface'
        if (self.cur != .ident) return error.ParseError;
        const tname = self.cur.ident;
        try self.advance();
        const type_params = try self.parseTypeParams();
        try self.expectOp('{');
        var fields: std.ArrayListUnmanaged(ast.TypeField) = .empty;
        while (!self.isOp('}')) {
            if (self.cur != .ident) return error.ParseError;
            const fname = self.cur.ident;
            try self.advance();
            const annotation = try self.parseOptionalMember();
            try fields.append(self.arena, .{ .name = fname, .annotation = annotation });
            if (self.isOp(',') or self.isOp(';')) try self.advance();
        }
        try self.expectOp('}');
        if (self.isOp(';')) try self.advance();
        return .{ .type_decl = .{ .name = tname, .fields = try fields.toOwnedSlice(self.arena), .type_params = type_params, .line = line, .col = col } };
    }

    /// `enum Name { A, B = 2, C }` (numeric) or `enum Name { Up = "up" }` (string).
    fn parseEnumDecl(self: *Parser, line: u32, col: u32) CompileError!Stmt {
        try self.advance(); // 'enum'
        if (self.cur != .ident) return error.ParseError;
        const ename = self.cur.ident;
        try self.advance();
        try self.expectOp('{');
        var members: std.ArrayListUnmanaged(ast.EnumMember) = .empty;
        var is_string = false;
        var auto: i64 = 0;
        while (!self.isOp('}')) {
            if (self.cur != .ident) return error.ParseError;
            const mname = self.cur.ident;
            try self.advance();
            var member: ast.EnumMember = .{ .name = mname };
            if (self.isOp('=')) {
                try self.advance();
                if (self.cur == .num) {
                    member.int_value = self.cur.num;
                    auto = self.cur.num + 1;
                    try self.advance();
                } else if (self.cur == .str) {
                    member.str_value = self.cur.str;
                    is_string = true;
                    try self.advance();
                } else return error.ParseError;
            } else {
                member.int_value = auto;
                auto += 1;
            }
            try members.append(self.arena, member);
            if (self.isOp(',')) try self.advance() else break;
        }
        try self.expectOp('}');
        if (self.isOp(';')) try self.advance();
        return .{ .enum_decl = .{ .name = ename, .is_string = is_string, .members = try members.toOwnedSlice(self.arena), .line = line, .col = col } };
    }

    fn parseFunctionDecl(self: *Parser, line: u32, col: u32, is_async: bool) CompileError!Stmt {
        try self.advance();
        if (self.cur != .ident) return error.ParseError;
        const name = self.cur.ident;
        try self.advance();
        const type_params = try self.parseTypeParams();
        const params = try self.parseParamList();
        try self.expectOp(':');
        const return_annotation = try self.parseTypeAnnotation();
        const body = try self.parseBlock();
        return .{ .function_decl = .{
            .name = name,
            .params = params,
            .return_annotation = return_annotation,
            .body = body,
            .type_params = type_params,
            .is_async = is_async,
            .line = line,
            .col = col,
        } };
    }

    fn parseParamList(self: *Parser) CompileError![]ast.FunctionParam {
        try self.expectOp('(');
        var params: std.ArrayListUnmanaged(ast.FunctionParam) = .empty;
        var seen_rest = false;
        while (!self.isOp(')')) {
            // A rest parameter `...name: T[]` may only appear last.
            var is_rest = false;
            if (self.isSpread()) {
                if (seen_rest) return error.ParseError;
                try self.advance();
                is_rest = true;
                seen_rest = true;
            }
            if (self.cur != .ident) return error.ParseError;
            const param_name = self.cur.ident;
            try self.advance();
            const annotation = try self.parseOptionalMember();
            // Optional default value `= expr`. Not allowed on a rest parameter.
            var default_value: ?*Expr = null;
            if (self.isOp('=')) {
                if (is_rest) return error.ParseError;
                try self.advance();
                default_value = try self.parseExpr();
            }
            try params.append(self.arena, .{ .name = param_name, .annotation = annotation, .is_rest = is_rest, .default = default_value });
            if (self.isOp(',')) try self.advance() else break;
        }
        // A rest parameter must be the final parameter.
        if (seen_rest and !params.items[params.items.len - 1].is_rest) return error.ParseError;
        try self.expectOp(')');
        return params.toOwnedSlice(self.arena);
    }

    /// Optional generic type-parameter list `<T, U, ...>` after a declaration
    /// name. Returns an empty slice when no `<` is present.
    fn parseTypeParams(self: *Parser) CompileError![][]const u8 {
        if (!self.isCmp("<")) return &.{};
        try self.advance(); // '<'
        var params: std.ArrayListUnmanaged([]const u8) = .empty;
        while (!self.isCmp(">")) {
            if (self.cur != .ident) return error.ParseError;
            try params.append(self.arena, self.cur.ident);
            try self.advance();
            if (self.isOp(',')) try self.advance() else break;
        }
        if (!self.isCmp(">")) return error.ParseError;
        try self.advance(); // '>'
        return params.toOwnedSlice(self.arena);
    }

    /// Generic type-argument list `<T, U, ...>` (concrete type annotations). The
    /// caller has confirmed (via lookahead) that `cur` is the opening `<`.
    fn parseTypeArgs(self: *Parser) CompileError![][]const u8 {
        try self.advance(); // '<'
        var args: std.ArrayListUnmanaged([]const u8) = .empty;
        while (!self.isCmp(">")) {
            const ann = try self.parseTypeAnnotation();
            try args.append(self.arena, ann);
            if (self.isOp(',')) try self.advance() else break;
        }
        if (!self.isCmp(">")) return error.ParseError;
        try self.advance(); // '>'
        return args.toOwnedSlice(self.arena);
    }

    /// Lookahead: starting at a `<` (cmp), is this an explicit type-argument list
    /// immediately followed by a `(` call? Scans `< ... >` (allowing nested `<`
    /// and `[]`) and checks for a following `(`. Restores parser state.
    fn looksLikeTypeArgs(self: *Parser) bool {
        const save_lex = self.lex;
        const save_cur = self.cur;
        const save_line = self.cur_line;
        const save_col = self.cur_col;
        defer {
            self.lex = save_lex;
            self.cur = save_cur;
            self.cur_line = save_line;
            self.cur_col = save_col;
        }
        self.advance() catch return false; // consume '<'
        var depth: u32 = 1;
        while (depth > 0) {
            if (self.cur == .eof) return false;
            // Only type-annotation tokens may appear inside a type-argument list.
            switch (self.cur) {
                .ident => {},
                .op => |c| if (c != ',' and c != '[' and c != ']' and c != '.') return false,
                .cmp => |s| {
                    if (std.mem.eql(u8, s, "<")) {
                        depth += 1;
                    } else if (std.mem.eql(u8, s, ">")) {
                        depth -= 1;
                    } else return false;
                },
                .op2 => |s| if (!std.mem.eql(u8, s, ">>")) return false else {
                    // `>>` closes two nested type-argument levels at once.
                    if (depth >= 2) depth -= 2 else return false;
                },
                else => return false,
            }
            self.advance() catch return false;
        }
        return self.isOp('(');
    }

    /// `class Name { field: T; constructor(p: T) { ... } method(p: T): R { ... } }`
    fn parseClassDecl(self: *Parser, line: u32, col: u32) CompileError!Stmt {
        try self.advance(); // 'class'
        if (self.cur != .ident) return error.ParseError;
        const name = self.cur.ident;
        try self.advance();
        const type_params = try self.parseTypeParams();
        var parent: ?[]const u8 = null;
        if (self.isKw("extends")) {
            try self.advance();
            if (self.cur != .ident) return error.ParseError;
            parent = self.cur.ident;
            try self.advance();
            // ignore any type args on the parent, e.g. `extends Base<T>`
            if (self.isCmp("<")) {
                try self.advance();
                while (!self.isCmp(">")) {
                    _ = try self.parseTypeAnnotation();
                    if (self.isOp(',')) try self.advance() else break;
                }
                try self.consumeTypeArgClose();
            }
        }
        var implements: std.ArrayListUnmanaged([]const u8) = .empty;
        if (self.isKw("implements")) {
            try self.advance();
            while (true) {
                if (self.cur != .ident) return error.ParseError;
                try implements.append(self.arena, self.cur.ident);
                try self.advance();
                if (self.isOp(',')) try self.advance() else break;
            }
        }
        try self.expectOp('{');
        var fields: std.ArrayListUnmanaged(ast.TypeField) = .empty;
        var methods: std.ArrayListUnmanaged(ast.FunctionDecl) = .empty;
        var has_ctor = false;
        var ctor_params: []ast.FunctionParam = &.{};
        var ctor_body: []Stmt = &.{};
        while (!self.isOp('}')) {
            // Optional member modifiers, in any order.
            var visibility: ast.Visibility = .public;
            var is_static = false;
            var is_readonly = false;
            var accessor: ast.Accessor = .none;
            while (self.cur == .ident) {
                const kw = self.cur.ident;
                if (std.mem.eql(u8, kw, "public")) {
                    visibility = .public;
                } else if (std.mem.eql(u8, kw, "private")) {
                    visibility = .private;
                } else if (std.mem.eql(u8, kw, "protected")) {
                    visibility = .protected;
                } else if (std.mem.eql(u8, kw, "static")) {
                    is_static = true;
                } else if (std.mem.eql(u8, kw, "readonly")) {
                    is_readonly = true;
                } else if (std.mem.eql(u8, kw, "get") or std.mem.eql(u8, kw, "set")) {
                    // `get`/`set` is an accessor prefix only when followed by an
                    // identifier name (not e.g. a method literally named `get`).
                    const save = self.lex;
                    const save_cur = self.cur;
                    try self.advance();
                    if (self.cur == .ident) {
                        accessor = if (std.mem.eql(u8, kw, "get")) .getter else .setter;
                        break;
                    }
                    // not an accessor: restore and treat `get`/`set` as the name
                    self.lex = save;
                    self.cur = save_cur;
                    break;
                } else break;
                try self.advance();
            }
            if (self.cur != .ident) return error.ParseError;
            const member = self.cur.ident;
            const m_line = self.cur_line;
            const m_col = self.cur_col;
            try self.advance();
            if (accessor == .none and std.mem.eql(u8, member, "constructor")) {
                ctor_params = try self.parseParamList();
                ctor_body = try self.parseBlock();
                has_ctor = true;
            } else if (self.isOp('(')) {
                // method (or accessor)
                const params = try self.parseParamList();
                var return_annotation: []const u8 = "void";
                if (self.isOp(':')) {
                    try self.advance();
                    return_annotation = try self.parseTypeAnnotation();
                }
                const body = try self.parseBlock();
                try methods.append(self.arena, .{
                    .name = member,
                    .params = params,
                    .return_annotation = return_annotation,
                    .body = body,
                    .visibility = visibility,
                    .is_static = is_static,
                    .accessor = accessor,
                    .line = m_line,
                    .col = m_col,
                });
            } else {
                // field: name: T ;
                const annotation = try self.parseOptionalMember();
                try fields.append(self.arena, .{
                    .name = member,
                    .annotation = annotation,
                    .visibility = visibility,
                    .is_static = is_static,
                    .is_readonly = is_readonly,
                });
                if (self.isOp(';') or self.isOp(',')) try self.advance();
            }
        }
        try self.expectOp('}');
        if (self.isOp(';')) try self.advance();
        return .{ .class_decl = .{
            .name = name,
            .fields = try fields.toOwnedSlice(self.arena),
            .has_ctor = has_ctor,
            .ctor_params = ctor_params,
            .ctor_body = ctor_body,
            .methods = try methods.toOwnedSlice(self.arena),
            .parent = parent,
            .implements = try implements.toOwnedSlice(self.arena),
            .type_params = type_params,
            .line = line,
            .col = col,
        } };
    }

    fn parseBlock(self: *Parser) CompileError![]Stmt {
        try self.expectOp('{');
        var body: std.ArrayListUnmanaged(Stmt) = .empty;
        while (!self.isOp('}')) try body.append(self.arena, try self.parseStmt());
        try self.expectOp('}');
        return body.toOwnedSlice(self.arena);
    }

    fn parseSwitchBody(self: *Parser) CompileError![]Stmt {
        var body: std.ArrayListUnmanaged(Stmt) = .empty;
        while (!self.isOp('}') and !self.isKw("case") and !self.isKw("default")) {
            try body.append(self.arena, try self.parseStmt());
        }
        return body.toOwnedSlice(self.arena);
    }

    fn parseSwitch(self: *Parser, line: u32, col: u32) CompileError!Stmt {
        try self.advance();
        try self.expectOp('(');
        const value = try self.parseExpr();
        try self.expectOp(')');
        try self.expectOp('{');
        var cases: std.ArrayListUnmanaged(ast.SwitchCase) = .empty;
        var default_body: ?[]Stmt = null;
        while (!self.isOp('}')) {
            if (self.isKw("case")) {
                const case_line = self.cur_line;
                const case_col = self.cur_col;
                try self.advance();
                const case_value = try self.parseExpr();
                try self.expectOp(':');
                try cases.append(self.arena, .{ .value = case_value, .body = try self.parseSwitchBody(), .line = case_line, .col = case_col });
            } else if (self.isKw("default")) {
                if (default_body != null) return error.ParseError;
                try self.advance();
                try self.expectOp(':');
                default_body = try self.parseSwitchBody();
            } else {
                return error.ParseError;
            }
        }
        try self.expectOp('}');
        return .{ .switch_stmt = .{ .value = value, .cases = try cases.toOwnedSlice(self.arena), .default_body = default_body, .line = line, .col = col } };
    }

    fn parseStmt(self: *Parser) CompileError!Stmt {
        const eq = std.mem.eql;
        const line = self.cur_line;
        const col = self.cur_col;
        if (self.cur == .op2 and (std.mem.eql(u8, self.cur.op2, "++") or std.mem.eql(u8, self.cur.op2, "--"))) {
            const op = self.cur.op2;
            return .{ .assign = try self.parsePrefixUpdate(op, line, col, true) };
        }
        if (self.cur != .ident) return error.ParseError;
        const kw = self.cur.ident;

        // `await <expr>;` as a statement (the resolved value is discarded).
        if (eq(u8, kw, "await")) {
            const value = try self.parseExpr();
            try self.expectOp(';');
            return .{ .expr_stmt = .{ .value = value, .line = line, .col = col } };
        }

        if (eq(u8, kw, "type")) return self.parseTypeDecl(line, col);
        if (eq(u8, kw, "interface")) return self.parseInterfaceDecl(line, col);
        if (eq(u8, kw, "enum")) return self.parseEnumDecl(line, col);
        if (eq(u8, kw, "extern")) return self.parseExternDecl(line, col);
        // `declare function NAME(...): R;` — the TypeScript-valid spelling for an
        // FFI declaration; identical lowering to `extern function`.
        if (eq(u8, kw, "declare")) return self.parseExternDecl(line, col);
        if (eq(u8, kw, "function")) return self.parseFunctionDecl(line, col, false);
        // `async function ...` — an asynchronous function returning a Promise<T>.
        if (eq(u8, kw, "async")) {
            try self.advance(); // 'async'
            if (!self.isKw("function")) return error.ParseError;
            return self.parseFunctionDecl(line, col, true);
        }
        if (eq(u8, kw, "switch")) return self.parseSwitch(line, col);
        if (eq(u8, kw, "class")) return self.parseClassDecl(line, col);

        // `this.field = value;` (member assignment) or `this.method(args);`
        if (eq(u8, kw, "this")) {
            try self.advance(); // 'this'
            try self.expectOp('.');
            if (self.cur != .ident) return error.ParseError;
            const member = self.cur.ident;
            try self.advance();
            if (self.isOp('(')) {
                try self.expectOp('(');
                var args: std.ArrayListUnmanaged(*Expr) = .empty;
                while (!self.isOp(')')) {
                    try args.append(self.arena, try self.parseExpr());
                    if (self.isOp(',')) try self.advance() else break;
                }
                try self.expectOp(')');
                try self.expectOp(';');
                const this_e = try self.node(.this_expr);
                const mc = try self.node(.{ .method_call = .{ .obj = this_e, .name = member, .args = try args.toOwnedSlice(self.arena) } });
                return .{ .expr_stmt = .{ .value = mc, .line = line, .col = col } };
            }
            var op: []const u8 = "=";
            if (self.isOp('=')) {
                try self.advance();
            } else if (self.cur == .op2 and (eq(u8, self.cur.op2, "+=") or eq(u8, self.cur.op2, "-=") or eq(u8, self.cur.op2, "*=") or eq(u8, self.cur.op2, "/=") or eq(u8, self.cur.op2, "%="))) {
                op = self.cur.op2;
                try self.advance();
            } else return error.ParseError;
            const value = try self.parseExpr();
            try self.expectOp(';');
            return .{ .member_assign = .{ .field = member, .op = op, .value = value, .line = line, .col = col } };
        }

        // `super(args);` (parent constructor) or `super.method(args);`.
        if (eq(u8, kw, "super")) {
            try self.advance(); // 'super'
            if (self.isOp('(')) {
                try self.expectOp('(');
                var args: std.ArrayListUnmanaged(*Expr) = .empty;
                while (!self.isOp(')')) {
                    try args.append(self.arena, try self.parseExpr());
                    if (self.isOp(',')) try self.advance() else break;
                }
                try self.expectOp(')');
                try self.expectOp(';');
                return .{ .super_ctor = .{ .args = try args.toOwnedSlice(self.arena), .line = line, .col = col } };
            }
            try self.expectOp('.');
            if (self.cur != .ident) return error.ParseError;
            const member = self.cur.ident;
            try self.advance();
            try self.expectOp('(');
            var args: std.ArrayListUnmanaged(*Expr) = .empty;
            while (!self.isOp(')')) {
                try args.append(self.arena, try self.parseExpr());
                if (self.isOp(',')) try self.advance() else break;
            }
            try self.expectOp(')');
            try self.expectOp(';');
            const sc = try self.node(.{ .super_call = .{ .name = member, .args = try args.toOwnedSlice(self.arena) } });
            return .{ .expr_stmt = .{ .value = sc, .line = line, .col = col } };
        }

        if (eq(u8, kw, "let") or eq(u8, kw, "const") or eq(u8, kw, "var")) {
            const mutable = eq(u8, kw, "let") or eq(u8, kw, "var");
            try self.advance();
            // Destructuring: `let [a, b] = e;` or `let { x, y } = e;`
            if (self.isOp('[') or self.isOp('{')) {
                const is_object = self.isOp('{');
                try self.advance();
                const close: u8 = if (is_object) '}' else ']';
                var bindings: std.ArrayListUnmanaged(ast.DestructBinding) = .empty;
                while (!self.isOp(close)) {
                    if (self.cur != .ident) return error.ParseError;
                    try bindings.append(self.arena, .{ .name = self.cur.ident });
                    try self.advance();
                    if (self.isOp(',')) try self.advance() else break;
                }
                try self.expectOp(close);
                try self.expectOp('=');
                const source = try self.parseExpr();
                try self.expectOp(';');
                return .{ .destructure_decl = .{ .mutable = mutable, .is_object = is_object, .bindings = try bindings.toOwnedSlice(self.arena), .source = source, .line = line, .col = col } };
            }
            if (self.cur != .ident) return error.ParseError;
            const name = self.cur.ident;
            try self.advance();
            var annotation: ?[]const u8 = null;
            if (self.isOp(':')) {
                try self.advance();
                annotation = try self.parseTypeAnnotation();
            }
            try self.expectOp('=');
            const initial_value = try self.parseExpr();
            try self.expectOp(';');
            return .{ .var_decl = .{ .mutable = mutable, .name = name, .annotation = annotation, .init = initial_value, .line = line, .col = col } };
        }

        // `using NAME = EXPR;` — TypeScript 5.2 scope-exit disposal. Reuses the
        // same scope-exit (LIFO) lowering as `defer`. Disposes the bound value at
        // block/function exit; see ast.UsingDecl.
        if (eq(u8, kw, "using")) {
            try self.advance();
            if (self.cur != .ident) return error.ParseError;
            const name = self.cur.ident;
            try self.advance();
            var annotation: ?[]const u8 = null;
            if (self.isOp(':')) {
                try self.advance();
                annotation = try self.parseTypeAnnotation();
            }
            try self.expectOp('=');
            // `using x = defer(() => BODY);` — the built-in scope-exit helper. The
            // body is parsed as statements (so `console.log(...)` works) and run
            // at scope exit, exactly like the `defer` statement. We still build an
            // `init` call node for the checker to validate the helper shape.
            if (self.isKw("defer") and self.peekIsOpenParen()) {
                try self.advance(); // 'defer'
                try self.expectOp('(');
                if (!self.isOp('(')) return error.ParseError; // require `() =>`
                try self.advance();
                try self.expectOp(')');
                if (!self.isOp2("=>")) return error.ParseError;
                try self.advance();
                var defer_body: []Stmt = undefined;
                if (self.isOp('{')) {
                    // Block-bodied arrow: `defer(() => { ...; ... })`.
                    defer_body = try self.parseBlock();
                } else {
                    // Single-expression arrow body, followed by the `)` that closes
                    // the `defer(` call (so no trailing `;` to consume here).
                    const single = try self.arena.alloc(Stmt, 1);
                    single[0] = try self.parseDeferHelperBodyStmt();
                    defer_body = single;
                }
                try self.expectOp(')');
                try self.expectOp(';');
                const init_call = try self.node(.{ .call = .{ .name = "defer", .args = &.{} } });
                return .{ .using_decl = .{ .name = name, .annotation = annotation, .init = init_call, .defer_body = defer_body, .line = line, .col = col } };
            }
            const initial_value = try self.parseExpr();
            try self.expectOp(';');
            return .{ .using_decl = .{ .name = name, .annotation = annotation, .init = initial_value, .line = line, .col = col } };
        }

        if (eq(u8, kw, "console")) {
            try self.advance();
            try self.expectOp('.');
            if (self.cur != .ident) return error.ParseError;
            const method = self.cur.ident;
            if (!eq(u8, method, "log") and !eq(u8, method, "error")) {
                self.last_err = "E_UNSUPPORTED_STD";
                return error.ParseError;
            }
            try self.advance();
            try self.expectOp('(');
            const value = try self.parseExpr();
            try self.expectOp(')');
            try self.expectOp(';');
            return .{ .console_log = .{ .method = method, .value = value, .line = line, .col = col } };
        }

        if (eq(u8, kw, "while")) {
            try self.advance();
            try self.expectOp('(');
            const cond = try self.parseExpr();
            try self.expectOp(')');
            const body = try self.parseBlock();
            return .{ .while_stmt = .{ .cond = cond, .body = body, .line = line, .col = col } };
        }

        if (eq(u8, kw, "do")) {
            try self.advance();
            const body = try self.parseBlock();
            if (!self.isKw("while")) return error.ParseError;
            try self.advance();
            try self.expectOp('(');
            const cond = try self.parseExpr();
            try self.expectOp(')');
            try self.expectOp(';');
            return .{ .do_while_stmt = .{ .body = body, .cond = cond, .line = line, .col = col } };
        }

        if (eq(u8, kw, "for")) {
            try self.advance();
            try self.expectOp('(');
            if (self.cur != .ident) return error.ParseError;
            const init_kw = self.cur.ident;
            const is_const = eq(u8, init_kw, "const");
            if (!eq(u8, init_kw, "let") and !eq(u8, init_kw, "var") and !is_const) return error.ParseError;
            try self.advance();
            if (self.cur != .ident) return error.ParseError;
            const init_name = self.cur.ident;
            const init_line = self.cur_line;
            const init_col = self.cur_col;
            try self.advance();
            // for...of: `for (const|let name of iterable) { ... }`
            if (self.isKw("of")) {
                try self.advance();
                const iterable = try self.parseExpr();
                try self.expectOp(')');
                const body = try self.parseBlock();
                return .{ .for_of_stmt = .{ .mutable = !is_const, .binding = init_name, .iterable = iterable, .body = body, .line = line, .col = col } };
            }
            // C-style for loops require a reassignable binding for the update step.
            if (is_const) return error.ParseError;
            var annotation: ?[]const u8 = null;
            if (self.isOp(':')) {
                try self.advance();
                annotation = try self.parseTypeAnnotation();
            }
            try self.expectOp('=');
            const init_value = try self.parseExpr();
            try self.expectOp(';');
            const cond = try self.parseExpr();
            try self.expectOp(';');
            const update_line = self.cur_line;
            const update_col = self.cur_col;
            const update = if (self.cur == .op2 and (std.mem.eql(u8, self.cur.op2, "++") or std.mem.eql(u8, self.cur.op2, "--"))) blk: {
                const op = self.cur.op2;
                break :blk try self.parsePrefixUpdate(op, update_line, update_col, false);
            } else blk: {
                if (self.cur != .ident) return error.ParseError;
                const update_name = self.cur.ident;
                try self.advance();
                break :blk try self.parseAssignmentTail(update_name, update_line, update_col, false);
            };
            try self.expectOp(')');
            const body = try self.parseBlock();
            return .{ .for_stmt = .{
                .init = .{ .mutable = true, .name = init_name, .annotation = annotation, .init = init_value, .line = init_line, .col = init_col },
                .cond = cond,
                .update = update,
                .body = body,
                .line = line,
                .col = col,
            } };
        }

        if (eq(u8, kw, "if")) {
            try self.advance();
            try self.expectOp('(');
            const cond = try self.parseExpr();
            try self.expectOp(')');
            const then_body = try self.parseBlock();
            var else_body: ?[]Stmt = null;
            if (self.isKw("else")) {
                try self.advance();
                if (self.isKw("if")) {
                    const nested_if = try self.parseStmt();
                    const nested_body = try self.arena.alloc(Stmt, 1);
                    nested_body[0] = nested_if;
                    else_body = nested_body;
                } else {
                    else_body = try self.parseBlock();
                }
            }
            return .{ .if_stmt = .{ .cond = cond, .then_body = then_body, .else_body = else_body, .line = line, .col = col } };
        }

        if (eq(u8, kw, "return")) {
            try self.advance();
            const value = if (self.isOp(';')) null else try self.parseExpr();
            try self.expectOp(';');
            return .{ .return_stmt = .{ .value = value, .line = line, .col = col } };
        }

        if (eq(u8, kw, "break")) {
            try self.advance();
            try self.expectOp(';');
            return .{ .break_stmt = .{ .line = line, .col = col } };
        }

        if (eq(u8, kw, "continue")) {
            try self.advance();
            try self.expectOp(';');
            return .{ .continue_stmt = .{ .line = line, .col = col } };
        }

        if (eq(u8, kw, "throw")) {
            try self.advance();
            const value = try self.parseExpr();
            try self.expectOp(';');
            return .{ .throw_stmt = .{ .value = value, .line = line, .col = col } };
        }

        if (eq(u8, kw, "defer")) {
            try self.advance();
            if (self.isOp('{')) {
                const body = try self.parseBlock();
                return .{ .defer_stmt = .{ .body = body, .line = line, .col = col } };
            }
            const single = try self.arena.alloc(Stmt, 1);
            single[0] = try self.parseStmt();
            return .{ .defer_stmt = .{ .body = single, .line = line, .col = col } };
        }

        if (eq(u8, kw, "try")) {
            try self.advance();
            const try_body = try self.parseBlock();
            if (!self.isKw("catch")) return error.ParseError;
            try self.advance();
            try self.expectOp('(');
            if (self.cur != .ident) return error.ParseError;
            const catch_name = self.cur.ident;
            try self.advance();
            try self.expectOp(')');
            const catch_body = try self.parseBlock();
            var finally_body: ?[]Stmt = null;
            if (self.isKw("finally")) {
                try self.advance();
                finally_body = try self.parseBlock();
            }
            return .{ .try_stmt = .{ .try_body = try_body, .catch_name = catch_name, .catch_body = catch_body, .finally_body = finally_body, .line = line, .col = col } };
        }

        // Test declarations. Two surfaces lower to the same `test_decl`:
        //   * `test "name" { ... }`              — the original block form.
        //   * `test("name", () => { ... });`     — the conventional function form
        //                                          (Jest/Vitest/node:test style),
        //                                          which is valid TypeScript.
        // Both are recognised only by lookahead, so `test` stays usable as an
        // ordinary identifier everywhere else.
        if (eq(u8, kw, "test")) {
            const save_lex = self.lex;
            const save_cur = self.cur;
            const save_line = self.cur_line;
            const save_col = self.cur_col;
            self.advance() catch {};
            const after_test = self.cur;
            self.lex = save_lex;
            self.cur = save_cur;
            self.cur_line = save_line;
            self.cur_col = save_col;
            if (after_test == .str) {
                // `test "name" { ... }`
                try self.advance(); // 'test'
                const name = self.cur.str;
                try self.advance(); // name string
                const tbody = try self.parseBlock();
                return .{ .test_decl = .{ .name = name, .body = tbody, .line = line, .col = col } };
            }
            if (after_test == .op and after_test.op == '(') {
                // `test("name", () => { ... });`
                try self.advance(); // 'test'
                try self.expectOp('(');
                if (self.cur != .str) return error.ParseError;
                const name = self.cur.str;
                try self.advance(); // name string
                try self.expectOp(',');
                // Callback `() => { ... }`: no params, block body.
                try self.expectOp('(');
                try self.expectOp(')');
                if (!self.isOp2("=>")) return error.ParseError;
                try self.advance(); // '=>'
                const tbody = try self.parseBlock();
                try self.expectOp(')');
                try self.expectOp(';');
                return .{ .test_decl = .{ .name = name, .body = tbody, .line = line, .col = col } };
            }
        }

        // `expect(...)` assertions. The boolean form `expect(cond);` and the
        // matcher form `expect(actual).toBe(expected);` (and `.toEqual`) both
        // lower to a single `expect` call node; the matcher carries the expected
        // value as a second argument and a marker name. Recognised only when an
        // open paren follows, so `expect` stays usable as an identifier.
        if (eq(u8, kw, "expect") and self.peekIsOpenParen()) {
            try self.advance(); // 'expect'
            try self.expectOp('(');
            const actual = try self.parseExpr();
            try self.expectOp(')');
            if (self.isOp('.')) {
                try self.advance(); // '.'
                if (self.cur != .ident) return error.ParseError;
                const matcher = self.cur.ident;
                const matcher_name: ?[]const u8 = if (eq(u8, matcher, "toBe"))
                    "__expectToBe"
                else if (eq(u8, matcher, "toEqual"))
                    "__expectToEqual"
                else
                    null;
                if (matcher_name == null) {
                    self.last_err = "E_UNKNOWN_MATCHER";
                    return error.ParseError;
                }
                try self.advance(); // matcher name
                try self.expectOp('(');
                const expected = try self.parseExpr();
                try self.expectOp(')');
                try self.expectOp(';');
                const args = try self.arena.alloc(*Expr, 2);
                args[0] = actual;
                args[1] = expected;
                const value = try self.node(.{ .call = .{ .name = matcher_name.?, .args = args } });
                return .{ .expr_stmt = .{ .value = value, .line = line, .col = col } };
            }
            // Boolean form: `expect(cond);`.
            try self.expectOp(';');
            const args = try self.arena.alloc(*Expr, 1);
            args[0] = actual;
            const value = try self.node(.{ .call = .{ .name = "expect", .args = args } });
            return .{ .expr_stmt = .{ .value = value, .line = line, .col = col } };
        }

        if (isBuiltin(kw)) {
            const value = try self.parseExpr();
            try self.expectOp(';');
            return .{ .expr_stmt = .{ .value = value, .line = line, .col = col } };
        }

        const name = kw;
        try self.advance();
        if (self.isOp('(')) {
            try self.expectOp('(');
            var args: std.ArrayListUnmanaged(*Expr) = .empty;
            while (!self.isOp(')')) {
                try args.append(self.arena, try self.parseSpreadOrExpr());
                if (self.isOp(',')) try self.advance() else break;
            }
            try self.expectOp(')');
            // A method call on a returned object, e.g. `make().go();`, continues
            // as a postfix expression statement.
            if (self.isOp('.') or self.isOp('[') or self.isOp2("?.")) {
                const call_e = try self.node(.{ .call = .{ .name = name, .args = try args.toOwnedSlice(self.arena) } });
                const e = try self.parsePostfixFrom(call_e);
                try self.expectOp(';');
                return .{ .expr_stmt = .{ .value = e, .line = line, .col = col } };
            }
            try self.expectOp(';');
            const value = try self.node(.{ .call = .{ .name = name, .args = try args.toOwnedSlice(self.arena) } });
            return .{ .expr_stmt = .{ .value = value, .line = line, .col = col } };
        }
        // Single-level member assignment: `obj.field = value;`,
        // `Class.staticField += value;`, or a setter property write.
        if (self.isOp('.')) {
            const save_lex = self.lex;
            const save_cur = self.cur;
            try self.advance(); // '.'
            if (self.cur == .ident) {
                const field = self.cur.ident;
                try self.advance();
                var op: []const u8 = "=";
                var is_assign = false;
                if (self.isOp('=')) {
                    is_assign = true;
                    try self.advance();
                } else if (self.cur == .op2 and (eq(u8, self.cur.op2, "+=") or eq(u8, self.cur.op2, "-=") or eq(u8, self.cur.op2, "*=") or eq(u8, self.cur.op2, "/=") or eq(u8, self.cur.op2, "%="))) {
                    is_assign = true;
                    op = self.cur.op2;
                    try self.advance();
                }
                if (is_assign) {
                    const obj = try self.node(.{ .var_ref = .{ .name = name } });
                    const value = try self.parseExpr();
                    try self.expectOp(';');
                    return .{ .member_assign = .{ .field = field, .op = op, .value = value, .obj = obj, .line = line, .col = col } };
                }
            }
            // Not a simple assignment: restore and fall through to postfix.
            self.lex = save_lex;
            self.cur = save_cur;
        }
        // Member-expression statement: `obj.method(args);`, `obj.field...`.
        if (self.isOp('.') or self.isOp('[') or self.isOp2("?.")) {
            const base = try self.node(.{ .var_ref = .{ .name = name } });
            const e = try self.parsePostfixFrom(base);
            try self.expectOp(';');
            return .{ .expr_stmt = .{ .value = e, .line = line, .col = col } };
        }
        return .{ .assign = try self.parseAssignmentTail(name, line, col, true) };
    }

    fn parseProgram(self: *Parser) CompileError!Program {
        var stmts: std.ArrayListUnmanaged(Stmt) = .empty;
        while (self.cur != .eof) try stmts.append(self.arena, try self.parseStmt());
        return .{ .stmts = try stmts.toOwnedSlice(self.arena) };
    }
};

// ── emit ─────────────────────────────────────────────────────────────────────

/// Zig type for an extern (C-ABI) signature slot. Identical to `types.zigName`
/// except a Lumen `string` maps to `[*:0]const u8` (a NUL-terminated C string)
/// rather than the slice `[]const u8`.
fn externZigName(t: types.Type, arena: std.mem.Allocator) []const u8 {
    return switch (t) {
        .string => "[*:0]const u8",
        else => types.zigName(arena, t) catch "void",
    };
}

fn emitExpr(e: *const Expr, w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    switch (e.*) {
        .num => |v| try w.print(arena, "{d}", .{v}),
        .float => |v| try w.print(arena, "{d}", .{v}),
        .null_lit => try w.appendSlice(arena, "null"),
        .bool => |v| try w.appendSlice(arena, if (v) "true" else "false"),
        .str => |s| {
            try w.append(arena, '"');
            for (s) |ch| {
                if (ch == '"' or ch == '\\') try w.append(arena, '\\');
                try w.append(arena, ch);
            }
            try w.append(arena, '"');
        },
        .array => |arr| {
            if (arr.elem_type) |elem| {
                // Array literal with `...spread` entries → runtime concatenation.
                // Each plain entry becomes a one-element slice; each spread emits
                // its source slice directly.
                const ez = try types.zigName(arena, elem);
                try w.print(arena, "(std.mem.concat(std.heap.page_allocator, {s}, &.{{ ", .{ez});
                for (arr.items, 0..) |item, i| {
                    if (i > 0) try w.appendSlice(arena, ", ");
                    if (item.* == .spread) {
                        try emitExpr(item.spread, w, arena);
                    } else {
                        try w.print(arena, "&[_]{s}{{ ", .{ez});
                        try emitExpr(item, w, arena);
                        try w.appendSlice(arena, " }");
                    }
                }
                try w.appendSlice(arena, " }) catch unreachable)");
            } else {
                try w.appendSlice(arena, "&.{ ");
                for (arr.items, 0..) |item, i| {
                    if (i > 0) try w.appendSlice(arena, ", ");
                    try emitExpr(item, w, arena);
                }
                try w.appendSlice(arena, " }");
            }
        },
        .spread => |inner| {
            // A bare spread only appears inside array/call/object emitters, which
            // handle it specially; emitting the inner expression is the safe
            // fallback should one slip through.
            try emitExpr(inner, w, arena);
        },
        .tuple_lit => |t| {
            // A positional struct literal `.{ .@"0" = a, .@"1" = b, ... }`.
            try w.appendSlice(arena, ".{ ");
            for (t.items, 0..) |item, i| {
                if (i > 0) try w.appendSlice(arena, ", ");
                try w.print(arena, ".@\"{d}\" = ", .{i});
                try emitExpr(item, w, arena);
            }
            try w.appendSlice(arena, " }");
        },
        .call => |cl| {
            // builtins lower to a Zig std wrapper taking (__io, __alloc, args...).
            if (std.mem.eql(u8, cl.name, "Error")) {
                if (cl.args.len > 0) try emitExpr(cl.args[0], w, arena);
            } else if (std.mem.eql(u8, cl.name, "expect")) {
                try w.appendSlice(arena, "try std.testing.expect(");
                if (cl.args.len > 0) try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.name, "__expectToBe") or std.mem.eql(u8, cl.name, "__expectToEqual") or std.mem.eql(u8, cl.name, "__expectStrEqual")) {
                // `expect(actual).toBe(expected)` lowers to a std.testing helper
                // taking (expected, actual). `.toEqual` is currently a
                // strict-equality alias of `.toBe` for V1 scalar/string values.
                // Strings compare by bytes via expectEqualStrings.
                const helper = if (std.mem.eql(u8, cl.name, "__expectStrEqual"))
                    "try std.testing.expectEqualStrings("
                else
                    "try std.testing.expectEqual(";
                try w.appendSlice(arena, helper);
                if (cl.args.len > 1) try emitExpr(cl.args[1], w, arena);
                try w.appendSlice(arena, ", ");
                if (cl.args.len > 0) try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.name, "argsCount")) {
                try w.appendSlice(arena, "@as(i32, @intCast(__args.len))");
            } else if (std.mem.eql(u8, cl.name, "arg")) {
                try w.appendSlice(arena, "(if (@as(usize, @intCast(");
                if (cl.args.len > 0) try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ")) < __args.len) __args[@as(usize, @intCast(");
                if (cl.args.len > 0) try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, "))] else \"\")");
            } else if (std.mem.eql(u8, cl.name, "httpGet")) {
                try w.appendSlice(arena, "__httpGet(__io, __alloc, ");
                if (cl.args.len > 0) try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.name, "serve")) {
                try w.appendSlice(arena, "__serve(__io, __alloc, ");
                if (cl.args.len > 0) try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                if (cl.args.len > 1) try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.name, "setTimeout")) {
                // setTimeout(cb, ms) -> __setTimeout(cb, @intCast(ms)).
                try w.appendSlice(arena, "__setTimeout(");
                if (cl.args.len > 0) try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", @intCast(");
                if (cl.args.len > 1) try emitExpr(cl.args[1], w, arena);
                try w.appendSlice(arena, "))");
            } else if (cl.is_closure) {
                // Function-value call through the fat pointer: f.call(f.ctx, args).
                const fname = cl.emit_name orelse cl.name;
                try w.print(arena, "{s}.call({s}.ctx", .{ fname, fname });
                for (cl.args) |arg| {
                    try w.appendSlice(arena, ", ");
                    try emitExpr(arg, w, arena);
                }
                try w.append(arena, ')');
            } else {
                // A `string` return from an extern function arrives as a raw
                // `[*:0]const u8`; copy it once into an owned Lumen string so the
                // value outlives the C buffer.
                if (cl.ffi_string_return) try w.appendSlice(arena, "(__alloc.dupe(u8, std.mem.span(");
                try w.print(arena, "{s}(", .{cl.emit_name orelse cl.name});
                for (cl.args, 0..) |arg, i| {
                    if (i > 0) try w.appendSlice(arena, ", ");
                    // A `string` argument crosses as a NUL-terminated C string.
                    if (i < cl.ffi_string_args.len and cl.ffi_string_args[i]) {
                        try w.appendSlice(arena, "(std.fmt.allocPrintSentinel(__alloc, \"{s}\", .{");
                        try emitExpr(arg, w, arena);
                        try w.appendSlice(arena, "}, 0) catch unreachable).ptr");
                    } else if (i < cl.ref_args.len and cl.ref_args[i]) {
                        // A by-reference (`Ref<T>`) argument: take its address so
                        // the callee mutates the caller's binding in place.
                        try w.append(arena, '&');
                        try emitExpr(arg, w, arena);
                    } else {
                        try emitExpr(arg, w, arena);
                    }
                }
                try w.append(arena, ')');
                if (cl.ffi_string_return) try w.appendSlice(arena, ")) catch unreachable)");
            }
        },
        .static_call => |cl| {
            const checked_type = cl.checked_type orelse return error.ParseError;
            if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "abs")) {
                if (checked_type == .f64) {
                    try w.appendSlice(arena, "@abs(");
                    try emitExpr(cl.args[0], w, arena);
                    try w.append(arena, ')');
                } else {
                    try w.print(arena, "@as({s}, @intCast(@abs(", .{try types.zigName(arena, checked_type)});
                    try emitExpr(cl.args[0], w, arena);
                    try w.appendSlice(arena, ")))");
                }
            } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "sign")) {
                try w.appendSlice(arena, "@as(i32, if (");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, " < 0) -1 else if (");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, " > 0) 1 else 0)");
            } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "sqrt")) {
                const arg_type = cl.checked_arg_type orelse return error.ParseError;
                try w.appendSlice(arena, "@sqrt(");
                if (arg_type == .f64) {
                    try emitExpr(cl.args[0], w, arena);
                } else {
                    try w.appendSlice(arena, "@as(f64, @floatFromInt(");
                    try emitExpr(cl.args[0], w, arena);
                    try w.appendSlice(arena, "))");
                }
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "Math") and (std.mem.eql(u8, cl.name, "max") or std.mem.eql(u8, cl.name, "min"))) {
                try w.print(arena, "@{s}(", .{cl.name});
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "clamp")) {
                try w.appendSlice(arena, "@min(@max(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.appendSlice(arena, "), ");
                try emitExpr(cl.args[2], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "String") and std.mem.eql(u8, cl.name, "isEmpty")) {
                try w.append(arena, '(');
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ".len == 0)");
            } else if (std.mem.eql(u8, cl.namespace, "String") and std.mem.eql(u8, cl.name, "contains")) {
                try w.appendSlice(arena, "(std.mem.indexOf(u8, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.appendSlice(arena, ") != null)");
            } else if (std.mem.eql(u8, cl.namespace, "String") and std.mem.eql(u8, cl.name, "startsWith")) {
                try w.appendSlice(arena, "std.mem.startsWith(u8, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "Array") and std.mem.eql(u8, cl.name, "isEmpty")) {
                try w.append(arena, '(');
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ".len == 0)");
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "readFileSync")) {
                try w.appendSlice(arena, "__readFileSync(__io, __alloc, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "Promise") and std.mem.eql(u8, cl.name, "resolve")) {
                // Promise.resolve(v) -> an already-resolved promise of v's type.
                const inner = cl.checked_arg_type orelse return error.ParseError;
                try w.print(arena, "__promiseResolved({s}, ", .{try types.zigName(arena, inner)});
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else return error.ParseError;
        },
        .var_ref => |ref| {
            if (ref.is_func_ref) {
                // A named function used as a function value: a fat pointer whose
                // call thunk ignores ctx and forwards to the real function.
                const sig = ref.func_sig orelse return error.ParseError;
                const sname = try types.funcStructName(arena, sig.*);
                try w.print(arena, "{s}{{ .ctx = undefined, .call = struct {{ fn __t(__ctx: *const anyopaque", .{sname});
                for (sig.params, 0..) |p, i| try w.print(arena, ", __p{d}: {s}", .{ i, try types.zigName(arena, p) });
                try w.print(arena, ") {s} {{ _ = __ctx; return {s}(", .{ try types.zigName(arena, sig.ret.*), ref.emit_name orelse ref.name });
                for (sig.params, 0..) |_, i| {
                    if (i > 0) try w.appendSlice(arena, ", ");
                    try w.print(arena, "__p{d}", .{i});
                }
                try w.appendSlice(arena, "); } }.__t }");
            } else {
                if (ref.capture) try w.appendSlice(arena, "__env."); // captured outer binding
                try w.appendSlice(arena, ref.emit_name orelse ref.name);
                if (ref.deref) try w.appendSlice(arena, ".*"); // scalar by-reference (`Ref<T>`) param read
                if (ref.unwrap) try w.appendSlice(arena, ".?"); // narrowed optional access
            }
        },
        .neg => |inner| {
            try w.appendSlice(arena, "-(");
            try emitExpr(inner, w, arena);
            try w.append(arena, ')');
        },
        .not => |inner| {
            try w.appendSlice(arena, "!(");
            try emitExpr(inner, w, arena);
            try w.append(arena, ')');
        },
        .bnot => |inner| {
            try w.appendSlice(arena, "~(");
            try emitExpr(inner, w, arena);
            try w.append(arena, ')');
        },
        .await_expr => |inner| {
            // Drive the event loop until the awaited promise resolves, then read
            // its value: (<promise>).await_().
            try w.append(arena, '(');
            try emitExpr(inner, w, arena);
            try w.appendSlice(arena, ").await_()");
        },
        .bin => |b| {
            if (b.op == '+' and b.checked_type != null and b.checked_type.? == .string) {
                try w.appendSlice(arena, "(std.mem.concat(std.heap.page_allocator, u8, &.{ ");
                try emitExpr(b.l, w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(b.r, w, arena);
                try w.appendSlice(arena, " }) catch std.process.exit(1))");
            } else if (b.op == '/') {
                try w.appendSlice(arena, "@divTrunc(");
                try emitExpr(b.l, w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(b.r, w, arena);
                try w.append(arena, ')');
            } else if (b.op == '%') {
                // Zig's `%` rejects signed operands → use @rem (operands are non-negative here).
                try w.appendSlice(arena, "@rem(");
                try emitExpr(b.l, w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(b.r, w, arena);
                try w.append(arena, ')');
            } else if (b.op == 'L' or b.op == 'R') {
                // Shifts: std.math.shl/shr handle the shift-amount cast for signed ints.
                const ty = try types.zigName(arena, b.checked_type orelse .i32);
                try w.print(arena, "std.math.{s}({s}, ", .{ if (b.op == 'L') "shl" else "shr", ty });
                try emitExpr(b.l, w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(b.r, w, arena);
                try w.append(arena, ')');
            } else if (b.op == 'P') {
                // Exponent: powi for integers, pow for floats.
                const t = b.checked_type orelse .i32;
                const ty = try types.zigName(arena, t);
                if (t == .f64) {
                    try w.print(arena, "std.math.pow({s}, ", .{ty});
                    try emitExpr(b.l, w, arena);
                    try w.appendSlice(arena, ", ");
                    try emitExpr(b.r, w, arena);
                    try w.append(arena, ')');
                } else {
                    try w.print(arena, "(std.math.powi({s}, ", .{ty});
                    try emitExpr(b.l, w, arena);
                    try w.appendSlice(arena, ", ");
                    try emitExpr(b.r, w, arena);
                    try w.appendSlice(arena, ") catch std.process.exit(1))");
                }
            } else {
                try w.append(arena, '(');
                try emitExpr(b.l, w, arena);
                try w.print(arena, " {c} ", .{b.op});
                try emitExpr(b.r, w, arena);
                try w.append(arena, ')');
            }
        },
        .bool_bin => |b| {
            try w.append(arena, '(');
            try emitExpr(b.l, w, arena);
            try w.print(arena, " {s} ", .{if (std.mem.eql(u8, b.op, "&&")) "and" else "or"});
            try emitExpr(b.r, w, arena);
            try w.append(arena, ')');
        },
        .cmp => |b| {
            if (b.checked_operand_type != null and b.checked_operand_type.? == .string and (std.mem.eql(u8, b.op, "==") or std.mem.eql(u8, b.op, "!="))) {
                if (std.mem.eql(u8, b.op, "!=")) try w.append(arena, '!');
                try w.appendSlice(arena, "std.mem.eql(u8, ");
                try emitExpr(b.l, w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(b.r, w, arena);
                try w.append(arena, ')');
            } else {
                try w.append(arena, '(');
                try emitExpr(b.l, w, arena);
                try w.print(arena, " {s} ", .{b.op});
                try emitExpr(b.r, w, arena);
                try w.append(arena, ')');
            }
        },
        .ternary => |ternary| {
            try w.appendSlice(arena, "(if (");
            try emitExpr(ternary.cond, w, arena);
            try w.appendSlice(arena, ") ");
            try emitExpr(ternary.then_expr, w, arena);
            try w.appendSlice(arena, " else ");
            try emitExpr(ternary.else_expr, w, arena);
            try w.append(arena, ')');
        },
        .coalesce => |c| {
            try w.append(arena, '(');
            try emitExpr(c.l, w, arena);
            try w.appendSlice(arena, " orelse ");
            try emitExpr(c.r, w, arena);
            try w.append(arena, ')');
        },
        .this_expr => try w.appendSlice(arena, "self"),
        .new_expr => |ne| {
            if (ne.container_type) |ct| {
                // Map/Set: allocate the generic container on the heap.
                const tname = (try types.zigName(arena, ct))[1..]; // strip leading '*'
                try w.print(arena, "{s}.__init()", .{tname});
                return;
            }
            try w.print(arena, "{s}.__init(", .{ne.class_name});
            for (ne.args, 0..) |arg, i| {
                if (i > 0) try w.appendSlice(arena, ", ");
                try emitExpr(arg, w, arena);
            }
            try w.append(arena, ')');
        },
        .method_call => |mc| {
            if (mc.string_method) {
                try emitStringMethod(mc, w, arena);
            } else if (mc.container_type != null) {
                // Map/Set method: dispatch directly to the runtime container method.
                try emitExpr(mc.obj, w, arena);
                try w.print(arena, ".{s}(", .{mc.name});
                for (mc.args, 0..) |arg, i| {
                    if (i > 0) try w.appendSlice(arena, ", ");
                    try emitExpr(arg, w, arena);
                }
                try w.append(arena, ')');
            } else if (mc.array_result_type != null) {
                try emitArrayMethod(mc, w, arena);
            } else if (mc.is_static) {
                // Class.staticMethod(args) -> Class.__static_m_name(args)
                try w.print(arena, "{s}.__static_m_{s}(", .{ mc.class_name orelse "", mc.name });
                for (mc.args, 0..) |arg, i| {
                    if (i > 0) try w.appendSlice(arena, ", ");
                    try emitExpr(arg, w, arena);
                }
                try w.append(arena, ')');
            } else {
                try emitExpr(mc.obj, w, arena);
                try w.print(arena, ".{s}(", .{mc.name});
                for (mc.args, 0..) |arg, i| {
                    if (i > 0) try w.appendSlice(arena, ", ");
                    try emitExpr(arg, w, arena);
                }
                try w.append(arena, ')');
            }
        },
        .super_call => |sc| {
            // super.method(args) -> self.__super_<owner>_method(args)
            try w.print(arena, "self.__super_{s}_{s}(", .{ sc.parent orelse "", sc.name });
            for (sc.args, 0..) |arg, i| {
                if (i > 0) try w.appendSlice(arena, ", ");
                try emitExpr(arg, w, arena);
            }
            try w.append(arena, ')');
        },
        .arrow => |arrow| {
            const ret = arrow.checked_return_type orelse return error.ParseError;
            // Build the fat-pointer struct name for this signature.
            const params = try arena.alloc(types.Type, arrow.params.len);
            for (arrow.params, 0..) |p, i| params[i] = p.checked_type orelse return error.ParseError;
            const ret_p = try arena.create(types.Type);
            ret_p.* = ret;
            const sname = try types.funcStructName(arena, .{ .params = params, .ret = ret_p });
            const ret_zig = try types.zigName(arena, ret);

            const Local = struct {
                fn emitCallFn(a: std.mem.Allocator, ww: *std.ArrayListUnmanaged(u8), ar: *const ast.ArrowExpr, rz: []const u8, capturing: bool) CompileError!void {
                    try ww.appendSlice(a, "struct { fn __a(__ctx: *const anyopaque");
                    for (ar.params) |p| try ww.print(a, ", {s}: {s}", .{ p.name, try types.zigName(a, p.checked_type.?) });
                    try ww.print(a, ") {s} {{ ", .{rz});
                    if (capturing) {
                        try ww.appendSlice(a, "const __env: *const Env = @ptrCast(@alignCast(__ctx)); ");
                    } else {
                        try ww.appendSlice(a, "_ = __ctx; ");
                    }
                    try ww.appendSlice(a, "return ");
                    try emitExpr(ar.body_expr, ww, a);
                    try ww.appendSlice(a, "; } }.__a");
                }
            };

            if (arrow.captures.len == 0) {
                try w.print(arena, "{s}{{ .ctx = undefined, .call = ", .{sname});
                try Local.emitCallFn(arena, w, arrow, ret_zig, false);
                try w.appendSlice(arena, " }");
            } else {
                // (blk: { const Env = struct {...}; const __e = heap; __e.* = {...};
                //         break :blk Fn{ .ctx = __e, .call = struct {...}.__a }; })
                try w.appendSlice(arena, "(blk: { const Env = struct { ");
                for (arrow.captures) |c| try w.print(arena, "{s}: {s}, ", .{ c.emit_name, try types.zigName(arena, c.ty) });
                try w.appendSlice(arena, "}; const __e = std.heap.page_allocator.create(Env) catch unreachable; __e.* = .{ ");
                for (arrow.captures) |c| try w.print(arena, ".{s} = {s}, ", .{ c.emit_name, c.emit_name });
                try w.print(arena, "}}; break :blk {s}{{ .ctx = __e, .call = ", .{sname});
                try Local.emitCallFn(arena, w, arrow, ret_zig, true);
                try w.appendSlice(arena, " }; })");
            }
        },
        .template => |parts| {
            // `a${e}b` -> (std.fmt.allocPrint(page, "a{s}b", .{ e }) catch unreachable)
            try w.appendSlice(arena, "(std.fmt.allocPrint(std.heap.page_allocator, \"");
            for (parts) |part| {
                if (part.text) |t| {
                    try emitTemplateText(t, w, arena);
                } else {
                    const spec = switch (part.expr_type orelse types.Type.string) {
                        .string, .string_literal_union => "{s}",
                        .bool => "{}",
                        else => "{d}",
                    };
                    try w.appendSlice(arena, spec);
                }
            }
            try w.appendSlice(arena, "\", .{ ");
            var first = true;
            for (parts) |part| {
                if (part.expr) |hole| {
                    if (!first) try w.appendSlice(arena, ", ");
                    try emitExpr(hole, w, arena);
                    first = false;
                }
            }
            try w.appendSlice(arena, " }) catch unreachable)");
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
            if (fa.optional_chain) {
                // a?.field  ->  (if (a) |__oc| @as(?T, __oc.field) else null)
                // The @as keeps both branches of the same optional type.
                const ft = try types.zigName(arena, fa.chain_field_type orelse .none);
                try w.appendSlice(arena, "(if (");
                try emitExpr(fa.obj, w, arena);
                try w.print(arena, ") |__oc| @as(?{s}, __oc.{s}) else null)", .{ ft, fa.name });
            } else if (fa.enum_value) |ev| {
                switch (ev) {
                    .int => |n| try w.print(arena, "{d}", .{n}),
                    .str => |s| {
                        try w.append(arena, '"');
                        for (s) |ch| {
                            if (ch == '"' or ch == '\\') try w.append(arena, '\\');
                            try w.append(arena, ch);
                        }
                        try w.append(arena, '"');
                    },
                }
            } else if (fa.builtin == .length) {
                try w.appendSlice(arena, "@as(i64, @intCast(");
                try emitExpr(fa.obj, w, arena);
                try w.appendSlice(arena, ".len))");
            } else if (fa.builtin == .container_size) {
                try emitExpr(fa.obj, w, arena);
                try w.appendSlice(arena, ".size()");
            } else if (fa.builtin == .error_message) {
                try emitExpr(fa.obj, w, arena);
            } else if (fa.is_static) {
                // Class.staticField -> Owner.__static_Owner_field
                const owner = fa.class_name orelse "";
                try w.print(arena, "{s}.__static_{s}_{s}", .{ owner, owner, fa.name });
            } else if (fa.is_getter) {
                // obj.prop -> obj.__get_prop()
                try emitExpr(fa.obj, w, arena);
                try w.print(arena, ".__get_{s}()", .{fa.name});
            } else {
                try emitExpr(fa.obj, w, arena);
                try w.print(arena, ".{s}", .{fa.name});
            }
        },
        .index => |idx| {
            if (idx.tuple_index) |pos| {
                // Tuple positional access -> struct field `t.@"N"`.
                try emitExpr(idx.obj, w, arena);
                try w.print(arena, ".@\"{d}\"", .{pos});
                return;
            }
            try emitExpr(idx.obj, w, arena);
            try w.appendSlice(arena, "[@as(usize, @intCast(");
            try emitExpr(idx.value, w, arena);
            try w.appendSlice(arena, "))]");
        },
        .cast => |c| {
            // `expr as T` is a checker-only assertion; the runtime value is the
            // same flat struct / scalar, so emit the operand unchanged.
            try emitExpr(c.inner, w, arena);
        },
    }
}

/// A neutral default value for a flat union-struct field, used so a single
/// variant's object literal can omit the other variants' fields.
fn zigZeroValue(arena: std.mem.Allocator, t: types.Type) CompileError![]const u8 {
    _ = arena;
    return switch (t) {
        .i32, .i64, .int_literal_union => "0",
        .f64 => "0",
        .bool => "false",
        .enum_type => |e| if (e.is_string) "\"\"" else "0",
        .string, .string_literal_union, .error_obj => "\"\"",
        .i32_array, .i64_array, .f64_array, .bool_array, .string_array => "&.{}",
        .named_array => "&.{}",
        .optional, .none => "null",
        else => "undefined",
    };
}

/// Emit value equality between a slice element `__e` and the (already-emitted)
/// needle expression for a given element type. Strings compare by bytes.
fn emitElemEq(elem: types.Type, needle: *const Expr, w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    if (types.isStringLike(elem)) {
        try w.appendSlice(arena, "std.mem.eql(u8, __e, ");
        try emitExpr(needle, w, arena);
        try w.append(arena, ')');
    } else {
        try w.appendSlice(arena, "(__e == ");
        try emitExpr(needle, w, arena);
        try w.append(arena, ')');
    }
}

/// Monotonic counter giving each emitted array-method block a unique label so
/// chained/nested calls (`xs.map(...).filter(...)`) don't collide on `blk`.
var g_array_method_seq: usize = 0;

/// Lower an array higher-order / value method `arr.m(args)` to an inline Zig
/// expression block over the underlying slice. Callbacks are invoked through the
/// uniform function-value representation (`__cb.call(__cb.ctx, ...)`).
fn emitArrayMethod(mc: anytype, w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    const elem = mc.array_elem_type orelse return error.ParseError;
    const result = mc.array_result_type orelse return error.ParseError;
    const elem_zig = try types.zigName(arena, elem);
    const eq = std.mem.eql;
    const name = mc.name;
    g_array_method_seq += 1;
    const lbl = try std.fmt.allocPrint(arena, "__am{d}", .{g_array_method_seq});

    if (eq(u8, name, "map")) {
        const u = types.arrayElem(result) orelse return error.ParseError;
        const u_zig = try types.zigName(arena, u);
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; const __cb = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; const __r = std.heap.page_allocator.alloc({s}, __arr.len) catch unreachable; for (__arr, 0..) |__e, __i| {{ __r[__i] = __cb.call(__cb.ctx, __e); }} break :{s} @as([]const {s}, __r); }})", .{ u_zig, lbl, u_zig });
        return;
    }

    if (eq(u8, name, "filter")) {
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; const __cb = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; var __r: std.ArrayListUnmanaged({s}) = .empty; for (__arr) |__e| {{ if (__cb.call(__cb.ctx, __e)) __r.append(std.heap.page_allocator, __e) catch unreachable; }} break :{s} @as([]const {s}, __r.items); }})", .{ elem_zig, lbl, elem_zig });
        return;
    }

    if (eq(u8, name, "forEach")) {
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; const __cb = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; for (__arr) |__e| {{ __cb.call(__cb.ctx, __e); }} break :{s} {{}}; }})", .{lbl});
        return;
    }

    if (eq(u8, name, "reduce")) {
        const acc = mc.array_acc_type orelse return error.ParseError;
        const acc_zig = try types.zigName(arena, acc);
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; const __cb = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; var __acc: {s} = ", .{acc_zig});
        try emitExpr(mc.args[1], w, arena);
        try w.print(arena, "; for (__arr) |__e| {{ __acc = __cb.call(__cb.ctx, __acc, __e); }} break :{s} __acc; }})", .{lbl});
        return;
    }

    if (eq(u8, name, "find")) {
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; const __cb = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; var __found: ?{s} = null; for (__arr) |__e| {{ if (__cb.call(__cb.ctx, __e)) {{ __found = __e; break; }} }} break :{s} __found; }})", .{ elem_zig, lbl });
        return;
    }

    if (eq(u8, name, "some")) {
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; const __cb = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; var __r = false; for (__arr) |__e| {{ if (__cb.call(__cb.ctx, __e)) {{ __r = true; break; }} }} break :{s} __r; }})", .{lbl});
        return;
    }

    if (eq(u8, name, "every")) {
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; const __cb = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; var __r = true; for (__arr) |__e| {{ if (!__cb.call(__cb.ctx, __e)) {{ __r = false; break; }} }} break :{s} __r; }})", .{lbl});
        return;
    }

    if (eq(u8, name, "indexOf")) {
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; var __idx: i32 = -1; for (__arr, 0..) |__e, __i| { if (");
        try emitElemEq(elem, mc.args[0], w, arena);
        try w.print(arena, ") {{ __idx = @as(i32, @intCast(__i)); break; }} }} break :{s} __idx; }})", .{lbl});
        return;
    }

    if (eq(u8, name, "includes")) {
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; var __r = false; for (__arr) |__e| { if (");
        try emitElemEq(elem, mc.args[0], w, arena);
        try w.print(arena, ") {{ __r = true; break; }} }} break :{s} __r; }})", .{lbl});
        return;
    }

    if (eq(u8, name, "join")) {
        const spec = switch (elem) {
            .string, .string_literal_union => "{s}",
            .bool => "{}",
            else => "{d}",
        };
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; const __sep: []const u8 = ");
        if (mc.args.len == 1) {
            try emitExpr(mc.args[0], w, arena);
        } else {
            try w.appendSlice(arena, "\",\"");
        }
        try w.appendSlice(arena, "; var __buf: std.ArrayListUnmanaged(u8) = .empty; for (__arr, 0..) |__e, __i| { if (__i > 0) __buf.appendSlice(std.heap.page_allocator, __sep) catch unreachable; ");
        try w.print(arena, "__buf.appendSlice(std.heap.page_allocator, std.fmt.allocPrint(std.heap.page_allocator, \"{s}\", .{{__e}}) catch unreachable) catch unreachable; }} break :{s} @as([]const u8, __buf.items); }})", .{ spec, lbl });
        return;
    }

    return error.ParseError;
}

/// Monotonic counter giving each emitted string-method block a unique label.
var g_string_method_seq: usize = 0;

/// Lower a string instance method `s.m(args)` to an inline Zig expression block
/// over the underlying byte slice. Results are allocated with the page allocator
/// (allocate-and-leak), matching the array-method lowering.
fn emitStringMethod(mc: anytype, w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    const eq = std.mem.eql;
    const name = mc.name;
    g_string_method_seq += 1;
    const lbl = try std.fmt.allocPrint(arena, "__sm{d}", .{g_string_method_seq});

    // Open the block and bind `__s` to the receiver string.
    try w.print(arena, "({s}: {{ const __s: []const u8 = ", .{lbl});
    try emitExpr(mc.obj, w, arena);
    try w.appendSlice(arena, "; ");

    // Helper to emit an argument coerced to isize (indices may be i32 or i64).
    const A = struct {
        fn idx(varname: []const u8, e: anytype, ww: *std.ArrayListUnmanaged(u8), ar: std.mem.Allocator) CompileError!void {
            try ww.print(ar, "const {s}: isize = @intCast(", .{varname});
            try emitExpr(e, ww, ar);
            try ww.appendSlice(ar, "); ");
        }
    };

    if (eq(u8, name, "charAt")) {
        try A.idx("__i", mc.args[0], w, arena);
        try w.print(arena, "break :{s} @as([]const u8, if (__i >= 0 and __i < @as(isize, @intCast(__s.len))) __s[@intCast(__i)..@as(usize, @intCast(__i)) + 1] else \"\"); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "charCodeAt")) {
        try A.idx("__i", mc.args[0], w, arena);
        try w.print(arena, "break :{s} @as(i32, if (__i >= 0 and __i < @as(isize, @intCast(__s.len))) @intCast(__s[@intCast(__i)]) else -1); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "indexOf")) {
        try w.appendSlice(arena, "const __needle: []const u8 = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; break :{s} @as(i32, if (std.mem.indexOf(u8, __s, __needle)) |__p| @intCast(__p) else -1); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "includes")) {
        try w.appendSlice(arena, "const __needle: []const u8 = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; break :{s} (std.mem.indexOf(u8, __s, __needle) != null); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "startsWith")) {
        try w.appendSlice(arena, "const __needle: []const u8 = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; break :{s} std.mem.startsWith(u8, __s, __needle); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "endsWith")) {
        try w.appendSlice(arena, "const __needle: []const u8 = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; break :{s} std.mem.endsWith(u8, __s, __needle); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "slice") or eq(u8, name, "substring")) {
        const is_sub = eq(u8, name, "substring");
        try w.appendSlice(arena, "const __len: isize = @intCast(__s.len); ");
        try A.idx("__a", mc.args[0], w, arena);
        if (mc.args.len == 2) {
            try A.idx("__b", mc.args[1], w, arena);
        } else {
            try w.appendSlice(arena, "const __b: isize = __len; ");
        }
        // Clamp both endpoints into [0, len].
        try w.appendSlice(arena, "const __c0: isize = if (__a < 0) 0 else if (__a > __len) __len else __a; ");
        try w.appendSlice(arena, "const __c1: isize = if (__b < 0) 0 else if (__b > __len) __len else __b; ");
        if (is_sub) {
            // substring swaps so the smaller endpoint is the start.
            try w.appendSlice(arena, "const __lo: isize = if (__c0 < __c1) __c0 else __c1; const __hi: isize = if (__c0 < __c1) __c1 else __c0; ");
        } else {
            // slice yields empty when start > end.
            try w.appendSlice(arena, "const __lo: isize = __c0; const __hi: isize = if (__c1 < __c0) __c0 else __c1; ");
        }
        try w.print(arena, "break :{s} @as([]const u8, __s[@intCast(__lo)..@intCast(__hi)]); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "toUpperCase")) {
        try w.print(arena, "const __r = std.heap.page_allocator.alloc(u8, __s.len) catch unreachable; for (__s, 0..) |__c, __i| {{ __r[__i] = std.ascii.toUpper(__c); }} break :{s} @as([]const u8, __r); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "toLowerCase")) {
        try w.print(arena, "const __r = std.heap.page_allocator.alloc(u8, __s.len) catch unreachable; for (__s, 0..) |__c, __i| {{ __r[__i] = std.ascii.toLower(__c); }} break :{s} @as([]const u8, __r); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "trim")) {
        try w.print(arena, "break :{s} @as([]const u8, std.mem.trim(u8, __s, \" \\t\\r\\n\")); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "repeat")) {
        try A.idx("__n", mc.args[0], w, arena);
        try w.appendSlice(arena, "const __count: usize = if (__n < 0) 0 else @intCast(__n); ");
        try w.appendSlice(arena, "var __buf: std.ArrayListUnmanaged(u8) = .empty; var __k: usize = 0; while (__k < __count) : (__k += 1) { __buf.appendSlice(std.heap.page_allocator, __s) catch unreachable; } ");
        try w.print(arena, "break :{s} @as([]const u8, __buf.items); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "padStart")) {
        try A.idx("__target", mc.args[0], w, arena);
        try w.appendSlice(arena, "const __pad: []const u8 = ");
        try emitExpr(mc.args[1], w, arena);
        try w.appendSlice(arena, "; const __goal: usize = if (__target < 0) 0 else @intCast(__target); ");
        try w.appendSlice(arena, "var __buf: std.ArrayListUnmanaged(u8) = .empty; if (__goal > __s.len and __pad.len > 0) { var __need: usize = __goal - __s.len; while (__need > 0) { const __take = if (__need < __pad.len) __need else __pad.len; __buf.appendSlice(std.heap.page_allocator, __pad[0..__take]) catch unreachable; __need -= __take; } } ");
        try w.appendSlice(arena, "__buf.appendSlice(std.heap.page_allocator, __s) catch unreachable; ");
        try w.print(arena, "break :{s} @as([]const u8, __buf.items); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "replace")) {
        try w.appendSlice(arena, "const __from: []const u8 = ");
        try emitExpr(mc.args[0], w, arena);
        try w.appendSlice(arena, "; const __to: []const u8 = ");
        try emitExpr(mc.args[1], w, arena);
        try w.appendSlice(arena, "; var __buf: std.ArrayListUnmanaged(u8) = .empty; if (__from.len > 0) { if (std.mem.indexOf(u8, __s, __from)) |__p| { __buf.appendSlice(std.heap.page_allocator, __s[0..__p]) catch unreachable; __buf.appendSlice(std.heap.page_allocator, __to) catch unreachable; __buf.appendSlice(std.heap.page_allocator, __s[__p + __from.len ..]) catch unreachable; } else { __buf.appendSlice(std.heap.page_allocator, __s) catch unreachable; } } else { __buf.appendSlice(std.heap.page_allocator, __s) catch unreachable; } ");
        try w.print(arena, "break :{s} @as([]const u8, __buf.items); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "split")) {
        try w.appendSlice(arena, "const __sep: []const u8 = ");
        try emitExpr(mc.args[0], w, arena);
        try w.appendSlice(arena, "; var __parts: std.ArrayListUnmanaged([]const u8) = .empty; ");
        try w.appendSlice(arena, "if (__sep.len == 0) { for (__s) |*__cp| __parts.append(std.heap.page_allocator, __cp[0..1]) catch unreachable; } ");
        try w.appendSlice(arena, "else { var __it = std.mem.splitSequence(u8, __s, __sep); while (__it.next()) |__seg| __parts.append(std.heap.page_allocator, __seg) catch unreachable; } ");
        try w.print(arena, "break :{s} @as([]const []const u8, __parts.items); }})", .{lbl});
        return;
    }

    return error.ParseError;
}

/// Escapes template literal text for embedding inside a Zig `std.fmt` format
/// string literal: quotes/backslashes escaped, braces doubled, control chars
/// turned into escape sequences.
fn emitTemplateText(text: []const u8, w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    for (text) |ch| {
        switch (ch) {
            '"' => try w.appendSlice(arena, "\\\""),
            '\\' => try w.appendSlice(arena, "\\\\"),
            '{' => try w.appendSlice(arena, "{{"),
            '}' => try w.appendSlice(arena, "}}"),
            '\n' => try w.appendSlice(arena, "\\n"),
            '\r' => try w.appendSlice(arena, "\\r"),
            '\t' => try w.appendSlice(arena, "\\t"),
            else => try w.append(arena, ch),
        }
    }
}

/// Whether `name` is referenced anywhere in an expression (as a variable read
/// or a function-value call target). Used to discard unused parameters so the
/// emitted Zig compiles (Zig forbids unused parameters/locals).
fn exprUsesName(e: *const Expr, name: []const u8) bool {
    return switch (e.*) {
        .num, .float, .bool, .str, .null_lit, .this_expr => false,
        .var_ref => |r| std.mem.eql(u8, r.name, name),
        .array => |a| blk: {
            for (a.items) |it| if (exprUsesName(it, name)) break :blk true;
            break :blk false;
        },
        .tuple_lit => |t| blk: {
            for (t.items) |it| if (exprUsesName(it, name)) break :blk true;
            break :blk false;
        },
        .spread => |inner| exprUsesName(inner, name),
        .neg, .not, .bnot, .await_expr => |inner| exprUsesName(inner, name),
        .bin => |b| exprUsesName(b.l, name) or exprUsesName(b.r, name),
        .bool_bin => |b| exprUsesName(b.l, name) or exprUsesName(b.r, name),
        .cmp => |b| exprUsesName(b.l, name) or exprUsesName(b.r, name),
        .ternary => |t| exprUsesName(t.cond, name) or exprUsesName(t.then_expr, name) or exprUsesName(t.else_expr, name),
        .coalesce => |c| exprUsesName(c.l, name) or exprUsesName(c.r, name),
        .arrow => |a| exprUsesName(a.body_expr, name),
        .new_expr => |ne| blk: {
            for (ne.args) |it| if (exprUsesName(it, name)) break :blk true;
            break :blk false;
        },
        .method_call => |mc| blk: {
            if (exprUsesName(mc.obj, name)) break :blk true;
            for (mc.args) |it| if (exprUsesName(it, name)) break :blk true;
            break :blk false;
        },
        .super_call => |sc| blk: {
            for (sc.args) |it| if (exprUsesName(it, name)) break :blk true;
            break :blk false;
        },
        .template => |parts| blk: {
            for (parts) |pt| if (pt.expr) |x| {
                if (exprUsesName(x, name)) break :blk true;
            };
            break :blk false;
        },
        .obj => |fields| blk: {
            for (fields) |f| if (exprUsesName(f.value, name)) break :blk true;
            break :blk false;
        },
        .field => |f| exprUsesName(f.obj, name),
        .index => |idx| exprUsesName(idx.obj, name) or exprUsesName(idx.value, name),
        .call => |cl| blk: {
            if (cl.is_closure and std.mem.eql(u8, cl.name, name)) break :blk true;
            for (cl.args) |it| if (exprUsesName(it, name)) break :blk true;
            break :blk false;
        },
        .static_call => |sc| blk: {
            for (sc.args) |it| if (exprUsesName(it, name)) break :blk true;
            break :blk false;
        },
        .cast => |c| exprUsesName(c.inner, name),
    };
}

fn bodyUsesName(body: []const Stmt, name: []const u8) bool {
    for (body) |*s| if (stmtUsesName(s, name)) return true;
    return false;
}

fn stmtUsesName(stmt: *const Stmt, name: []const u8) bool {
    return switch (stmt.*) {
        .var_decl => |d| exprUsesName(d.init, name),
        .destructure_decl => |d| exprUsesName(d.source, name),
        .assign => |a| std.mem.eql(u8, a.name, name) or exprUsesName(a.value, name),
        .member_assign => |ma| exprUsesName(ma.value, name) or (ma.obj != null and exprUsesName(ma.obj.?, name)),
        .super_ctor => |sc| blk: {
            for (sc.args) |it| if (exprUsesName(it, name)) break :blk true;
            break :blk false;
        },
        .console_log => |log| exprUsesName(log.value, name),
        .return_stmt => |r| if (r.value) |x| exprUsesName(x, name) else false,
        .throw_stmt => |t| exprUsesName(t.value, name),
        .expr_stmt => |x| exprUsesName(x.value, name),
        .while_stmt => |w| exprUsesName(w.cond, name) or bodyUsesName(w.body, name),
        .do_while_stmt => |w| exprUsesName(w.cond, name) or bodyUsesName(w.body, name),
        .for_stmt => |f| exprUsesName(f.init.init, name) or exprUsesName(f.cond, name) or exprUsesName(f.update.value, name) or bodyUsesName(f.body, name),
        .for_of_stmt => |f| exprUsesName(f.iterable, name) or bodyUsesName(f.body, name),
        .if_stmt => |b| exprUsesName(b.cond, name) or bodyUsesName(b.then_body, name) or (b.else_body != null and bodyUsesName(b.else_body.?, name)),
        .switch_stmt => |sw| blk: {
            if (exprUsesName(sw.value, name)) break :blk true;
            for (sw.cases) |cse| if (exprUsesName(cse.value, name) or bodyUsesName(cse.body, name)) break :blk true;
            if (sw.default_body) |db| if (bodyUsesName(db, name)) break :blk true;
            break :blk false;
        },
        .try_stmt => |t| bodyUsesName(t.try_body, name) or bodyUsesName(t.catch_body, name) or (t.finally_body != null and bodyUsesName(t.finally_body.?, name)),
        .defer_stmt => |d| bodyUsesName(d.body, name),
        .using_decl => |u| blk: {
            if (u.defer_body) |b| if (bodyUsesName(b, name)) break :blk true;
            if (u.dispose_call) |d| if (exprUsesName(d, name)) break :blk true;
            break :blk exprUsesName(u.init, name);
        },
        else => false,
    };
}

/// Whether a statement can assign the enclosing try's throw slot, i.e. it
/// contains a `throw` that is not swallowed by a fully-handling nested
/// try/catch. Used to choose `var` vs `const` for the slot so the generated
/// Zig does not warn about an unmutated `var`.
fn stmtCanThrow(stmt: *const Stmt) bool {
    return switch (stmt.*) {
        .throw_stmt => true,
        .while_stmt => |w| bodyCanThrow(w.body),
        .do_while_stmt => |w| bodyCanThrow(w.body),
        .for_stmt => |f| bodyCanThrow(f.body),
        .for_of_stmt => |f| bodyCanThrow(f.body),
        .if_stmt => |b| bodyCanThrow(b.then_body) or (b.else_body != null and bodyCanThrow(b.else_body.?)),
        .switch_stmt => |sw| blk: {
            for (sw.cases) |cse| if (bodyCanThrow(cse.body)) break :blk true;
            if (sw.default_body) |db| if (bodyCanThrow(db)) break :blk true;
            break :blk false;
        },
        .defer_stmt => |d| bodyCanThrow(d.body),
        .using_decl => |u| if (u.defer_body) |b| bodyCanThrow(b) else false,
        // A nested try swallows throws from its own try body via its own slot;
        // it propagates to the outer slot only if its catch or finally throws.
        .try_stmt => |t| bodyCanThrow(t.catch_body) or (t.finally_body != null and bodyCanThrow(t.finally_body.?)),
        else => false,
    };
}

fn bodyCanThrow(body: []const Stmt) bool {
    for (body) |*stmt| if (stmtCanThrow(stmt)) return true;
    return false;
}

/// Whether a statement unconditionally diverts control via `throw` (lowered to
/// a `break` out of the enclosing try). Anything after such a statement in the
/// same try body is dead code, which Zig rejects, so the emitter stops there.
fn stmtAlwaysThrows(stmt: *const Stmt) bool {
    return switch (stmt.*) {
        .throw_stmt => true,
        .if_stmt => |b| b.else_body != null and bodyAlwaysThrows(b.then_body) and bodyAlwaysThrows(b.else_body.?),
        else => false,
    };
}

fn bodyAlwaysThrows(body: []const Stmt) bool {
    if (body.len == 0) return false;
    return stmtAlwaysThrows(&body[body.len - 1]);
}

/// Whether a statement unconditionally diverts control via `return` or `throw`
/// (used to decide whether an async `Promise<void>` body needs a trailing
/// resolved-promise return, which would otherwise be unreachable code).
fn stmtAlwaysReturns(stmt: *const Stmt) bool {
    return switch (stmt.*) {
        .return_stmt, .throw_stmt => true,
        .if_stmt => |b| b.else_body != null and bodyAlwaysReturns(b.then_body) and bodyAlwaysReturns(b.else_body.?),
        else => false,
    };
}

fn bodyAlwaysReturns(body: []const Stmt) bool {
    for (body) |*stmt| if (stmtAlwaysReturns(stmt)) return true;
    return false;
}

/// Whether an expression reads `this` (so the enclosing method needs `self`).
fn exprUsesThis(e: *const Expr) bool {
    return switch (e.*) {
        .this_expr => true,
        .num, .float, .bool, .str, .null_lit, .var_ref => false,
        .array => |a| blk: {
            for (a.items) |it| if (exprUsesThis(it)) break :blk true;
            break :blk false;
        },
        .tuple_lit => |t| blk: {
            for (t.items) |it| if (exprUsesThis(it)) break :blk true;
            break :blk false;
        },
        .spread => |inner| exprUsesThis(inner),
        .neg, .not, .bnot, .await_expr => |inner| exprUsesThis(inner),
        .bin => |b| exprUsesThis(b.l) or exprUsesThis(b.r),
        .bool_bin => |b| exprUsesThis(b.l) or exprUsesThis(b.r),
        .cmp => |b| exprUsesThis(b.l) or exprUsesThis(b.r),
        .ternary => |t| exprUsesThis(t.cond) or exprUsesThis(t.then_expr) or exprUsesThis(t.else_expr),
        .coalesce => |c| exprUsesThis(c.l) or exprUsesThis(c.r),
        .arrow => |a| exprUsesThis(a.body_expr),
        .new_expr => |ne| blk: {
            for (ne.args) |it| if (exprUsesThis(it)) break :blk true;
            break :blk false;
        },
        .method_call => |mc| blk: {
            if (exprUsesThis(mc.obj)) break :blk true;
            for (mc.args) |it| if (exprUsesThis(it)) break :blk true;
            break :blk false;
        },
        .super_call => true, // emits `self.__super_...`
        .template => |parts| blk: {
            for (parts) |pt| if (pt.expr) |x| {
                if (exprUsesThis(x)) break :blk true;
            };
            break :blk false;
        },
        .obj => |fields| blk: {
            for (fields) |f| if (exprUsesThis(f.value)) break :blk true;
            break :blk false;
        },
        .field => |f| exprUsesThis(f.obj),
        .index => |idx| exprUsesThis(idx.obj) or exprUsesThis(idx.value),
        .call => |cl| blk: {
            for (cl.args) |it| if (exprUsesThis(it)) break :blk true;
            break :blk false;
        },
        .static_call => |sc| blk: {
            for (sc.args) |it| if (exprUsesThis(it)) break :blk true;
            break :blk false;
        },
        .cast => |c| exprUsesThis(c.inner),
    };
}

fn stmtUsesThis(stmt: *const Stmt) bool {
    return switch (stmt.*) {
        .member_assign => |ma| ma.obj == null or exprUsesThis(ma.obj.?) or exprUsesThis(ma.value),
        .super_ctor => true, // inlined parent ctor writes `self.field`
        .var_decl => |d| exprUsesThis(d.init),
        .destructure_decl => |d| exprUsesThis(d.source),
        .assign => |a| exprUsesThis(a.value),
        .console_log => |log| exprUsesThis(log.value),
        .return_stmt => |r| if (r.value) |x| exprUsesThis(x) else false,
        .throw_stmt => |t| exprUsesThis(t.value),
        .expr_stmt => |x| exprUsesThis(x.value),
        .while_stmt => |w| exprUsesThis(w.cond) or bodyUsesThis(w.body),
        .do_while_stmt => |w| exprUsesThis(w.cond) or bodyUsesThis(w.body),
        .for_stmt => |f| exprUsesThis(f.init.init) or exprUsesThis(f.cond) or exprUsesThis(f.update.value) or bodyUsesThis(f.body),
        .for_of_stmt => |f| exprUsesThis(f.iterable) or bodyUsesThis(f.body),
        .if_stmt => |b| exprUsesThis(b.cond) or bodyUsesThis(b.then_body) or (b.else_body != null and bodyUsesThis(b.else_body.?)),
        .switch_stmt => |sw| blk: {
            if (exprUsesThis(sw.value)) break :blk true;
            for (sw.cases) |cse| if (exprUsesThis(cse.value) or bodyUsesThis(cse.body)) break :blk true;
            if (sw.default_body) |db| if (bodyUsesThis(db)) break :blk true;
            break :blk false;
        },
        .try_stmt => |t| bodyUsesThis(t.try_body) or bodyUsesThis(t.catch_body) or (t.finally_body != null and bodyUsesThis(t.finally_body.?)),
        .defer_stmt => |d| bodyUsesThis(d.body),
        .using_decl => |u| blk: {
            if (u.defer_body) |b| if (bodyUsesThis(b)) break :blk true;
            if (u.dispose_call) |d| if (exprUsesThis(d)) break :blk true;
            break :blk exprUsesThis(u.init);
        },
        else => false,
    };
}

fn bodyUsesThis(body: []const Stmt) bool {
    for (body) |*s| if (stmtUsesThis(s)) return true;
    return false;
}

/// Emit `_ = name;` discards for any parameters the body never references, so
/// the generated Zig function compiles. (A no-op for fully-used parameter lists,
/// so non-generic functions are unaffected.)
fn emitUnusedParamDiscards(params: []const ast.FunctionParam, body: []const Stmt, w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    for (params) |param| {
        if (!bodyUsesName(body, param.name)) {
            try w.print(arena, "    _ = {s};\n", .{param.name});
        }
    }
}

fn printFormat(t: types.Type) []const u8 {
    return switch (t) {
        .string, .string_literal_union => "{s}",
        .bool => "{}",
        .enum_type => |e| if (e.is_string) "{s}" else "{d}",
        .optional => |inner| switch (inner.*) {
            .string, .string_literal_union => "{?s}",
            .bool => "{?}",
            else => "{?d}",
        },
        else => "{d}",
    };
}

pub const CompileOptions = struct {
    runtime_locations: bool = true,
};

/// Collect the inheritance chain from a root ancestor down to `c` (inclusive).
fn collectChain(c: *const ast.ClassDecl, arena: std.mem.Allocator) CompileError![]*const ast.ClassDecl {
    var list: std.ArrayListUnmanaged(*const ast.ClassDecl) = .empty;
    var cur: ?*const ast.ClassDecl = c;
    while (cur) |cc| {
        try list.append(arena, cc);
        cur = if (cc.parent) |p| findClass(p) else null;
    }
    // Reverse to root-first order.
    const items = list.items;
    var i: usize = 0;
    while (i < items.len / 2) : (i += 1) {
        const t = items[i];
        items[i] = items[items.len - 1 - i];
        items[items.len - 1 - i] = t;
    }
    return items;
}

/// A zero/default initializer literal for a static field of the given type.
fn zeroValue(ty: types.Type) []const u8 {
    return switch (ty) {
        .i32, .i64 => "0",
        .f64 => "0",
        .bool => "false",
        .string => "\"\"",
        else => "undefined",
    };
}

/// Lower a class to a Zig struct: ancestor fields are flattened in, instance
/// methods (own + inherited, with overrides) are emitted bound to the struct,
/// `super.method` copies are emitted under internal names, statics become struct
/// globals/free functions, and getters/setters become `__get_`/`__set_` methods.
fn emitClass(c: *const ast.ClassDecl, decls: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, throw_target: ?[]const u8, switch_break_target: ?[]const u8, options: CompileOptions) CompileError!void {
    const chain = try collectChain(c, arena);

    try decls.print(arena, "const {s} = struct {{\n", .{c.name});

    // Instance fields, ancestors first (flattened layout).
    for (chain) |cc| {
        for (cc.fields) |field| {
            if (field.is_static) continue;
            try decls.print(arena, "    {s}: {s},\n", .{ field.name, try types.zigName(arena, field.checked_type orelse return error.ParseError) });
        }
    }

    // Static fields -> struct-scoped vars with a zero default. Declared only on
    // the owning class so the whole hierarchy shares one storage location,
    // accessed as `Owner.__static_Owner_field`.
    for (c.fields) |field| {
        if (!field.is_static) continue;
        const ty = field.checked_type orelse return error.ParseError;
        try decls.print(arena, "    var __static_{s}_{s}: {s} = {s};\n", .{ c.name, field.name, try types.zigName(arena, ty), zeroValue(ty) });
    }

    // Constructor: resolve the nearest ctor among the chain that the most
    // derived class provides; if the class has none, inherit the parent's.
    try decls.print(arena, "    fn __init(", .{});
    var ctor_owner: *const ast.ClassDecl = c;
    if (!c.has_ctor) {
        var k: usize = chain.len;
        while (k > 0) {
            k -= 1;
            if (chain[k].has_ctor) {
                ctor_owner = chain[k];
                break;
            }
        }
    }
    for (ctor_owner.ctor_params, 0..) |param, i| {
        if (i > 0) try decls.appendSlice(arena, ", ");
        try decls.print(arena, "{s}: {s}", .{ param.name, try types.zigName(arena, param.checked_type orelse return error.ParseError) });
    }
    try decls.print(arena, ") *{s} {{\n", .{c.name});
    try decls.print(arena, "    const self = std.heap.page_allocator.create({s}) catch unreachable;\n", .{c.name});
    try emitUnusedParamDiscards(ctor_owner.ctor_params, ctor_owner.ctor_body, decls, arena);
    for (ctor_owner.ctor_body) |*body_stmt| try emitStmtWithThrow(body_stmt, decls, decls, arena, throw_target, switch_break_target, options);
    try decls.appendSlice(arena, "    return self;\n    }\n");

    // Instance methods, getters, setters: most-derived definition wins. Walk the
    // chain root-first; a later (more derived) definition overwrites an earlier
    // one by emitting under the same name, so emit only the resolved definition.
    var emitted: std.StringHashMapUnmanaged(void) = .empty;
    var d: usize = chain.len;
    while (d > 0) {
        d -= 1;
        const cc = chain[d];
        for (cc.methods) |m| {
            if (m.is_static) continue;
            const key = switch (m.accessor) {
                .none => try std.fmt.allocPrint(arena, "m:{s}", .{m.name}),
                .getter => try std.fmt.allocPrint(arena, "g:{s}", .{m.name}),
                .setter => try std.fmt.allocPrint(arena, "s:{s}", .{m.name}),
            };
            if (emitted.contains(key)) continue;
            try emitted.put(arena, key, {});
            try emitClassMethod(c.name, m, decls, arena, throw_target, switch_break_target, options);
        }
    }

    // `super.method` copies: for each super call in the class's methods/ctor,
    // emit a copy of the resolved ancestor method as `__super_<owner>_<name>`.
    var super_emitted: std.StringHashMapUnmanaged(void) = .empty;
    for (c.methods) |m| try emitSuperCopies(c, m.body, decls, arena, &super_emitted, throw_target, switch_break_target, options);
    try emitSuperCopies(c, c.ctor_body, decls, arena, &super_emitted, throw_target, switch_break_target, options);

    // `super(...)` parent-constructor helpers: emit `__superctor_<owner>` for
    // each ancestor that has a constructor, bound to the most-derived struct so
    // its parameters live in their own scope (no shadowing of the child ctor).
    for (chain) |cc| {
        if (std.mem.eql(u8, cc.name, c.name)) continue; // not the class itself
        if (!cc.has_ctor) continue;
        try decls.print(arena, "    fn __superctor_{s}(self: *{s}", .{ cc.name, c.name });
        for (cc.ctor_params) |param| {
            try decls.print(arena, ", {s}: {s}", .{ param.name, try types.zigName(arena, param.checked_type orelse return error.ParseError) });
        }
        try decls.appendSlice(arena, ") void {\n");
        if (!bodyUsesThis(cc.ctor_body)) try decls.appendSlice(arena, "    _ = self;\n");
        try emitUnusedParamDiscards(cc.ctor_params, cc.ctor_body, decls, arena);
        for (cc.ctor_body) |*body_stmt| try emitStmtWithThrow(body_stmt, decls, decls, arena, throw_target, switch_break_target, options);
        try decls.appendSlice(arena, "    }\n");
    }

    // Static methods -> struct-scoped free functions `__static_m_<name>`,
    // declared only on their owning class and called as `Owner.__static_m_x`.
    {
        const cc = c;
        for (cc.methods) |m| {
            if (!m.is_static) continue;
            try decls.print(arena, "    fn __static_m_{s}(", .{m.name});
            for (m.params, 0..) |param, i| {
                if (i > 0) try decls.appendSlice(arena, ", ");
                try decls.print(arena, "{s}: {s}", .{ param.name, try types.zigName(arena, param.checked_type orelse return error.ParseError) });
            }
            try decls.print(arena, ") {s} {{\n", .{try types.zigName(arena, m.checked_return_type orelse return error.ParseError)});
            try emitUnusedParamDiscards(m.params, m.body, decls, arena);
            for (m.body) |*body_stmt| try emitStmtWithThrow(body_stmt, decls, decls, arena, throw_target, switch_break_target, options);
            try decls.appendSlice(arena, "    }\n");
        }
    }

    try decls.appendSlice(arena, "};\n");
}

fn emitClassMethod(self_type: []const u8, m: ast.FunctionDecl, decls: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, throw_target: ?[]const u8, switch_break_target: ?[]const u8, options: CompileOptions) CompileError!void {
    const fn_name = switch (m.accessor) {
        .none => m.name,
        .getter => try std.fmt.allocPrint(arena, "__get_{s}", .{m.name}),
        .setter => try std.fmt.allocPrint(arena, "__set_{s}", .{m.name}),
    };
    try decls.print(arena, "    fn {s}(self: *{s}", .{ fn_name, self_type });
    for (m.params) |param| {
        const pt = param.checked_type orelse return error.ParseError;
        const ztype = if (param.is_ref) try types.refZigName(arena, pt) else try types.zigName(arena, pt);
        try decls.print(arena, ", {s}: {s}", .{ param.name, ztype });
    }
    try decls.print(arena, ") {s} {{\n", .{try types.zigName(arena, m.checked_return_type orelse return error.ParseError)});
    if (!bodyUsesThis(m.body)) try decls.appendSlice(arena, "    _ = self;\n");
    try emitUnusedParamDiscards(m.params, m.body, decls, arena);
    for (m.body) |*body_stmt| try emitStmtWithThrow(body_stmt, decls, decls, arena, throw_target, switch_break_target, options);
    try decls.appendSlice(arena, "    }\n");
}

/// Emit `__super_<owner>_<name>` method copies for every `super.method` call
/// referenced inside `body`, bound to the most-derived struct `c`.
fn emitSuperCopies(c: *const ast.ClassDecl, body: []const Stmt, decls: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, seen: *std.StringHashMapUnmanaged(void), throw_target: ?[]const u8, switch_break_target: ?[]const u8, options: CompileOptions) CompileError!void {
    for (body) |*stmt| try collectSuperInStmt(c, stmt, decls, arena, seen, throw_target, switch_break_target, options);
}

fn collectSuperInStmt(c: *const ast.ClassDecl, stmt: *const Stmt, decls: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, seen: *std.StringHashMapUnmanaged(void), throw_target: ?[]const u8, switch_break_target: ?[]const u8, options: CompileOptions) CompileError!void {
    switch (stmt.*) {
        .expr_stmt => |x| try collectSuperInExpr(c, x.value, decls, arena, seen, throw_target, switch_break_target, options),
        .return_stmt => |r| if (r.value) |v| try collectSuperInExpr(c, v, decls, arena, seen, throw_target, switch_break_target, options),
        .var_decl => |v| try collectSuperInExpr(c, v.init, decls, arena, seen, throw_target, switch_break_target, options),
        .member_assign => |ma| try collectSuperInExpr(c, ma.value, decls, arena, seen, throw_target, switch_break_target, options),
        .console_log => |log| try collectSuperInExpr(c, log.value, decls, arena, seen, throw_target, switch_break_target, options),
        .if_stmt => |b| {
            try collectSuperInExpr(c, b.cond, decls, arena, seen, throw_target, switch_break_target, options);
            try emitSuperCopies(c, b.then_body, decls, arena, seen, throw_target, switch_break_target, options);
            if (b.else_body) |eb| try emitSuperCopies(c, eb, decls, arena, seen, throw_target, switch_break_target, options);
        },
        .while_stmt => |w| try emitSuperCopies(c, w.body, decls, arena, seen, throw_target, switch_break_target, options),
        .for_stmt => |f| try emitSuperCopies(c, f.body, decls, arena, seen, throw_target, switch_break_target, options),
        .for_of_stmt => |f| try emitSuperCopies(c, f.body, decls, arena, seen, throw_target, switch_break_target, options),
        else => {},
    }
}

fn collectSuperInExpr(c: *const ast.ClassDecl, e: *const Expr, decls: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, seen: *std.StringHashMapUnmanaged(void), throw_target: ?[]const u8, switch_break_target: ?[]const u8, options: CompileOptions) CompileError!void {
    switch (e.*) {
        .super_call => |sc| {
            const owner = sc.parent orelse return;
            const key = try std.fmt.allocPrint(arena, "{s}:{s}", .{ owner, sc.name });
            for (sc.args) |a| try collectSuperInExpr(c, a, decls, arena, seen, throw_target, switch_break_target, options);
            if (seen.contains(key)) return;
            try seen.put(arena, key, {});
            // Find the resolved ancestor method and emit a copy bound to `c`.
            const oc = findClass(owner) orelse return;
            for (oc.methods) |m| {
                if (m.accessor == .none and !m.is_static and std.mem.eql(u8, m.name, sc.name)) {
                    var copy = m;
                    copy.name = try std.fmt.allocPrint(arena, "__super_{s}_{s}", .{ owner, sc.name });
                    try emitClassMethod(c.name, copy, decls, arena, throw_target, switch_break_target, options);
                    return;
                }
            }
        },
        .bin => |b| {
            try collectSuperInExpr(c, b.l, decls, arena, seen, throw_target, switch_break_target, options);
            try collectSuperInExpr(c, b.r, decls, arena, seen, throw_target, switch_break_target, options);
        },
        .method_call => |mc| {
            try collectSuperInExpr(c, mc.obj, decls, arena, seen, throw_target, switch_break_target, options);
            for (mc.args) |a| try collectSuperInExpr(c, a, decls, arena, seen, throw_target, switch_break_target, options);
        },
        .call => |cl| for (cl.args) |a| try collectSuperInExpr(c, a, decls, arena, seen, throw_target, switch_break_target, options),
        .field => |f| try collectSuperInExpr(c, f.obj, decls, arena, seen, throw_target, switch_break_target, options),
        else => {},
    }
}

fn emitStmt(stmt: *const Stmt, decls: *std.ArrayListUnmanaged(u8), body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, options: CompileOptions) CompileError!void {
    return emitStmtWithThrow(stmt, decls, body, arena, null, null, options);
}

fn emitAssignExpr(assignment: ast.Assign, body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    const base = assignment.emit_name orelse assignment.name;
    // A scalar by-reference (`Ref<T>`) param assigns through its pointer.
    const name = if (assignment.deref) try std.fmt.allocPrint(arena, "{s}.*", .{base}) else base;
    try body.print(arena, "{s} = ", .{name});
    if (std.mem.eql(u8, assignment.op, "=")) {
        try emitExpr(assignment.value, body, arena);
    } else if (assignment.op[0] == '/') {
        try body.print(arena, "@divTrunc({s}, ", .{name});
        try emitExpr(assignment.value, body, arena);
        try body.append(arena, ')');
    } else if (assignment.op[0] == '%') {
        try body.print(arena, "@rem({s}, ", .{name});
        try emitExpr(assignment.value, body, arena);
        try body.append(arena, ')');
    } else {
        try body.print(arena, "({s} {c} ", .{ name, assignment.op[0] });
        try emitExpr(assignment.value, body, arena);
        try body.append(arena, ')');
    }
}

/// Whether a switch case/default body contains a `break` that targets the switch
/// itself. Descends through `if`/`try`/`defer` blocks but not into nested loops
/// or switches, whose own `break` binds to that inner construct.
fn bodyHasSwitchBreak(body: []const Stmt) bool {
    for (body) |*s| {
        switch (s.*) {
            .break_stmt => return true,
            .if_stmt => |b| {
                if (bodyHasSwitchBreak(b.then_body)) return true;
                if (b.else_body) |eb| if (bodyHasSwitchBreak(eb)) return true;
            },
            .try_stmt => |t| {
                if (bodyHasSwitchBreak(t.try_body)) return true;
                if (bodyHasSwitchBreak(t.catch_body)) return true;
                if (t.finally_body) |fb| if (bodyHasSwitchBreak(fb)) return true;
            },
            .defer_stmt => |d| if (bodyHasSwitchBreak(d.body)) return true,
            else => {},
        }
    }
    return false;
}

fn emitSwitchCaseMatch(switch_type: types.Type, switch_value: *const Expr, case_value: *const Expr, body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    if (types.isStringLike(switch_type)) {
        try body.appendSlice(arena, "std.mem.eql(u8, ");
        try emitExpr(switch_value, body, arena);
        try body.appendSlice(arena, ", ");
        try emitExpr(case_value, body, arena);
        try body.append(arena, ')');
    } else {
        try body.append(arena, '(');
        try emitExpr(switch_value, body, arena);
        try body.appendSlice(arena, " == ");
        try emitExpr(case_value, body, arena);
        try body.append(arena, ')');
    }
}

fn emitStmtWithThrow(stmt: *const Stmt, decls: *std.ArrayListUnmanaged(u8), body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, throw_target: ?[]const u8, switch_break_target: ?[]const u8, options: CompileOptions) CompileError!void {
    if (options.runtime_locations) {
        const line_col: SourceLoc = switch (stmt.*) {
            .type_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .enum_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .extern_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .class_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .member_assign => |ma| .{ .line = ma.line, .col = ma.col },
            .super_ctor => |sc| .{ .line = sc.line, .col = sc.col },
            .test_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .function_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .var_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .using_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .destructure_decl => |d| .{ .line = d.line, .col = d.col },
            .assign => |assignment| .{ .line = assignment.line, .col = assignment.col },
            .console_log => |log| .{ .line = log.line, .col = log.col },
            .while_stmt => |loop| .{ .line = loop.line, .col = loop.col },
            .do_while_stmt => |loop| .{ .line = loop.line, .col = loop.col },
            .for_stmt => |loop| .{ .line = loop.line, .col = loop.col },
            .for_of_stmt => |loop| .{ .line = loop.line, .col = loop.col },
            .if_stmt => |branch| .{ .line = branch.line, .col = branch.col },
            .switch_stmt => |switch_stmt| .{ .line = switch_stmt.line, .col = switch_stmt.col },
            .return_stmt => |ret| .{ .line = ret.line, .col = ret.col },
            .throw_stmt => |throw_stmt| .{ .line = throw_stmt.line, .col = throw_stmt.col },
            .try_stmt => |try_stmt| .{ .line = try_stmt.line, .col = try_stmt.col },
            .break_stmt => |control| .{ .line = control.line, .col = control.col },
            .continue_stmt => |control| .{ .line = control.line, .col = control.col },
            .defer_stmt => |d| .{ .line = d.line, .col = d.col },
            .expr_stmt => |expr_stmt| .{ .line = expr_stmt.line, .col = expr_stmt.col },
        };
        try body.print(arena, "    __lumen_line = {d}; __lumen_col = {d};\n", .{ line_col.line, line_col.col });
    }

    switch (stmt.*) {
        .type_decl => |decl| {
            if (decl.string_literals != null) return;
            if (decl.int_literals != null) return;
            if (decl.alias != null) return; // aliases are erased: resolve to target
            if (decl.union_variants != null) {
                // A discriminated union lowers to a flat struct holding the union
                // of every variant's fields, each with a default so a single
                // variant's object literal initializes cleanly.
                try decls.print(arena, "const {s} = struct {{\n", .{decl.name});
                for (decl.fields) |field| {
                    const field_type = field.checked_type orelse return error.ParseError;
                    const zty = try types.zigName(arena, field_type);
                    try decls.print(arena, "    {s}: {s} = {s},\n", .{ field.name, zty, try zigZeroValue(arena, field_type) });
                }
                try decls.appendSlice(arena, "};\n");
                return;
            }
            if (decl.type_params.len > 0) return; // generic template: only specializations emit
            try decls.print(arena, "const {s} = struct {{\n", .{decl.name});
            for (decl.fields) |field| {
                const field_type = field.checked_type orelse return error.ParseError;
                try decls.print(arena, "    {s}: {s},\n", .{ field.name, try types.zigName(arena, field_type) });
            }
            try decls.appendSlice(arena, "};\n");
        },
        .enum_decl => {}, // members are inlined as constants at each use site
        .extern_decl => |decl| {
            // extern fn name(p0: T, ...) Ret;  -- resolved at link time.
            // A `string` parameter/return crosses the C ABI as a NUL-terminated
            // `const char*`, i.e. Zig `[*:0]const u8`; the call site marshals
            // between that and the Lumen `[]const u8` string.
            try decls.print(arena, "extern fn {s}(", .{decl.name});
            for (decl.params, 0..) |param, i| {
                if (i > 0) try decls.appendSlice(arena, ", ");
                try decls.print(arena, "{s}: {s}", .{ param.name, externZigName(param.checked_type orelse return error.ParseError, arena) });
            }
            try decls.print(arena, ") {s};\n", .{externZigName(decl.checked_return_type orelse return error.ParseError, arena)});
        },
        .class_decl => |*c| {
            if (c.type_params.len > 0) return; // generic template: only specializations emit
            try emitClass(c, decls, arena, throw_target, switch_break_target, options);
        },
        .super_ctor => |sc| {
            // super(args) -> self.__superctor_<Parent>(args);
            const parent = sc.parent orelse return;
            try body.print(arena, "    self.__superctor_{s}(", .{parent});
            for (sc.args, 0..) |arg, i| {
                if (i > 0) try body.appendSlice(arena, ", ");
                try emitExpr(arg, body, arena);
            }
            try body.appendSlice(arena, ");\n");
        },
        .member_assign => |ma| {
            // Resolve the receiver expression: `self.` (this), `Class.` (static),
            // a setter call, or `obj.` (external instance field).
            if (ma.is_setter) {
                // obj.prop = value  ->  obj.__set_prop(value);
                try body.appendSlice(arena, "    ");
                try emitExpr(ma.obj.?, body, arena);
                try body.print(arena, ".__set_{s}(", .{ma.field});
                try emitExpr(ma.value, body, arena);
                try body.appendSlice(arena, ");\n");
                return;
            }
            // Build the lvalue prefix string.
            var lv: std.ArrayListUnmanaged(u8) = .empty;
            if (ma.is_static) {
                const owner = ma.class_name orelse "";
                try lv.print(arena, "{s}.__static_{s}_{s}", .{ owner, owner, ma.field });
            } else if (ma.obj) |obj| {
                try emitExpr(obj, &lv, arena);
                try lv.print(arena, ".{s}", .{ma.field});
            } else {
                try lv.print(arena, "self.{s}", .{ma.field});
            }
            const lvs = lv.items;
            try body.print(arena, "    {s} = ", .{lvs});
            if (std.mem.eql(u8, ma.op, "=")) {
                try emitExpr(ma.value, body, arena);
            } else if (ma.op[0] == '/') {
                try body.print(arena, "@divTrunc({s}, ", .{lvs});
                try emitExpr(ma.value, body, arena);
                try body.append(arena, ')');
            } else if (ma.op[0] == '%') {
                try body.print(arena, "@rem({s}, ", .{lvs});
                try emitExpr(ma.value, body, arena);
                try body.append(arena, ')');
            } else {
                try body.print(arena, "({s} {c} ", .{ lvs, ma.op[0] });
                try emitExpr(ma.value, body, arena);
                try body.append(arena, ')');
            }
            try body.appendSlice(arena, ";\n");
        },
        .test_decl => |t| {
            // Emit a Zig `test "name" { ... }` block into the top-level decls.
            try decls.appendSlice(arena, "test \"");
            for (t.name) |ch| {
                if (ch == '"' or ch == '\\') try decls.append(arena, '\\');
                try decls.append(arena, ch);
            }
            try decls.appendSlice(arena, "\" {\n");
            for (t.body) |*test_stmt| try emitStmtWithThrow(test_stmt, decls, decls, arena, throw_target, switch_break_target, options);
            try decls.appendSlice(arena, "}\n");
        },
        .function_decl => |decl| {
            if (decl.type_params.len > 0) return; // generic template: only specializations emit
            const return_type = decl.checked_return_type orelse types.fromAnnotation(decl.return_annotation);
            try decls.print(arena, "fn {s}(", .{decl.name});
            for (decl.params, 0..) |param, i| {
                if (i > 0) try decls.appendSlice(arena, ", ");
                const param_type = param.checked_type orelse types.fromAnnotation(param.annotation);
                const ztype = if (param.is_ref) try types.refZigName(arena, param_type) else try types.zigName(arena, param_type);
                try decls.print(arena, "{s}: {s}", .{ param.name, ztype });
            }
            // An async function returns its declared `*LumenPromise(T)`; `return v`
            // statements in the body resolve the promise with `v`.
            try decls.print(arena, ") {s} {{\n", .{try types.zigName(arena, return_type)});
            const prev_async_inner = g_async_inner;
            if (decl.is_async and return_type == .promise_type) {
                g_async_inner = try types.zigName(arena, return_type.promise_type.*);
            } else {
                g_async_inner = null;
            }
            defer g_async_inner = prev_async_inner;
            try emitUnusedParamDiscards(decl.params, decl.body, decls, arena);
            for (decl.body) |*body_stmt| try emitStmt(body_stmt, decls, decls, arena, options);
            // An async `Promise<void>` body may legally fall through without a
            // `return`; emit a trailing resolved promise so the Promise-returning
            // function still returns a value. Skip it when the body already
            // returns on every path (the trailing return would be dead code).
            if (decl.is_async and return_type == .promise_type and return_type.promise_type.* == .void and !bodyAlwaysReturns(decl.body)) {
                try decls.appendSlice(arena, "    return __promiseResolved(void, {});\n");
            }
            try decls.appendSlice(arena, "}\n");
        },
        .var_decl => |decl| {
            const final_zty = decl.checked_type orelse return error.ParseError;
            try body.print(arena, "    {s} {s}: {s} = ", .{ if (decl.mutable and decl.reassigned) "var" else "const", decl.emit_name orelse decl.name, try types.zigName(arena, final_zty) });
            try emitExpr(decl.init, body, arena);
            try body.appendSlice(arena, ";\n");
        },
        .using_decl => |decl| {
            // `using` lowers to Zig `defer`, which already runs LIFO at scope
            // exit and interleaves correctly with `defer`-statement blocks.
            if (decl.defer_body) |defer_body| {
                // `using x = defer(() => BODY);` — run BODY at scope exit.
                try body.appendSlice(arena, "    defer {\n");
                for (defer_body) |*defer_stmt| try emitStmtWithThrow(defer_stmt, decls, body, arena, throw_target, switch_break_target, options);
                try body.appendSlice(arena, "    }\n");
            } else {
                // `using r = EXPR;` — bind the value, then `defer r.dispose();`.
                const final_zty = decl.checked_type orelse return error.ParseError;
                try body.print(arena, "    const {s}: {s} = ", .{ decl.emit_name orelse decl.name, try types.zigName(arena, final_zty) });
                try emitExpr(decl.init, body, arena);
                try body.appendSlice(arena, ";\n");
                const dispose = decl.dispose_call orelse return error.ParseError;
                try body.appendSlice(arena, "    defer {\n        _ = ");
                try emitExpr(dispose, body, arena);
                try body.appendSlice(arena, ";\n    }\n");
            }
        },
        .destructure_decl => |d| {
            // Bind a temp to the source, then one const per element/field. No
            // wrapping block, so the bindings remain in the enclosing scope.
            const src = try std.fmt.allocPrint(arena, "__lumen_ds_{d}_{d}", .{ d.line, d.col });
            try body.print(arena, "    const {s} = ", .{src});
            try emitExpr(d.source, body, arena);
            try body.appendSlice(arena, ";\n");
            for (d.bindings, 0..) |b, i| {
                const bty = b.checked_type orelse return error.ParseError;
                try body.print(arena, "    const {s}: {s} = ", .{ b.emit_name orelse b.name, try types.zigName(arena, bty) });
                if (d.is_object) {
                    try body.print(arena, "{s}.{s};\n", .{ src, b.name });
                } else {
                    try body.print(arena, "{s}[{d}];\n", .{ src, i });
                }
            }
        },
        .assign => |assignment| {
            try body.appendSlice(arena, "    ");
            try emitAssignExpr(assignment, body, arena);
            try body.appendSlice(arena, ";\n");
        },
        .console_log => |log| {
            const log_type = log.checked_type orelse return error.ParseError;
            try body.print(arena, "    std.debug.print(\"{s}\\n\", .{{", .{printFormat(log_type)});
            try emitExpr(log.value, body, arena);
            try body.appendSlice(arena, "});\n");
        },
        .while_stmt => |loop| {
            try body.appendSlice(arena, "    while (");
            try emitExpr(loop.cond, body, arena);
            try body.appendSlice(arena, ") {\n");
            for (loop.body) |*body_stmt| try emitStmtWithThrow(body_stmt, decls, body, arena, throw_target, null, options);
            try body.appendSlice(arena, "    }\n");
        },
        .do_while_stmt => |loop| {
            try body.appendSlice(arena, "    while (true) : ({ if (!(");
            try emitExpr(loop.cond, body, arena);
            try body.appendSlice(arena, ")) break; }) {\n");
            for (loop.body) |*body_stmt| try emitStmtWithThrow(body_stmt, decls, body, arena, throw_target, null, options);
            try body.appendSlice(arena, "    }\n");
        },
        .for_stmt => |loop| {
            try body.appendSlice(arena, "    {\n");
            var init_stmt: Stmt = .{ .var_decl = loop.init };
            try emitStmtWithThrow(&init_stmt, decls, body, arena, throw_target, switch_break_target, options);
            try body.appendSlice(arena, "    while (");
            try emitExpr(loop.cond, body, arena);
            try body.appendSlice(arena, ") : (");
            try emitAssignExpr(loop.update, body, arena);
            try body.appendSlice(arena, ") {\n");
            for (loop.body) |*body_stmt| try emitStmtWithThrow(body_stmt, decls, body, arena, throw_target, null, options);
            try body.appendSlice(arena, "    }\n");
            try body.appendSlice(arena, "    }\n");
        },
        .for_of_stmt => |loop| {
            const iter_ty = loop.iter_type orelse return error.ParseError;
            const elem_ty = loop.elem_type orelse return error.ParseError;
            const seq = try std.fmt.allocPrint(arena, "__lumen_of_seq_{d}_{d}", .{ loop.line, loop.col });
            const idx = try std.fmt.allocPrint(arena, "__lumen_of_idx_{d}_{d}", .{ loop.line, loop.col });
            const binding = loop.binding_emit_name orelse loop.binding;
            const elem_zig = try types.zigName(arena, elem_ty);
            try body.appendSlice(arena, "    {\n");
            try body.print(arena, "    const {s} = ", .{seq});
            try emitExpr(loop.iterable, body, arena);
            try body.appendSlice(arena, ";\n");
            try body.print(arena, "    var {s}: usize = 0;\n", .{idx});
            try body.print(arena, "    while ({s} < {s}.len) : ({s} += 1) {{\n", .{ idx, seq, idx });
            // String iteration yields single-character substrings ([]const u8);
            // array iteration yields the element directly.
            if (types.isStringLike(iter_ty)) {
                try body.print(arena, "    const {s}: {s} = {s}[{s} .. {s} + 1];\n", .{ binding, elem_zig, seq, idx, idx });
            } else {
                try body.print(arena, "    const {s}: {s} = {s}[{s}];\n", .{ binding, elem_zig, seq, idx });
            }
            for (loop.body) |*body_stmt| try emitStmtWithThrow(body_stmt, decls, body, arena, throw_target, null, options);
            try body.appendSlice(arena, "    }\n");
            try body.appendSlice(arena, "    }\n");
        },
        .if_stmt => |branch| {
            try body.appendSlice(arena, "    if (");
            try emitExpr(branch.cond, body, arena);
            try body.appendSlice(arena, ") {\n");
            for (branch.then_body) |*body_stmt| try emitStmtWithThrow(body_stmt, decls, body, arena, throw_target, switch_break_target, options);
            try body.appendSlice(arena, "    }");
            if (branch.else_body) |else_body| {
                try body.appendSlice(arena, " else {\n");
                for (else_body) |*body_stmt| try emitStmtWithThrow(body_stmt, decls, body, arena, throw_target, switch_break_target, options);
                try body.appendSlice(arena, "    }");
            }
            try body.appendSlice(arena, "\n");
        },
        .switch_stmt => |switch_stmt| {
            const switch_type = switch_stmt.checked_type orelse return error.ParseError;
            // The break-target label is only emitted when a case actually breaks;
            // a switch whose cases all `return` (e.g. discriminated-union
            // dispatch) needs no label, which Zig would reject as unused.
            var needs_label = false;
            for (switch_stmt.cases) |case| {
                if (bodyHasSwitchBreak(case.body)) needs_label = true;
            }
            if (switch_stmt.default_body) |db| {
                if (bodyHasSwitchBreak(db)) needs_label = true;
            }
            const label = try std.fmt.allocPrint(arena, "__lumen_switch_{d}_{d}", .{ switch_stmt.line, switch_stmt.col });
            const label_target: ?[]const u8 = if (needs_label) label else null;
            if (needs_label) try body.print(arena, "    {s}: {{\n", .{label}) else try body.appendSlice(arena, "    {\n");
            for (switch_stmt.cases, 0..) |case, i| {
                try body.appendSlice(arena, if (i == 0) "    if (" else "    else if (");
                try emitSwitchCaseMatch(switch_type, switch_stmt.value, case.value, body, arena);
                try body.appendSlice(arena, ") {\n");
                for (case.body) |*case_stmt| try emitStmtWithThrow(case_stmt, decls, body, arena, throw_target, label_target, options);
                try body.appendSlice(arena, "    }\n");
            }
            if (switch_stmt.default_body) |default_body| {
                try body.appendSlice(arena, if (switch_stmt.cases.len == 0) "    {\n" else "    else {\n");
                for (default_body) |*default_stmt| try emitStmtWithThrow(default_stmt, decls, body, arena, throw_target, label_target, options);
                try body.appendSlice(arena, "    }\n");
            }
            try body.appendSlice(arena, "    }\n");
        },
        .return_stmt => |ret| {
            if (ret.value) |value| {
                if (g_async_inner) |inner_zig| {
                    // Inside an async body: resolve the promise with the value.
                    try body.print(arena, "    return __promiseResolved({s}, ", .{inner_zig});
                    try emitExpr(value, body, arena);
                    try body.appendSlice(arena, ");\n");
                } else {
                    try body.appendSlice(arena, "    return ");
                    try emitExpr(value, body, arena);
                    try body.appendSlice(arena, ";\n");
                }
            } else if (g_async_inner) |inner_zig| {
                // `return;` in an async `Promise<void>` body resolves with void {}.
                try body.print(arena, "    return __promiseResolved({s}, {{}});\n", .{inner_zig});
            } else {
                try body.appendSlice(arena, "    return;\n");
            }
        },
        .throw_stmt => |throw_stmt| {
            if (throw_target) |target| {
                // Set the enclosing try's slot, then break out of its labeled
                // try block so the remaining try statements are skipped.
                const label = try std.mem.replaceOwned(u8, arena, target, "__lumen_throw_", "__lumen_try_");
                try body.print(arena, "    {s} = ", .{target});
                try emitExpr(throw_stmt.value, body, arena);
                try body.print(arena, ";\n    break :{s};\n", .{label});
            } else {
                try body.appendSlice(arena, "    @panic(");
                try emitExpr(throw_stmt.value, body, arena);
                try body.appendSlice(arena, ");\n");
            }
        },
        .try_stmt => |try_stmt| {
            const slot = try std.fmt.allocPrint(arena, "__lumen_throw_{d}_{d}", .{ try_stmt.line, try_stmt.col });
            const label = try std.fmt.allocPrint(arena, "__lumen_try_{d}_{d}", .{ try_stmt.line, try_stmt.col });
            const can_throw = bodyCanThrow(try_stmt.try_body);
            const slot_kw = if (can_throw) "var" else "const";
            try body.print(arena, "    {s} {s}: ?[]const u8 = null;\n", .{ slot_kw, slot });
            // Wrap the whole try/catch in an outer block. `finally` lowers to a
            // `defer` at the top of that block, so it always runs on every exit
            // — normal fallthrough, a caught throw, or a rethrow that breaks out
            // to an enclosing try (the defer unwinds before the break leaves).
            try body.appendSlice(arena, "    {\n");
            if (try_stmt.finally_body) |finally_body| {
                try body.appendSlice(arena, "    defer {\n");
                for (finally_body) |*finally_stmt| try emitStmtWithThrow(finally_stmt, decls, body, arena, throw_target, switch_break_target, options);
                try body.appendSlice(arena, "    }\n");
            }
            // The try body runs in a single block so its locals share one scope.
            // When it can throw, the block is labeled so a `throw` can set the
            // slot and break out, skipping the remaining try statements.
            if (can_throw) {
                try body.print(arena, "    {s}: {{\n", .{label});
            } else {
                try body.appendSlice(arena, "    {\n");
            }
            for (try_stmt.try_body) |*try_body_stmt| {
                try emitStmtWithThrow(try_body_stmt, decls, body, arena, slot, switch_break_target, options);
                // A `throw` lowers to a `break`; later siblings are dead code.
                if (stmtAlwaysThrows(try_body_stmt)) break;
            }
            try body.appendSlice(arena, "    }\n");
            const catch_emit = try_stmt.catch_emit_name orelse try_stmt.catch_name;
            try body.print(arena, "    if ({s}) |{s}| {{\n", .{ slot, catch_emit });
            // Zig rejects an unused capture, so discard the binding when the
            // catch body never reads it.
            if (!bodyUsesName(try_stmt.catch_body, try_stmt.catch_name)) {
                try body.print(arena, "    _ = {s};\n", .{catch_emit});
            }
            for (try_stmt.catch_body) |*catch_stmt| {
                try emitStmtWithThrow(catch_stmt, decls, body, arena, throw_target, switch_break_target, options);
                // A rethrow lowers to a `break`; later siblings are dead code.
                // Only meaningful when an enclosing try provides a throw target.
                if (throw_target != null and stmtAlwaysThrows(catch_stmt)) break;
            }
            try body.appendSlice(arena, "    }\n");
            try body.appendSlice(arena, "    }\n");
        },
        .defer_stmt => |d| {
            try body.appendSlice(arena, "    defer {\n");
            for (d.body) |*defer_stmt| try emitStmtWithThrow(defer_stmt, decls, body, arena, throw_target, switch_break_target, options);
            try body.appendSlice(arena, "    }\n");
        },
        .break_stmt => {
            if (switch_break_target) |target| {
                try body.print(arena, "    break :{s};\n", .{target});
            } else {
                try body.appendSlice(arena, "    break;\n");
            }
        },
        .continue_stmt => {
            try body.appendSlice(arena, "    continue;\n");
        },
        .expr_stmt => |expr_stmt| {
            const is_serve = expr_stmt.value.* == .call and std.mem.eql(u8, expr_stmt.value.call.name, "serve");
            try body.appendSlice(arena, if (is_serve) "    " else "    _ = ");
            try emitExpr(expr_stmt.value, body, arena);
            try body.appendSlice(arena, ";\n");
        },
    }
}

/// Set during emission so the class lowering can walk the inheritance chain
/// (the checker's class registry is not available at emit time). Single-threaded.
var g_program: ?*const Program = null;

// The Zig spelling of an async function's resolved value type while emitting its
// body, so a `return v;` lowers to `return __promiseResolved(<T>, v);`. Null
// outside an async body (and for plain functions).
var g_async_inner: ?[]const u8 = null;

fn findClass(name: []const u8) ?*const ast.ClassDecl {
    const prog = g_program orelse return null;
    for (prog.stmts) |*stmt| {
        if (stmt.* == .class_decl and std.mem.eql(u8, stmt.class_decl.name, name)) return &stmt.class_decl;
    }
    return null;
}

fn emitProgram(program: *const Program, decls: *std.ArrayListUnmanaged(u8), body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, options: CompileOptions) CompileError!void {
    g_program = program;
    for (program.stmts) |*stmt| try emitStmt(stmt, decls, body, arena, options);
}

/// Compile TypeScript-syntax `source` (from `filename`) to Zig source text. On a compile-time error,
/// `diag` is filled (located in the .ts source) and `error.ParseError` returned. `filename` is also
/// embedded so a runtime panic reports the .ts location.
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
    // Async programs run their event loop on libuv. The CLI auto-injects libuv's
    // include/link flags into the native build whenever a program uses async, so
    // this C import resolves without any user configuration.
    if (program.needs_async) {
        try out.appendSlice(arena, "const uv = @cImport(@cInclude(\"uv.h\"));\n");
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
            \\            const p = std.heap.page_allocator.create(Self) catch unreachable;
            \\            p.* = .{};
            \\            return p;
            \\        }
            \\        fn __find(self: *Self, key: K) ?usize {
            \\            for (self.keys_.items, 0..) |k, i| { if (__lumenEql(K, k, key)) return i; }
            \\            return null;
            \\        }
            \\        fn set(self: *Self, key: K, value: V) void {
            \\            if (self.__find(key)) |i| { self.values_.items[i] = value; return; }
            \\            self.keys_.append(std.heap.page_allocator, key) catch unreachable;
            \\            self.values_.append(std.heap.page_allocator, value) catch unreachable;
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
            \\            const p = std.heap.page_allocator.create(Self) catch unreachable;
            \\            p.* = .{};
            \\            return p;
            \\        }
            \\        fn __find(self: *Self, value: T) ?usize {
            \\            for (self.items_.items, 0..) |v, i| { if (__lumenEql(T, v, value)) return i; }
            \\            return null;
            \\        }
            \\        fn add(self: *Self, value: T) void {
            \\            if (self.__find(value) != null) return;
            \\            self.items_.append(std.heap.page_allocator, value) catch unreachable;
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
        // The event loop is libuv. `setTimeout` schedules a `uv_timer_t`; `await`
        // drives the loop one event at a time (`uv_run(..., UV_RUN_ONCE)`) until
        // the awaited promise resolves, then reads its value; the program ends by
        // draining remaining work with `uv_run(..., UV_RUN_DEFAULT)`. This is
        // sound for the supported subset (already-resolved and timer-resolved
        // promises) and keeps timer ordering deterministic, because libuv fires
        // equal-deadline timers in start order.
        try out.appendSlice(arena,
            \\var __uv_loop: *uv.uv_loop_t = undefined;
            \\const LumenLoop = struct {
            \\    fn init() void { __uv_loop = uv.uv_default_loop().?; }
            \\    fn driveUntil(ctx: *const anyopaque, done: *const fn (*const anyopaque) bool) void {
            \\        while (!done(ctx)) {
            \\            if (uv.uv_run(__uv_loop, uv.UV_RUN_ONCE) == 0) break;
            \\        }
            \\    }
            \\    fn drain() void { _ = uv.uv_run(__uv_loop, uv.UV_RUN_DEFAULT); }
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
            \\        timer: uv.uv_timer_t,
            \\        fn onTimer(t: [*c]uv.uv_timer_t) callconv(.c) void {
            \\            const h: *@This() = @fieldParentPtr("timer", @as(*uv.uv_timer_t, @ptrCast(t)));
            \\            h.f.call(h.f.ctx);
            \\            _ = uv.uv_timer_stop(t);
            \\            uv.uv_close(@ptrCast(t), null);
            \\        }
            \\    };
            \\    const h = __alloc.create(Holder) catch unreachable;
            \\    h.* = .{ .f = cb, .timer = undefined };
            \\    _ = uv.uv_timer_init(__uv_loop, &h.timer);
            \\    const delay: u64 = if (ms > 0) @intCast(ms) else 0;
            \\    _ = uv.uv_timer_start(&h.timer, Holder.onTimer, delay, 0);
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
