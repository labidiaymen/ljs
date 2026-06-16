//! Lexical grammar for the M0 subset (ECMA-262 §12). Hand-rolled scanner producing tokens
//! on demand. Covers numbers, string literals, the `true`/`false`/`null` keywords, and the
//! punctuators the M0 expression grammar needs.
const std = @import("std");
const unicode_id = @import("unicode_id.zig");

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
    kw_do, // do (DoWhileStatement, §14.7.2)
    kw_for,
    kw_throw,
    kw_try,
    kw_catch,
    kw_finally,
    kw_break,
    kw_continue,
    kw_typeof,
    kw_void, // void (UnaryExpression, §13.5.2)
    kw_delete, // delete (UnaryExpression, §13.5.1)
    kw_new,
    kw_instanceof,
    kw_switch,
    kw_case,
    kw_default,
    kw_with, // with (WithStatement, §14.11 — sloppy-only)
    kw_import, // import (modules / dynamic ImportCall — unsupported, parse-rejected)
    kw_class, // class (ClassDeclaration / ClassExpression, §15.7)
    kw_extends, // extends (ClassHeritage, §15.7)
    kw_super, // super (SuperCall / SuperProperty — unsupported, parse-rejected until Cycle 2)
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
    private_identifier, // §12.7 PrivateIdentifier `#name` (only valid inside a class body; §15.7)
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
    /// §12.9.4.1 / Annex B.1.2: the string literal contained a LegacyOctalEscapeSequence,
    /// NonOctalDecimalEscapeSequence (`\8`/`\9`), or a `\0` immediately followed by a decimal digit.
    /// Legal in sloppy mode; a strict-mode Early Error. The lexer cannot know strict-ness (it runs
    /// before the directive prologue / RunMode is resolved), so it flags the token and the parser
    /// rejects it when `self.strict` — mirroring how other strict Early Errors are threaded.
    has_legacy_octal: bool = false,
    /// §12.7.1: the IdentifierName contained a `\uHHHH` / `\u{H…}` UnicodeEscapeSequence. For such an
    /// identifier `lexeme` holds the DECODED StringValue (used for keyword matching + as the name). A
    /// keyword spelled with an escape is NOT a keyword token — it stays `.identifier`/`.private_identifier`.
    /// The §12.7.2 ReservedWord rejection (other than `yield`/`await`) is applied by the PARSER at
    /// Identifier / BindingIdentifier / IdentifierReference positions only (so an escaped reserved word
    /// is still a valid IdentifierName for a property name, e.g. `o.\u{69}f`); see `isEscapedReservedIdent`.
    had_escape: bool = false,
};

