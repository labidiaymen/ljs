//! §22.2.1/§22.2.2 the RegExp pattern engine: a recursive-descent parser → backtracking bytecode VM.
//! Byte-oriented (consistent with ljs's UTF-8/byte string model — a documented deviation from the
//! code-point semantics; ASCII patterns/inputs behave per spec). Supports: literal chars, `.`, char
//! classes `[...]` (ranges, negation, `\d\w\s\D\W\S`, escapes), anchors `^ $ \b \B`, quantifiers
//! `* + ? {n} {n,} {n,m}` (greedy + lazy `?`), groups `( )` (capturing) / `(?: )` / `(?<name> )`,
//! alternation `|`, backreferences `\1` / `\k<name>`, and Unicode property escapes `\p{…}`/`\P{…}`
//! (spec 140 — code-point matched via unicode_props.zig). Lookaround + full u/v-mode strictness are
//! deferred. `compile` throws SyntaxError on malformed syntax.
const std = @import("std");
const unicode_id = @import("unicode_id.zig");
const uprops = @import("unicode_props.zig");

pub const CompileError = error{ SyntaxError, OutOfMemory };

/// §22.2.1 a Unicode property escape `\p{…}` / `\P{…}` referenced from a class. `negate` is set for the
/// `\P` form (membership inverted). Matched code-point-wise (see the `.class` VM op).
const UProp = struct { id: uprops.PropId, negate: bool };

/// A compiled instruction for the backtracking VM.
const Inst = union(enum) {
    char: u8, // match one exact byte (case-folded when ignore_case)
    any, // `.` — any byte except a line terminator (unless dot_all)
    class: struct { ranges: []const Range, negated: bool, uprops: []const UProp = &.{} }, // [...] / \d\w\s... / \p{…}
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
    // §22.2.2.3 Assertion :: (?= ) (?! ) (?<= ) (?<! ) — a lookaround. The body is its own compiled
    // sub-program (its instructions end in `match`); `behind` runs it right-to-left (reversed +
    // backward), `ahead` forward, both anchored at the current position and consuming nothing. On a
    // positive assertion the body's captures persist; a negative assertion (whether it succeeds by the
    // body failing) leaves the captures it would have set as undefined.
    look: struct { negated: bool, behind: bool, body: *const Look },
    match, // success
};

