//! Tier 1 of the ljs JIT (spec 112) — compile the bytecode VM's **integer subset** to native x86-64.
//! This is the tier that beats Node on numeric compute: a JIT'd integer loop runs entirely in
//! registers with V8-style small-integer (SMI) arithmetic + overflow guards, deopting to the
//! interpreter on anything it can't prove.
//!
//! Contract (correctness by construction):
//!   * Only a tiny, side-effect-FREE subset compiles: load_const(int)/load_slot/store_slot,
//!     add/sub/mul (overflow-guarded), lt/gt/le/ge **fused** with a following conditional jump,
//!     jump / jump_if_false / jump_if_true (integer truthiness), ret, ret_undef. ANYTHING else →
//!     `compileChunk` returns null → caller uses the tree-walk. So a JIT'd function is a pure
//!     function of its integer args (no calls, no property/global access, no closures).
//!   * Values are unboxed to **i64** but every result is guarded to the **i32 SMI range** (exactly
//!     V8's 32-bit SMI window) — so i64 arithmetic == f64 arithmetic (integers ≤ 2^31 are f64-exact).
//!     On overflow the native code sets `*deopt` and returns; the caller re-runs on the interpreter.
//!   * The caller guards that every arg is a safe integer before calling; a non-int arg → no JIT.
//!     Locals must be written before read (a store that dominates — conservatively, a store before
//!     any branch); else the chunk is rejected. Together these make the unboxing sound.
//!
//! Win64 ABI. The JIT'd function is `fn(slots: [*]i64, deopt: *u8) i64` — rcx = slots, rdx = deopt.
const std = @import("std");
const bc = @import("bytecode.zig");
const Op = bc.Op;
const Chunk = bc.Chunk;
const x64 = @import("jit_x64.zig");
const Reg = x64.Reg;
const Emitter = x64.Emitter;
const Value = @import("value.zig").Value;

/// PERF (spec 112): global on/off for the native JIT (set from `LJS_JIT` by the CLI / harness).
/// Default OFF until its differential Test262 is clean. Independent of the bytecode-VM flag.
var g_jit_enabled: bool = false;
pub fn setEnabled(on: bool) void {
    g_jit_enabled = on;
}
pub fn enabled() bool {
    return g_jit_enabled;
}

/// A compiled native function: integer slots in, integer result out; `*deopt` set to 1 if the native
/// code bailed (overflow / reached an unsupported path) — the caller then re-runs the interpreter.
pub const JitFn = *const fn (slots: [*]i64, deopt: *u8) callconv(.c) i64;

// Register file (Win64): slots in callee-saved regs (preserved via push/pop), operand stack in
// caller-saved regs, deopt pointer parked in r15. Bail if a chunk needs more than we have.
const slot_regs = [_]Reg{ .rbx, .rsi, .rdi, .r12, .r13, .r14 };
const stack_regs = [_]Reg{ .rax, .rcx, .rdx, .r8, .r9, .r10, .r11 };
const deopt_reg: Reg = .r15;
const slots_ptr: Reg = .rcx; // Win64 arg0

inline fn readU16(code: []const u8, ip: usize) u16 {
    return @as(u16, code[ip]) | (@as(u16, code[ip + 1]) << 8);
}

const Fixup = struct { at: usize, target_pc: usize };

const Operand = union(enum) { imm: i32, slot: u16 };
const SlotUpdate = struct {
    op: Op, // add / sub / mul
    operand: Operand,
    end_ip: usize,
};