pub const LexError = error{ UnexpectedCharacter, UnterminatedString, InvalidEscape, OutOfMemory };

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

        // §12.9.3 NumericLiteral — decimal (int/fraction/exponent), `0x`/`0o`/`0b` radix prefixes, and
        // `_` NumericLiteralSeparators. The value is computed by the parser from `lexeme` (BigInt `n`
        // suffix is not consumed → deferred).
        if (isDigit(c) or (c == '.' and isDigit(self.peek2()))) {
            if (c == '0' and self.pos + 1 < self.src.len and switch (self.src[self.pos + 1]) {
                'x', 'X', 'o', 'O', 'b', 'B' => true,
                else => false,
            }) {
                self.pos += 2; // 0x / 0o / 0b — over-accept hex digits; the parser validates per radix
                while (self.pos < self.src.len and (isHexDigit(self.src[self.pos]) or self.src[self.pos] == '_')) self.pos += 1;
            } else {
                while (self.pos < self.src.len and (isDigit(self.src[self.pos]) or self.src[self.pos] == '_')) self.pos += 1;
                if (self.pos < self.src.len and self.src[self.pos] == '.') {
                    self.pos += 1;
                    while (self.pos < self.src.len and (isDigit(self.src[self.pos]) or self.src[self.pos] == '_')) self.pos += 1;
                }
                if (self.pos < self.src.len and (self.src[self.pos] == 'e' or self.src[self.pos] == 'E')) {
                    self.pos += 1;
                    if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) self.pos += 1;
                    while (self.pos < self.src.len and (isDigit(self.src[self.pos]) or self.src[self.pos] == '_')) self.pos += 1;
                }
            }
            // §12.9.3: the char immediately after a NumericLiteral must not be an IdentifierStart or a
            // digit (a `\` begins a `\u` IdentifierStart escape) — an Early Error (catches `3in`, `0b0a`).
            if (self.pos < self.src.len) {
                const nxt = self.src[self.pos];
                if (isIdentStart(nxt) or nxt == '\\' or isDigit(nxt)) return LexError.UnexpectedCharacter;
            }
            return .{ .kind = .number, .lexeme = self.src[start..self.pos] };
        }

        // Identifiers / keywords. §12.7. An IdentifierName starts with an ASCII IdentifierStart
        // (`$ _ A-Za-z`) or a `\uHHHH` / `\u{H…}` escape whose code point is a valid ID_Start
        // (§12.7.1). The escaped form is scanned by `scanIdentifier`, which decodes + validates and
        // returns whether any escape was present.
        if (isIdentStart(c) or c == '\\') {
            const id = try self.scanIdentifier(start, false);
            const word = id.value;
            // §12.7.1: a keyword spelled with an escape is NOT a keyword token; it is an identifier
            // whose name is the decoded text. The ReservedWord rejection (§12.7.2) is NOT applied here
            // — it belongs to the `Identifier :: IdentifierName but not ReservedWord` production, so an
            // escaped reserved word is still a valid IdentifierName for a *property name* (`o.\u{69}f`,
            // `{ \u{69}f: 1 }`). The parser rejects escaped reserved words only at Identifier /
            // BindingIdentifier / IdentifierReference positions (see `rejectEscapedReserved`).
            if (id.had_escape) return .{ .kind = .identifier, .lexeme = word, .had_escape = true };
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
            if (std.mem.eql(u8, word, "do")) return .{ .kind = .kw_do, .lexeme = word };
            if (std.mem.eql(u8, word, "for")) return .{ .kind = .kw_for, .lexeme = word };
            if (std.mem.eql(u8, word, "throw")) return .{ .kind = .kw_throw, .lexeme = word };
            if (std.mem.eql(u8, word, "try")) return .{ .kind = .kw_try, .lexeme = word };
            if (std.mem.eql(u8, word, "catch")) return .{ .kind = .kw_catch, .lexeme = word };
            if (std.mem.eql(u8, word, "finally")) return .{ .kind = .kw_finally, .lexeme = word };
            if (std.mem.eql(u8, word, "break")) return .{ .kind = .kw_break, .lexeme = word };
            if (std.mem.eql(u8, word, "continue")) return .{ .kind = .kw_continue, .lexeme = word };
            if (std.mem.eql(u8, word, "typeof")) return .{ .kind = .kw_typeof, .lexeme = word };
            if (std.mem.eql(u8, word, "void")) return .{ .kind = .kw_void, .lexeme = word };
            if (std.mem.eql(u8, word, "delete")) return .{ .kind = .kw_delete, .lexeme = word };
            if (std.mem.eql(u8, word, "new")) return .{ .kind = .kw_new, .lexeme = word };
            if (std.mem.eql(u8, word, "instanceof")) return .{ .kind = .kw_instanceof, .lexeme = word };
            if (std.mem.eql(u8, word, "in")) return .{ .kind = .kw_in, .lexeme = word };
            if (std.mem.eql(u8, word, "switch")) return .{ .kind = .kw_switch, .lexeme = word };
            if (std.mem.eql(u8, word, "case")) return .{ .kind = .kw_case, .lexeme = word };
            if (std.mem.eql(u8, word, "default")) return .{ .kind = .kw_default, .lexeme = word };
            if (std.mem.eql(u8, word, "with")) return .{ .kind = .kw_with, .lexeme = word };
            if (std.mem.eql(u8, word, "import")) return .{ .kind = .kw_import, .lexeme = word };
            if (std.mem.eql(u8, word, "class")) return .{ .kind = .kw_class, .lexeme = word };
            if (std.mem.eql(u8, word, "extends")) return .{ .kind = .kw_extends, .lexeme = word };
            if (std.mem.eql(u8, word, "super")) return .{ .kind = .kw_super, .lexeme = word };
            return .{ .kind = .identifier, .lexeme = word };
        }

        // §12.7 PrivateIdentifier `#name` — a `#` immediately followed by an IdentifierName. The
        // lexeme INCLUDES the leading `#` (so `#x` and `x` never collide as map keys). A bare `#`
        // not followed by an identifier start is an UnexpectedCharacter (the parser further restricts
        // private identifiers to class-body member contexts, §15.7).
        if (c == '#') {
            const after = self.peek2();
            if (!isIdentStart(after) and after != '\\') return LexError.UnexpectedCharacter;
            self.pos += 1; // '#'
            const id = try self.scanIdentifier(self.pos, false);
            // §15.7 PrivateName lexeme INCLUDES the leading `#` (so `#x` and `x` never collide). The
            // name part is the (possibly decoded) IdentifierName. An escaped reserved word is still
            // legal as a PrivateName (`#if` is fine), so no reserved-word check here.
            if (id.had_escape) {
                const name = std.mem.concat(self.arena, u8, &.{ "#", id.value }) catch return LexError.OutOfMemory;
                return .{ .kind = .private_identifier, .lexeme = name, .had_escape = true };
            }
            return .{ .kind = .private_identifier, .lexeme = self.src[start..self.pos] };
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
        var has_octal = false;
        while (self.pos < self.src.len) {
            const ch = self.src[self.pos];
            if (ch == quote) {
                self.pos += 1;
                return .{ .kind = .string, .lexeme = self.src[start..self.pos], .string_value = buf.items, .has_legacy_octal = has_octal };
            }
            // §12.9.4 a raw LineTerminator may not appear in a StringLiteral (a LineContinuation needs
            // the leading `\`). LF/CR (and U+2028/U+2029) terminate the literal → unterminated.
            if (ch == '\n' or ch == '\r') return LexError.UnterminatedString;
            if (ch == '\\') {
                try self.decodeEscapeInto(&buf, false, &has_octal);
                continue;
            }
            try buf.append(self.arena, ch);
            self.pos += 1;
        }
        return LexError.UnterminatedString;
    }

    /// §12.9.4.1 / §12.9.6 — decode the single EscapeSequence at `self.pos` (which points at the `\`)
    /// into `buf`, advancing `self.pos` past it. `is_template` selects template semantics (no legacy
    /// octal / `\8` / `\9`; `\0` is the NUL escape). For string literals a LegacyOctalEscapeSequence /
    /// NonOctalDecimalEscape / `\0`-before-a-digit sets `has_octal.*` (a strict-mode Early Error the
    /// parser rejects). Invalid hex / unicode escapes are an `InvalidEscape` LexError (→ SyntaxError).
    fn decodeEscapeInto(self: *Lexer, buf: *std.ArrayList(u8), is_template: bool, has_octal: *bool) LexError!void {
        // self.src[self.pos] == '\\'
        self.pos += 1; // consume the backslash
        if (self.pos >= self.src.len) return LexError.UnterminatedString;
        const esc = self.src[self.pos];
        switch (esc) {
            // §12.9.4.1 LineContinuation — `\` + LineTerminatorSequence produces nothing.
            '\n' => {
                self.pos += 1;
                return;
            },
            '\r' => {
                self.pos += 1;
                if (self.pos < self.src.len and self.src[self.pos] == '\n') self.pos += 1; // CRLF = one LineTerminatorSequence
                return;
            },
            // U+2028 LINE SEPARATOR / U+2029 PARAGRAPH SEPARATOR (UTF-8: E2 80 A8 / E2 80 A9) as a
            // LineContinuation. Detect the 3-byte sequence after the backslash.
            0xE2 => {
                if (self.pos + 2 < self.src.len and self.src[self.pos + 1] == 0x80 and
                    (self.src[self.pos + 2] == 0xA8 or self.src[self.pos + 2] == 0xA9))
                {
                    self.pos += 3;
                    return;
                }
                // otherwise an IdentityEscape of the (multi-byte) character — copy the lead byte and
                // let the loop copy the continuation bytes verbatim.
                try buf.append(self.arena, esc);
                self.pos += 1;
                return;
            },
            // §12.9.4.1 CharacterEscapeSequence (single-char).
            'n' => {
                try buf.append(self.arena, '\n');
                self.pos += 1;
            },
            't' => {
                try buf.append(self.arena, '\t');
                self.pos += 1;
            },
            'r' => {
                try buf.append(self.arena, '\r');
                self.pos += 1;
            },
            'b' => {
                try buf.append(self.arena, 0x08); // BACKSPACE
                self.pos += 1;
            },
            'f' => {
                try buf.append(self.arena, 0x0C); // FORM FEED
                self.pos += 1;
            },
            'v' => {
                try buf.append(self.arena, 0x0B); // LINE TABULATION (vertical tab)
                self.pos += 1;
            },
            // §12.9.4.1 HexEscapeSequence `\xHH` — exactly 2 hex digits. An invalid hex escape is a
            // SyntaxError — in a StringLiteral AND in a TemplateLiteral (§12.9.6: an UNtagged template
            // with an invalid escape IS a SyntaxError; only a TAGGED template would have `cooked =
            // undefined`. ljs does not model per-quasi cooked-undefined for tagged templates, so the
            // rare tagged-template-invalid-escape case is deferred — see spec Out of scope.)
            'x' => {
                self.pos += 1; // past 'x'
                if (self.pos + 1 >= self.src.len) return LexError.InvalidEscape;
                const hi = hexDigit(self.src[self.pos]) orelse return LexError.InvalidEscape;
                const lo = hexDigit(self.src[self.pos + 1]) orelse return LexError.InvalidEscape;
                self.pos += 2;
                try self.encodeCodePoint(buf, @as(u21, hi) * 16 + lo);
            },
            // §12.9.4.1 UnicodeEscapeSequence `\uHHHH` or `\u{H…}` — invalid → SyntaxError (string + template).
            'u' => {
                self.pos += 1; // past 'u'
                const cp = try self.scanUnicodeEscape();
                try self.encodeCodePoint(buf, cp);
            },
            // §12.9.4.1 `\0` (and, Annex B, LegacyOctalEscapeSequence) + NonOctalDecimalEscape.
            '0'...'9' => {
                if (is_template) {
                    // §12.9.6: templates forbid legacy octal / `\8` / `\9`; only `\0` (not followed by a
                    // digit) is the NUL escape. We decode `\0`→NUL leniently and copy others as identity
                    // (the strict `cooked = undefined` refinement is deferred — see spec Out of scope).
                    if (esc == '0' and !(self.pos + 1 < self.src.len and isDigit(self.src[self.pos + 1]))) {
                        try buf.append(self.arena, 0);
                        self.pos += 1;
                        return;
                    }
                    try buf.append(self.arena, esc);
                    self.pos += 1;
                    return;
                }
                // NonOctalDecimalEscapeSequence (Annex B.1.2): `\8` / `\9` → the digit char `8`/`9`.
                if (esc == '8' or esc == '9') {
                    has_octal.* = true;
                    try buf.append(self.arena, esc);
                    self.pos += 1;
                    return;
                }
                // `\0` not followed by a decimal digit → NUL (legal in both modes, no octal flag).
                if (esc == '0' and !(self.pos + 1 < self.src.len and isDigit(self.src[self.pos + 1]))) {
                    try buf.append(self.arena, 0);
                    self.pos += 1;
                    return;
                }
                // LegacyOctalEscapeSequence (Annex B.1.2): 1–3 octal digits, value ≤ 255. The first
                // digit being 0–3 permits 3 digits; 4–7 permits 2. `\0`-before-a-digit lands here too.
                has_octal.* = true;
                var value: u16 = @intCast(esc - '0');
                self.pos += 1;
                const max_more: usize = if (esc <= '3') 2 else 1;
                var count: usize = 0;
                while (count < max_more and self.pos < self.src.len) : (count += 1) {
                    const d = self.src[self.pos];
                    if (d < '0' or d > '7') break;
                    value = value * 8 + (d - '0');
                    self.pos += 1;
                }
                try self.encodeCodePoint(buf, value); // ≤ 0o377 = 255, a single code unit
            },
            // §12.9.4.1 NonEscapeCharacter → IdentityEscape (`\\ \' \" \` \$` and any other char `\c`→`c`).
            else => {
                try buf.append(self.arena, esc);
                self.pos += 1;
            },
        }
    }

    const ScannedIdent = struct { value: []const u8, had_escape: bool };

    /// §12.7 / §12.7.1 — scan an IdentifierName beginning at `from`, supporting `\uHHHH` / `\u{H…}`
    /// UnicodeEscapeSequences at the start and in parts (escapes-only: raw non-ASCII bytes are not
    /// identifier characters here). On entry `self.pos == from`. On return `self.pos` points just past
    /// the last identifier character. The IdentifierStart code point is validated against ID_Start and
    /// every IdentifierPart against ID_Continue (§12.7); a violating escaped code point → SyntaxError.
    /// When no escape is present `value` aliases the source slice (the fast path); otherwise it is the
    /// decoded StringValue, UTF-8-encoded into the arena. `_ = is_private` is reserved for symmetry.
    fn scanIdentifier(self: *Lexer, from: usize, is_private: bool) LexError!ScannedIdent {
        _ = is_private;
        self.pos = from;
        // Fast path: a plain ASCII identifier with no escape. Scan greedily; if we hit a `\` the
        // identifier contained an escape and we restart on the buffered path.
        if (self.pos < self.src.len and isIdentStart(self.src[self.pos])) {
            var p = self.pos + 1;
            while (p < self.src.len and isIdentPart(self.src[p])) p += 1;
            if (p >= self.src.len or self.src[p] != '\\') {
                const slice = self.src[from..p];
                self.pos = p;
                return .{ .value = slice, .had_escape = false };
            }
        }
        // Buffered path: at least one `\u` escape somewhere in the identifier.
        var buf: std.ArrayList(u8) = .empty;
        var first = true;
        while (self.pos < self.src.len) {
            const ch = self.src[self.pos];
            if (ch == '\\') {
                // §12.7.1: only `\` UnicodeEscapeSequence is permitted in an identifier.
                if (self.pos + 1 >= self.src.len or self.src[self.pos + 1] != 'u') return LexError.InvalidEscape;
                self.pos += 2; // consume `\u`
                const cp = try self.scanUnicodeEscape();
                if (first) {
                    if (!unicode_id.isIdStart(cp)) return LexError.UnexpectedCharacter;
                } else {
                    if (!unicode_id.isIdContinue(cp)) return LexError.UnexpectedCharacter;
                }
                try self.encodeCodePoint(&buf, cp);
                first = false;
                continue;
            }
            if (isIdentStart(ch) or (!first and isDigit(ch))) {
                // A raw ASCII identifier character (ID_Start / digit). Append as-is.
                try buf.append(self.arena, ch);
                self.pos += 1;
                first = false;
                continue;
            }
            break;
        }
        if (first) return LexError.UnexpectedCharacter; // empty (e.g. a bare `\` that was not `\u`)
        return .{ .value = buf.items, .had_escape = true };
    }

    /// §12.9.4.1 — parse a UnicodeEscapeSequence body (after the `\u`): `HHHH` (4 hex) or `{H…}`
    /// (1+ hex, code point ≤ 0x10FFFF). Returns the code point. Invalid → InvalidEscape. `self.pos`
    /// points just past the `u`; on return it points past the consumed digits / closing brace.
    fn scanUnicodeEscape(self: *Lexer) LexError!u21 {
        if (self.pos < self.src.len and self.src[self.pos] == '{') {
            self.pos += 1; // '{'
            var value: u32 = 0;
            var any = false;
            while (self.pos < self.src.len and self.src[self.pos] != '}') {
                const d = hexDigit(self.src[self.pos]) orelse return LexError.InvalidEscape;
                value = value * 16 + d;
                if (value > 0x10FFFF) return LexError.InvalidEscape; // CodePoint > 0x10FFFF
                any = true;
                self.pos += 1;
            }
            if (!any) return LexError.InvalidEscape; // `\u{}` empty
            if (self.pos >= self.src.len or self.src[self.pos] != '}') return LexError.InvalidEscape;
            self.pos += 1; // '}'
            return @intCast(value);
        }
        // `\uHHHH` — exactly 4 hex digits.
        if (self.pos + 3 >= self.src.len) return LexError.InvalidEscape;
        var value: u21 = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            const d = hexDigit(self.src[self.pos + i]) orelse return LexError.InvalidEscape;
            value = value * 16 + d;
        }
        self.pos += 4;
        return value;
    }

    /// UTF-8-encode a code point into `buf`. ljs strings are `[]const u8` (UTF-8). Lone surrogates
    /// (0xD800–0xDFFF) — reachable via `\uHHHH` / `\u{D800}` — are not valid UTF-8, so they are
    /// hand-encoded in the 3-byte WTF-8 form (ljs keeps byte strings; see spec Edge Cases).
    fn encodeCodePoint(self: *Lexer, buf: *std.ArrayList(u8), cp: u21) LexError!void {
        if (cp >= 0xD800 and cp <= 0xDFFF) {
            try buf.append(self.arena, @intCast(0xE0 | (cp >> 12)));
            try buf.append(self.arena, @intCast(0x80 | ((cp >> 6) & 0x3F)));
            try buf.append(self.arena, @intCast(0x80 | (cp & 0x3F)));
            return;
        }
        var tmp: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &tmp) catch return LexError.InvalidEscape;
        try buf.appendSlice(self.arena, tmp[0..len]);
    }

    /// Decode every EscapeSequence in `raw` into `buf` (no quotes / backticks). Used by the template
    /// decoder (`is_template = true`). String literals decode inline in `lexString`. Code points are
    /// UTF-8-encoded. (`raw` is the literal text between delimiters; `${…}` is handled by the caller.)
    pub fn decodeEscapesInto(arena: std.mem.Allocator, buf: *std.ArrayList(u8), raw: []const u8, is_template: bool) LexError!void {
        var lx = Lexer.init(arena, raw);
        var ignored_octal = false;
        while (lx.pos < raw.len) {
            const ch = raw[lx.pos];
            if (ch == '\\') {
                try lx.decodeEscapeInto(buf, is_template, &ignored_octal);
                continue;
            }
            try buf.append(arena, ch);
            lx.pos += 1;
        }
    }
};

