//! Recursive-descent / precedence-climbing parser (ECMA-262 §13–§14). M1 adds statements
//! (declarations, blocks, expression statements) and identifier / assignment expressions.
//! Reports SyntaxError on malformed input (the parse-phase error for negative Test262 cases).
const std = @import("std");
const ast = @import("ast.zig");
const lex = @import("lexer.zig");

pub const ParseError = error{ UnexpectedToken, UnexpectedEof } || lex.LexError;

pub const Parser = struct {
    tokens: []const lex.Token,
    idx: usize = 0,
    arena: std.mem.Allocator,

    pub fn parse(arena: std.mem.Allocator, src: []const u8) ParseError!ast.Program {
        var lexer = lex.Lexer.init(arena, src);
        var toks: std.ArrayList(lex.Token) = .empty;
        while (true) {
            const t = try lexer.next();
            try toks.append(arena, t);
            if (t.kind == .eof) break;
        }
        var p = Parser{ .tokens = toks.items, .arena = arena };
        return p.parseProgram();
    }

    fn peek(self: *Parser) lex.Token {
        return self.tokens[self.idx];
    }

    fn advance(self: *Parser) lex.Token {
        const t = self.tokens[self.idx];
        if (self.idx + 1 < self.tokens.len) self.idx += 1;
        return t;
    }

    fn expect(self: *Parser, kind: lex.TokenKind) ParseError!lex.Token {
        if (self.peek().kind != kind) return ParseError.UnexpectedToken;
        return self.advance();
    }

    fn alloc(self: *Parser, node: ast.Node) ParseError!*const ast.Node {
        const p = try self.arena.create(ast.Node);
        p.* = node;
        return p;
    }

    fn allocStmt(self: *Parser, stmt: ast.Stmt) ParseError!*const ast.Stmt {
        const p = try self.arena.create(ast.Stmt);
        p.* = stmt;
        return p;
    }

    /// §13.2.8 Template literal: split raw inner text into cooked quasis + expression sources,
    /// sub-parsing each `${...}`. quasis.len == exprs.len + 1.
    fn parseTemplate(self: *Parser, raw: []const u8) ParseError!*const ast.Node {
        var quasis: std.ArrayList([]const u8) = .empty;
        var exprs: std.ArrayList(*const ast.Node) = .empty;
        var cooked: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                const d: u8 = switch (raw[i + 1]) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    else => raw[i + 1], // \\, \`, \$, \", \' → literal
                };
                try cooked.append(self.arena, d);
                i += 2;
                continue;
            }
            if (raw[i] == '$' and i + 1 < raw.len and raw[i + 1] == '{') {
                try quasis.append(self.arena, cooked.items);
                cooked = .empty;
                i += 2;
                const expr_start = i;
                var depth: usize = 1;
                while (i < raw.len and depth > 0) {
                    if (raw[i] == '{') depth += 1 else if (raw[i] == '}') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                    i += 1;
                }
                const prog = try Parser.parse(self.arena, raw[expr_start..i]);
                const node = if (prog.statements.len > 0 and prog.statements[0] == .expr)
                    prog.statements[0].expr
                else
                    try self.alloc(.{ .string = "" });
                try exprs.append(self.arena, node);
                i += 1; // skip closing }
                continue;
            }
            try cooked.append(self.arena, raw[i]);
            i += 1;
        }
        try quasis.append(self.arena, cooked.items);
        return self.alloc(.{ .template = .{ .quasis = quasis.items, .exprs = exprs.items } });
    }

    /// §13.3.5 `new Callee(args)`. Callee is a member expression (no call); the argument list
    /// binds to the `new`, so `new a.b.C(x)` constructs `a.b.C`.
    fn parseNew(self: *Parser) ParseError!*const ast.Node {
        _ = self.advance(); // new
        var callee = try self.parsePrimary();
        while (true) {
            switch (self.peek().kind) {
                .dot => {
                    _ = self.advance();
                    const name = try self.expect(.identifier);
                    callee = try self.alloc(.{ .member = .{ .object = callee, .name = name.lexeme } });
                },
                .lbracket => {
                    _ = self.advance();
                    const key = try self.parseAssignment();
                    _ = try self.expect(.rbracket);
                    callee = try self.alloc(.{ .index = .{ .object = callee, .key = key } });
                },
                else => break,
            }
        }
        var args: []const *const ast.Node = &.{};
        if (self.peek().kind == .lparen) {
            _ = self.advance();
            var list: std.ArrayList(*const ast.Node) = .empty;
            while (self.peek().kind != .rparen and self.peek().kind != .eof) {
                try list.append(self.arena, try self.parseAssignment());
                if (self.peek().kind == .comma) {
                    _ = self.advance();
                    continue;
                }
                break;
            }
            _ = try self.expect(.rparen);
            args = list.items;
        }
        return self.alloc(.{ .new_expr = .{ .callee = callee, .args = args } });
    }

    fn parseIf(self: *Parser) ParseError!ast.Stmt {
        _ = self.advance(); // if
        _ = try self.expect(.lparen);
        const cond = try self.parseAssignment();
        _ = try self.expect(.rparen);
        const then = try self.allocStmt(try self.parseStmt());
        var otherwise: ?*const ast.Stmt = null;
        if (self.peek().kind == .kw_else) {
            _ = self.advance();
            otherwise = try self.allocStmt(try self.parseStmt());
        }
        return .{ .if_stmt = .{ .cond = cond, .then = then, .otherwise = otherwise } };
    }

    fn parseWhile(self: *Parser) ParseError!ast.Stmt {
        _ = self.advance(); // while
        _ = try self.expect(.lparen);
        const cond = try self.parseAssignment();
        _ = try self.expect(.rparen);
        const body = try self.allocStmt(try self.parseStmt());
        return .{ .while_stmt = .{ .cond = cond, .body = body } };
    }

    fn parseFor(self: *Parser) ParseError!ast.Stmt {
        _ = self.advance(); // for
        _ = try self.expect(.lparen);
        var init_stmt: ?*const ast.Stmt = null;
        switch (self.peek().kind) {
            .semicolon => _ = self.advance(),
            .kw_var, .kw_let, .kw_const => init_stmt = try self.allocStmt(try self.parseDecl()), // parseDecl eats the ;
            else => {
                init_stmt = try self.allocStmt(.{ .expr = try self.parseAssignment() });
                _ = try self.expect(.semicolon);
            },
        }
        var cond: ?*const ast.Node = null;
        if (self.peek().kind != .semicolon) cond = try self.parseAssignment();
        _ = try self.expect(.semicolon);
        var update: ?*const ast.Node = null;
        if (self.peek().kind != .rparen) update = try self.parseAssignment();
        _ = try self.expect(.rparen);
        const body = try self.allocStmt(try self.parseStmt());
        return .{ .for_stmt = .{ .init = init_stmt, .cond = cond, .update = update, .body = body } };
    }

    fn parseSwitch(self: *Parser) ParseError!ast.Stmt {
        _ = self.advance(); // switch
        _ = try self.expect(.lparen);
        const disc = try self.parseAssignment();
        _ = try self.expect(.rparen);
        _ = try self.expect(.lbrace);
        var cases: std.ArrayList(ast.Case) = .empty;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            var test_expr: ?*const ast.Node = null;
            switch (self.peek().kind) {
                .kw_case => {
                    _ = self.advance();
                    test_expr = try self.parseAssignment();
                },
                .kw_default => _ = self.advance(),
                else => return ParseError.UnexpectedToken,
            }
            _ = try self.expect(.colon);
            var body: std.ArrayList(ast.Stmt) = .empty;
            while (true) {
                switch (self.peek().kind) {
                    .kw_case, .kw_default, .rbrace, .eof => break,
                    else => try body.append(self.arena, try self.parseStmt()),
                }
            }
            try cases.append(self.arena, .{ .test_expr = test_expr, .body = body.items });
        }
        _ = try self.expect(.rbrace);
        return .{ .switch_stmt = .{ .discriminant = disc, .cases = cases.items } };
    }

    fn parseTry(self: *Parser) ParseError!ast.Stmt {
        _ = self.advance(); // try
        const block = try self.parseBlock();
        var catch_param: ?[]const u8 = null;
        var catch_block: ?[]const ast.Stmt = null;
        var finally_block: ?[]const ast.Stmt = null;
        if (self.peek().kind == .kw_catch) {
            _ = self.advance();
            if (self.peek().kind == .lparen) {
                _ = self.advance();
                catch_param = (try self.expect(.identifier)).lexeme;
                _ = try self.expect(.rparen);
            }
            catch_block = try self.parseBlock();
        }
        if (self.peek().kind == .kw_finally) {
            _ = self.advance();
            finally_block = try self.parseBlock();
        }
        return .{ .try_stmt = .{ .block = block, .catch_param = catch_param, .catch_block = catch_block, .finally_block = finally_block } };
    }

    // ── statements ──────────────────────────────────────────────────────────

    fn parseProgram(self: *Parser) ParseError!ast.Program {
        var stmts: std.ArrayList(ast.Stmt) = .empty;
        while (self.peek().kind != .eof) {
            try stmts.append(self.arena, try self.parseStmt());
        }
        return .{ .statements = stmts.items };
    }

    fn parseStmt(self: *Parser) ParseError!ast.Stmt {
        switch (self.peek().kind) {
            .lbrace => return .{ .block = try self.parseBlock() },
            .kw_var, .kw_let, .kw_const => return self.parseDecl(),
            .kw_function => {
                _ = self.advance();
                return .{ .func_decl = try self.parseFunction() };
            },
            .kw_return => {
                _ = self.advance();
                var arg: ?*const ast.Node = null;
                const k = self.peek().kind;
                if (k != .semicolon and k != .rbrace and k != .eof) arg = try self.parseAssignment();
                if (self.peek().kind == .semicolon) _ = self.advance();
                return .{ .ret = arg };
            },
            .kw_if => return self.parseIf(),
            .kw_while => return self.parseWhile(),
            .kw_for => return self.parseFor(),
            .kw_switch => return self.parseSwitch(),
            .kw_try => return self.parseTry(),
            .kw_throw => {
                _ = self.advance();
                const e = try self.parseAssignment();
                if (self.peek().kind == .semicolon) _ = self.advance();
                return .{ .throw_stmt = e };
            },
            .kw_break => {
                _ = self.advance();
                if (self.peek().kind == .semicolon) _ = self.advance();
                return .break_stmt;
            },
            .kw_continue => {
                _ = self.advance();
                if (self.peek().kind == .semicolon) _ = self.advance();
                return .continue_stmt;
            },
            else => {
                const e = try self.parseAssignment();
                if (self.peek().kind == .semicolon) _ = self.advance();
                return .{ .expr = e };
            },
        }
    }

    /// §15.2: `function [name] (params) { body }` — shared by declarations and expressions.
    fn parseFunction(self: *Parser) ParseError!*const ast.Function {
        var name: ?[]const u8 = null;
        if (self.peek().kind == .identifier) name = self.advance().lexeme;
        const params = try self.parseParams();
        const body = try self.parseBlock();
        const f = try self.arena.create(ast.Function);
        f.* = .{ .name = name, .params = params, .body = body };
        return f;
    }

    fn parseParams(self: *Parser) ParseError![]const []const u8 {
        _ = try self.expect(.lparen);
        var params: std.ArrayList([]const u8) = .empty;
        while (self.peek().kind != .rparen and self.peek().kind != .eof) {
            const p = try self.expect(.identifier);
            try params.append(self.arena, p.lexeme);
            if (self.peek().kind == .comma) {
                _ = self.advance();
                continue;
            }
            break;
        }
        _ = try self.expect(.rparen);
        return params.items;
    }

    fn parseBlock(self: *Parser) ParseError![]const ast.Stmt {
        _ = try self.expect(.lbrace);
        var stmts: std.ArrayList(ast.Stmt) = .empty;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            try stmts.append(self.arena, try self.parseStmt());
        }
        _ = try self.expect(.rbrace);
        return stmts.items;
    }

    fn parseDecl(self: *Parser) ParseError!ast.Stmt {
        const kind: ast.DeclKind = switch (self.advance().kind) {
            .kw_var => .var_decl,
            .kw_let => .let_decl,
            else => .const_decl,
        };
        var decls: std.ArrayList(ast.Declarator) = .empty;
        while (true) {
            const name_tok = try self.expect(.identifier);
            var init_expr: ?*const ast.Node = null;
            if (self.peek().kind == .assign) {
                _ = self.advance();
                init_expr = try self.parseAssignment();
            }
            try decls.append(self.arena, .{ .name = name_tok.lexeme, .init = init_expr });
            if (self.peek().kind == .comma) {
                _ = self.advance();
                continue;
            }
            break;
        }
        if (self.peek().kind == .semicolon) _ = self.advance();
        return .{ .declaration = .{ .kind = kind, .decls = decls.items } };
    }

    // ── expressions ─────────────────────────────────────────────────────────

    /// §13.15 Assignment (right-associative). Only identifier targets in M1 Cycle A.
    fn parseAssignment(self: *Parser) ParseError!*const ast.Node {
        const left = try self.parseConditional();
        const op = self.peek().kind;
        if (op == .assign or compoundBinOp(op) != null) {
            _ = self.advance();
            const rhs = try self.parseAssignment();
            // Compound assignment `x op= v` desugars to `x = x op v`.
            const value = if (compoundBinOp(op)) |bop|
                try self.alloc(.{ .binary = .{ .op = bop, .left = left, .right = rhs } })
            else
                rhs;
            switch (left.*) {
                .identifier => |n| return self.alloc(.{ .assign = .{ .name = n, .value = value } }),
                .member => |m| return self.alloc(.{ .assign_member = .{ .object = m.object, .name = m.name, .value = value } }),
                .index => |ix| return self.alloc(.{ .assign_index = .{ .object = ix.object, .key = ix.key, .value = value } }),
                else => return ParseError.UnexpectedToken, // invalid assignment target
            }
        }
        return left;
    }

    /// §13.14 Conditional `cond ? then : otherwise` (above assignment, right-associative branches).
    fn parseConditional(self: *Parser) ParseError!*const ast.Node {
        const cond = try self.parseExpr(0);
        if (self.peek().kind == .question) {
            _ = self.advance();
            const then = try self.parseAssignment();
            _ = try self.expect(.colon);
            const otherwise = try self.parseAssignment();
            return self.alloc(.{ .conditional = .{ .cond = cond, .then = then, .otherwise = otherwise } });
        }
        return cond;
    }

    /// Precedence-climbing for binary + logical operators. Higher number binds tighter.
    /// Logical `||`/`&&` build short-circuiting `logical` nodes; everything else is `binary`.
    fn parseExpr(self: *Parser, min_prec: u8) ParseError!*const ast.Node {
        var left = try self.parseUnary();
        while (true) {
            const k = self.peek().kind;
            const prec = opPrecedence(k) orelse break;
            if (prec < min_prec) break;
            _ = self.advance();
            // `**` is right-associative; everything else left-associative.
            const right = try self.parseExpr(if (k == .star_star) prec else prec + 1);
            left = switch (k) {
                .pipe_pipe => try self.alloc(.{ .logical = .{ .op = .or_, .left = left, .right = right } }),
                .amp_amp => try self.alloc(.{ .logical = .{ .op = .and_, .left = left, .right = right } }),
                else => try self.alloc(.{ .binary = .{ .op = binaryOpFor(k).?, .left = left, .right = right } }),
            };
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!*const ast.Node {
        // §13.4.4/5 prefix ++ / --
        if (self.peek().kind == .plus_plus or self.peek().kind == .minus_minus) {
            const op: ast.UpdateOp = if (self.peek().kind == .plus_plus) .inc else .dec;
            _ = self.advance();
            const target = try self.parseUnary();
            return self.alloc(.{ .update = .{ .op = op, .prefix = true, .target = target } });
        }
        const uop: ?ast.UnaryOp = switch (self.peek().kind) {
            .plus => .plus,
            .minus => .minus,
            .bang => .not,
            .kw_typeof => .typeof_,
            .bit_not => .bit_not,
            else => null,
        };
        if (uop) |op| {
            _ = self.advance();
            const operand = try self.parseUnary();
            return self.alloc(.{ .unary = .{ .op = op, .operand = operand } });
        }
        return self.parsePostfix();
    }

    /// §13.3 Member access postfix: `a.b` and `a[expr]`, left-associative, highest precedence.
    fn parsePostfix(self: *Parser) ParseError!*const ast.Node {
        var expr = try self.parsePrimary();
        while (true) {
            switch (self.peek().kind) {
                .dot => {
                    _ = self.advance();
                    const name = try self.expect(.identifier);
                    expr = try self.alloc(.{ .member = .{ .object = expr, .name = name.lexeme } });
                },
                .lbracket => {
                    _ = self.advance();
                    const key = try self.parseAssignment();
                    _ = try self.expect(.rbracket);
                    expr = try self.alloc(.{ .index = .{ .object = expr, .key = key } });
                },
                .lparen => { // §13.3.6 call
                    _ = self.advance();
                    var args: std.ArrayList(*const ast.Node) = .empty;
                    while (self.peek().kind != .rparen and self.peek().kind != .eof) {
                        try args.append(self.arena, try self.parseAssignment());
                        if (self.peek().kind == .comma) {
                            _ = self.advance();
                            continue;
                        }
                        break;
                    }
                    _ = try self.expect(.rparen);
                    expr = try self.alloc(.{ .call = .{ .callee = expr, .args = args.items } });
                },
                else => break,
            }
        }
        // §13.4.2/3 postfix ++ / --
        if (self.peek().kind == .plus_plus or self.peek().kind == .minus_minus) {
            const op: ast.UpdateOp = if (self.peek().kind == .plus_plus) .inc else .dec;
            _ = self.advance();
            expr = try self.alloc(.{ .update = .{ .op = op, .prefix = false, .target = expr } });
        }
        return expr;
    }

    /// §13.2.5 Object initializer `{ key: value, ... }` (identifier or string keys, M1).
    fn parseObjectLiteral(self: *Parser) ParseError!*const ast.Node {
        _ = try self.expect(.lbrace);
        var props: std.ArrayList(ast.Property) = .empty;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            const kt = self.advance();
            const key = switch (kt.kind) {
                .identifier => kt.lexeme,
                .string => kt.string_value,
                else => return ParseError.UnexpectedToken,
            };
            _ = try self.expect(.colon);
            const value = try self.parseAssignment();
            try props.append(self.arena, .{ .key = key, .value = value });
            if (self.peek().kind == .comma) {
                _ = self.advance();
                continue;
            }
            break;
        }
        _ = try self.expect(.rbrace);
        return self.alloc(.{ .object_literal = props.items });
    }

    fn parsePrimary(self: *Parser) ParseError!*const ast.Node {
        const t = self.peek();
        switch (t.kind) {
            .number => {
                _ = self.advance();
                const n = std.fmt.parseFloat(f64, t.lexeme) catch return ParseError.UnexpectedToken;
                return self.alloc(.{ .number = n });
            },
            .string => {
                _ = self.advance();
                return self.alloc(.{ .string = t.string_value });
            },
            .kw_true => {
                _ = self.advance();
                return self.alloc(.{ .boolean = true });
            },
            .kw_false => {
                _ = self.advance();
                return self.alloc(.{ .boolean = false });
            },
            .kw_null => {
                _ = self.advance();
                return self.alloc(.null);
            },
            .identifier => {
                _ = self.advance();
                return self.alloc(.{ .identifier = t.lexeme });
            },
            .lbrace => return self.parseObjectLiteral(),
            .lbracket => { // §13.2.4 array literal
                _ = self.advance();
                var elems: std.ArrayList(*const ast.Node) = .empty;
                while (self.peek().kind != .rbracket and self.peek().kind != .eof) {
                    try elems.append(self.arena, try self.parseAssignment());
                    if (self.peek().kind == .comma) {
                        _ = self.advance();
                        continue;
                    }
                    break;
                }
                _ = try self.expect(.rbracket);
                return self.alloc(.{ .array_literal = elems.items });
            },
            .kw_function => {
                _ = self.advance();
                return self.alloc(.{ .function = try self.parseFunction() });
            },
            .kw_this => {
                _ = self.advance();
                return self.alloc(.this);
            },
            .template => {
                _ = self.advance();
                return self.parseTemplate(t.string_value);
            },
            .kw_new => return self.parseNew(),
            .lparen => {
                _ = self.advance();
                const inner = try self.parseAssignment();
                _ = try self.expect(.rparen);
                return inner;
            },
            .eof => return ParseError.UnexpectedEof,
            else => return ParseError.UnexpectedToken,
        }
    }
};