/// Match `<operand>, (add|sub|mul), dup, store_slot X, pop` starting at byte `ip` (right after a
/// `load_slot X`), where the store targets the same slot X — i.e. `X = X OP operand` as a discarded
/// statement. Returns the fused op + operand + the byte offset just past `pop`, or null.
fn fuseSlotUpdate(code: []const u8, consts: []const Value, ip: usize, x: u16) ?SlotUpdate {
    // operand: load_const k (3 bytes) → imm, or load_slot y (3 bytes) → slot. Then arith(1) dup(1)
    // store_slot(3) pop(1): the operand op + 3 trailing ops, so the window is ip+3 .. ip+9.
    if (ip + 9 > code.len) return null;
    const opnd_op: Op = @enumFromInt(code[ip]);
    const operand: Operand = switch (opnd_op) {
        .load_const => blk: {
            const k = @as(u16, code[ip + 1]) | (@as(u16, code[ip + 2]) << 8);
            if (k >= consts.len) return null;
            const c = asSmi(consts[k]) orelse return null;
            break :blk .{ .imm = @intCast(c) };
        },
        .load_slot => .{ .slot = @as(u16, code[ip + 1]) | (@as(u16, code[ip + 2]) << 8) },
        else => return null,
    };
    const arith: Op = @enumFromInt(code[ip + 3]);
    switch (arith) {
        .add, .sub, .mul => {},
        else => return null,
    }
    if (@as(Op, @enumFromInt(code[ip + 4])) != .dup) return null;
    if (@as(Op, @enumFromInt(code[ip + 5])) != .store_slot) return null;
    const store_x = @as(u16, code[ip + 6]) | (@as(u16, code[ip + 7]) << 8);
    if (store_x != x) return null;
    if (@as(Op, @enumFromInt(code[ip + 8])) != .pop) return null;
    return .{ .op = arith, .operand = operand, .end_ip = ip + 9 };
}

