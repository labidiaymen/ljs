//! §22.2.1/§22.2.2 the RegExp pattern engine: a recursive-descent parser → backtracking bytecode VM.
//! Byte-oriented (consistent with ljs's UTF-8/byte string model — a documented deviation from the
//! code-point semantics; ASCII patterns/inputs behave per spec). Supports: literal chars, `.`, char
//! classes `[...]` (ranges, negation, `\d\w\s\D\W\S`, escapes), anchors `^ $ \b \B`, quantifiers
//! `* + ? {n} {n,} {n,m}` (greedy + lazy `?`), groups `( )` (capturing) / `(?: )` / `(?<name> )`,
//! alternation `|`, and backreferences `\1` / `\k<name>`. Lookaround, Unicode property escapes, and
//! full u/v-mode strictness are deferred. `compile` throws SyntaxError on malformed syntax.
const std = @import("std");

pub const CompileError = error{ SyntaxError, OutOfMemory };

/// A compiled instruction for the backtracking VM.
const Inst = union(enum) {
    char: u8, // match one exact byte (case-folded when ignore_case)
    any, // `.` — any byte except a line terminator (unless dot_all)
    class: struct { ranges: []const Range, negated: bool }, // [...] / \d\w\s...
    save: usize, // record the current position into capture slot n
    split: struct { a: usize, b: usize }, // try a, then (on backtrack) b
    jmp: usize,
    assert_start, // ^
    assert_end, // $
    word_boundary: bool, // \b (false) / \B (true = negated)
    backref: usize, // \n — match the text previously captured by group n
    count_init: usize, // counters[n] = 0 (enter a counted-repeat loop)
    count_inc: usize, // counters[n] += 1 (one iteration done)
    // Counted-repeat loop head: with the loop counter at `counter`, branch to `body` for another
    // iteration or to `exit` when satisfied. < min → mandatory `body`; in [min,max) → a backtrack choice
    // (greedy prefers `body`, lazy prefers `exit`); ≥ max → `exit`. Avoids expanding `{n,m}` literally so
    // huge bounds (e.g. `b{9007199254740991}`) compile in O(1) space.
    rep_loop: struct { counter: usize, min: usize, max: usize, body: usize, exit: usize, greedy: bool },
    match, // success
};

const Range = struct { lo: u8, hi: u8 };

pub const Program = struct {
    insts: []const Inst,
    num_groups: usize, // capturing groups (excludes the whole-match group 0)
    num_counters: usize, // counted-repeat loops (each owns one VM counter register)
    names: []const NamedGroup, // (?<name>...) → group index
    ignore_case: bool,
    multiline: bool,
    dot_all: bool,
};

pub const NamedGroup = struct { name: []const u8, index: usize };

// ─── Parser (pattern text → AST) ────────────────────────────────────────────────────────────────

const NodeTag = enum { char, any, class, concat, alt, repeat, group, assert_start, assert_end, word_boundary, backref };

const Node = struct {
    tag: NodeTag,
    ch: u8 = 0,
    ranges: []Range = &.{},
    negated: bool = false,
    kids: []*Node = &.{}, // concat: sequence; alt: alternatives
    sub: ?*Node = null, // repeat/group child
    min: usize = 0,
    max: usize = 0, // for repeat; std.math.maxInt(usize) = unbounded
    greedy: bool = true,
    group_index: usize = 0, // 0 = non-capturing
    backref_index: usize = 0,
};