fn binaryOpFor(kind: lex.TokenKind) ?ast.BinaryOp {
    return switch (kind) {
        .plus => .add,
        .minus => .sub,
        .star => .mul,
        .slash => .div,
        .percent => .mod,
        .star_star => .exp,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        .shl => .shl,
        .shr => .shr,
        .shr_un => .shr_un,
        .lt => .lt,
        .gt => .gt,
        .le => .le,
        .ge => .ge,
        .kw_instanceof => .instanceof_,
        .kw_in => .in_op,
        .eq => .eq,
        .ne => .ne,
        .seq => .seq,
        .sne => .sne,
        else => null,
    };
}

/// The binary operator a compound-assignment token (`+=`, …) desugars to, else null.
fn compoundBinOp(kind: lex.TokenKind) ?ast.BinaryOp {
    return switch (kind) {
        .plus_assign => .add,
        .minus_assign => .sub,
        .star_assign => .mul,
        .slash_assign => .div,
        .percent_assign => .mod,
        else => null,
    };
}

/// Precedence over token kinds (covers logical, equality, relational, additive,
/// multiplicative). Assignment is handled separately in `parseAssignment`.
fn opPrecedence(kind: lex.TokenKind) ?u8 {
    return switch (kind) {
        .pipe_pipe => 1,
        .amp_amp => 2,
        .bit_or => 3,
        .bit_xor => 4,
        .bit_and => 5,
        .eq, .ne, .seq, .sne => 6,
        .lt, .gt, .le, .ge, .kw_instanceof, .kw_in => 7,
        .shl, .shr, .shr_un => 8,
        .plus, .minus => 9,
        .star, .slash, .percent => 10,
        .star_star => 11, // right-assoc (handled in parseExpr)
        else => null,
    };
}
