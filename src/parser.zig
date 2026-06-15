//! Recursive-descent / precedence-climbing parser for the M0 expression grammar
//! (ECMA-262 §13). Produces an arena-allocated `ast.Program`. Reports SyntaxError on
//! malformed input (the parse-phase error used by negative Test262 cases).
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

    fn parseProgram(self: *Parser) ParseError!ast.Program {
        var stmts: std.ArrayList(*const ast.Node) = .empty;
        while (self.peek().kind != .eof) {
            const expr = try self.parseExpr(0);
            try stmts.append(self.arena, expr);
            // Optional statement terminator.
            if (self.peek().kind == .semicolon) _ = self.advance();
        }
        return .{ .statements = stmts.items };
    }

    /// Precedence-climbing. Higher number binds tighter.
    fn parseExpr(self: *Parser, min_prec: u8) ParseError!*const ast.Node {
        var left = try self.parseUnary();
        while (true) {
            const op = binaryOpFor(self.peek().kind) orelse break;
            const prec = precedence(op);
            if (prec < min_prec) break;
            _ = self.advance();
            const right = try self.parseExpr(prec + 1); // left-associative
            left = try self.alloc(.{ .binary = .{ .op = op, .left = left, .right = right } });
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!*const ast.Node {
        const k = self.peek().kind;
        const uop: ?ast.UnaryOp = switch (k) {
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
            .lparen => {
                _ = self.advance();
                const inner = try self.parseExpr(0);
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