const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    group_count: usize = 0, // capturing groups seen
    names: std.ArrayListUnmanaged(NamedGroup) = .empty,
    unicode: bool,

    fn mk(self: *Parser, n: Node) CompileError!*Node {
        const p = try self.arena.create(Node);
        p.* = n;
        return p;
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    /// Disjunction: Alternative ( `|` Alternative )*
    fn parseDisjunction(self: *Parser) CompileError!*Node {
        var alts: std.ArrayListUnmanaged(*Node) = .empty;
        try alts.append(self.arena, try self.parseAlternative());
        while (self.peek() == '|') {
            self.pos += 1;
            try alts.append(self.arena, try self.parseAlternative());
        }
        if (alts.items.len == 1) return alts.items[0];
        return self.mk(.{ .tag = .alt, .kids = alts.items });
    }

    /// Alternative: Term*
    fn parseAlternative(self: *Parser) CompileError!*Node {
        var terms: std.ArrayListUnmanaged(*Node) = .empty;
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            try terms.append(self.arena, try self.parseTerm());
        }
        return self.mk(.{ .tag = .concat, .kids = terms.items });
    }

    /// Term: Assertion | Atom Quantifier?
    fn parseTerm(self: *Parser) CompileError!*Node {
        const c = self.peek().?;
        // Assertions (no quantifier).
        if (c == '^') {
            self.pos += 1;
            return self.mk(.{ .tag = .assert_start });
        }
        if (c == '$') {
            self.pos += 1;
            return self.mk(.{ .tag = .assert_end });
        }
        if (c == '\\' and self.pos + 1 < self.src.len and (self.src[self.pos + 1] == 'b' or self.src[self.pos + 1] == 'B')) {
            const neg = self.src[self.pos + 1] == 'B';
            self.pos += 2;
            return self.mk(.{ .tag = .word_boundary, .negated = neg });
        }
        const atom = try self.parseAtom();
        return self.parseQuantifier(atom);
    }

    fn parseQuantifier(self: *Parser, atom: *Node) CompileError!*Node {
        const c = self.peek() orelse return atom;
        var min: usize = 0;
        var max: usize = 0;
        switch (c) {
            '*' => {
                self.pos += 1;
                min = 0;
                max = std.math.maxInt(usize);
            },
            '+' => {
                self.pos += 1;
                min = 1;
                max = std.math.maxInt(usize);
            },
            '?' => {
                self.pos += 1;
                min = 0;
                max = 1;
            },
            '{' => {
                const save = self.pos;
                if (try self.parseBraceQuantifier(&min, &max)) {
                    // parsed
                } else {
                    self.pos = save; // `{` not a quantifier → a literal brace (Annex B); no quantifier
                    return atom;
                }
            },
            else => return atom,
        }
        var greedy = true;
        if (self.peek() == '?') {
            self.pos += 1;
            greedy = false;
        }
        // A quantifier directly on an assertion/another quantifier is a SyntaxError (caught: atom is an
        // Atom here, but `**` would re-enter with atom = repeat — reject a quantifier on a repeat).
        if (atom.tag == .repeat) return CompileError.SyntaxError;
        return self.mk(.{ .tag = .repeat, .sub = atom, .min = min, .max = max, .greedy = greedy });
    }

    /// `{n}` / `{n,}` / `{n,m}`. Returns false if the braces don't form a valid quantifier.
    fn parseBraceQuantifier(self: *Parser, min: *usize, max: *usize) CompileError!bool {
        self.pos += 1; // '{'
        const n0 = self.pos;
        while (self.peek()) |d| {
            if (d < '0' or d > '9') break;
            self.pos += 1;
        }
        if (self.pos == n0) return false; // no digits → not a quantifier
        const lo = std.fmt.parseInt(usize, self.src[n0..self.pos], 10) catch std.math.maxInt(usize);
        if (self.peek() == '}') {
            self.pos += 1;
            min.* = lo;
            max.* = lo;
            return true;
        }
        if (self.peek() != ',') return false;
        self.pos += 1; // ','
        if (self.peek() == '}') {
            self.pos += 1;
            min.* = lo;
            max.* = std.math.maxInt(usize);
            return true;
        }
        const m0 = self.pos;
        while (self.peek()) |d| {
            if (d < '0' or d > '9') break;
            self.pos += 1;
        }
        if (self.pos == m0 or self.peek() != '}') return false;
        const hi = std.fmt.parseInt(usize, self.src[m0..self.pos], 10) catch std.math.maxInt(usize);
        self.pos += 1; // '}'
        if (lo > hi) return CompileError.SyntaxError; // {2,1}
        min.* = lo;
        max.* = hi;
        return true;
    }

    fn parseAtom(self: *Parser) CompileError!*Node {
        const c = self.peek() orelse return CompileError.SyntaxError;
        switch (c) {
            '.' => {
                self.pos += 1;
                return self.mk(.{ .tag = .any });
            },
            '(' => return self.parseGroup(),
            '[' => return self.parseClass(),
            '\\' => return self.parseAtomEscape(),
            '*', '+', '?' => return CompileError.SyntaxError, // nothing to repeat
            ')' => return CompileError.SyntaxError,
            else => {
                self.pos += 1;
                return self.mk(.{ .tag = .char, .ch = c });
            },
        }
    }

    fn parseGroup(self: *Parser) CompileError!*Node {
        self.pos += 1; // '('
        var capturing = true;
        var gi: usize = 0;
        if (self.peek() == '?') {
            // (?: ...) non-capturing, or (?<name> ...) named, or lookaround (deferred → reject)
            self.pos += 1;
            const k = self.peek() orelse return CompileError.SyntaxError;
            if (k == ':') {
                self.pos += 1;
                capturing = false;
            } else if (k == '<' and self.pos + 1 < self.src.len and self.src[self.pos + 1] != '=' and self.src[self.pos + 1] != '!') {
                self.pos += 1; // '<'
                const ns = self.pos;
                while (self.peek()) |nc| {
                    if (nc == '>') break;
                    self.pos += 1;
                }
                if (self.peek() != '>') return CompileError.SyntaxError;
                const name = self.src[ns..self.pos];
                self.pos += 1; // '>'
                self.group_count += 1;
                gi = self.group_count;
                try self.names.append(self.arena, .{ .name = name, .index = gi });
            } else {
                // (?=...) (?!...) (?<=...) (?<!...) lookaround — not yet supported.
                return CompileError.SyntaxError;
            }
        } else {
            self.group_count += 1;
            gi = self.group_count;
        }
        const body = try self.parseDisjunction();
        if (self.peek() != ')') return CompileError.SyntaxError;
        self.pos += 1; // ')'
        return self.mk(.{ .tag = .group, .sub = body, .group_index = if (capturing) gi else 0 });
    }

    fn parseClass(self: *Parser) CompileError!*Node {
        self.pos += 1; // '['
        var negated = false;
        if (self.peek() == '^') {
            self.pos += 1;
            negated = true;
        }
        var ranges: std.ArrayListUnmanaged(Range) = .empty;
        while (self.peek()) |c| {
            if (c == ']') break;
            const lo = try self.parseClassAtom(&ranges);
            // a range `a-z` (only when not at the end and the next is not `]`)
            if (lo != null and self.peek() == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] != ']') {
                self.pos += 1; // '-'
                const hi = try self.parseClassAtom(&ranges);
                if (hi) |h| {
                    if (lo.? > h) return CompileError.SyntaxError; // z-a
                    try ranges.append(self.arena, .{ .lo = lo.?, .hi = h });
                } else {
                    // hi was a class-escape (e.g. a-\d) → treat `-` as literal
                    try ranges.append(self.arena, .{ .lo = lo.?, .hi = lo.? });
                    try ranges.append(self.arena, .{ .lo = '-', .hi = '-' });
                }
            } else if (lo) |l| {
                try ranges.append(self.arena, .{ .lo = l, .hi = l });
            }
        }
        if (self.peek() != ']') return CompileError.SyntaxError;
        self.pos += 1; // ']'
        return self.mk(.{ .tag = .class, .ranges = ranges.items, .negated = negated });
    }

    /// Parse one class member. Returns the byte for a single char (for range building), or null when it
    /// appended a multi-byte set (a \d\w\s class escape) directly to `ranges`.
    fn parseClassAtom(self: *Parser, ranges: *std.ArrayListUnmanaged(Range)) CompileError!?u8 {
        const c = self.peek().?;
        if (c == '\\') {
            self.pos += 1;
            const e = self.peek() orelse return CompileError.SyntaxError;
            self.pos += 1;
            switch (e) {
                'd', 'D', 'w', 'W', 's', 'S' => {
                    try appendClassEscape(self.arena, ranges, e);
                    return null;
                },
                'n' => return '\n',
                'r' => return '\r',
                't' => return '\t',
                'f' => return 0x0C,
                'v' => return 0x0B,
                'b' => return 0x08, // \b in a class is backspace
                '0' => return 0,
                'x' => return @as(u8, try self.parseHex(2)),
                'u' => return @as(u8, try self.parseHex(4)),
                else => return e, // identity escape (Annex B lenient)
            }
        }
        self.pos += 1;
        return c;
    }

    fn parseHex(self: *Parser, n: usize) CompileError!u8 {
        var v: u32 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const d = self.peek() orelse return CompileError.SyntaxError;
            const nib: u32 = switch (d) {
                '0'...'9' => d - '0',
                'a'...'f' => d - 'a' + 10,
                'A'...'F' => d - 'A' + 10,
                else => return CompileError.SyntaxError,
            };
            v = v * 16 + nib;
            self.pos += 1;
        }
        return @truncate(v); // byte-oriented: code points > 0xFF truncate (deviation)
    }

    fn parseAtomEscape(self: *Parser) CompileError!*Node {
        self.pos += 1; // '\'
        const e = self.peek() orelse return CompileError.SyntaxError;
        switch (e) {
            'd', 'D', 'w', 'W', 's', 'S' => {
                self.pos += 1;
                var ranges: std.ArrayListUnmanaged(Range) = .empty;
                try appendClassEscape(self.arena, &ranges, e);
                return self.mk(.{ .tag = .class, .ranges = ranges.items, .negated = false });
            },
            '1'...'9' => {
                const n0 = self.pos;
                while (self.peek()) |d| {
                    if (d < '0' or d > '9') break;
                    self.pos += 1;
                }
                const idx = std.fmt.parseInt(usize, self.src[n0..self.pos], 10) catch return CompileError.SyntaxError;
                return self.mk(.{ .tag = .backref, .backref_index = idx });
            },
            'k' => {
                self.pos += 1;
                if (self.peek() != '<') return CompileError.SyntaxError;
                self.pos += 1;
                const ns = self.pos;
                while (self.peek()) |nc| {
                    if (nc == '>') break;
                    self.pos += 1;
                }
                if (self.peek() != '>') return CompileError.SyntaxError;
                const name = self.src[ns..self.pos];
                self.pos += 1;
                // resolved to an index at compile end; store name via a sentinel backref (resolved later)
                for (self.names.items) |ng| {
                    if (std.mem.eql(u8, ng.name, name)) return self.mk(.{ .tag = .backref, .backref_index = ng.index });
                }
                // forward named backref — resolve after full parse; store 0 (matches empty) as fallback
                return self.mk(.{ .tag = .backref, .backref_index = 0 });
            },
            else => {
                const b = try self.singleCharEscape();
                return self.mk(.{ .tag = .char, .ch = b });
            },
        }
    }

    fn singleCharEscape(self: *Parser) CompileError!u8 {
        const e = self.peek().?;
        self.pos += 1;
        return switch (e) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'f' => 0x0C,
            'v' => 0x0B,
            '0' => 0,
            'x' => self.parseHex(2),
            'u' => self.parseHex(4),
            else => e, // identity escape (Annex B lenient)
        };
    }
};

