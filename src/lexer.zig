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
    kw_var,
    kw_let,
    kw_const,
    kw_function,
    kw_return,
    kw_this,
    kw_if,
    kw_else,
    kw_while,
    kw_for,
    kw_throw,
    kw_try,
    kw_catch,
    kw_finally,
    kw_break,
    kw_continue,
    kw_typeof,
    kw_new,
    kw_instanceof,
    kw_switch,
    kw_case,
    kw_default,
    kw_import, // import (modules / dynamic ImportCall — unsupported, parse-rejected)
    kw_class, // class (ClassDeclaration / ClassExpression — unsupported, parse-rejected)
    kw_super, // super (SuperCall / SuperProperty — unsupported, parse-rejected)
    pipe_pipe, // ||
    amp_amp, // &&
    star_star, // **
    bit_and, // &
    bit_or, // |
    bit_xor, // ^
    bit_not, // ~
    shl, // <<
    shr, // >>
    shr_un, // >>>
    template, // `...${}...` (raw inner stored in string_value)
    ellipsis, // ...
    fat_arrow, // => (ArrowFunction, §15.3)
    kw_in, // in
    plus_plus, // ++
    minus_minus, // --
    question, // ?
    question_dot, // ?. (optional chaining, §13.3.9 — NOT before a digit)
    question_question, // ?? (nullish coalescing, §13.13)
    plus_assign, // +=
    minus_assign, // -=
    star_assign, // *=
    slash_assign, // /=
    percent_assign, // %=
    star_star_assign, // **= (§13.15)
    shl_assign, // <<=
    shr_assign, // >>=
    shr_un_assign, // >>>=
    amp_assign, // &=
    pipe_assign, // |=
    caret_assign, // ^=
    amp_amp_assign, // &&= (§13.15.2 logical assignment, short-circuit)
    pipe_pipe_assign, // ||=
    question_question_assign, // ??=
    identifier,
    plus,
    minus,
    star,
    slash,
    percent,
    bang,
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    dot,
    colon,
    comma,
    assign, // =
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
    /// §12.3: a LineTerminator appeared in the trivia immediately before this token. Needed for
    /// the restricted productions (ASI, and the `[no LineTerminator here]` arrow `=>`, §15.3.1).
    newline_before: bool = false,
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

    // §12.2 White Space / §12.3 Line Terminators / §12.4 Comments. Returns true iff a
    // LineTerminator was skipped (so `next` can flag the following token for restricted productions).
    fn skipTrivia(self: *Lexer) bool {
        var saw_newline = false;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                if (c == '\n' or c == '\r') saw_newline = true;
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
                        !(self.src[self.pos] == '*' and self.src[self.pos + 1] == '/')) : (self.pos += 1)
                    {
                        // §12.3: a multi-line comment containing a LineTerminator counts as one.
                        if (self.src[self.pos] == '\n' or self.src[self.pos] == '\r') saw_newline = true;
                    }
                    self.pos = @min(self.pos + 2, self.src.len);
                    continue;
                }
            }
            break;
        }
        return saw_newline;
    }

    /// §12.1 — produce the next token, flagging it if a LineTerminator preceded it (§12.3).
    pub fn next(self: *Lexer) LexError!Token {
        const nl = self.skipTrivia();
        var t = try self.scanToken();
        t.newline_before = nl;
        return t;
    }

    fn scanToken(self: *Lexer) LexError!Token {
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
            if (std.mem.eql(u8, word, "var")) return .{ .kind = .kw_var, .lexeme = word };
            if (std.mem.eql(u8, word, "let")) return .{ .kind = .kw_let, .lexeme = word };
            if (std.mem.eql(u8, word, "const")) return .{ .kind = .kw_const, .lexeme = word };
            if (std.mem.eql(u8, word, "function")) return .{ .kind = .kw_function, .lexeme = word };
            if (std.mem.eql(u8, word, "return")) return .{ .kind = .kw_return, .lexeme = word };
            if (std.mem.eql(u8, word, "this")) return .{ .kind = .kw_this, .lexeme = word };
            if (std.mem.eql(u8, word, "if")) return .{ .kind = .kw_if, .lexeme = word };
            if (std.mem.eql(u8, word, "else")) return .{ .kind = .kw_else, .lexeme = word };
            if (std.mem.eql(u8, word, "while")) return .{ .kind = .kw_while, .lexeme = word };
            if (std.mem.eql(u8, word, "for")) return .{ .kind = .kw_for, .lexeme = word };
            if (std.mem.eql(u8, word, "throw")) return .{ .kind = .kw_throw, .lexeme = word };
            if (std.mem.eql(u8, word, "try")) return .{ .kind = .kw_try, .lexeme = word };
            if (std.mem.eql(u8, word, "catch")) return .{ .kind = .kw_catch, .lexeme = word };
            if (std.mem.eql(u8, word, "finally")) return .{ .kind = .kw_finally, .lexeme = word };
            if (std.mem.eql(u8, word, "break")) return .{ .kind = .kw_break, .lexeme = word };
            if (std.mem.eql(u8, word, "continue")) return .{ .kind = .kw_continue, .lexeme = word };
            if (std.mem.eql(u8, word, "typeof")) return .{ .kind = .kw_typeof, .lexeme = word };
            if (std.mem.eql(u8, word, "new")) return .{ .kind = .kw_new, .lexeme = word };
            if (std.mem.eql(u8, word, "instanceof")) return .{ .kind = .kw_instanceof, .lexeme = word };
            if (std.mem.eql(u8, word, "in")) return .{ .kind = .kw_in, .lexeme = word };
            if (std.mem.eql(u8, word, "switch")) return .{ .kind = .kw_switch, .lexeme = word };
            if (std.mem.eql(u8, word, "case")) return .{ .kind = .kw_case, .lexeme = word };
            if (std.mem.eql(u8, word, "default")) return .{ .kind = .kw_default, .lexeme = word };
            if (std.mem.eql(u8, word, "import")) return .{ .kind = .kw_import, .lexeme = word };
            if (std.mem.eql(u8, word, "class")) return .{ .kind = .kw_class, .lexeme = word };
            if (std.mem.eql(u8, word, "super")) return .{ .kind = .kw_super, .lexeme = word };
            return .{ .kind = .identifier, .lexeme = word };
        }

        // String literals. §12.9.4 (subset: no escapes beyond the basics).
        if (c == '"' or c == '\'') return self.lexString(c);

        // Template literals. §12.9.6 — capture the raw inner text; the parser splits quasis/exprs.
        if (c == '`') return self.lexTemplate();

        // Punctuators.
        self.pos += 1;
        switch (c) {
            '+' => {
                if (self.peek() == '+') {
                    self.pos += 1;
                    return tok(.plus_plus, self.src[start..self.pos]);
                }
                return self.maybeCompound(.plus, .plus_assign, start);
            },
            '-' => {
                if (self.peek() == '-') {
                    self.pos += 1;
                    return tok(.minus_minus, self.src[start..self.pos]);
                }
                return self.maybeCompound(.minus, .minus_assign, start);
            },
            '*' => {
                if (self.peek() == '*') {
                    self.pos += 1;
                    // §13.15: `**=` (maximal munch — before `**`).
                    if (self.peek() == '=') {
                        self.pos += 1;
                        return tok(.star_star_assign, self.src[start..self.pos]);
                    }
                    return tok(.star_star, self.src[start..self.pos]);
                }
                return self.maybeCompound(.star, .star_assign, start);
            },
            '/' => return self.maybeCompound(.slash, .slash_assign, start),
            '%' => return self.maybeCompound(.percent, .percent_assign, start),
            '?' => {
                // §13.13 nullish coalescing `??` / §13.15.2 logical assignment `??=`
                // (maximal munch — `??=` before `??`).
                if (self.peek() == '?') {
                    self.pos += 1;
                    if (self.peek() == '=') {
                        self.pos += 1;
                        return tok(.question_question_assign, self.src[start..self.pos]);
                    }
                    return tok(.question_question, self.src[start..self.pos]);
                }
                // §13.3.9 optional chaining `?.` — but `?.` followed by a decimal digit is the
                // conditional `?` then a number (e.g. `a ? .5 : b`), so only consume `.` here when
                // the char after it is NOT a digit (§12.10 punctuator lookahead).
                if (self.peek() == '.' and !isDigit(self.peek2())) {
                    self.pos += 1;
                    return tok(.question_dot, self.src[start..self.pos]);
                }
                return tok(.question, self.src[start..self.pos]);
            },
            '(' => return tok(.lparen, self.src[start..self.pos]),
            ')' => return tok(.rparen, self.src[start..self.pos]),
            '{' => return tok(.lbrace, self.src[start..self.pos]),
            '}' => return tok(.rbrace, self.src[start..self.pos]),
            '[' => return tok(.lbracket, self.src[start..self.pos]),
            ']' => return tok(.rbracket, self.src[start..self.pos]),
            '.' => {
                if (self.peek() == '.' and self.peek2() == '.') {
                    self.pos += 2;
                    return tok(.ellipsis, self.src[start..self.pos]);
                }
                return tok(.dot, self.src[start..self.pos]);
            },
            ':' => return tok(.colon, self.src[start..self.pos]),
            ',' => return tok(.comma, self.src[start..self.pos]),
            ';' => return tok(.semicolon, self.src[start..self.pos]),
            '<' => {
                if (self.peek() == '<') {
                    self.pos += 1;
                    // §13.15: `<<=` (maximal munch — before `<<`).
                    if (self.peek() == '=') {
                        self.pos += 1;
                        return tok(.shl_assign, self.src[start..self.pos]);
                    }
                    return tok(.shl, self.src[start..self.pos]);
                }
                return self.maybeEq(.lt, .le, start);
            },
            '>' => {
                if (self.peek() == '>') {
                    self.pos += 1;
                    if (self.peek() == '>') {
                        self.pos += 1;
                        // §13.15: `>>>=` (maximal munch — before `>>>`).
                        if (self.peek() == '=') {
                            self.pos += 1;
                            return tok(.shr_un_assign, self.src[start..self.pos]);
                        }
                        return tok(.shr_un, self.src[start..self.pos]);
                    }
                    // §13.15: `>>=` (maximal munch — before `>>`).
                    if (self.peek() == '=') {
                        self.pos += 1;
                        return tok(.shr_assign, self.src[start..self.pos]);
                    }
                    return tok(.shr, self.src[start..self.pos]);
                }
                return self.maybeEq(.gt, .ge, start);
            },
            '!' => {
                if (self.peek() == '=') return self.lexBangEq(start);
                return tok(.bang, self.src[start..self.pos]);
            },
            '=' => {
                if (self.peek() == '=') return self.lexEqEq(start);
                if (self.peek() == '>') { // §15.3 ArrowFunction `=>`
                    self.pos += 1;
                    return tok(.fat_arrow, self.src[start..self.pos]);
                }
                return tok(.assign, self.src[start..self.pos]);
            },
            '|' => {
                if (self.peek() == '|') {
                    self.pos += 1;
                    // §13.15.2: `||=` (maximal munch — before `||`).
                    if (self.peek() == '=') {
                        self.pos += 1;
                        return tok(.pipe_pipe_assign, self.src[start..self.pos]);
                    }
                    return tok(.pipe_pipe, self.src[start..self.pos]);
                }
                // §13.15: `|=` (before `|`).
                return self.maybeCompound(.bit_or, .pipe_assign, start);
            },
            '&' => {
                if (self.peek() == '&') {
                    self.pos += 1;
                    // §13.15.2: `&&=` (maximal munch — before `&&`).
                    if (self.peek() == '=') {
                        self.pos += 1;
                        return tok(.amp_amp_assign, self.src[start..self.pos]);
                    }
                    return tok(.amp_amp, self.src[start..self.pos]);
                }
                // §13.15: `&=` (before `&`).
                return self.maybeCompound(.bit_and, .amp_assign, start);
            },
            '^' => return self.maybeCompound(.bit_xor, .caret_assign, start), // §13.15 `^=`
            '~' => return tok(.bit_not, self.src[start..self.pos]),
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

    /// `op` or `op=` (compound assignment).
    fn maybeCompound(self: *Lexer, base: TokenKind, with_eq: TokenKind, start: usize) Token {
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

    /// Scan a template literal; returns its raw inner text (between backticks) in `string_value`.
    /// `${...}` substitutions are kept raw (brace-depth tracked so a `}` inside an expr doesn't
    /// end the template); the parser splits quasis from expression sources.
    fn lexTemplate(self: *Lexer) LexError!Token {
        self.pos += 1; // opening backtick
        const start = self.pos;
        var depth: usize = 0;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\\' and self.pos + 1 < self.src.len) {
                self.pos += 2;
                continue;
            }
            if (c == '$' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '{') {
                depth += 1;
                self.pos += 2;
                continue;
            }
            if (c == '}' and depth > 0) {
                depth -= 1;
                self.pos += 1;
                continue;
            }
            if (c == '`' and depth == 0) {
                const inner = self.src[start..self.pos];
                self.pos += 1; // closing backtick
                return .{ .kind = .template, .lexeme = inner, .string_value = inner };
            }
            self.pos += 1;
        }
        return LexError.UnterminatedString;
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
