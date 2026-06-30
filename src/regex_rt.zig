// Regex runtime for Lumen-compiled programs. A small backtracking engine over a
// practical subset of JS regex: literals, `.`, classes `[...]` with ranges and
// `\d \w \s` (and negations), quantifiers `* + ? {n,m}` (greedy), anchors `^ $`,
// groups `( )`, alternation `|`, escapes, and the `i` flag.
//
// This file is BOTH a standalone, `zig test`-able module AND embedded verbatim
// into generated programs (see lumen_compiler.zig). It therefore avoids clashing
// with the generated program's `std` by aliasing it as `__re_std`, and prefixes
// all public symbols with `__lumen_re_`.
const __re_std = @import("std");

// Everything lives inside one namespaced struct so that embedding this file into
// a generated program adds exactly one top-level name (`__lumen_regex`) and can
// never clash with a user's type/function names.
pub const __lumen_regex = struct {
    pub const Range = struct { lo: u8, hi: u8 };

    const digit_ranges = [_]Range{.{ .lo = '0', .hi = '9' }};
    const word_ranges = [_]Range{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = 'a', .hi = 'z' }, .{ .lo = '_', .hi = '_' } };
    const space_ranges = [_]Range{ .{ .lo = ' ', .hi = ' ' }, .{ .lo = 9, .hi = 13 } };

    pub const Class = struct { negated: bool, ranges: []const Range };

    pub const Node = union(enum) {
        empty,
        char: u8,
        any,
        class: Class,
        astart,
        aend,
        concat: []const *Node,
        alt: []const *Node,
        star: *Node,
        plus: *Node,
        quest: *Node,
    };

    const ParseError = error{ OutOfMemory, BadPattern };

    const Parser = struct {
        s: []const u8,
        i: usize = 0,
        a: __re_std.mem.Allocator,

        fn peek(self: *Parser) ?u8 {
            return if (self.i < self.s.len) self.s[self.i] else null;
        }

        fn mk(self: *Parser, n: Node) ParseError!*Node {
            const p = try self.a.create(Node);
            p.* = n;
            return p;
        }

        // alt := concat ('|' concat)*
        fn parseAlt(self: *Parser) ParseError!*Node {
            var alts: __re_std.ArrayListUnmanaged(*Node) = .empty;
            try alts.append(self.a, try self.parseConcat());
            while (self.peek() == '|') {
                self.i += 1;
                try alts.append(self.a, try self.parseConcat());
            }
            if (alts.items.len == 1) return alts.items[0];
            return self.mk(.{ .alt = alts.items });
        }

        // concat := quant*
        fn parseConcat(self: *Parser) ParseError!*Node {
            var items: __re_std.ArrayListUnmanaged(*Node) = .empty;
            while (self.peek()) |c| {
                if (c == '|' or c == ')') break;
                try items.append(self.a, try self.parseQuant());
            }
            if (items.items.len == 0) return self.mk(.empty);
            if (items.items.len == 1) return items.items[0];
            return self.mk(.{ .concat = items.items });
        }

        // quant := atom ('*' | '+' | '?' | '{n,m}')*
        fn parseQuant(self: *Parser) ParseError!*Node {
            var node = try self.parseAtom();
            while (self.peek()) |c| {
                switch (c) {
                    '*' => {
                        self.i += 1;
                        node = try self.mk(.{ .star = node });
                    },
                    '+' => {
                        self.i += 1;
                        node = try self.mk(.{ .plus = node });
                    },
                    '?' => {
                        self.i += 1;
                        node = try self.mk(.{ .quest = node });
                    },
                    '{' => {
                        const saved = self.i;
                        node = self.parseRepeat(node) catch |e| switch (e) {
                            error.BadPattern => blk: {
                                // Not a valid `{n,m}`; treat `{` as a literal.
                                self.i = saved;
                                break :blk node;
                            },
                            else => return e,
                        };
                        if (self.i == saved) break; // `{` was literal; stop quantifiers
                    },
                    else => break,
                }
            }
            return node;
        }

        // Desugars `x{n,m}` into a concat of copies plus optional/star tail.
        fn parseRepeat(self: *Parser, inner: *Node) ParseError!*Node {
            __re_std.debug.assert(self.s[self.i] == '{');
            var j = self.i + 1;
            const min = try readInt(self.s, &j);
            var has_max = true;
            var max: u32 = min;
            if (j < self.s.len and self.s[j] == ',') {
                j += 1;
                if (j < self.s.len and self.s[j] == '}') {
                    has_max = false;
                } else {
                    max = try readInt(self.s, &j);
                }
            }
            if (j >= self.s.len or self.s[j] != '}') return error.BadPattern;
            if (has_max and max < min) return error.BadPattern;
            self.i = j + 1;
            var items: __re_std.ArrayListUnmanaged(*Node) = .empty;
            var k: u32 = 0;
            while (k < min) : (k += 1) try items.append(self.a, inner);
            if (has_max) {
                var q = min;
                while (q < max) : (q += 1) try items.append(self.a, try self.mk(.{ .quest = inner }));
            } else {
                try items.append(self.a, try self.mk(.{ .star = inner }));
            }
            if (items.items.len == 0) return self.mk(.empty);
            if (items.items.len == 1) return items.items[0];
            return self.mk(.{ .concat = items.items });
        }

        fn parseAtom(self: *Parser) ParseError!*Node {
            const c = self.peek() orelse return self.mk(.empty);
            switch (c) {
                '(' => {
                    self.i += 1;
                    // Non-capturing group prefix `(?:` is accepted and ignored.
                    if (self.i + 1 < self.s.len and self.s[self.i] == '?' and self.s[self.i + 1] == ':') self.i += 2;
                    const inner = try self.parseAlt();
                    if (self.peek() != ')') return error.BadPattern;
                    self.i += 1;
                    return inner;
                },
                '[' => return self.parseClass(),
                '.' => {
                    self.i += 1;
                    return self.mk(.any);
                },
                '^' => {
                    self.i += 1;
                    return self.mk(.astart);
                },
                '$' => {
                    self.i += 1;
                    return self.mk(.aend);
                },
                '\\' => {
                    self.i += 1;
                    if (self.i >= self.s.len) return error.BadPattern;
                    const e = self.s[self.i];
                    self.i += 1;
                    return switch (e) {
                        'd' => self.mk(.{ .class = .{ .negated = false, .ranges = &digit_ranges } }),
                        'D' => self.mk(.{ .class = .{ .negated = true, .ranges = &digit_ranges } }),
                        'w' => self.mk(.{ .class = .{ .negated = false, .ranges = &word_ranges } }),
                        'W' => self.mk(.{ .class = .{ .negated = true, .ranges = &word_ranges } }),
                        's' => self.mk(.{ .class = .{ .negated = false, .ranges = &space_ranges } }),
                        'S' => self.mk(.{ .class = .{ .negated = true, .ranges = &space_ranges } }),
                        'n' => self.mk(.{ .char = '\n' }),
                        't' => self.mk(.{ .char = '\t' }),
                        'r' => self.mk(.{ .char = '\r' }),
                        else => self.mk(.{ .char = e }),
                    };
                },
                else => {
                    self.i += 1;
                    return self.mk(.{ .char = c });
                },
            }
        }

        fn parseClass(self: *Parser) ParseError!*Node {
            self.i += 1; // consume '['
            var negated = false;
            if (self.peek() == '^') {
                negated = true;
                self.i += 1;
            }
            var ranges: __re_std.ArrayListUnmanaged(Range) = .empty;
            while (self.peek()) |c| {
                if (c == ']') {
                    self.i += 1;
                    return self.mk(.{ .class = .{ .negated = negated, .ranges = ranges.items } });
                }
                var lo: u8 = c;
                if (c == '\\' and self.i + 1 < self.s.len) {
                    self.i += 1;
                    const e = self.s[self.i];
                    self.i += 1;
                    switch (e) {
                        'd' => {
                            try ranges.appendSlice(self.a, &digit_ranges);
                            continue;
                        },
                        'w' => {
                            try ranges.appendSlice(self.a, &word_ranges);
                            continue;
                        },
                        's' => {
                            try ranges.appendSlice(self.a, &space_ranges);
                            continue;
                        },
                        'n' => lo = '\n',
                        't' => lo = '\t',
                        'r' => lo = '\r',
                        else => lo = e,
                    }
                } else {
                    self.i += 1;
                }
                // Range `a-z` when a '-' followed by a non-']' char comes next.
                if (self.peek() == '-' and self.i + 1 < self.s.len and self.s[self.i + 1] != ']') {
                    self.i += 1; // consume '-'
                    var hi: u8 = self.s[self.i];
                    if (hi == '\\' and self.i + 1 < self.s.len) {
                        self.i += 1;
                        hi = self.s[self.i];
                    }
                    self.i += 1;
                    try ranges.append(self.a, .{ .lo = lo, .hi = hi });
                } else {
                    try ranges.append(self.a, .{ .lo = lo, .hi = lo });
                }
            }
            return error.BadPattern; // unterminated class
        }
    };

    fn readInt(s: []const u8, j: *usize) ParseError!u32 {
        const start = j.*;
        var v: u32 = 0;
        while (j.* < s.len and s[j.*] >= '0' and s[j.*] <= '9') : (j.* += 1) {
            v = v * 10 + (s[j.*] - '0');
        }
        if (j.* == start) return error.BadPattern;
        return v;
    }

    // --- bytecode ---

    const Inst = union(enum) {
        char: u8,
        any,
        class: Class,
        match,
        jmp: usize,
        split: struct { x: usize, y: usize },
        astart,
        aend,
    };

    const Prog = __re_std.ArrayListUnmanaged(Inst);

    fn emit(prog: *Prog, a: __re_std.mem.Allocator, inst: Inst) ParseError!usize {
        try prog.append(a, inst);
        return prog.items.len - 1;
    }

    fn compile(node: *const Node, prog: *Prog, a: __re_std.mem.Allocator) ParseError!void {
        switch (node.*) {
            .empty => {},
            .char => |c| _ = try emit(prog, a, .{ .char = c }),
            .any => _ = try emit(prog, a, .any),
            .class => |cl| _ = try emit(prog, a, .{ .class = cl }),
            .astart => _ = try emit(prog, a, .astart),
            .aend => _ = try emit(prog, a, .aend),
            .concat => |items| for (items) |it| try compile(it, prog, a),
            .alt => |alts| {
                var jmps: __re_std.ArrayListUnmanaged(usize) = .empty;
                for (alts, 0..) |alt, idx| {
                    if (idx + 1 < alts.len) {
                        const sp = try emit(prog, a, .{ .split = .{ .x = prog.items.len + 1, .y = 0 } });
                        try compile(alt, prog, a);
                        try jmps.append(a, try emit(prog, a, .{ .jmp = 0 }));
                        prog.items[sp].split.y = prog.items.len;
                    } else {
                        try compile(alt, prog, a);
                    }
                }
                for (jmps.items) |jp| prog.items[jp].jmp = prog.items.len;
            },
            .star => |inner| {
                const l1 = try emit(prog, a, .{ .split = .{ .x = 0, .y = 0 } });
                prog.items[l1].split.x = prog.items.len;
                try compile(inner, prog, a);
                _ = try emit(prog, a, .{ .jmp = l1 });
                prog.items[l1].split.y = prog.items.len;
            },
            .plus => |inner| {
                const l1 = prog.items.len;
                try compile(inner, prog, a);
                _ = try emit(prog, a, .{ .split = .{ .x = l1, .y = prog.items.len + 1 } });
            },
            .quest => |inner| {
                const sp = try emit(prog, a, .{ .split = .{ .x = prog.items.len + 1, .y = 0 } });
                try compile(inner, prog, a);
                prog.items[sp].split.y = prog.items.len;
            },
        }
    }

    fn lower(c: u8) u8 {
        return if (c >= 'A' and c <= 'Z') c + 32 else c;
    }

    fn chEq(a: u8, b: u8, ci: bool) bool {
        return if (ci) lower(a) == lower(b) else a == b;
    }

    fn inRanges(ranges: []const Range, ch: u8) bool {
        for (ranges) |r| if (ch >= r.lo and ch <= r.hi) return true;
        return false;
    }

    fn classMatch(cl: Class, ch: u8, ci: bool) bool {
        var hit = inRanges(cl.ranges, ch);
        if (!hit and ci) {
            const swapped: u8 = if (ch >= 'a' and ch <= 'z') ch - 32 else if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
            if (swapped != ch) hit = inRanges(cl.ranges, swapped);
        }
        return hit != cl.negated;
    }

    // Backtracking VM: does prog match `text` starting at `sp`?
    fn run(prog: []const Inst, pc0: usize, text: []const u8, sp0: usize, ci: bool) bool {
        var pc = pc0;
        var sp = sp0;
        while (true) {
            switch (prog[pc]) {
                .match => return true,
                .char => |c| {
                    if (sp < text.len and chEq(text[sp], c, ci)) {
                        pc += 1;
                        sp += 1;
                    } else return false;
                },
                .any => {
                    if (sp < text.len and text[sp] != '\n') {
                        pc += 1;
                        sp += 1;
                    } else return false;
                },
                .class => |cl| {
                    if (sp < text.len and classMatch(cl, text[sp], ci)) {
                        pc += 1;
                        sp += 1;
                    } else return false;
                },
                .astart => {
                    if (sp == 0) pc += 1 else return false;
                },
                .aend => {
                    if (sp == text.len) pc += 1 else return false;
                },
                .jmp => |x| pc = x,
                .split => |s| {
                    if (run(prog, s.x, text, sp, ci)) return true;
                    pc = s.y;
                },
            }
        }
    }

    /// Parses `pattern` into its AST (used by the compiler at build time to decide
    /// whether a literal can be specialized into straight-line code). Null if the
    /// pattern is malformed.
    pub fn parse(a: __re_std.mem.Allocator, pattern: []const u8) ?*Node {
        var parser = Parser{ .s = pattern, .a = a };
        const ast = parser.parseAlt() catch return null;
        if (parser.i != pattern.len) return null;
        return ast;
    }

    /// A compiled regex: the bytecode program plus the case-insensitive flag. A
    /// regex literal is a constant, so this is built once and reused across matches.
    pub const Compiled = struct { prog: []const Inst, ci: bool };

    /// Compiles `pattern`/`flags` into reusable bytecode (allocated in `a`). Returns
    /// null on a malformed pattern.
    pub fn compilePattern(a: __re_std.mem.Allocator, pattern: []const u8, flags: []const u8) ?Compiled {
        var parser = Parser{ .s = pattern, .a = a };
        const ast = parser.parseAlt() catch return null;
        if (parser.i != pattern.len) return null; // trailing junk (e.g. stray ')')
        var prog: Prog = .empty;
        compile(ast, &prog, a) catch return null;
        _ = emit(&prog, a, .match) catch return null;
        var ci = false;
        for (flags) |f| {
            if (f == 'i') ci = true;
        }
        return .{ .prog = prog.items, .ci = ci };
    }

    /// Does the compiled regex match anywhere in `input` (JS `RegExp.test`)?
    pub fn matchOne(c: Compiled, input: []const u8) bool {
        var start: usize = 0;
        while (start <= input.len) : (start += 1) {
            if (run(c.prog, 0, input, start, c.ci)) return true;
        }
        return false;
    }

    /// Compile-and-match in one call (recompiles each time; for one-shot use).
    pub fn search(pattern: []const u8, flags: []const u8, input: []const u8) bool {
        var arena = __re_std.heap.ArenaAllocator.init(__re_std.heap.page_allocator);
        defer arena.deinit();
        const c = compilePattern(arena.allocator(), pattern, flags) orelse return false;
        return matchOne(c, input);
    }
};

