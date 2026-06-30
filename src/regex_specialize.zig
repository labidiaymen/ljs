//! Compile-time regex specialization ("Plan B").
//! =============================================
//!
//! ## What this file does, in one sentence
//! When a program contains a *literal* regex used in `.test()` (e.g.
//! `/^\d+\.\d+$/.test(s)`), this module turns that pattern into a small, fast,
//! pattern-specific Zig matcher *at compile time*, instead of leaving it to the
//! general-purpose runtime engine in `regex_rt.zig`.
//!
//! ## Why bother (the experiment)
//! Lumen has two ways to match a regex:
//!
//!   1. The **runtime interpreter** (`regex_rt.zig`): parses the pattern into a
//!      tiny bytecode program and runs a backtracking VM. General — handles every
//!      pattern — but it pays interpreter overhead on every byte (a `switch` per
//!      instruction, recursion for backtracking).
//!
//!   2. This **compile-time specializer**: because a *literal* pattern is known
//!      while we are generating code, we can emit straight-line Zig that matches
//!      exactly that pattern ("scan digits, expect a dot, scan digits, ...").
//!      No interpreter, no bytecode, no per-call setup.
//!
//! In benchmarks the specialized form runs several times faster than V8's JIT
//! `RegExp` for anchored patterns like semver/identifier validation, whereas the
//! interpreter is a bit slower than V8. The point of the experiment: an
//! ahead-of-time compiler can beat a runtime JIT *for the cases it can specialize*
//! because it does the specialization for free, before the program ever runs.
//!
//! ## The golden rule: specialize-or-fall-back, never specialize-and-be-wrong
//! `emitTest` returns `true` only when it has emitted a matcher it can *prove* is
//! equivalent to the real regex semantics. For anything it is not sure about it
//! returns `false`, and the caller (the codegen in `lumen_compiler.zig`) falls
//! back to the runtime interpreter. So correctness never depends on the
//! specializer being clever — only speed does. Every pattern still works.
//!
//! ## The subset we specialize
//! We only specialize patterns that need **no backtracking**, so that a single
//! greedy left-to-right scan is correct. Concretely:
//!
//!   - optional leading `^` and trailing `$` anchors
//!   - a flat sequence of single-atom *terms*: a literal char, `.`, or a class
//!     `[...]` / `\d \w \s` (and negations)
//!   - each term may carry a greedy quantifier `* + ? {n,m}`
//!
//! Patterns outside this shape (alternation `a|b`, groups used with a quantifier
//! like `(ab)+`, the `i`/`m`/`g` flags, ...) return `false` and use the
//! interpreter. `x{n,m}` *is* supported: the parser desugars it into a concat of
//! copies, and `flatten` turns those copies into ordinary terms.
//!
//! ## The safety proof (why no backtracking is needed)
//! A greedy quantifier is dangerous only if, after consuming greedily, a *later*
//! mandatory part of the pattern still needs one of the characters it ate (that is
//! when a real engine backtracks). We avoid that by requiring every greedy/optional
//! term's atom to be **disjoint** from the next *mandatory* term's atom — no byte
//! can match both. Then greedy consumption can never "steal" a character a later
//! term needs, so a one-pass scan is exact. `atomsDisjoint` checks this by brute
//! force over all 256 byte values. If the proof fails we fall back.
//!
//! ## Shape of the emitted code
//! For `/^\d+\.\d+$/.test(s)` we emit a labeled block expression (so it can sit
//! inside an `if (...)`), roughly:
//!
//!     __re_0: {
//!         const __re_s_0 = <s>;             // evaluate the argument once
//!         var __re_i_0: usize = 0;          // cursor
//!         { const a = __re_i_0;             // \d+  (greedy, needs >= 1)
//!           while (__re_i_0 < __re_s_0.len and (__re_s_0[__re_i_0] >= 48 and __re_s_0[__re_i_0] <= 57)) __re_i_0 += 1;
//!           if (__re_i_0 == a) break :__re_0 false; }
//!         if (__re_i_0 >= __re_s_0.len or !(__re_s_0[__re_i_0] == 46)) break :__re_0 false; __re_i_0 += 1;  // '.'
//!         ... \d+ again ...
//!         if (__re_i_0 != __re_s_0.len) break :__re_0 false;   // trailing $
//!         break :__re_0 true;
//!     }
//!
//! Unanchored patterns wrap that in a `while` over start positions, where a
//! mismatch does `break :__re_try_N` (try the next start) instead of failing.
//! Character comparisons use raw byte values (`== 46`) to dodge Zig char-literal
//! escaping entirely.
//!
//! A unique `uid` per call keeps the generated identifiers from colliding when
//! several specialized tests appear in one expression.
//!
//! ## How it plugs in
//! `lumen_compiler.zig` calls `emitTest(...)` from the `.method_call` codegen for
//! a regex `.test()`. It passes `emitExpr` (its own expression emitter) in as a
//! function pointer so this module does not need to import the codegen back —
//! avoiding a circular dependency.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const diag = @import("lumen_diag.zig");
const regex_engine = @import("regex_rt.zig");

