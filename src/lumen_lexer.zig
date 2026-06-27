const std = @import("std");
const diag = @import("lumen_diag.zig");

pub const Tok = union(enum) {
    num: i64,
    flt: f64, // floating-point literal (e.g. 3.14, 1.5e-2)
    str: []const u8, // string literal content (raw, between quotes)
    op: u8, // + - * / % ! ? ( ) { } ; , . : =
    op2: []const u8, // ++ -- += -= *= /= %=
    cmp: []const u8, // < > <= >= == != && ||
    ident: []const u8,
    eof,
};

pub const Lexer = struct {
    src: []const u8,
    i: usize = 0,
    line: u32 = 1, // current source line
    line_start: usize = 0, // byte index where the current line begins (for column math)
    tok_line: u32 = 1, // line where the most-recently-returned token starts
    tok_col: u32 = 1, // column where that token starts (1-based)
    err_code: ?[]const u8 = null, // diagnostic code for the last lexer error

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
    }
    fn isIdentPart(c: u8) bool {
        return isIdentStart(c) or (c >= '0' and c <= '9');
    }
    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }
    fn isHexDigit(c: u8) bool {
        return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }

    pub fn next(self: *Lexer) diag.CompileError!Tok {
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == '\n') {
                self.line += 1;
                self.i += 1;
                self.line_start = self.i;
                continue;
            }
            if (c == ' ' or c == '\t' or c == '\r') {
                self.i += 1;
                continue;
            }
            if (c == '/' and self.i + 1 < self.src.len and self.src[self.i + 1] == '/') {
                while (self.i < self.src.len and self.src[self.i] != '\n') self.i += 1;
                continue;
            }
            if (c == '/' and self.i + 1 < self.src.len and self.src[self.i + 1] == '*') {
                self.i += 2;
                while (self.i + 1 < self.src.len and !(self.src[self.i] == '*' and self.src[self.i + 1] == '/')) {
                    if (self.src[self.i] == '\n') {
                        self.line += 1;
                        self.line_start = self.i + 1;
                    }
                    self.i += 1;
                }
                if (self.i + 1 >= self.src.len) {
                    self.err_code = "E_UNTERMINATED_COMMENT";
                    return error.ParseError;
                }
                self.i += 2; // consume the closing */
                continue;
            }
            break;
        }
        self.tok_line = self.line;
        self.tok_col = @intCast(self.i - self.line_start + 1);
        if (self.i >= self.src.len) return .eof;
        const c = self.src[self.i];

        if (c == '|') {
            if (self.i + 1 < self.src.len and self.src[self.i + 1] == c) {
                const s = self.src[self.i .. self.i + 2];
                self.i += 2;
                return .{ .cmp = s };
            }
            const s = self.src[self.i .. self.i + 1];
            self.i += 1;
            return .{ .cmp = s };
        }
        if (c == '&') {
            if (self.i + 1 < self.src.len and self.src[self.i + 1] == '&') {
                const s = self.src[self.i .. self.i + 2];
                self.i += 2;
                return .{ .cmp = s };
            }
            self.i += 1;
            return .{ .op = '&' }; // bitwise and
        }
        if ((c == '+' or c == '-' or c == '*' or c == '/' or c == '%') and self.i + 1 < self.src.len and self.src[self.i + 1] == '=') {
            const s = self.src[self.i .. self.i + 2];
            self.i += 2;
            return .{ .op2 = s };
        }
        if ((c == '+' or c == '-') and self.i + 1 < self.src.len and self.src[self.i + 1] == c) {
            const s = self.src[self.i .. self.i + 2];
            self.i += 2;
            return .{ .op2 = s };
        }
        // `**` exponent and `<<`/`>>` shifts are two-char operator tokens.
        if (c == '*' and self.i + 1 < self.src.len and self.src[self.i + 1] == '*') {
            const s = self.src[self.i .. self.i + 2];
            self.i += 2;
            return .{ .op2 = s };
        }
        if ((c == '<' or c == '>') and self.i + 1 < self.src.len and self.src[self.i + 1] == c) {
            const s = self.src[self.i .. self.i + 2];
            self.i += 2;
            return .{ .op2 = s };
        }
        // `??` nullish coalescing and `?.` optional chaining.
        if (c == '?' and self.i + 1 < self.src.len and (self.src[self.i + 1] == '?' or self.src[self.i + 1] == '.')) {
            const s = self.src[self.i .. self.i + 2];
            self.i += 2;
            return .{ .op2 = s };
        }
        if (c == '<' or c == '>' or c == '=' or c == '!') {
            const two = self.i + 1 < self.src.len and self.src[self.i + 1] == '=';
            if (c == '=' and !two) {
                self.i += 1;
                return .{ .op = '=' };
            }
            if (c == '!' and !two) {
                self.i += 1;
                return .{ .op = '!' };
            }
            // Strict equality `===`/`!==` lowers to the same comparison as `==`/`!=`;
            // statically typed operands make loose and strict equality identical.
            if ((c == '=' or c == '!') and two and self.i + 2 < self.src.len and self.src[self.i + 2] == '=') {
                self.i += 3;
                return .{ .cmp = if (c == '=') "==" else "!=" };
            }
            if (two) {
                const s = self.src[self.i .. self.i + 2];
                self.i += 2;
                return .{ .cmp = s };
            }
            const s = self.src[self.i .. self.i + 1];
            self.i += 1;
            return .{ .cmp = s };
        }
        if (c == '"') {
            self.i += 1;
            const start = self.i;
            while (self.i < self.src.len and self.src[self.i] != '"') {
                if (self.src[self.i] == '\\' and self.i + 1 < self.src.len) self.i += 1;
                self.i += 1;
            }
            const s = self.src[start..self.i];
            if (self.i < self.src.len) self.i += 1;
            return .{ .str = s };
        }
        switch (c) {
            '+', '-', '*', '/', '%', '?', '(', ')', '[', ']', ';', ',', '.', ':', '{', '}', '^', '~' => {
                self.i += 1;
                return .{ .op = c };
            },
            else => {},
        }
        if (isDigit(c)) {
            const start = self.i;
            // Non-decimal integer bases: 0x / 0o / 0b. `parseInt(_, _, 0)` detects
            // the base from the prefix and accepts `_` digit separators.
            if (c == '0' and self.i + 1 < self.src.len) {
                const p = self.src[self.i + 1];
                if (p == 'x' or p == 'X' or p == 'o' or p == 'O' or p == 'b' or p == 'B') {
                    self.i += 2;
                    const digits_start = self.i;
                    while (self.i < self.src.len and (isHexDigit(self.src[self.i]) or self.src[self.i] == '_')) self.i += 1;
                    if (self.i == digits_start) {
                        self.err_code = "E_INVALID_NUMBER";
                        return error.ParseError;
                    }
                    const text = self.src[start..self.i];
                    const v = std.fmt.parseInt(i64, text, 0) catch {
                        self.err_code = "E_INVALID_NUMBER";
                        return error.ParseError;
                    };
                    return .{ .num = v };
                }
            }
            // Decimal integer or float. `_` separators are permitted between digits;
            // `parseInt`/`parseFloat` validate separator placement.
            var is_float = false;
            while (self.i < self.src.len and (isDigit(self.src[self.i]) or self.src[self.i] == '_')) self.i += 1;
            // fractional part: only treat `.` as a decimal point when a digit follows,
            // so member access like `arr.length` is untouched.
            if (self.i + 1 < self.src.len and self.src[self.i] == '.' and isDigit(self.src[self.i + 1])) {
                is_float = true;
                self.i += 1; // consume '.'
                while (self.i < self.src.len and (isDigit(self.src[self.i]) or self.src[self.i] == '_')) self.i += 1;
            }
            // exponent part
            if (self.i < self.src.len and (self.src[self.i] == 'e' or self.src[self.i] == 'E')) {
                is_float = true;
                self.i += 1;
                if (self.i < self.src.len and (self.src[self.i] == '+' or self.src[self.i] == '-')) self.i += 1;
                while (self.i < self.src.len and (isDigit(self.src[self.i]) or self.src[self.i] == '_')) self.i += 1;
            }
            const text = self.src[start..self.i];
            if (is_float) {
                const f = std.fmt.parseFloat(f64, text) catch {
                    self.err_code = "E_INVALID_NUMBER";
                    return error.ParseError;
                };
                return .{ .flt = f };
            }
            const v = std.fmt.parseInt(i64, text, 10) catch {
                self.err_code = "E_INVALID_NUMBER";
                return error.ParseError;
            };
            return .{ .num = v };
        }
        if (isIdentStart(c)) {
            const start = self.i;
            while (self.i < self.src.len and isIdentPart(self.src[self.i])) self.i += 1;
            return .{ .ident = self.src[start..self.i] };
        }
        return error.ParseError;
    }
};