test "regex engine: literals, anchors, quantifiers, classes, alternation, flags" {
    const t = __re_std.testing;
    const S = __lumen_regex.search;
    // literals + unanchored search
    try t.expect(S("abc", "", "xabcy"));
    try t.expect(!S("abc", "", "abx"));
    // quantifiers
    try t.expect(S("ab+c", "", "xabbbc"));
    try t.expect(!S("ab+c", "", "ac"));
    try t.expect(S("ab*c", "", "ac"));
    try t.expect(S("colou?r", "", "color"));
    try t.expect(S("colou?r", "", "colour"));
    // anchors
    try t.expect(S("^\\d+$", "", "12345"));
    try t.expect(!S("^\\d+$", "", "12a45"));
    try t.expect(!S("^abc$", "", "xabc"));
    // classes + ranges + shorthands
    try t.expect(S("[a-z]+", "", "Hello"));
    try t.expect(!S("^[a-z]+$", "", "Hello"));
    try t.expect(S("[^0-9]", "", "a"));
    try t.expect(S("\\w+", "", "foo_bar9"));
    try t.expect(S("\\s", "", "a b"));
    try t.expect(!S("\\s", "", "ab"));
    // {n,m}
    try t.expect(S("^a{2,4}$", "", "aaa"));
    try t.expect(!S("^a{2,4}$", "", "a"));
    try t.expect(!S("^a{2,4}$", "", "aaaaa"));
    try t.expect(S("^\\d{3}$", "", "123"));
    // alternation + groups
    try t.expect(S("^(cat|dog|bird)$", "", "dog"));
    try t.expect(!S("^(cat|dog)$", "", "fish"));
    try t.expect(S("^(ab)+$", "", "ababab"));
    // i flag
    try t.expect(S("hello", "i", "HELLO"));
    try t.expect(S("[a-z]+", "i", "ABC"));
    try t.expect(!S("hello", "", "HELLO"));
    // escaped metachars
    try t.expect(S("a\\.b", "", "a.b"));
    try t.expect(!S("a\\.b", "", "axb"));
    // a semver-ish pattern
    try t.expect(S("^\\d+\\.\\d+\\.\\d+$", "", "1.2.30"));
    try t.expect(!S("^\\d+\\.\\d+\\.\\d+$", "", "1.2"));
}