/// Compile `chunk` (whose first `n_params` slots are the parameters) to native code, or null if it
/// uses anything outside the integer subset. The returned `JitFn` lives in `arena`-owned RWX memory.
pub fn compileChunk(arena: std.mem.Allocator, chunk: *const Chunk, n_params: u16) ?JitFn {
    if (chunk.n_slots > slot_regs.len) return null;
    if (chunk.max_stack > stack_regs.len) return null;

    var e = Emitter{ .arena = arena };
    const code = chunk.code.items;
    const consts = chunk.consts.items;

    var pc_to_native = arena.alloc(usize, code.len + 1) catch return null;
    for (pc_to_native) |*p| p.* = 0;
    var jumps: std.ArrayListUnmanaged(Fixup) = .empty;
    var deopts: std.ArrayListUnmanaged(usize) = .empty;
    var epi_jumps: std.ArrayListUnmanaged(usize) = .empty;

    // `written[s]` = slot s provably holds an integer before any read (params always do; a local
    // gains it via a store before the first branch). `branched` goes true at the first jump.
    var written = [_]bool{false} ** slot_regs.len;
    var s_i: u16 = 0;
    while (s_i < n_params) : (s_i += 1) written[s_i] = true;
    var branched = false;

    // ── prologue: save callee-saved regs, park deopt ptr, load params into slot regs ──
    for (slot_regs) |r| e.push(r) catch return null;
    e.push(deopt_reg) catch return null;
    e.movReg(deopt_reg, .rdx) catch return null; // r15 = deopt ptr (rdx = Win64 arg1)
    {
        var i: u16 = 0;
        while (i < n_params) : (i += 1) e.movFromMem(slot_regs[i], slots_ptr, @intCast(i * 8)) catch return null;
    }

    var ip: usize = 0;
    var sp: i32 = 0; // compile-time operand-stack height
    while (ip < code.len) {
        pc_to_native[ip] = e.here();
        const op: Op = @enumFromInt(code[ip]);
        ip += 1;
        switch (op) {
            .load_const => {
                const k = readU16(code, ip);
                const v = consts[k];
                const iv = asSmi(v) orelse return null;
                // Peephole: `<a>, load_const C, (shl|shr|shr_un)` → shift a by (C & 31) using the
                // immediate form (no count register, so no CL juggling). `>>` is arithmetic (sar),
                // `>>>` is logical (shr) and deopts if the uint32 result exceeds the i32 SMI window.
                if (sp >= 1 and ip + 2 < code.len) {
                    const nxt: Op = @enumFromInt(code[ip + 2]);
                    const dst = stack_regs[@intCast(sp - 1)];
                    const amt: u8 = @intCast(iv & 31);
                    switch (nxt) {
                        .shl => {
                            e.shlImm32(dst, amt) catch return null;
                            ip += 3;
                            continue;
                        },
                        .shr => {
                            e.sarImm32(dst, amt) catch return null;
                            ip += 3;
                            continue;
                        },
                        .shr_un => {
                            e.shrImm32(dst, amt) catch return null;
                            // uint32 result with bit 31 set is ≥ 2^31 → not an SMI → deopt.
                            e.cmpImm32(dst, 0) catch return null;
                            deopts.append(arena, e.jcc(.l) catch return null) catch return null;
                            ip += 3;
                            continue;
                        },
                        else => {},
                    }
                }
                ip += 2;
                if (sp >= stack_regs.len) return null;
                e.movImm32(stack_regs[@intCast(sp)], @intCast(iv)) catch return null;
                sp += 1;
            },
            .load_slot => {
                const s = readU16(code, ip);
                if (s >= chunk.n_slots) return null;
                if (!written[s]) return null; // read-before-write → not provably an integer
                // Peephole: `s = s OP operand` (load_slot s, <operand>, add/sub/mul, dup, store_slot s,
                // pop) compiles straight onto the slot register — `op32 slotReg[s], operand; jo` — with
                // no load/temp/store round-trip. This is the dominant hot-loop shape (i = i + 1, s += i).
                if (fuseSlotUpdate(code, consts, ip + 2, s)) |fu| {
                    const dst = slot_regs[s];
                    switch (fu.operand) {
                        .imm => |c| switch (fu.op) {
                            .add => e.addImm32(dst, c) catch return null,
                            .sub => e.subImm32(dst, c) catch return null,
                            .mul => e.imulImm32(dst, dst, c) catch return null,
                            else => unreachable,
                        },
                        .slot => |y| {
                            if (y >= chunk.n_slots or !written[y]) return null;
                            switch (fu.op) {
                                .add => e.add32(dst, slot_regs[y]) catch return null,
                                .sub => e.sub32(dst, slot_regs[y]) catch return null,
                                .mul => e.imul32(dst, slot_regs[y]) catch return null,
                                else => unreachable,
                            }
                        },
                    }
                    deopts.append(arena, e.jcc(.o) catch return null) catch return null;
                    if (fu.op == .mul) { // zero product may be -0 (see above)
                        e.cmpImm32(dst, 0) catch return null;
                        deopts.append(arena, e.jcc(.e) catch return null) catch return null;
                    }
                    ip = fu.end_ip; // net stack height unchanged
                    continue;
                }
                ip += 2;
                if (sp >= stack_regs.len) return null;
                e.movReg32(stack_regs[@intCast(sp)], slot_regs[s]) catch return null;
                sp += 1;
            },
            .store_slot => {
                const s = readU16(code, ip);
                ip += 2;
                if (s >= chunk.n_slots or sp < 1) return null;
                sp -= 1;
                e.movReg32(slot_regs[s], stack_regs[@intCast(sp)]) catch return null;
                if (!branched) written[s] = true;
            },
            .pop => {
                if (sp < 1) return null;
                sp -= 1;
            },
            .dup => {
                // Peephole: `dup, store_slot X, pop` (an assignment whose value is discarded) → store
                // the top straight into X with no duplicate. Covers `x = <expr>;` statements.
                if (ip + 4 <= code.len and @as(Op, @enumFromInt(code[ip])) == .store_slot and
                    @as(Op, @enumFromInt(code[ip + 3])) == .pop)
                {
                    const s = readU16(code, ip + 1);
                    if (s >= chunk.n_slots or sp < 1) return null;
                    e.movReg32(slot_regs[s], stack_regs[@intCast(sp - 1)]) catch return null;
                    sp -= 1;
                    if (!branched) written[s] = true;
                    ip += 4; // skip store_slot (3) + pop (1)
                    continue;
                }
                if (sp < 1 or sp >= stack_regs.len) return null;
                e.movReg32(stack_regs[@intCast(sp)], stack_regs[@intCast(sp - 1)]) catch return null;
                sp += 1;
            },
            inline .add, .sub, .mul => |o| {
                if (sp < 2) return null;
                const a = stack_regs[@intCast(sp - 2)];
                const b = stack_regs[@intCast(sp - 1)];
                switch (o) {
                    .add => e.add32(a, b) catch return null,
                    .sub => e.sub32(a, b) catch return null,
                    .mul => e.imul32(a, b) catch return null,
                    else => unreachable,
                }
                // SMI overflow guard: the 32-bit op set OF on i32 overflow — a single `jo` to deopt
                // (vs. range compares). Operands are i32-range, so i32 arithmetic == f64 arithmetic.
                deopts.append(arena, e.jcc(.o) catch return null) catch return null;
                // A zero product may be IEEE -0 (e.g. -1*0); integer 0 boxes to +0, so deopt on it.
                if (o == .mul) {
                    e.cmpImm32(a, 0) catch return null;
                    deopts.append(arena, e.jcc(.e) catch return null) catch return null;
                }
                sp -= 1;
            },
            // ── bitwise binary: JS `& | ^` are ToInt32-based; on i32 SMIs the result is a clean i32
            //    (no overflow, no -0), so no guard is needed. ──
            inline .bit_and, .bit_or, .bit_xor => |o| {
                if (sp < 2) return null;
                const a = stack_regs[@intCast(sp - 2)];
                const b = stack_regs[@intCast(sp - 1)];
                switch (o) {
                    .bit_and => e.and32(a, b) catch return null,
                    .bit_or => e.or32(a, b) catch return null,
                    .bit_xor => e.xor32(a, b) catch return null,
                    else => unreachable,
                }
                sp -= 1;
            },
            .neg => {
                if (sp < 1) return null;
                const v = stack_regs[@intCast(sp - 1)];
                // -x: negating integer 0 must yield IEEE -0 (deopt), and -(i32_min) overflows i32 (jo).
                e.cmpImm32(v, 0) catch return null;
                deopts.append(arena, e.jcc(.e) catch return null) catch return null;
                e.neg32(v) catch return null;
                deopts.append(arena, e.jcc(.o) catch return null) catch return null;
            },
            .pos => {
                // +x = ToNumber(x); x is already a number (SMI) here, so this is the identity — no code.
                if (sp < 1) return null;
            },
            inline .lt, .gt, .le, .ge => |o| {
                // Must be immediately consumed by a conditional jump (fused compare+branch); the JIT
                // doesn't materialize boolean values.
                if (ip >= code.len or sp < 2) return null;
                const next: Op = @enumFromInt(code[ip]);
                const on_true = switch (next) {
                    .jump_if_true => true,
                    .jump_if_false => false,
                    else => return null,
                };
                ip += 1;
                const target = readU16(code, ip);
                ip += 2;
                const a = stack_regs[@intCast(sp - 2)];
                const b = stack_regs[@intCast(sp - 1)];
                e.cmp32(a, b) catch return null; // flags = a - b (32-bit signed)
                // branch-when-true uses the op's condition; branch-when-false uses its negation.
                const cond: x64.Cond = switch (o) {
                    .lt => if (on_true) .l else .ge,
                    .gt => if (on_true) .g else .le,
                    .le => if (on_true) .le else .g,
                    .ge => if (on_true) .ge else .l,
                    else => unreachable,
                };
                jumps.append(arena, .{ .at = e.jcc(cond) catch return null, .target_pc = target }) catch return null;
                branched = true;
                sp -= 2;
            },
            .jump => {
                const target = readU16(code, ip);
                ip += 2;
                jumps.append(arena, .{ .at = e.jmp() catch return null, .target_pc = target }) catch return null;
                branched = true;
            },
            inline .jump_if_false, .jump_if_true => |o| {
                // Standalone truthiness test on an integer value: 0 = falsy.
                const target = readU16(code, ip);
                ip += 2;
                if (sp < 1) return null;
                const v = stack_regs[@intCast(sp - 1)];
                e.cmpImm32(v, 0) catch return null;
                const cond: x64.Cond = if (o == .jump_if_false) .e else .ne;
                jumps.append(arena, .{ .at = e.jcc(cond) catch return null, .target_pc = target }) catch return null;
                branched = true;
                sp -= 1;
            },
            .ret => {
                if (sp < 1) return null;
                e.movsxd(.rax, stack_regs[@intCast(sp - 1)]) catch return null; // sign-extend i32 SMI → i64
                epi_jumps.append(arena, e.jmp() catch return null) catch return null;
                sp -= 1;
            },
            .ret_undef => {
                // The JIT only returns integers; `return undefined` (or falling off the end) deopts so
                // the interpreter produces the correct `undefined`.
                deopts.append(arena, e.jmp() catch return null) catch return null;
            },
            else => return null, // div/mod/bitops/globals/calls/properties/logical-keep/… → tree-walk
        }
    }

    // ── deopt + epilogue (shared tails) ──
    const deopt_label = e.here();
    e.movByteImm(deopt_reg, 1) catch return null; // *deopt = 1, then fall through to the epilogue
    const epi_label = e.here();
    e.pop(deopt_reg) catch return null;
    var ri: usize = slot_regs.len;
    while (ri > 0) {
        ri -= 1;
        e.pop(slot_regs[ri]) catch return null;
    }
    e.ret() catch return null;

    for (deopts.items) |at| e.patch(at, deopt_label);
    for (epi_jumps.items) |at| e.patch(at, epi_label);
    for (jumps.items) |f| e.patch(f.at, pc_to_native[f.target_pc]);

    return x64.makeExecutable(JitFn, e.code.items);
}