fn appendClassEscape(arena: std.mem.Allocator, ranges: *std.ArrayListUnmanaged(Range), e: u8) CompileError!void {
    switch (e) {
        'd' => try ranges.append(arena, .{ .lo = '0', .hi = '9' }),
        'D' => try appendNegated(arena, ranges, &.{.{ .lo = '0', .hi = '9' }}),
        'w' => {
            try ranges.append(arena, .{ .lo = 'a', .hi = 'z' });
            try ranges.append(arena, .{ .lo = 'A', .hi = 'Z' });
            try ranges.append(arena, .{ .lo = '0', .hi = '9' });
            try ranges.append(arena, .{ .lo = '_', .hi = '_' });
        },
        'W' => try appendNegated(arena, ranges, &.{ .{ .lo = 'a', .hi = 'z' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = '0', .hi = '9' }, .{ .lo = '_', .hi = '_' } }),
        's' => try appendWhitespace(arena, ranges),
        'S' => {
            // negation of whitespace — build whitespace then complement over 0..255
            var tmp: std.ArrayListUnmanaged(Range) = .empty;
            try appendWhitespace(arena, &tmp);
            try appendNegated(arena, ranges, tmp.items);
        },
        else => unreachable,
    }
}

fn appendWhitespace(arena: std.mem.Allocator, ranges: *std.ArrayListUnmanaged(Range)) CompileError!void {
    try ranges.append(arena, .{ .lo = ' ', .hi = ' ' });
    try ranges.append(arena, .{ .lo = '\t', .hi = '\r' }); // \t \n \v \f \r (0x09..0x0D)
    try ranges.append(arena, .{ .lo = 0xA0, .hi = 0xA0 }); // NBSP (byte model)
}