const Expr = ast.Expr;
const CompileError = diag.CompileError;
/// A node of the parsed regex AST (shared with the runtime engine in regex_rt).
const ReNode = regex_engine.__lumen_regex.Node;

/// The codegen's expression emitter, passed in to avoid importing the codegen
/// module back (which would be a circular import). It writes the Zig source for a
/// Lumen expression — here, the string argument of `.test(arg)`.
pub const EmitExprFn = *const fn (e: *const Expr, w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void;

/// Per-call counter giving each emitted matcher unique identifier/label names so
/// multiple specialized `.test()` calls in one expression never collide.
var g_uid: usize = 0;

/// Does `byte` match this single atom (literal char / `.` / class)? Used only by
/// the disjointness check below; the *emitted* code re-derives the same condition.
fn atomMatches(atom: *const ReNode, byte: u8) bool {
    return switch (atom.*) {
        .char => |c| byte == c,
        .any => byte != '\n',
        .class => |cl| blk: {
            var hit = false;
            for (cl.ranges) |r| {
                if (byte >= r.lo and byte <= r.hi) {
                    hit = true;
                    break;
                }
            }
            break :blk hit != cl.negated;
        },
        else => false,
    };
}

/// Whether `n` is a single, un-quantified atom we know how to match in one step.
fn bareAtom(n: *const ReNode) bool {
    return switch (n.*) {
        .char, .any, .class => true,
        else => false,
    };
}

/// True when no byte matches both atoms. This is the safety property that lets a
/// greedy quantifier on `a` run without backtracking when followed by `b`.
fn atomsDisjoint(a: *const ReNode, b: *const ReNode) bool {
    var byte: u16 = 0;
    while (byte < 256) : (byte += 1) {
        const bb: u8 = @intCast(byte);
        if (atomMatches(a, bb) and atomMatches(b, bb)) return false;
    }
    return true;
}

/// A term = one atom plus its quantifier. `quant`: 0 one, 1 `*`, 2 `+`, 3 `?`.
const Term = struct { atom: *const ReNode, quant: u8 };

/// Classifies a node as a specializable term, or null if it is not one (e.g. an
/// alternation, or a quantifier wrapping a group rather than a bare atom).
fn termInfo(n: *const ReNode) ?Term {
    return switch (n.*) {
        .char, .any, .class => Term{ .atom = n, .quant = 0 },
        .star => |a| if (bareAtom(a)) Term{ .atom = a, .quant = 1 } else null,
        .plus => |a| if (bareAtom(a)) Term{ .atom = a, .quant = 2 } else null,
        .quest => |a| if (bareAtom(a)) Term{ .atom = a, .quant = 3 } else null,
        else => null,
    };
}

/// Emits the boolean Zig condition "the character `charx` matches `atom`", using
/// raw byte values to avoid char-literal escaping.
fn emitAtomCond(atom: *const ReNode, charx: []const u8, w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    switch (atom.*) {
        .char => |c| try w.print(arena, "{s} == {d}", .{ charx, c }),
        .any => try w.print(arena, "{s} != 10", .{charx}),
        .class => |cl| {
            try w.appendSlice(arena, if (cl.negated) "!(" else "(");
            if (cl.ranges.len == 0) try w.appendSlice(arena, "false");
            for (cl.ranges, 0..) |r, i| {
                if (i > 0) try w.appendSlice(arena, " or ");
                if (r.lo == r.hi)
                    try w.print(arena, "{s} == {d}", .{ charx, r.lo })
                else
                    try w.print(arena, "({s} >= {d} and {s} <= {d})", .{ charx, r.lo, charx, r.hi });
            }
            try w.appendSlice(arena, ")");
        },
        else => unreachable,
    }
}

/// Flattens nested `concat` nodes into one term list. The parser desugars
/// `x{n,m}` into a concat of copies, so flattening makes those copies first-class
/// terms the specializer handles directly.
fn flatten(n: *const ReNode, list: *std.ArrayListUnmanaged(*const ReNode), arena: std.mem.Allocator) CompileError!void {
    switch (n.*) {
        .concat => |items| for (items) |it| try flatten(it, list, arena),
        else => try list.append(arena, n),
    }
}

/// Emits the per-term matching code. `fail` is the statement run on a mismatch
/// (`break :__re_N false` when anchored, `break :__re_try_N` to try the next
/// start position when unanchored).
fn emitTerms(middle: []const *const ReNode, uid: usize, charx: []const u8, fail: []const u8, has_end: bool, w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    for (middle) |tn| {
        const ti = termInfo(tn).?;
        switch (ti.quant) {
            0 => { // exactly one
                try w.print(arena, "if (__re_i_{d} >= __re_s_{d}.len or !(", .{ uid, uid });
                try emitAtomCond(ti.atom, charx, w, arena);
                try w.print(arena, ")) {s}; __re_i_{d} += 1; ", .{ fail, uid });
            },
            1 => { // star (greedy)
                try w.print(arena, "while (__re_i_{d} < __re_s_{d}.len and (", .{ uid, uid });
                try emitAtomCond(ti.atom, charx, w, arena);
                try w.print(arena, ")) __re_i_{d} += 1; ", .{uid});
            },
            2 => { // plus (greedy, >=1)
                try w.print(arena, "{{ const __re_a_{d} = __re_i_{d}; while (__re_i_{d} < __re_s_{d}.len and (", .{ uid, uid, uid, uid });
                try emitAtomCond(ti.atom, charx, w, arena);
                try w.print(arena, ")) __re_i_{d} += 1; if (__re_i_{d} == __re_a_{d}) {s}; }} ", .{ uid, uid, uid, fail });
            },
            else => { // quest (0 or 1)
                try w.print(arena, "if (__re_i_{d} < __re_s_{d}.len and (", .{ uid, uid });
                try emitAtomCond(ti.atom, charx, w, arena);
                try w.print(arena, ")) __re_i_{d} += 1; ", .{uid});
            },
        }
    }
    if (has_end) try w.print(arena, "if (__re_i_{d} != __re_s_{d}.len) {s}; ", .{ uid, uid, fail });
}

/// Tries to emit a specialized straight-line matcher for `/source/flags.test(arg)`.
/// Returns true if it emitted the code; false means the caller must fall back to
/// the runtime interpreter. See the module header for the subset and safety proof.
pub fn emitTest(source: []const u8, flags: []const u8, arg: *const Expr, emit_expr: EmitExprFn, w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!bool {
    if (flags.len != 0) return false; // the `i`/`m`/`g` flags are not specialized yet
    const re_ast = regex_engine.__lumen_regex.parse(arena, source) orelse return false;

    // Flatten nested concats (notably the parser's `{n,m}` desugaring) into one
    // flat list of terms.
    var term_list: std.ArrayListUnmanaged(*const ReNode) = .empty;
    try flatten(re_ast, &term_list, arena);
    const terms = term_list.items;
    if (terms.len == 0) return false;

    // Peel off a leading `^` and trailing `$`.
    var lo: usize = 0;
    var anchored = false;
    if (terms[0].* == .astart) {
        anchored = true;
        lo = 1;
    }
    var hi = terms.len;
    var has_end = false;
    if (hi > lo and terms[hi - 1].* == .aend) {
        has_end = true;
        hi -= 1;
    }
    const middle = terms[lo..hi];
    if (middle.len == 0) return false;

    // Every middle term must be a single-atom term; no stray anchors in between.
    for (middle) |tn| {
        switch (tn.*) {
            .astart, .aend => return false,
            else => {},
        }
        _ = termInfo(tn) orelse return false;
    }
    // Safety: every greedy/optional term must be disjoint from the next mandatory
    // term, so greedy consumption never needs to backtrack (see module header).
    for (middle, 0..) |tn, idx| {
        const ti = termInfo(tn).?;
        if (ti.quant == 0) continue; // exact-one term: no greediness to worry about
        var j = idx + 1;
        while (j < middle.len) : (j += 1) {
            const tj = termInfo(middle[j]).?;
            if (tj.quant == 0 or tj.quant == 2) { // 0 = one, 2 = plus: both mandatory
                if (!atomsDisjoint(ti.atom, tj.atom)) return false;
                break;
            }
        }
    }

    // Emit the matcher as a labeled block expression.
    const uid = g_uid;
    g_uid += 1;
    const charx = try std.fmt.allocPrint(arena, "__re_s_{d}[__re_i_{d}]", .{ uid, uid });
    try w.print(arena, "__re_{d}: {{ const __re_s_{d} = ", .{ uid, uid });
    try emit_expr(arg, w, arena);
    try w.appendSlice(arena, "; ");
    if (anchored) {
        // Anchored at start: match from position 0; a mismatch fails outright.
        const fail = try std.fmt.allocPrint(arena, "break :__re_{d} false", .{uid});
        try w.print(arena, "var __re_i_{d}: usize = 0; ", .{uid});
        try emitTerms(middle, uid, charx, fail, has_end, w, arena);
        try w.print(arena, "break :__re_{d} true; }}", .{uid});
    } else {
        // Unanchored: try the match at each start position; a mismatch advances
        // to the next start rather than failing.
        const fail = try std.fmt.allocPrint(arena, "break :__re_try_{d}", .{uid});
        try w.print(arena, "var __re_st_{d}: usize = 0; while (__re_st_{d} <= __re_s_{d}.len) : (__re_st_{d} += 1) {{ var __re_i_{d}: usize = __re_st_{d}; __re_try_{d}: {{ ", .{ uid, uid, uid, uid, uid, uid, uid });
        try emitTerms(middle, uid, charx, fail, has_end, w, arena);
        try w.print(arena, "break :__re_{d} true; }} }} break :__re_{d} false; }}", .{ uid, uid });
    }
    return true;
}
