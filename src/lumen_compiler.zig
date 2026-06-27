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
                if (prev_was_dot) {
                    pending_dynamic_write_line = lex.tok_line;
                    pending_dynamic_write_col = lex.tok_col;
                }
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
    fn node(self: *Parser, e: Expr) CompileError!*Expr {
        const p = try self.arena.create(Expr);
        p.* = e;
        return p;
    }
    fn isStdNamespace(name: []const u8) bool {
        return std.mem.eql(u8, name, "Math") or std.mem.eql(u8, name, "String") or std.mem.eql(u8, name, "Array") or std.mem.eql(u8, name, "fs");
    }
    fn parseTypeMember(self: *Parser) CompileError![]const u8 {
        if (self.cur != .ident) return error.ParseError;
        const base = self.cur.ident;
        try self.advance();
        if (self.isOp('[')) {
            try self.advance();
            try self.expectOp(']');
            return std.fmt.allocPrint(self.arena, "{s}[]", .{base}) catch error.OutOfMemory;
        }
        return base;
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

    fn parseTypeAnnotation(self: *Parser) CompileError![]const u8 {
        const eq = std.mem.eql;
        if (self.isOp('(')) return self.parseFunctionType();
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
        return self.parsePostfix();
    }
    fn parsePostfix(self: *Parser) CompileError!*Expr {
        var e = try self.parsePrimary();
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
                    if (e.* != .var_ref or !isStdNamespace(e.var_ref.name)) return error.ParseError;
                    const namespace = e.var_ref.name;
                    try self.expectOp('(');
                    var args: std.ArrayListUnmanaged(*Expr) = .empty;
                    while (!self.isOp(')')) {
                        try args.append(self.arena, try self.parseExpr());
                        if (self.isOp(',')) try self.advance() else break;
                    }
                    try self.expectOp(')');
                    e = try self.node(.{ .static_call = .{ .namespace = namespace, .name = name, .args = try args.toOwnedSlice(self.arena) } });
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
            if (self.isOp('(')) {
                try self.expectOp('(');
                var args: std.ArrayListUnmanaged(*Expr) = .empty;
                while (!self.isOp(')')) {
                    try args.append(self.arena, try self.parseExpr());
                    if (self.isOp(',')) try self.advance() else break;
                }
                try self.expectOp(')');
                return self.node(.{ .call = .{ .name = name, .args = try args.toOwnedSlice(self.arena) } });
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
                try items.append(self.arena, try self.parseExpr());
                if (self.isOp(',')) try self.advance() else break;
            }
            try self.expectOp(']');
            return self.node(.{ .array = try items.toOwnedSlice(self.arena) });
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
        try self.expectOp('{');
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

    /// `interface Name { field: T; field2: U }` — a synonym for an object `type`.
    /// Accepts `;` or `,` (or newline) between members.
    fn parseInterfaceDecl(self: *Parser, line: u32, col: u32) CompileError!Stmt {
        try self.advance(); // 'interface'
        if (self.cur != .ident) return error.ParseError;
        const tname = self.cur.ident;
        try self.advance();
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
        return .{ .type_decl = .{ .name = tname, .fields = try fields.toOwnedSlice(self.arena), .line = line, .col = col } };
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

    fn parseFunctionDecl(self: *Parser, line: u32, col: u32) CompileError!Stmt {
        try self.advance();
        if (self.cur != .ident) return error.ParseError;
        const name = self.cur.ident;
        try self.advance();
        try self.expectOp('(');
        var params: std.ArrayListUnmanaged(ast.FunctionParam) = .empty;
        while (!self.isOp(')')) {
            if (self.cur != .ident) return error.ParseError;
            const param_name = self.cur.ident;
            try self.advance();
            const annotation = try self.parseOptionalMember();
            try params.append(self.arena, .{ .name = param_name, .annotation = annotation });
            if (self.isOp(',')) try self.advance() else break;
        }
        try self.expectOp(')');
        try self.expectOp(':');
        const return_annotation = try self.parseTypeAnnotation();
        const body = try self.parseBlock();
        return .{ .function_decl = .{
            .name = name,
            .params = try params.toOwnedSlice(self.arena),
            .return_annotation = return_annotation,
            .body = body,
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

        if (eq(u8, kw, "type")) return self.parseTypeDecl(line, col);
        if (eq(u8, kw, "interface")) return self.parseInterfaceDecl(line, col);
        if (eq(u8, kw, "enum")) return self.parseEnumDecl(line, col);
        if (eq(u8, kw, "function")) return self.parseFunctionDecl(line, col);
        if (eq(u8, kw, "switch")) return self.parseSwitch(line, col);
        if (eq(u8, kw, "class")) {
            self.last_err = "E_UNSUPPORTED_CLASS";
            return error.ParseError;
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
                try args.append(self.arena, try self.parseExpr());
                if (self.isOp(',')) try self.advance() else break;
            }
            try self.expectOp(')');
            try self.expectOp(';');
            const value = try self.node(.{ .call = .{ .name = name, .args = try args.toOwnedSlice(self.arena) } });
            return .{ .expr_stmt = .{ .value = value, .line = line, .col = col } };
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
        .array => |items| {
            try w.appendSlice(arena, "&.{ ");
            for (items, 0..) |item, i| {
                if (i > 0) try w.appendSlice(arena, ", ");
                try emitExpr(item, w, arena);
            }
            try w.appendSlice(arena, " }");
        },
        .call => |cl| {
            // builtins lower to a Zig std wrapper taking (__io, __alloc, args...).
            if (std.mem.eql(u8, cl.name, "Error")) {
                if (cl.args.len > 0) try emitExpr(cl.args[0], w, arena);
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
            } else {
                try w.print(arena, "{s}(", .{cl.emit_name orelse cl.name});
                for (cl.args, 0..) |arg, i| {
                    if (i > 0) try w.appendSlice(arena, ", ");
                    try emitExpr(arg, w, arena);
                }
                try w.append(arena, ')');
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
            } else return error.ParseError;
        },
        .var_ref => |ref| {
            if (ref.is_func_ref) try w.append(arena, '&'); // top-level function used as a value
            try w.appendSlice(arena, ref.emit_name orelse ref.name);
            if (ref.unwrap) try w.appendSlice(arena, ".?"); // narrowed optional access
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
        .arrow => |arrow| {
            // (x: T) => e  ->  &(struct { fn f(x: T) R { _ = x; return e; } }.f)
            const ret = arrow.checked_return_type orelse return error.ParseError;
            try w.appendSlice(arena, "&(struct { fn __arrow(");
            for (arrow.params, 0..) |p, i| {
                if (i > 0) try w.appendSlice(arena, ", ");
                try w.print(arena, "{s}: {s}", .{ p.name, try types.zigName(arena, p.checked_type orelse return error.ParseError) });
            }
            try w.print(arena, ") {s} {{ return ", .{try types.zigName(arena, ret)});
            try emitExpr(arrow.body_expr, w, arena);
            try w.appendSlice(arena, "; } }.__arrow)");
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
            } else if (fa.builtin == .error_message) {
                try emitExpr(fa.obj, w, arena);
            } else {
                try emitExpr(fa.obj, w, arena);
                try w.print(arena, ".{s}", .{fa.name});
            }
        },
        .index => |idx| {
            try emitExpr(idx.obj, w, arena);
            try w.appendSlice(arena, "[@as(usize, @intCast(");
            try emitExpr(idx.value, w, arena);
            try w.appendSlice(arena, "))]");
        },
    }
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

fn emitStmt(stmt: *const Stmt, decls: *std.ArrayListUnmanaged(u8), body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, options: CompileOptions) CompileError!void {
    return emitStmtWithThrow(stmt, decls, body, arena, null, null, options);
}

fn emitAssignExpr(assignment: ast.Assign, body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    const name = assignment.emit_name orelse assignment.name;
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
            .function_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .var_decl => |decl| .{ .line = decl.line, .col = decl.col },
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
            try decls.print(arena, "const {s} = struct {{\n", .{decl.name});
            for (decl.fields) |field| {
                const field_type = field.checked_type orelse return error.ParseError;
                try decls.print(arena, "    {s}: {s},\n", .{ field.name, try types.zigName(arena, field_type) });
            }
            try decls.appendSlice(arena, "};\n");
        },
        .enum_decl => {}, // members are inlined as constants at each use site
        .function_decl => |decl| {
            const return_type = decl.checked_return_type orelse types.fromAnnotation(decl.return_annotation);
            try decls.print(arena, "fn {s}(", .{decl.name});
            for (decl.params, 0..) |param, i| {
                if (i > 0) try decls.appendSlice(arena, ", ");
                const param_type = param.checked_type orelse types.fromAnnotation(param.annotation);
                try decls.print(arena, "{s}: {s}", .{ param.name, try types.zigName(arena, param_type) });
            }
            try decls.print(arena, ") {s} {{\n", .{try types.zigName(arena, return_type)});
            for (decl.body) |*body_stmt| try emitStmt(body_stmt, decls, decls, arena, options);
            try decls.appendSlice(arena, "}\n");
        },
        .var_decl => |decl| {
            const final_zty = decl.checked_type orelse return error.ParseError;
            try body.print(arena, "    {s} {s}: {s} = ", .{ if (decl.mutable and decl.reassigned) "var" else "const", decl.emit_name orelse decl.name, try types.zigName(arena, final_zty) });
            try emitExpr(decl.init, body, arena);
            try body.appendSlice(arena, ";\n");
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
            const label = try std.fmt.allocPrint(arena, "__lumen_switch_{d}_{d}", .{ switch_stmt.line, switch_stmt.col });
            try body.print(arena, "    {s}: {{\n", .{label});
            for (switch_stmt.cases, 0..) |case, i| {
                try body.appendSlice(arena, if (i == 0) "    if (" else "    else if (");
                try emitSwitchCaseMatch(switch_type, switch_stmt.value, case.value, body, arena);
                try body.appendSlice(arena, ") {\n");
                for (case.body) |*case_stmt| try emitStmtWithThrow(case_stmt, decls, body, arena, throw_target, label, options);
                try body.appendSlice(arena, "    }\n");
            }
            if (switch_stmt.default_body) |default_body| {
                try body.appendSlice(arena, if (switch_stmt.cases.len == 0) "    {\n" else "    else {\n");
                for (default_body) |*default_stmt| try emitStmtWithThrow(default_stmt, decls, body, arena, throw_target, label, options);
                try body.appendSlice(arena, "    }\n");
            }
            try body.appendSlice(arena, "    }\n");
        },
        .return_stmt => |ret| {
            if (ret.value) |value| {
                try body.appendSlice(arena, "    return ");
                try emitExpr(value, body, arena);
                try body.appendSlice(arena, ";\n");
            } else {
                try body.appendSlice(arena, "    return;\n");
            }
        },
        .throw_stmt => |throw_stmt| {
            if (throw_target) |target| {
                try body.print(arena, "    {s} = ", .{target});
                try emitExpr(throw_stmt.value, body, arena);
                try body.appendSlice(arena, ";\n");
            } else {
                try body.appendSlice(arena, "    @panic(");
                try emitExpr(throw_stmt.value, body, arena);
                try body.appendSlice(arena, ");\n");
            }
        },
        .try_stmt => |try_stmt| {
            const slot = try std.fmt.allocPrint(arena, "__lumen_throw_{d}_{d}", .{ try_stmt.line, try_stmt.col });
            try body.print(arena, "    var {s}: ?[]const u8 = null;\n", .{slot});
            try body.appendSlice(arena, "    {\n");
            for (try_stmt.try_body) |*try_body_stmt| {
                try body.print(arena, "    if ({s} == null) {{\n", .{slot});
                try emitStmtWithThrow(try_body_stmt, decls, body, arena, slot, switch_break_target, options);
                try body.appendSlice(arena, "    }\n");
            }
            try body.appendSlice(arena, "    }\n");
            try body.print(arena, "    if ({s}) |{s}| {{\n", .{ slot, try_stmt.catch_emit_name orelse try_stmt.catch_name });
            for (try_stmt.catch_body) |*catch_stmt| try emitStmtWithThrow(catch_stmt, decls, body, arena, throw_target, switch_break_target, options);
            try body.appendSlice(arena, "    }\n");
            if (try_stmt.finally_body) |finally_body| {
                for (finally_body) |*finally_stmt| try emitStmtWithThrow(finally_stmt, decls, body, arena, throw_target, switch_break_target, options);
            }
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

fn emitProgram(program: *const Program, decls: *std.ArrayListUnmanaged(u8), body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, options: CompileOptions) CompileError!void {
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

    try emitProgram(&program, &decls, &body, arena, options);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(arena, "const std = @import(\"std\");\n");

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
        try out.appendSlice(arena, "    const __io = __init.io;\n    const __alloc = __init.arena.allocator();\n");
        if (program.needs_args) {
            try out.appendSlice(arena, "    const __args = __init.minimal.args.toSlice(__alloc) catch std.process.exit(1);\n");
        }
    } else {
        try out.appendSlice(arena, "pub fn main() void {\n");
    }
    try out.appendSlice(arena, body.items);
    try out.appendSlice(arena, "}\n");
    return out.items;
}
