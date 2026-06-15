//! Lexical grammar for the M0 subset (ECMA-262 §12). Hand-rolled scanner producing tokens
//! on demand. Covers numbers, string literals, the `true`/`false`/`null` keywords, and the
//! punctuators the M0 expression grammar needs.
const std = @import("std");

pub const TokenKind = enum {
    number,
    string,
    kw_true,
    kw_false,
    kw_null,
    plus,
    minus,
    star,
    slash,
    percent,
    bang,
    lparen,
    rparen,
    semicolon,
    lt,
    gt,
    le,
    ge,
    eq, // ==
    ne, // !=
    seq, // ===
    sne, // !==
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    /// Source slice for the token (for numbers/strings).
    lexeme: []const u8,
    /// Decoded string contents (string tokens only), allocated in the arena.
    string_value: []const u8 = "",
};

pub const LexError = error{ UnexpectedCharacter, UnterminatedString, OutOfMemory };

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,

    pub fn init(arena: std.mem.Allocator, src: []const u8) Lexer {
        return .{ .src = src, .arena = arena };
    }

    fn peek(self: *Lexer) u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else 0;
    }

    fn peek2(self: *Lexer) u8 {
        return if (self.pos + 1 < self.src.len) self.src[self.pos + 1] else 0;
    }

    // §12.2 White Space / §12.3 Line Terminators / §12.4 Comments.
    fn skipTrivia(self: *Lexer) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.pos += 1;
                continue;
            }
            if (c == '/' and self.pos + 1 < self.src.len) {
                const c2 = self.src[self.pos + 1];
                if (c2 == '/') { // single-line comment
                    self.pos += 2;
                    while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                    continue;
                }
                if (c2 == '*') { // block comment
                    self.pos += 2;
                    while (self.pos + 1 < self.src.len and
                        !(self.src[self.pos] == '*' and self.src[self.pos + 1] == '/')) self.pos += 1;
                    self.pos = @min(self.pos + 2, self.src.len);
                    continue;
                }
            }
            break;
        }
    }

    pub fn next(self: *Lexer) LexError!Token {
        self.skipTrivia();
        if (self.pos >= self.src.len) return .{ .kind = .eof, .lexeme = "" };

        const c = self.src[self.pos];
        const start = self.pos;

        // Numbers (decimal, optional fraction). §12.9.3 (subset).
        if (isDigit(c) or (c == '.' and isDigit(self.peek2()))) {
            self.pos += 1;
            while (self.pos < self.src.len and (isDigit(self.src[self.pos]) or self.src[self.pos] == '.')) {
                self.pos += 1;
            }
            return .{ .kind = .number, .lexeme = self.src[start..self.pos] };
        }

        // Identifiers / keywords (only the literals we support). §12.7 (subset).
        if (isIdentStart(c)) {
            self.pos += 1;
            while (self.pos < self.src.len and isIdentPart(self.src[self.pos])) self.pos += 1;
            const word = self.src[start..self.pos];
            if (std.mem.eql(u8, word, "true")) return .{ .kind = .kw_true, .lexeme = word };
            if (std.mem.eql(u8, word, "false")) return .{ .kind = .kw_false, .lexeme = word };
            if (std.mem.eql(u8, word, "null")) return .{ .kind = .kw_null, .lexeme = word };
            return LexError.UnexpectedCharacter; // identifiers/bindings not in M0
        }

        // String literals. §12.9.4 (subset: no escapes beyond the basics).
        if (c == '"' or c == '\'') return self.lexString(c);

        // Punctuators.
        self.pos += 1;
        switch (c) {
            '+' => return tok(.plus, self.src[start..self.pos]),
            '-' => return tok(.minus, self.src[start..self.pos]),
            '*' => return tok(.star, self.src[start..self.pos]),
            '/' => return tok(.slash, self.src[start..self.pos]),
            '%' => return tok(.percent, self.src[start..self.pos]),
            '(' => return tok(.lparen, self.src[start..self.pos]),
            ')' => return tok(.rparen, self.src[start..self.pos]),
            ';' => return tok(.semicolon, self.src[start..self.pos]),
            '<' => return self.maybeEq(.lt, .le, start),
            '>' => return self.maybeEq(.gt, .ge, start),
            '!' => {
                if (self.peek() == '=') return self.lexBangEq(start);
                return tok(.bang, self.src[start..self.pos]);
            },
            '=' => {
                if (self.peek() == '=') return self.lexEqEq(start);
                return LexError.UnexpectedCharacter; // assignment not in M0
            },
            else => return LexError.UnexpectedCharacter,
        }
    }

    fn maybeEq(self: *Lexer, base: TokenKind, with_eq: TokenKind, start: usize) Token {
        if (self.peek() == '=') {
            self.pos += 1;
            return tok(with_eq, self.src[start..self.pos]);
        }
        return tok(base, self.src[start..self.pos]);
    }

    fn lexEqEq(self: *Lexer, start: usize) Token {
        self.pos += 1; // second '='
        if (self.peek() == '=') {
            self.pos += 1;
            return tok(.seq, self.src[start..self.pos]);
        }
        return tok(.eq, self.src[start..self.pos]);
    }

    fn lexBangEq(self: *Lexer, start: usize) Token {
        self.pos += 1; // '='
        if (self.peek() == '=') {
            self.pos += 1;
            return tok(.sne, self.src[start..self.pos]);
        }
        return tok(.ne, self.src[start..self.pos]);
    }

    fn lexString(self: *Lexer, quote: u8) LexError!Token {
        const start = self.pos;
        self.pos += 1; // opening quote
        var buf: std.ArrayList(u8) = .empty;
        while (self.pos < self.src.len) {
            const ch = self.src[self.pos];
            if (ch == quote) {
                self.pos += 1;
                return .{ .kind = .string, .lexeme = self.src[start..self.pos], .string_value = buf.items };
            }
            if (ch == '\\' and self.pos + 1 < self.src.len) {
                self.pos += 1;
                const esc = self.src[self.pos];
                const decoded: u8 = switch (esc) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '\\' => '\\',
                    '"' => '"',
                    '\'' => '\'',
                    else => esc,
                };
                try buf.append(self.arena, decoded);
                self.pos += 1;
                continue;
            }
            try buf.append(self.arena, ch);
            self.pos += 1;
        }
        return LexError.UnterminatedString;
    }
};

fn tok(kind: TokenKind, lexeme: []const u8) Token {
    return .{ .kind = kind, .lexeme = lexeme };
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}
fn isIdentPart(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}