/// A `Value` that is a number with an integral value in the i32 SMI window → its i64 value, else null.
/// Rejects `-0` (an i32 SMI can't carry the sign of zero; a function that returns it must see the real
/// `-0` on the tree-walk) — so a `-0` arg makes the call deopt rather than silently become `+0`.
pub fn asSmi(v: Value) ?i64 {
    if (v != .number) return null;
    const x = v.number;
    if (x != @trunc(x)) return null;
    if (x < -2147483648.0 or x > 2147483647.0) return null;
    if (x == 0 and std.math.signbit(x)) return null; // -0
    return @intFromFloat(x);
}

// ── tests ──────────────────────────────────────────────────────────────────────
const builtin = @import("builtin");
const compiler = @import("compiler.zig");
const Parser = @import("parser.zig").Parser;

fn jitOf(arena: std.mem.Allocator, src: []const u8) !struct { fn_ptr: JitFn, n_params: u16 } {
    const program = try Parser.parseMode(arena, src, false);
    const fdecl = program.statements[0].func_decl;
    var n_params: u16 = 0;
    const chunk = compiler.compile(arena, fdecl.params, fdecl.body, &n_params) orelse return error.NotCompilable;
    const f = compileChunk(arena, chunk, n_params) orelse return error.NotJitable;
    return .{ .fn_ptr = f, .n_params = n_params };
}

