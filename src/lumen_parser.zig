//! The parser -- stage 2 of the compiler.
//!
//! Consumes the lexer's token stream and produces the AST (`lumen_ast.zig`). It is
//! a hand-written recursive-descent parser: `Parser.init(arena, source)` wraps a
//! `Lexer`, and `Parser.parseProgram()` returns a `Program`. The parser only knows
//! about tokens and AST nodes -- it does no type checking and no code generation
//! (those are `lumen_check.zig` and the codegen in `lumen_compiler.zig`).
//!
//! Errors are reported as `error.ParseError`; the caller turns the lexer's current
//! position into a user-facing diagnostic. Type annotations are kept as raw source
//! strings on the AST and resolved later by the checker.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const lexer = @import("lumen_lexer.zig");
const diag_mod = @import("lumen_diag.zig");

const CompileError = diag_mod.CompileError;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Program = ast.Program;
const FieldInit = ast.FieldInit;
const Lexer = lexer.Lexer;
const Tok = lexer.Tok;

/// Names the parser treats as built-in calls rather than user identifiers.
fn isBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "httpGet") or std.mem.eql(u8, name, "serve");
}

pub const Parser = struct {
    arena: std.mem.Allocator,
    lex: Lexer,
    cur: Tok,
    cur_line: u32 = 1, // source line of `cur`
    cur_col: u32 = 1, // source column of `cur`
    last_err: []const u8 = "syntax error", // message for the next diagnostic

    pub fn init(arena: std.mem.Allocator, src: []const u8) CompileError!Parser {
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
        if (self.cur == .regex) {
            const rx = self.cur.regex;
            try self.advance();
            return self.node(.{ .regex = .{ .source = rx.pattern, .flags = rx.flags } });
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

    pub fn parseProgram(self: *Parser) CompileError!Program {
        var stmts: std.ArrayListUnmanaged(Stmt) = .empty;
        while (self.cur != .eof) try stmts.append(self.arena, try self.parseStmt());
        return .{ .stmts = try stmts.toOwnedSlice(self.arena) };
    }
};