/// Append the complement of `src` (over the byte range 0..255) to `out`.
fn appendNegated(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(Range), src: []const Range) CompileError!void {
    var present = [_]bool{false} ** 256;
    for (src) |r| {
        var b: usize = r.lo;
        while (b <= r.hi) : (b += 1) present[b] = true;
    }
    var i: usize = 0;
    while (i < 256) {
        if (!present[i]) {
            const lo: u8 = @intCast(i);
            while (i < 256 and !present[i]) i += 1;
            try out.append(arena, .{ .lo = lo, .hi = @intCast(i - 1) });
        } else i += 1;
    }
}

// ─── Compiler (AST → bytecode) ───────────────────────────────────────────────────────────────────

const Compiler = struct {
    arena: std.mem.Allocator,
    insts: std.ArrayListUnmanaged(Inst) = .empty,
    num_counters: usize = 0,

    /// Above this, a `{min,max}` bound is compiled with a runtime counter loop instead of being unrolled
    /// into literal copies — so `b{9007199254740991}` doesn't try to emit quadrillions of instructions.
    const expand_limit: usize = 1000;

    fn emit(self: *Compiler, inst: Inst) CompileError!usize {
        const at = self.insts.items.len;
        try self.insts.append(self.arena, inst);
        return at;
    }

    fn compileNode(self: *Compiler, n: *Node) CompileError!void {
        switch (n.tag) {
            .char => _ = try self.emit(.{ .char = n.ch }),
            .any => _ = try self.emit(.any),
            .class => _ = try self.emit(.{ .class = .{ .ranges = n.ranges, .negated = n.negated } }),
            .assert_start => _ = try self.emit(.assert_start),
            .assert_end => _ = try self.emit(.assert_end),
            .word_boundary => _ = try self.emit(.{ .word_boundary = n.negated }),
            .backref => _ = try self.emit(.{ .backref = n.backref_index }),
            .concat => for (n.kids) |k| try self.compileNode(k),
            .alt => {
                // split a,b ; a: ...; jmp end; b: ...(recurse for >2)
                var jmp_ends: std.ArrayListUnmanaged(usize) = .empty;
                for (n.kids, 0..) |k, i| {
                    if (i + 1 < n.kids.len) {
                        const sp = try self.emit(.{ .split = .{ .a = 0, .b = 0 } });
                        self.insts.items[sp].split.a = self.insts.items.len;
                        try self.compileNode(k);
                        const je = try self.emit(.{ .jmp = 0 });
                        try jmp_ends.append(self.arena, je);
                        self.insts.items[sp].split.b = self.insts.items.len;
                    } else {
                        try self.compileNode(k);
                    }
                }
                for (jmp_ends.items) |je| self.insts.items[je].jmp = self.insts.items.len;
            },
            .group => {
                if (n.group_index > 0) _ = try self.emit(.{ .save = 2 * n.group_index });
                try self.compileNode(n.sub.?);
                if (n.group_index > 0) _ = try self.emit(.{ .save = 2 * n.group_index + 1 });
            },
            .repeat => try self.compileRepeat(n),
        }
    }

    fn compileRepeat(self: *Compiler, n: *Node) CompileError!void {
        const sub = n.sub.?;
        // Large bounds → counter loop (avoids unrolling huge counts into instructions).
        const big_min = n.min > expand_limit;
        const big_opt = n.max != std.math.maxInt(usize) and (n.max - n.min) > expand_limit;
        if (big_min or big_opt) return self.compileCountedRepeat(n);
        // `min` mandatory copies.
        var i: usize = 0;
        while (i < n.min) : (i += 1) try self.compileNode(sub);
        if (n.max == std.math.maxInt(usize)) {
            // unbounded tail: L: split body,end (greedy) / split end,body (lazy); body: sub; jmp L; end:
            const l = self.insts.items.len;
            const sp = try self.emit(.{ .split = .{ .a = 0, .b = 0 } });
            const body = self.insts.items.len;
            try self.compileNode(sub);
            _ = try self.emit(.{ .jmp = l });
            const end = self.insts.items.len;
            if (n.greedy) {
                self.insts.items[sp].split = .{ .a = body, .b = end };
            } else {
                self.insts.items[sp].split = .{ .a = end, .b = body };
            }
        } else {
            // (max - min) optional copies: each `split body,end` (greedy) and a shared end.
            var jmp_ends: std.ArrayListUnmanaged(usize) = .empty;
            var k: usize = n.min;
            while (k < n.max) : (k += 1) {
                const sp = try self.emit(.{ .split = .{ .a = 0, .b = 0 } });
                const body = self.insts.items.len;
                if (n.greedy) self.insts.items[sp].split.a = body else self.insts.items[sp].split.b = body;
                try self.compileNode(sub);
                // the non-body branch jumps to the shared end
                const je = self.insts.items.len;
                _ = je;
                if (n.greedy) {
                    // b (skip) → end; record sp.b to patch
                    try jmp_ends.append(self.arena, sp);
                } else {
                    try jmp_ends.append(self.arena, sp);
                }
            }
            const end = self.insts.items.len;
            for (jmp_ends.items) |sp| {
                if (n.greedy) self.insts.items[sp].split.b = end else self.insts.items[sp].split.a = end;
            }
        }
    }

    /// `e{min,max}` via a runtime counter (O(1) instructions regardless of the bounds):
    ///   count_init c ; L: rep_loop(c,min,max → body|exit) ; body: <e> ; count_inc c ; jmp L ; exit:
    fn compileCountedRepeat(self: *Compiler, n: *Node) CompileError!void {
        const counter = self.num_counters;
        self.num_counters += 1;
        _ = try self.emit(.{ .count_init = counter });
        const loop = try self.emit(.{ .rep_loop = .{ .counter = counter, .min = n.min, .max = n.max, .body = 0, .exit = 0, .greedy = n.greedy } });
        self.insts.items[loop].rep_loop.body = self.insts.items.len;
        try self.compileNode(n.sub.?);
        _ = try self.emit(.{ .count_inc = counter });
        _ = try self.emit(.{ .jmp = loop });
        self.insts.items[loop].rep_loop.exit = self.insts.items.len;
    }
};