fn runJit(j: anytype, args: []const i64) struct { result: i64, deopt: u8 } {
    var slots: [16]i64 = undefined;
    for (slots[0..]) |*s| s.* = 0;
    for (args, 0..) |a, i| slots[i] = a;
    var deopt: u8 = 0;
    const r = j.fn_ptr(&slots, &deopt);
    return .{ .result = r, .deopt = deopt };
}

test "jit: sum loop matches the spec" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var ai = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ai.deinit();
    const a = ai.allocator();
    const j = try jitOf(a, "function f(n){ var s = 0; var i = 0; while (i < n) { s = s + i; i = i + 1; } return s; }");
    try std.testing.expectEqual(@as(i64, 0), runJit(j, &.{0}).deopt);
    try std.testing.expectEqual(@as(i64, 4950), runJit(j, &.{100}).result);
    try std.testing.expectEqual(@as(i64, 12497500), runJit(j, &.{5000}).result);
    try std.testing.expectEqual(@as(i64, 0), runJit(j, &.{0}).result);
}

test "jit: arithmetic + for loop" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var ai = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ai.deinit();
    const a = ai.allocator();
    const j = try jitOf(a, "function f(a, b){ return a * b - a; }");
    try std.testing.expectEqual(@as(i64, 36), runJit(j, &.{ 6, 7 }).result); // 42-6
    const k = try jitOf(a, "function f(n){ var t = 0; for (var i = 1; i <= n; i = i + 1) { t = t + i; } return t; }");
    try std.testing.expectEqual(@as(i64, 55), runJit(k, &.{10}).result);
}

