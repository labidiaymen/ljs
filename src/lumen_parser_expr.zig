//! Type-annotation and expression parsing.
//!
//! Type annotations are kept as raw source-text strings on the AST (resolved
//! later by the checker), so `parseTypeAnnotation`/`parseFunctionType`/
//! `parseTupleType`/`parseTypeMember` mostly scan and slice rather than build
//! structure. Expression parsing is a standard precedence-climbing cascade
//! (`parseTernary` -> `parseCoalesce` -> `parseOr` -> ... -> `parseUnary` ->
//! `parsePostfix` -> `parsePrimary`), each level handling one precedence tier
//! and falling through to the next for anything it does not recognize.
//!
//! Pulled out of `lumen_parser.zig` as the "parsing a value" concern, distinct
//! from statement and declaration parsing (which call into this for every
//! expression they contain).

const std = @import("std");
const ast = @import("lumen_ast.zig");
const lexer = @import("lumen_lexer.zig");
const diag_mod = @import("lumen_diag.zig");
const parser_mod = @import("lumen_parser.zig");

const CompileError = diag_mod.CompileError;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const FieldInit = ast.FieldInit;
const Parser = parser_mod.Parser;

pub fn parseTypeMember(self: *Parser) CompileError![]const u8 {
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
pub fn consumeTypeArgClose(self: *Parser) CompileError!void {
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
pub fn parseFunctionType(self: *Parser) CompileError![]const u8 {
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
pub fn parseTupleType(self: *Parser) CompileError![]const u8 {
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

pub fn parseTypeAnnotation(self: *Parser) CompileError![]const u8 {
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

pub fn parseExpr(self: *Parser) CompileError!*Expr {
    return self.parseTernary();
}

/// Parses one array-literal element or call argument, recognizing a leading
/// `...` spread (`...expr`) and wrapping it in a `spread` node.
pub fn parseSpreadOrExpr(self: *Parser) CompileError!*Expr {
    if (self.isSpread()) {
        try self.advance();
        const inner = try self.parseExpr();
        return self.node(.{ .spread = inner });
    }
    return self.parseExpr();
}

/// Splits a template literal's raw inner text into literal-text and `${expr}`
/// parts, sub-parsing each hole as an expression.
pub fn parseTemplateParts(self: *Parser, raw: []const u8) CompileError![]ast.TemplatePart {
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
pub fn parseTernary(self: *Parser) CompileError!*Expr {
    const cond = try self.parseCoalesce();
    if (!self.isOp('?')) return cond;
    try self.advance();
    const then_expr = try self.parseExpr();
    try self.expectOp(':');
    const else_expr = try self.parseExpr();
    return self.node(.{ .ternary = .{ .cond = cond, .then_expr = then_expr, .else_expr = else_expr } });
}
pub fn parseCoalesce(self: *Parser) CompileError!*Expr {
    var left = try self.parseOr();
    while (self.isOp2("??")) {
        try self.advance();
        const right = try self.parseOr();
        left = try self.node(.{ .coalesce = .{ .l = left, .r = right } });
    }
    return left;
}
pub fn isCmp(self: *Parser, op: []const u8) bool {
    return self.cur == .cmp and std.mem.eql(u8, self.cur.cmp, op);
}
pub fn isComparison(self: *Parser) bool {
    if (self.cur != .cmp) return false;
    const op = self.cur.cmp;
    return std.mem.eql(u8, op, "<") or
        std.mem.eql(u8, op, ">") or
        std.mem.eql(u8, op, "<=") or
        std.mem.eql(u8, op, ">=") or
        std.mem.eql(u8, op, "==") or
        std.mem.eql(u8, op, "!=");
}
pub fn parseOr(self: *Parser) CompileError!*Expr {
    var left = try self.parseAnd();
    while (self.isCmp("||")) {
        const op = self.cur.cmp;
        try self.advance();
        const right = try self.parseAnd();
        left = try self.node(.{ .bool_bin = .{ .op = op, .l = left, .r = right } });
    }
    return left;
}
pub fn parseAnd(self: *Parser) CompileError!*Expr {
    var left = try self.parseBitOr();
    while (self.isCmp("&&")) {
        const op = self.cur.cmp;
        try self.advance();
        const right = try self.parseBitOr();
        left = try self.node(.{ .bool_bin = .{ .op = op, .l = left, .r = right } });
    }
    return left;
}
pub fn parseBitOr(self: *Parser) CompileError!*Expr {
    var left = try self.parseBitXor();
    while (self.isCmp("|")) {
        try self.advance();
        const right = try self.parseBitXor();
        left = try self.node(.{ .bin = .{ .op = '|', .l = left, .r = right } });
    }
    return left;
}
pub fn parseBitXor(self: *Parser) CompileError!*Expr {
    var left = try self.parseBitAnd();
    while (self.isOp('^')) {
        try self.advance();
        const right = try self.parseBitAnd();
        left = try self.node(.{ .bin = .{ .op = '^', .l = left, .r = right } });
    }
    return left;
}
pub fn parseBitAnd(self: *Parser) CompileError!*Expr {
    var left = try self.parseCmp();
    while (self.isOp('&')) {
        try self.advance();
        const right = try self.parseCmp();
        left = try self.node(.{ .bin = .{ .op = '&', .l = left, .r = right } });
    }
    return left;
}
pub fn parseCmp(self: *Parser) CompileError!*Expr {
    var left = try self.parseShift();
    if (self.isComparison()) {
        const op = self.cur.cmp;
        try self.advance();
        const right = try self.parseShift();
        left = try self.node(.{ .cmp = .{ .op = op, .l = left, .r = right } });
    }
    return left;
}
pub fn parseShift(self: *Parser) CompileError!*Expr {
    var left = try self.parseAdd();
    while (self.isOp2("<<") or self.isOp2(">>")) {
        const op: u8 = if (self.isOp2("<<")) 'L' else 'R';
        try self.advance();
        const right = try self.parseAdd();
        left = try self.node(.{ .bin = .{ .op = op, .l = left, .r = right } });
    }
    return left;
}
pub fn parseAdd(self: *Parser) CompileError!*Expr {
    var left = try self.parseMul();
    while (self.isOp('+') or self.isOp('-')) {
        const op = self.cur.op;
        try self.advance();
        const right = try self.parseMul();
        left = try self.node(.{ .bin = .{ .op = op, .l = left, .r = right } });
    }
    return left;
}
pub fn parseMul(self: *Parser) CompileError!*Expr {
    var left = try self.parseExp();
    while (self.isOp('*') or self.isOp('/') or self.isOp('%')) {
        const op = self.cur.op;
        try self.advance();
        const right = try self.parseExp();
        left = try self.node(.{ .bin = .{ .op = op, .l = left, .r = right } });
    }
    return left;
}
pub fn parseExp(self: *Parser) CompileError!*Expr {
    const left = try self.parseUnary();
    if (self.isOp2("**")) {
        try self.advance();
        const right = try self.parseExp(); // right-associative
        return self.node(.{ .bin = .{ .op = 'P', .l = left, .r = right } });
    }
    return left;
}
pub fn parseUnary(self: *Parser) CompileError!*Expr {
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
pub fn parsePostfix(self: *Parser) CompileError!*Expr {
    return self.parsePostfixFrom(try self.parsePrimary());
}
pub fn parsePostfixFrom(self: *Parser, base: *Expr) CompileError!*Expr {
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
                if (e.* == .var_ref and Parser.isStdNamespace(e.var_ref.name)) {
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
pub fn looksLikeArrow(self: *Parser) bool {
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
pub fn parseArrow(self: *Parser) CompileError!*Expr {
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
pub fn parseDeferHelperBodyStmt(self: *Parser) CompileError!Stmt {
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

pub fn parsePrimary(self: *Parser) CompileError!*Expr {
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

pub fn parseAssignmentTail(self: *Parser, name: []const u8, line: u32, col: u32, needs_semicolon: bool) CompileError!ast.Assign {
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

pub fn parsePrefixUpdate(self: *Parser, op: []const u8, line: u32, col: u32, needs_semicolon: bool) CompileError!ast.Assign {
    try self.advance();
    if (self.cur != .ident) return error.ParseError;
    const name = self.cur.ident;
    try self.advance();
    if (needs_semicolon) try self.expectOp(';');
    return .{ .name = name, .op = if (std.mem.eql(u8, op, "++")) "+=" else "-=", .value = try self.oneExpr(1), .line = line, .col = col };
}