/// §22.2.2 compile a pattern source + flags into a Program (throws SyntaxError on malformed syntax).
pub fn compile(arena: std.mem.Allocator, source: []const u8, ignore_case: bool, multiline: bool, dot_all: bool, unicode: bool) CompileError!Program {
    var p = Parser{ .arena = arena, .src = source, .unicode = unicode };
    const ast = try p.parseDisjunction();
    if (p.pos != source.len) return CompileError.SyntaxError; // trailing `)` etc.
    var c = Compiler{ .arena = arena };
    _ = try c.emit(.{ .save = 0 }); // whole-match start
    try c.compileNode(ast);
    _ = try c.emit(.{ .save = 1 }); // whole-match end
    _ = try c.emit(.match);
    return .{
        .insts = c.insts.items,
        .num_groups = p.group_count,
        .num_counters = c.num_counters,
        .names = p.names.items,
        .ignore_case = ignore_case,
        .multiline = multiline,
        .dot_all = dot_all,
    };
}

// ─── Backtracking VM ─────────────────────────────────────────────────────────────────────────────

pub const Match = struct { saves: []?usize };

fn foldByte(b: u8) u8 {
    return if (b >= 'A' and b <= 'Z') b + 32 else b;
}

fn isWordByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_';
}

fn classMatch(ranges: []const Range, negated: bool, b: u8, ignore_case: bool) bool {
    var hit = false;
    for (ranges) |r| {
        if (b >= r.lo and b <= r.hi) {
            hit = true;
            break;
        }
        if (ignore_case) {
            const fb = foldByte(b);
            if (fb >= foldByte(r.lo) and fb <= foldByte(r.hi) and r.lo <= 'z' and r.hi <= 'z') {
                hit = true;
                break;
            }
        }
    }
    return hit != negated;
}