test "jit: overflow deopts (stays f64-exact)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var ai = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ai.deinit();
    const a = ai.allocator();
    // 100000*100000 = 1e10 overflows the i32 SMI window → must deopt, not return a wrong int.
    const j = try jitOf(a, "function f(a, b){ return a * b; }");
    try std.testing.expectEqual(@as(u8, 1), runJit(j, &.{ 100000, 100000 }).deopt);
    try std.testing.expectEqual(@as(i64, 6), runJit(j, &.{ 2, 3 }).result); // small → no deopt
    // -1 * 0 is IEEE -0, not integer 0 → must deopt so the interpreter yields -0.
    try std.testing.expectEqual(@as(u8, 1), runJit(j, &.{ -1, 0 }).deopt);
    try std.testing.expectEqual(@as(i64, 12), runJit(j, &.{ 3, 4 }).result);
}

test "jit: duplicate-parameter function is not JIT-able" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var ai = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ai.deinit();
    const a = ai.allocator();
    // `f(x, x)` (sloppy, last-wins) must fall back to the tree-walk: the compiler rejects it (the
    // 1-slot-per-param model can't express last-wins), so it never reaches the JIT.
    try std.testing.expectError(error.NotCompilable, jitOf(a, "function f(x, x){ return x; }"));
}

test "jit: bitwise + unary" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var ai = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ai.deinit();
    const a = ai.allocator();
    const j = try jitOf(a, "function f(a, b){ return (a & b) | (a ^ b); }"); // == a | b
    try std.testing.expectEqual(@as(i64, 14), runJit(j, &.{ 12, 10 }).result); // 8 | 6
    const m = try jitOf(a, "function f(a){ return -a; }");
    try std.testing.expectEqual(@as(i64, -7), runJit(m, &.{7}).result);
    try std.testing.expectEqual(@as(u8, 1), runJit(m, &.{0}).deopt); // -0 → deopt
    const p = try jitOf(a, "function f(a){ return +a + 1; }");
    try std.testing.expectEqual(@as(i64, 6), runJit(p, &.{5}).result);
}

test "jit: constant shifts" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var ai = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ai.deinit();
    const a = ai.allocator();
    try std.testing.expectEqual(@as(i64, 20), runJit(try jitOf(a, "function f(a){ return a << 2; }"), &.{5}).result);
    try std.testing.expectEqual(@as(i64, -4), runJit(try jitOf(a, "function f(a){ return a >> 1; }"), &.{-8}).result); // arithmetic
    try std.testing.expectEqual(@as(i64, 4), runJit(try jitOf(a, "function f(a){ return a >>> 1; }"), &.{8}).result); // logical
    // -1 >>> 0 = 4294967295 > i32 max → must deopt; 5 >>> 0 = 5 (no deopt).
    const u = try jitOf(a, "function f(a){ return a >>> 0; }");
    try std.testing.expectEqual(@as(u8, 1), runJit(u, &.{-1}).deopt);
    try std.testing.expectEqual(@as(i64, 5), runJit(u, &.{5}).result);
    // variable-count shift is not JIT-able (would need CL) → bails to tree-walk.
    try std.testing.expectError(error.NotJitable, jitOf(a, "function f(a, b){ return a << b; }"));
}

test "jit: non-integer subset is rejected" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var ai = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ai.deinit();
    const a = ai.allocator();
    try std.testing.expectError(error.NotJitable, jitOf(a, "function f(a){ return a.x; }")); // property read
    try std.testing.expectError(error.NotJitable, jitOf(a, "function f(a){ return a % 2; }")); // mod
    try std.testing.expectError(error.NotJitable, jitOf(a, "function f(a){ return foo(a); }")); // global/call
}
