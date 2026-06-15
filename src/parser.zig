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
            else => {
                const e = try self.parseAssignment();
                if (self.peek().kind == .semicolon) _ = self.advance();
                return .{ .expr = e };
            },
        }
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
        const left = try self.parseExpr(0);
        if (self.peek().kind == .assign) {
            if (left.* != .identifier) return ParseError.UnexpectedToken;
            _ = self.advance();
            const value = try self.parseAssignment();
            return self.alloc(.{ .assign = .{ .name = left.identifier, .value = value } });
        }
        return left;
    }

    /// Precedence-climbing for binary operators. Higher number binds tighter.
    fn parseExpr(self: *Parser, min_prec: u8) ParseError!*const ast.Node {
        var left = try self.parseUnary();
        while (true) {
            const op = binaryOpFor(self.peek().kind) orelse break;
            const prec = precedence(op);
            if (prec < min_prec) break;
            _ = self.advance();
            const right = try self.parseExpr(prec + 1);
            left = try self.alloc(.{ .binary = .{ .op = op, .left = left, .right = right } });
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!*const ast.Node {
        const uop: ?ast.UnaryOp = switch (self.peek().kind) {
            .plus => .plus,
            .minus => .minus,
            .bang => .not,
            else => null,
        };
        if (uop) |op| {
            _ = self.advance();
            const operand = try self.parseUnary();
            return self.alloc(.{ .unary = .{ .op = op, .operand = operand } });
        }
        return self.parsePrimary();
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
        .lt => .lt,
        .gt => .gt,
        .le => .le,
        .ge => .ge,
        .eq => .eq,
        .ne => .ne,
        .seq => .seq,
        .sne => .sne,
        else => null,
    };
}

fn precedence(op: ast.BinaryOp) u8 {
    return switch (op) {
        .eq, .ne, .seq, .sne => 1,
        .lt, .gt, .le, .ge => 2,
        .add, .sub => 3,
        .mul, .div, .mod => 4,
    };
}