fn tok(kind: TokenKind, lexeme: []const u8) Token {
    return .{ .kind = kind, .lexeme = lexeme };
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
/// A single hex digit's value, or null if `c` is not `[0-9A-Fa-f]` (§12.9.4.1 HexDigit).
fn hexDigit(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}
fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}
fn isIdentPart(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

/// §12.7.2 ReservedWord — the keywords that may not be the StringValue of an IdentifierName that
/// contained a UnicodeEscapeSequence (§12.7.1). The full set EXCLUDES `yield` and `await` (the
/// §12.7.1 exception: they are contextual and only reserved in certain goal symbols, handled by the
/// parser). `let`/`static`/`async`/`of`/`as`/`get`/`set`/`from`/`yield`/`await` are contextual, not
/// ReservedWords, so they are absent. Includes `enum`, `export`, `import`, `with`, `debugger`, `super`,
/// which the keyword table in `scanToken` does not all cover — hence this dedicated predicate.
pub fn isReservedWord(name: []const u8) bool {
    const words = [_][]const u8{
        "break",    "case",    "catch",  "class",      "const", "continue",
        "debugger", "default", "delete", "do",         "else",  "enum",
        "export",   "extends", "false",  "finally",    "for",   "function",
        "if",       "import",  "in",     "instanceof", "new",   "null",
        "return",   "super",   "switch", "this",       "throw", "true",
        "try",      "typeof",  "var",    "void",       "while", "with",
    };
    for (words) |w| {
        if (std.mem.eql(u8, name, w)) return true;
    }
    return false;
}