fn isLineTerm(b: u8) bool {
    return b == '\n' or b == '\r';
}

/// A pending backtracking choice point: the lower-priority branch of a `split` to try if the preferred
/// branch fails. `undo_len` records the capture-undo-log length at the split so the saves array can be
/// rolled back to its state at that point when this alternative is taken.
const Choice = struct { pc: usize, sp: usize, undo_len: usize };

/// One entry of the backtracking undo log: the prior value of a capture slot (before a `save`) or of a
/// loop counter (before a `count_init`/`count_inc`), so it can be restored when a choice point is taken.
const Undo = union(enum) {
    save: struct { slot: usize, old: ?usize },
    counter: struct { idx: usize, old: usize },
};

/// A budget on total VM steps: catastrophic backtracking (e.g. `(a*)*b` over a long non-matching input)
/// is exponential, so rather than hang we abort and report no match once the budget is spent. Legitimate
/// matches finish in far fewer steps; pathological patterns that would only match past the budget are the
/// documented casualty (Test262's catastrophic cases expect no match anyway).
const max_steps: usize = 2_000_000;

/// Backtracking execution starting at instruction 0, string position `at`. Returns the capture saves on a
/// full match, or null on failure / step-budget exhaustion.
///
/// Iterative, with a single shared `saves` array mutated in place: each `split` pushes a `Choice` for the
/// alternative branch, and each `save` logs the overwritten slot to `undo`. On backtrack the saves are
/// rolled back to the choice point's `undo_len` and execution resumes there. Memory stays bounded by the
/// current path depth (both stacks shrink on backtrack), so a long `a*` loop or deep nesting neither
/// overflows the native call stack (no recursion) nor exhausts the heap (no per-step allocation).
fn matchAt(arena: std.mem.Allocator, prog: *const Program, input: []const u8, at: usize) error{OutOfMemory}!?[]?usize {
    const nslots = 2 * (prog.num_groups + 1);
    const saves = try arena.alloc(?usize, nslots);
    @memset(saves, null);
    const counters = try arena.alloc(usize, prog.num_counters);
    @memset(counters, 0);
    var bt: std.ArrayListUnmanaged(Choice) = .empty;
    var undo: std.ArrayListUnmanaged(Undo) = .empty;
    var pc: usize = 0;
    var sp: usize = at;
    var steps: usize = 0;
    while (true) {
        steps += 1;
        if (steps > max_steps) return null;
        // `fail` rolls back to the most recent choice point (restoring saves via the undo log); if there
        // are none, the match fails at this start position.
        var failed = false;
        switch (prog.insts[pc]) {
            .match => return saves,
            .jmp => |x| pc = x,
            .char => |c| {
                if (sp >= input.len) {
                    failed = true;
                } else {
                    const ib = input[sp];
                    const eq = if (prog.ignore_case) foldByte(ib) == foldByte(c) else ib == c;
                    if (!eq) {
                        failed = true;
                    } else {
                        sp += 1;
                        pc += 1;
                    }
                }
            },
            .any => {
                if (sp >= input.len or (!prog.dot_all and isLineTerm(input[sp]))) {
                    failed = true;
                } else {
                    sp += 1;
                    pc += 1;
                }
            },
            .class => |cl| {
                if (sp >= input.len or !classMatch(cl.ranges, cl.negated, input[sp], prog.ignore_case)) {
                    failed = true;
                } else {
                    sp += 1;
                    pc += 1;
                }
            },
            .assert_start => {
                const ok = sp == 0 or (prog.multiline and sp > 0 and isLineTerm(input[sp - 1]));
                if (!ok) failed = true else pc += 1;
            },
            .assert_end => {
                const ok = sp == input.len or (prog.multiline and isLineTerm(input[sp]));
                if (!ok) failed = true else pc += 1;
            },
            .word_boundary => |neg| {
                const before = sp > 0 and isWordByte(input[sp - 1]);
                const after = sp < input.len and isWordByte(input[sp]);
                const boundary = before != after;
                if (boundary == neg) failed = true else pc += 1;
            },
            .backref => |gi| {
                const a = if (2 * gi < saves.len) saves[2 * gi] else null;
                const b = if (2 * gi + 1 < saves.len) saves[2 * gi + 1] else null;
                if (a == null or b == null) {
                    pc += 1; // an unmatched group backref matches the empty string
                } else {
                    const seg = input[a.?..b.?];
                    if (sp + seg.len > input.len) {
                        failed = true;
                    } else {
                        for (seg, 0..) |sc, i| {
                            const ib = input[sp + i];
                            const eq = if (prog.ignore_case) foldByte(ib) == foldByte(sc) else ib == sc;
                            if (!eq) {
                                failed = true;
                                break;
                            }
                        }
                        if (!failed) {
                            sp += seg.len;
                            pc += 1;
                        }
                    }
                }
            },
            .save => |n| {
                if (n < saves.len) {
                    try undo.append(arena, .{ .save = .{ .slot = n, .old = saves[n] } });
                    saves[n] = sp;
                }
                pc += 1;
            },
            .count_init => |c| {
                try undo.append(arena, .{ .counter = .{ .idx = c, .old = counters[c] } });
                counters[c] = 0;
                pc += 1;
            },
            .count_inc => |c| {
                try undo.append(arena, .{ .counter = .{ .idx = c, .old = counters[c] } });
                counters[c] += 1;
                pc += 1;
            },
            .rep_loop => |r| {
                const cnt = counters[r.counter];
                if (cnt < r.min) {
                    pc = r.body; // still mandatory — no choice
                } else if (r.max == std.math.maxInt(usize) or cnt < r.max) {
                    // optional iteration: greedy prefers another rep, lazy prefers exiting
                    if (r.greedy) {
                        try bt.append(arena, .{ .pc = r.exit, .sp = sp, .undo_len = undo.items.len });
                        pc = r.body;
                    } else {
                        try bt.append(arena, .{ .pc = r.body, .sp = sp, .undo_len = undo.items.len });
                        pc = r.exit;
                    }
                } else {
                    pc = r.exit; // reached max
                }
            },
            .split => |s| {
                // Try `a` first (greedy/lazy ordering already baked into a vs b by the compiler); record
                // `b` as the lower-priority alternative, restorable to the saves state as of this split.
                try bt.append(arena, .{ .pc = s.b, .sp = sp, .undo_len = undo.items.len });
                pc = s.a;
            },
        }
        if (failed) {
            const cp = bt.pop() orelse return null;
            while (undo.items.len > cp.undo_len) {
                switch (undo.pop().?) {
                    .save => |u| saves[u.slot] = u.old,
                    .counter => |u| counters[u.idx] = u.old,
                }
            }
            pc = cp.pc;
            sp = cp.sp;
        }
    }
}

/// Try to match `prog` against `input`. If `sticky`, only at `start`; else scan forward from `start`.
/// Returns the capture saves (slot 0/1 = whole match; 2k/2k+1 = group k) or null if no match.
pub fn exec(arena: std.mem.Allocator, prog: *const Program, input: []const u8, start: usize, sticky: bool) error{OutOfMemory}!?Match {
    var at = start;
    while (at <= input.len) : (at += 1) {
        if (try matchAt(arena, prog, input, at)) |saves| return Match{ .saves = saves };
        if (sticky) return null;
    }
    return null;
}