/// A compiled lookaround body: a self-contained instruction stream (ending in `match`) plus its own
/// counter-register count and the reverse flag (set for lookbehind, where the body was compiled in
/// reverse term order and is executed backward).
pub const Look = struct {
    insts: []const Inst,
    num_counters: usize,
    reverse: bool,
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

const NodeTag = enum { char, any, class, concat, alt, repeat, group, assert_start, assert_end, word_boundary, backref, look };

const Node = struct {
    tag: NodeTag,
    ch: u8 = 0,
    ranges: []Range = &.{},
    uprops: []const UProp = &.{}, // §22.2.1 `\p{…}` property refs carried by a `.class` node
    negated: bool = false,
    kids: []*Node = &.{}, // concat: sequence; alt: alternatives
    sub: ?*Node = null, // repeat/group child
    min: usize = 0,
    max: usize = 0, // for repeat; std.math.maxInt(usize) = unbounded
    greedy: bool = true,
    group_index: usize = 0, // 0 = non-capturing
    backref_index: usize = 0,
    behind: bool = false, // look: lookbehind (?<= / (?<! vs lookahead
};

const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    last_atom_codepoint: u32 = 0,
    group_count: usize = 0, // capturing groups seen
    names: std.ArrayListUnmanaged(NamedGroup) = .empty,
    /// §22.2.1 `\k<name>` references, resolved to group indices after the whole pattern is parsed (so
    /// forward references work); a name with no matching group is a dangling-reference SyntaxError.
    named_refs: std.ArrayListUnmanaged(struct { name: []const u8, node: *Node }) = .empty,
    /// Highest `\N` numeric backreference seen. In UnicodeMode a reference past the last group is a
    /// SyntaxError (§22.2.1 — non-UnicodeMode treats it as a legacy octal/literal escape instead).
    max_backref: usize = 0,
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
        // §22.2.1 Term grammar: a lookbehind `(?<= )` / `(?<! )` is an Assertion, never a
        // QuantifiableAssertion — quantifying it (`(?<=.)?`, `(?<=.){2,3}`) is always a SyntaxError.
        // A lookahead `(?= )` / `(?! )` is a QuantifiableAssertion only in non-UnicodeMode (Annex B);
        // in UnicodeMode (`u`/`v`) quantifying it is a SyntaxError too.
        if (atom.tag == .look and (atom.behind or self.unicode)) return CompileError.SyntaxError;
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
            '{' => {
                // §22.2.1: in UnicodeMode `{` is never a PatternCharacter — always a SyntaxError here.
                // In non-UnicodeMode (Annex B) a `{` that forms a valid quantifier at this position has
                // nothing to repeat (→ SyntaxError); otherwise it is a literal `{`.
                if (self.unicode) return CompileError.SyntaxError;
                const save = self.pos;
                var mn: usize = 0;
                var mx: usize = 0;
                if (try self.parseBraceQuantifier(&mn, &mx)) return CompileError.SyntaxError;
                self.pos = save + 1;
                return self.mk(.{ .tag = .char, .ch = c });
            },
            '}', ']' => {
                // §22.2.1: a lone `}`/`]` is a SyntaxError in UnicodeMode; Annex B allows it as a literal.
                if (self.unicode) return CompileError.SyntaxError;
                self.pos += 1;
                return self.mk(.{ .tag = .char, .ch = c });
            },
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
            } else if (k == '=' or k == '!') {
                // (?=Disjunction) / (?!Disjunction) — lookahead assertion (consumes nothing).
                self.pos += 1; // '=' or '!'
                const lbody = try self.parseDisjunction();
                if (self.peek() != ')') return CompileError.SyntaxError;
                self.pos += 1; // ')'
                return self.mk(.{ .tag = .look, .sub = lbody, .negated = k == '!', .behind = false });
            } else if (k == '<' and self.pos + 1 < self.src.len and (self.src[self.pos + 1] == '=' or self.src[self.pos + 1] == '!')) {
                // (?<=Disjunction) / (?<!Disjunction) — lookbehind assertion (consumes nothing).
                const neg = self.src[self.pos + 1] == '!';
                self.pos += 2; // '<' then '=' or '!'
                const lbody = try self.parseDisjunction();
                if (self.peek() != ')') return CompileError.SyntaxError;
                self.pos += 1; // ')'
                return self.mk(.{ .tag = .look, .sub = lbody, .negated = neg, .behind = true });
            } else if (k == '<') {
                self.pos += 1; // '<'
                // §22.2.1 GroupSpecifier: `<` RegExpIdentifierName `>` — validated (non-empty, valid
                // identifier code points) and unique within the pattern (duplicate name → SyntaxError).
                const name = try self.parseGroupName();
                for (self.names.items) |ng| {
                    if (std.mem.eql(u8, ng.name, name)) return CompileError.SyntaxError;
                }
                self.group_count += 1;
                gi = self.group_count;
                try self.names.append(self.arena, .{ .name = name, .index = gi });
            } else {
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
        var ups: std.ArrayListUnmanaged(UProp) = .empty;
        while (self.peek()) |c| {
            if (c == ']') break;
            // §22.2.1 a `\p{…}`/`\P{…}` ClassEscape inside the class (UnicodeMode) — collect a property
            // ref rather than a byte. A property may NOT be a range endpoint (`\p{L}-x` is a SyntaxError).
            if (c == '\\' and self.pos + 1 < self.src.len and self.unicode and
                (self.src[self.pos + 1] == 'p' or self.src[self.pos + 1] == 'P'))
            {
                const neg = self.src[self.pos + 1] == 'P';
                self.pos += 2; // consume `\` and `p`/`P`
                try ups.append(self.arena, try self.parsePropEscape(neg));
                if (self.peek() == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] != ']') return CompileError.SyntaxError;
                continue;
            }
            // `parseClassAtom` returns the byte for a single-char atom, or null when it appended a
            // CharacterClassEscape (\d\w\s…) directly to `ranges`.
            const lo = try self.parseClassAtom(&ranges);
            const lo_cp = self.last_atom_codepoint;
            // a range `X-Y` (only when a `-` follows and it is not the closing `]`)
            if (self.peek() == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] != ']') {
                self.pos += 1; // '-'
                const hi = try self.parseClassAtom(&ranges);
                const hi_cp = self.last_atom_codepoint;
                if (lo != null and hi != null) {
                    // §22.2.1: order check on the FULL code points so a genuinely inverted range
                    // (z-a, or uFFFF-u0000) is a SyntaxError, while a valid astral range like
                    // uFDF0-uFFEF (whose truncated bytes 0xF0-0xEF only LOOK inverted) is accepted;
                    // store it only if representable in bytes, else drop it (byte-engine deviation).
                    if (lo_cp > hi_cp) return CompileError.SyntaxError;
                    if (lo.? <= hi.?) try ranges.append(self.arena, .{ .lo = lo.?, .hi = hi.? });
                } else {
                    // §22.2.1 NonemptyClassRanges: a range endpoint that is a CharacterClassEscape
                    // (e.g. `\d-a`, `a-\d`, `\s-\d`) is a SyntaxError in UnicodeMode; Annex B treats the
                    // `-` (and any single-char side) as literals (the escape side is already appended).
                    if (self.unicode) return CompileError.SyntaxError;
                    if (lo) |l| try ranges.append(self.arena, .{ .lo = l, .hi = l });
                    try ranges.append(self.arena, .{ .lo = '-', .hi = '-' });
                    if (hi) |h| try ranges.append(self.arena, .{ .lo = h, .hi = h });
                }
            } else if (lo) |l| {
                try ranges.append(self.arena, .{ .lo = l, .hi = l });
            }
        }
        if (self.peek() != ']') return CompileError.SyntaxError;
        self.pos += 1; // ']'
        return self.mk(.{ .tag = .class, .ranges = ranges.items, .uprops = ups.items, .negated = negated });
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
                'n' => return self.recordCp('\n'),
                'r' => return self.recordCp('\r'),
                't' => return self.recordCp('\t'),
                'f' => return self.recordCp(0x0C),
                'v' => return self.recordCp(0x0B),
                'b' => return self.recordCp(0x08), // \b in a class is backspace
                '0' => return self.recordCp(0),
                'x' => return self.recordCp(try self.parseHexFull(2)),
                'u' => return self.recordCp(try self.parseHexFull(4)),
                else => return self.recordCp(e), // identity escape (Annex B lenient)
            }
        }
        self.pos += 1;
        return self.recordCp(c);
    }

    /// Record an atom's FULL code point (for the range-order check) and return it truncated to a byte
    /// (the engine is byte-oriented; code points > 0xFF are a documented matching deviation).
    fn recordCp(self: *Parser, v: u32) u8 {
        self.last_atom_codepoint = v;
        return @truncate(v);
    }

    fn parseHex(self: *Parser, n: usize) CompileError!u8 {
        return @truncate(try self.parseHexFull(n)); // byte-oriented: code points > 0xFF truncate (deviation)
    }

    fn parseHexFull(self: *Parser, n: usize) CompileError!u32 {
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
        return v;
    }

    /// §22.2.1 CharacterClassEscape `p{…}` / `P{…}`: parse the `{ Name (= Value)? }` after a `\p`/`\P`
    /// (`negate` set for `\P`). Property escapes are valid only in UnicodeMode; the caller has consumed
    /// the `p`/`P`. Resolves the name via `unicode_props.lookup` (a `Name=Value` form uses the Value).
    fn parsePropEscape(self: *Parser, negate: bool) CompileError!UProp {
        if (!self.unicode) return CompileError.SyntaxError; // `\p` is a property escape only with `/u`
        if (self.peek() != '{') return CompileError.SyntaxError;
        self.pos += 1; // '{'
        const name_start = self.pos;
        while (self.peek()) |c| {
            if (c == '}') break;
            if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '=')) return CompileError.SyntaxError;
            self.pos += 1;
        }
        if (self.peek() != '}') return CompileError.SyntaxError;
        const raw = self.src[name_start..self.pos];
        self.pos += 1; // '}'
        if (raw.len == 0) return CompileError.SyntaxError;
        const name = if (std.mem.indexOfScalar(u8, raw, '=')) |eqp| raw[eqp + 1 ..] else raw;
        const id = uprops.lookup(name) orelse return CompileError.SyntaxError;
        return .{ .id = id, .negate = negate };
    }

    /// A standalone `\p{…}`/`\P{…}` atom → a `.class` node carrying one property ref (no byte ranges).
    fn propEscapeNode(self: *Parser, negate: bool) CompileError!*Node {
        const up = try self.parsePropEscape(negate);
        const arr = try self.arena.alloc(UProp, 1);
        arr[0] = up;
        return self.mk(.{ .tag = .class, .ranges = &.{}, .uprops = arr, .negated = false });
    }

    fn parseAtomEscape(self: *Parser) CompileError!*Node {
        self.pos += 1; // '\'
        const e = self.peek() orelse return CompileError.SyntaxError;
        switch (e) {
            'p', 'P' => {
                if (self.unicode) {
                    self.pos += 1; // consume 'p'/'P'
                    return self.propEscapeNode(e == 'P');
                }
                // non-UnicodeMode: `\p` is an identity escape (Annex B) → the literal char.
                const b = try self.singleCharEscape();
                return self.mk(.{ .tag = .char, .ch = b });
            },
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
                if (idx > self.max_backref) self.max_backref = idx; // checked vs group_count after parse (UnicodeMode)
                return self.mk(.{ .tag = .backref, .backref_index = idx });
            },
            'c' => {
                // §22.2.1 ControlEscape `\cX` (X a control letter A–Za–z) → the control character X mod 32.
                self.pos += 1; // 'c'
                if (self.peek()) |letter| {
                    if ((letter >= 'A' and letter <= 'Z') or (letter >= 'a' and letter <= 'z')) {
                        self.pos += 1;
                        return self.mk(.{ .tag = .char, .ch = letter % 32 });
                    }
                }
                // `\c` not followed by a control letter: SyntaxError in UnicodeMode; Annex B treats the
                // `\` as a literal backslash (the `c` is then an ordinary PatternCharacter).
                if (self.unicode) return CompileError.SyntaxError;
                return self.mk(.{ .tag = .char, .ch = '\\' });
            },
            'k' => {
                self.pos += 1;
                if (self.peek() != '<') return CompileError.SyntaxError;
                self.pos += 1; // '<'
                // §22.2.1 `\k<RegExpIdentifierName>` — validated like a GroupSpecifier; the index is
                // resolved after the whole pattern is parsed so forward references work.
                const name = try self.parseGroupName();
                const node = try self.mk(.{ .tag = .backref, .backref_index = 0 });
                try self.named_refs.append(self.arena, .{ .name = name, .node = node });
                return node;
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
            // §22.2.1 IdentityEscape: in UnicodeMode only SyntaxCharacters and `/` may be escaped — any
            // other `\c` (e.g. `\a`, `\M`, `\8`) is a SyntaxError. Non-UnicodeMode is Annex-B lenient.
            else => {
                if (self.unicode and !isSyntaxChar(e) and e != '/') return CompileError.SyntaxError;
                return e;
            },
        };
    }

    /// §22.2.1 RegExpIdentifierName for a `(?<name>…)` GroupSpecifier or `\k<name>` — entered with
    /// `self.pos` just past the `<`. Validates a non-empty run of RegExpIdentifierStart/Part code
    /// points (decoding raw UTF-8 and `\u`/`\u{}` escapes), consumes the closing `>`, and returns the
    /// raw name slice. An empty name, an invalid code point, or a missing `>` is a SyntaxError.
    fn parseGroupName(self: *Parser) CompileError![]const u8 {
        const start = self.pos;
        var count: usize = 0;
        while (true) {
            const b = self.peek() orelse return CompileError.SyntaxError; // unterminated `<…`
            if (b == '>') {
                if (count == 0) return CompileError.SyntaxError; // empty GroupSpecifier
                const name = self.src[start..self.pos];
                self.pos += 1; // '>'
                return name;
            }
            const cp = if (b == '\\') blk: {
                if (self.pos + 1 >= self.src.len or self.src[self.pos + 1] != 'u') return CompileError.SyntaxError;
                self.pos += 2; // `\u`
                break :blk try self.parseUnicodeEscapeCp();
            } else if (b < 0x80) blk: {
                self.pos += 1;
                break :blk @as(u21, b);
            } else blk: {
                const len = std.unicode.utf8ByteSequenceLength(b) catch return CompileError.SyntaxError;
                if (self.pos + len > self.src.len) return CompileError.SyntaxError;
                const cp = std.unicode.utf8Decode(self.src[self.pos .. self.pos + len]) catch return CompileError.SyntaxError;
                self.pos += len;
                break :blk cp;
            };
            const ok = if (count == 0) isRegExpIdStart(cp) else isRegExpIdPart(cp);
            if (!ok) return CompileError.SyntaxError;
            count += 1;
        }
    }

    /// A `\uHHHH` or `\u{H…}` escape (entered just past the `\u`), returning the code point. Used by
    /// RegExpIdentifierName; a malformed escape or an out-of-range `\u{}` value is a SyntaxError.
    fn parseUnicodeEscapeCp(self: *Parser) CompileError!u21 {
        if (self.peek() == '{') {
            self.pos += 1;
            var v: u32 = 0;
            var n: usize = 0;
            while (self.peek()) |d| {
                const nib = hexVal(d) orelse break;
                v = v * 16 + nib;
                if (v > 0x10FFFF) return CompileError.SyntaxError;
                self.pos += 1;
                n += 1;
            }
            if (n == 0 or self.peek() != '}') return CompileError.SyntaxError;
            self.pos += 1; // '}'
            return @intCast(v);
        }
        var v: u32 = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            const d = self.peek() orelse return CompileError.SyntaxError;
            const nib = hexVal(d) orelse return CompileError.SyntaxError;
            v = v * 16 + nib;
            self.pos += 1;
        }
        return @intCast(v);
    }
};

