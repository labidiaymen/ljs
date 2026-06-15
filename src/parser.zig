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
        const left = try self.parseExpr(0);
        if (self.peek().kind == .assign) {
            _ = self.advance();
            const value = try self.parseAssignment();
            switch (left.*) {
                .identifier => |n| return self.alloc(.{ .assign = .{ .name = n, .value = value } }),
                .member => |m| return self.alloc(.{ .assign_member = .{ .object = m.object, .name = m.name, .value = value } }),
                .index => |ix| return self.alloc(.{ .assign_index = .{ .object = ix.object, .key = ix.key, .value = value } }),
                else => return ParseError.UnexpectedToken, // invalid assignment target
            }
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
            .kw_function => {
                _ = self.advance();
                return self.alloc(.{ .function = try self.parseFunction() });
            },
            .kw_this => {
                _ = self.advance();
                return self.alloc(.this);
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
