const diag = @import("lumen_diag.zig");

pub const Tok = union(enum) {
    num: i64,
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

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
    }
    fn isIdentPart(c: u8) bool {
        return isIdentStart(c) or (c >= '0' and c <= '9');
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
            break;
        }
        self.tok_line = self.line;
        self.tok_col = @intCast(self.i - self.line_start + 1);
        if (self.i >= self.src.len) return .eof;
        const c = self.src[self.i];

        if (c == '&' or c == '|') {
            if (self.i + 1 >= self.src.len or self.src[self.i + 1] != c) return error.ParseError;
            const s = self.src[self.i .. self.i + 2];
            self.i += 2;
            return .{ .cmp = s };
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
            '+', '-', '*', '/', '%', '?', '(', ')', '[', ']', ';', ',', '.', ':', '{', '}' => {
                self.i += 1;
                return .{ .op = c };
            },
            else => {},
        }
        if (c >= '0' and c <= '9') {
            var v: i64 = 0;
            while (self.i < self.src.len and self.src[self.i] >= '0' and self.src[self.i] <= '9') {
                v = v * 10 + @as(i64, self.src[self.i] - '0');
                self.i += 1;
            }
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