/// §12.9.5 SyntaxCharacter :: one of `^ $ \ . * + ? ( ) [ ] { } |`.
fn isSyntaxChar(c: u8) bool {
    return switch (c) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|' => true,
        else => false,
    };
}

fn hexVal(c: u8) ?u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// §22.2.1 RegExpIdentifierStart — UnicodeIDStart, `$`, or `_` (surrogate pairs fold into the decoded
/// code point under the byte model).
fn isRegExpIdStart(cp: u21) bool {
    return cp == '$' or cp == '_' or unicode_id.isIdStart(cp);
}

/// §22.2.1 RegExpIdentifierPart — UnicodeIDContinue, `$`, `_`, ZWNJ (U+200C), or ZWJ (U+200D).
fn isRegExpIdPart(cp: u21) bool {
    return cp == '$' or cp == '_' or cp == 0x200C or cp == 0x200D or unicode_id.isIdContinue(cp);
}

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
    /// When set (compiling a lookbehind body), a `concat` is emitted in reverse term order so that
    /// backward VM execution visits the terms in source order. Atoms emit unchanged — the VM consumes
    /// backward under a direction flag; only sequencing must be flipped here.
    reverse: bool = false,

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
            .class => _ = try self.emit(.{ .class = .{ .ranges = n.ranges, .negated = n.negated, .uprops = n.uprops } }),
            .assert_start => _ = try self.emit(.assert_start),
            .assert_end => _ = try self.emit(.assert_end),
            .word_boundary => _ = try self.emit(.{ .word_boundary = n.negated }),
            .backref => _ = try self.emit(.{ .backref = n.backref_index }),
            .concat => if (self.reverse) {
                var i = n.kids.len;
                while (i > 0) {
                    i -= 1;
                    try self.compileNode(n.kids[i]);
                }
            } else for (n.kids) |k| try self.compileNode(k),
            .look => try self.compileLook(n),
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
                // Forward: save start (2k) then end (2k+1). Reversed (lookbehind): the body runs
                // backward, so we encounter the group's END boundary first — emit save 2k+1 first and
                // 2k last, keeping start ≤ end in the recorded positions.
                const first: usize = if (self.reverse) 2 * n.group_index + 1 else 2 * n.group_index;
                const last: usize = if (self.reverse) 2 * n.group_index else 2 * n.group_index + 1;
                if (n.group_index > 0) _ = try self.emit(.{ .save = first });
                try self.compileNode(n.sub.?);
                if (n.group_index > 0) _ = try self.emit(.{ .save = last });
            },
            .repeat => try self.compileRepeat(n),
        }
    }

    /// Compile a lookaround body into its own self-contained sub-program (ending in `match`) and emit a
    /// `look` instruction referencing it. Lookbehind bodies compile in reverse (and run backward).
    fn compileLook(self: *Compiler, n: *Node) CompileError!void {
        var sub = Compiler{ .arena = self.arena, .reverse = n.behind };
        try sub.compileNode(n.sub.?);
        _ = try sub.emit(.match);
        const look = try self.arena.create(Look);
        look.* = .{ .insts = sub.insts.items, .num_counters = sub.num_counters, .reverse = n.behind };
        _ = try self.emit(.{ .look = .{ .negated = n.negated, .behind = n.behind, .body = look } });
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
    // §22.2.1 post-parse Static Semantics. Resolve `\k<name>` against the group names now that the
    // whole pattern (including forward references) is known; an unmatched name is a SyntaxError.
    for (p.named_refs.items) |ref| {
        var found = false;
        for (p.names.items) |ng| {
            if (std.mem.eql(u8, ng.name, ref.name)) {
                ref.node.backref_index = ng.index;
                found = true;
                break;
            }
        }
        if (!found) return CompileError.SyntaxError; // dangling \k<name>
    }
    // §22.2.1: in UnicodeMode a `\N` numeric reference past the last capturing group is a SyntaxError.
    if (unicode and p.max_backref > p.group_count) return CompileError.SyntaxError;
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

/// §12.9.5 Static Semantics: Early Errors for a RegularExpressionLiteral — the FlagText must be a set
/// of the recognized flags `dgimsuvy` with no code point repeated and not both `u` and `v`, and the
/// BodyText must parse as a Pattern (in UnicodeMode iff `u`/`v` is present). Pure (arena-only) so the
/// PARSER can enforce it at parse time: an invalid literal is a parse-phase SyntaxError, not a deferred
/// runtime one. `error.SyntaxError` covers both an invalid flag set and an unparsable pattern.
pub fn validateLiteral(arena: std.mem.Allocator, pattern: []const u8, flags: []const u8) CompileError!void {
    var seen = [_]bool{false} ** 8; // d g i m s u v y
    var unicode = false;
    var unicode_sets = false;
    for (flags) |f| {
        const idx: usize = switch (f) {
            'd' => 0,
            'g' => 1,
            'i' => 2,
            'm' => 3,
            's' => 4,
            'u' => blk: {
                unicode = true;
                break :blk 5;
            },
            'v' => blk: {
                unicode_sets = true;
                break :blk 6;
            },
            'y' => 7,
            else => return CompileError.SyntaxError, // unrecognized flag code point
        };
        if (seen[idx]) return CompileError.SyntaxError; // duplicate flag
        seen[idx] = true;
    }
    if (unicode and unicode_sets) return CompileError.SyntaxError; // `u` and `v` are mutually exclusive
    // ignore_case/multiline/dot_all do not affect parse validity; only UnicodeMode (u/v) does.
    _ = try compile(arena, pattern, false, false, false, unicode or unicode_sets);
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

/// Decode the UTF-8 code point at `input[sp]` → its scalar + byte length. An invalid/lone byte decodes
/// to itself with length 1 (the byte engine's lenient fallback). Used by the property `.class` path.
fn decodeCpFwd(input: []const u8, sp: usize) struct { cp: u21, len: usize } {
    const b = input[sp];
    if (b < 0x80) return .{ .cp = b, .len = 1 };
    const len = std.unicode.utf8ByteSequenceLength(b) catch return .{ .cp = b, .len = 1 };
    if (sp + len > input.len) return .{ .cp = b, .len = 1 };
    const cp = std.unicode.utf8Decode(input[sp .. sp + len]) catch return .{ .cp = b, .len = 1 };
    return .{ .cp = cp, .len = len };
}

/// The code point ENDING just before `sp` (back up over UTF-8 continuation bytes to the lead) → its
/// scalar + start index. For the backward (lookbehind) property `.class` path.
fn decodeCpBack(input: []const u8, sp: usize) struct { cp: u21, start: usize } {
    var s = sp - 1;
    while (s > 0 and (input[s] & 0xC0) == 0x80) s -= 1;
    const d = decodeCpFwd(input, s);
    // Only treat it as multi-byte if the decoded span actually reaches `sp` (else it's a lone byte).
    if (s + d.len == sp) return .{ .cp = d.cp, .start = s };
    return .{ .cp = input[sp - 1], .start = sp - 1 };
}

/// §22.2.1 membership for a class that carries Unicode property refs (`\p{…}`), tested by code point.
/// Byte ranges (`[a-z_…]`) match only for cp < 0x100; each `\p`/`\P` ref adds (cp ∈ prop) / (cp ∉ prop);
/// then the class-level `[^…]` negation is applied.
fn classMatchCp(cl: anytype, cp: u21, ignore_case: bool) bool {
    var matched = false;
    if (cp < 0x100 and classMatch(cl.ranges, false, @intCast(cp), ignore_case)) matched = true;
    if (!matched) for (cl.uprops) |up| {
        if (up.negate != uprops.contains(up.id, cp)) {
            matched = true;
            break;
        }
    };
    return cl.negated != matched;
}

/// A pending backtracking choice point: the lower-priority branch of a `split` to try if the preferred
/// branch fails. `undo_len` records the capture-undo-log length at the split so the saves array can be
/// rolled back to its state at that point when this alternative is taken.
const Choice = struct { pc: usize, sp: usize, undo_len: usize };

/// One entry of the backtracking undo log: the prior value of a capture slot (before a `save`) or of a
/// loop counter (before a `count_init`/`count_inc`), so it can be restored when a choice point is taken.
/// `saves_snapshot` restores the whole capture array to a copy taken before a lookaround sub-match ran
/// (a lookaround's nested backtracking can mutate many slots, so the cheapest faithful undo is a copy).
const Undo = union(enum) {
    save: struct { slot: usize, old: ?usize },
    counter: struct { idx: usize, old: usize },
    saves_snapshot: []const ?usize,
};

/// Shared per-`exec` matching context. `saves` is the single capture array threaded through the whole
/// pattern and every (possibly nested) lookaround sub-match; `steps` is the shared step budget.
const Ctx = struct {
    arena: std.mem.Allocator,
    prog: *const Program,
    input: []const u8,
    saves: []?usize,
    steps: usize = 0,
};

/// A budget on total VM steps: catastrophic backtracking (e.g. `(a*)*b` over a long non-matching input)
/// is exponential, so rather than hang we abort and report no match once the budget is spent. Legitimate
/// matches finish in far fewer steps; pathological patterns that would only match past the budget are the
/// documented casualty (Test262's catastrophic cases expect no match anyway).
const max_steps: usize = 2_000_000;

/// Backtracking execution of an instruction stream, starting at instruction 0, string position `start`.
/// Returns the end position on a full match (the shared `ctx.saves` is left holding the captures), or
/// null on failure / step-budget exhaustion. `dir` is +1 forward (the whole pattern and lookahead
/// bodies) or -1 backward (lookbehind bodies, whose instructions were compiled in reverse term order).
///
/// Iterative, with the shared `ctx.saves` array mutated in place: each `split` pushes a `Choice` for the
/// alternative branch, and each `save` logs the overwritten slot to `undo`. On backtrack the saves are
/// rolled back to the choice point's `undo_len` and execution resumes there. A `look` recursively runs
/// its body (sharing `ctx.saves`); the captures it sets persist on success and are snapshot-restored on
/// backtrack. Both stacks shrink on backtrack, so memory stays bounded by the current path depth.
fn run(ctx: *Ctx, insts: []const Inst, counters: []usize, start: usize, dir: i2) error{OutOfMemory}!?usize {
    const arena = ctx.arena;
    const input = ctx.input;
    const prog = ctx.prog;
    const saves = ctx.saves;
    var bt: std.ArrayListUnmanaged(Choice) = .empty;
    var undo: std.ArrayListUnmanaged(Undo) = .empty;
    var pc: usize = 0;
    var sp: usize = start;
    const fwd = dir > 0;
    while (true) {
        ctx.steps += 1;
        if (ctx.steps > max_steps) return null;
        // `failed` rolls back to the most recent choice point (restoring saves via the undo log); if there
        // are none, the match fails.
        var failed = false;
        switch (insts[pc]) {
            .match => return sp,
            .jmp => |x| pc = x,
            .char => |c| {
                // Forward reads input[sp] and advances; backward reads input[sp-1] and retreats.
                const have = if (fwd) sp < input.len else sp > 0;
                if (!have) {
                    failed = true;
                } else {
                    const ib = if (fwd) input[sp] else input[sp - 1];
                    const eq = if (prog.ignore_case) foldByte(ib) == foldByte(c) else ib == c;
                    if (!eq) failed = true else {
                        sp = if (fwd) sp + 1 else sp - 1;
                        pc += 1;
                    }
                }
            },
            .any => {
                const have = if (fwd) sp < input.len else sp > 0;
                const ch: u8 = if (have) (if (fwd) input[sp] else input[sp - 1]) else 0;
                if (!have or (!prog.dot_all and isLineTerm(ch))) {
                    failed = true;
                } else {
                    sp = if (fwd) sp + 1 else sp - 1;
                    pc += 1;
                }
            },
            .class => |cl| {
                const have = if (fwd) sp < input.len else sp > 0;
                if (!have) {
                    failed = true;
                } else if (cl.uprops.len != 0) {
                    // §22.2.1 a `\p{…}`-bearing class matches whole CODE POINTS (decode + advance by the
                    // utf8 length); property-free classes keep the byte fast path below (no regression).
                    if (fwd) {
                        const d = decodeCpFwd(input, sp);
                        if (!classMatchCp(cl, d.cp, prog.ignore_case)) failed = true else {
                            sp += d.len;
                            pc += 1;
                        }
                    } else {
                        const d = decodeCpBack(input, sp);
                        if (!classMatchCp(cl, d.cp, prog.ignore_case)) failed = true else {
                            sp = d.start;
                            pc += 1;
                        }
                    }
                } else {
                    const ch: u8 = if (fwd) input[sp] else input[sp - 1];
                    if (!classMatch(cl.ranges, cl.negated, ch, prog.ignore_case)) failed = true else {
                        sp = if (fwd) sp + 1 else sp - 1;
                        pc += 1;
                    }
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
                    // Forward consumes the captured bytes ahead of sp; backward consumes them behind sp.
                    const have = if (fwd) sp + seg.len <= input.len else sp >= seg.len;
                    if (!have) {
                        failed = true;
                    } else {
                        const base = if (fwd) sp else sp - seg.len;
                        for (seg, 0..) |sc, i| {
                            const ib = input[base + i];
                            const eq = if (prog.ignore_case) foldByte(ib) == foldByte(sc) else ib == sc;
                            if (!eq) {
                                failed = true;
                                break;
                            }
                        }
                        if (!failed) {
                            sp = if (fwd) sp + seg.len else sp - seg.len;
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
            .look => |lk| {
                // §22.2.2.3: run the body anchored at the current position, consuming nothing. A copy of
                // the captures is taken first so a later backtrack past this assertion can restore them;
                // for a negative assertion we always restore (its inner captures stay undefined per spec).
                const snap = try arena.dupe(?usize, saves);
                const sub_counters = try arena.alloc(usize, lk.body.num_counters);
                @memset(sub_counters, 0);
                const sub_dir: i2 = if (lk.behind) -1 else 1;
                const matched = (try run(ctx, lk.body.insts, sub_counters, sp, sub_dir)) != null;
                if (matched == lk.negated) {
                    // Negative-and-matched or positive-and-failed → assertion fails. Restore captures.
                    @memcpy(saves, snap);
                    failed = true;
                } else {
                    if (lk.negated) {
                        @memcpy(saves, snap); // negative success: inner captures are reset
                    } else {
                        // positive success: keep the body's captures, but log a snapshot so a backtrack
                        // past this point restores them.
                        try undo.append(arena, .{ .saves_snapshot = snap });
                    }
                    pc += 1; // position unchanged — lookaround consumes nothing
                }
            },
        }
        if (failed) {
            const cp = bt.pop() orelse return null;
            while (undo.items.len > cp.undo_len) {
                switch (undo.pop().?) {
                    .save => |u| saves[u.slot] = u.old,
                    .counter => |u| counters[u.idx] = u.old,
                    .saves_snapshot => |snap| @memcpy(saves, snap),
                }
            }
            pc = cp.pc;
            sp = cp.sp;
        }
    }
}

/// Backtracking execution of the whole pattern at string position `at`. Returns the capture saves on a
/// full match, or null on failure / step-budget exhaustion.
fn matchAt(arena: std.mem.Allocator, prog: *const Program, input: []const u8, at: usize) error{OutOfMemory}!?[]?usize {
    const nslots = 2 * (prog.num_groups + 1);
    const saves = try arena.alloc(?usize, nslots);
    @memset(saves, null);
    const counters = try arena.alloc(usize, prog.num_counters);
    @memset(counters, 0);
    var ctx = Ctx{ .arena = arena, .prog = prog, .input = input, .saves = saves };
    if ((try run(&ctx, prog.insts, counters, at, 1)) != null) return saves;
    return null;
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
