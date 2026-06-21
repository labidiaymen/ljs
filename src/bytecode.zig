//! Bytecode for the ljs VM (spec 111 — the "Ignition" tier). A `Chunk` is the compiled form of a
//! function/script body: a flat instruction stream + a constant pool + the local-slot count. The VM
//! (`vm.zig`) executes it; the compiler (`compiler.zig`) produces it from the AST. This is Phase 0 — a
//! deliberately small opcode set covering numeric/string expressions, locals, control flow, return,
//! and calls; anything else makes the compiler bail (→ tree-walk fallback), so semantics are preserved.
//!
//! Encoding: each instruction is a 1-byte `Op` followed by 0+ little-endian u16 operands (constant
//! index / slot index / jump target). Operands are u16 (≤ 65535 constants/slots/code-bytes per chunk —
//! the compiler bails past that). Jump targets are absolute byte offsets into `code`.
const std = @import("std");
const Value = @import("value.zig").Value;

/// PERF (spec 111): global on/off for the bytecode-VM fast path. Set once at startup from the `LJS_VM`
/// env var by the CLI / Test262 harness (default OFF — the VM is opt-in until its differential Test262
/// is clean). A process-global is fine: the VM is a pure-perf execution choice, not realm state.
var g_vm_enabled: bool = false;
pub fn setEnabled(on: bool) void {
    g_vm_enabled = on;
}
pub fn enabled() bool {
    return g_vm_enabled;
}

pub const Op = enum(u8) {
    // ── stack / constants / locals ──
    load_const, // [k]  push consts[k]
    load_undef, // push undefined
    load_null, // push null
    load_true, // push true
    load_false, // push false
    load_slot, // [s]  push slots[s]
    store_slot, // [s]  slots[s] = pop()
    load_global, // [k]  push ResolveBinding(consts[k] as name)   (env-chain lookup)
    store_global, // [k]  PutValue(consts[k] as name, pop())
    pop, // discard top
    dup, // duplicate top

    // ── binary operators (delegate to interp_ops; matched to ast.BinaryOp) ──
    add,
    sub,
    mul,
    div,
    mod,
    exp,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    shr_un,
    lt,
    gt,
    le,
    ge,
    eq,
    ne,
    seq,
    sne,

    // ── unary ──
    neg, // -x
    pos, // +x  (ToNumber)
    not_, // !x
    bit_not, // ~x
    typeof_, // typeof x   (operand already a value — the non-reference form)

    // ── control flow ──
    jump, // [t]  ip = t
    jump_if_false, // [t]  if !ToBoolean(pop()) ip = t
    jump_if_true, // [t]  if ToBoolean(pop()) ip = t
    jump_if_false_keep, // [t]  if !ToBoolean(peek()) ip = t else pop()   (for `&&`)
    jump_if_true_keep, // [t]  if ToBoolean(peek()) ip = t else pop()    (for `||`)

    // ── calls / properties (Phase 0: reads only) ──
    call, // [argc]  stack: callee, arg0..argN ; result pushed (this = undefined)
    call_method, // [k][argc]  stack: obj, arg0..argN ; calls obj[consts[k]] with this=obj
    get_prop, // [k]  push GetV(pop(), consts[k] as name)
    get_index, // push GetV(obj, key)  (key on top, obj below)

    // ── return ──
    ret, // return pop()
    ret_undef, // return undefined
};

/// A compiled function/script body.
pub const Chunk = struct {
    code: std.ArrayListUnmanaged(u8) = .empty,
    consts: std.ArrayListUnmanaged(Value) = .empty,
    n_slots: u16 = 0,
    /// Max operand-stack depth the compiler computed (so the VM pre-allocates exactly).
    max_stack: u16 = 0,

    pub fn emit(self: *Chunk, arena: std.mem.Allocator, op: Op) std.mem.Allocator.Error!void {
        try self.code.append(arena, @intFromEnum(op));
    }
    pub fn emitU16(self: *Chunk, arena: std.mem.Allocator, v: u16) std.mem.Allocator.Error!void {
        try self.code.append(arena, @truncate(v & 0xff));
        try self.code.append(arena, @truncate(v >> 8));
    }
    /// Emit `op` + a u16 operand; returns the byte offset of the operand (for jump patching).
    pub fn emitOp1(self: *Chunk, arena: std.mem.Allocator, op: Op, v: u16) std.mem.Allocator.Error!usize {
        try self.emit(arena, op);
        const at = self.code.items.len;
        try self.emitU16(arena, v);
        return at;
    }
    /// Add a constant, returning its index (no dedup in Phase 0 — cheap + correct).
    pub fn addConst(self: *Chunk, arena: std.mem.Allocator, v: Value) std.mem.Allocator.Error!u16 {
        const idx = self.consts.items.len;
        try self.consts.append(arena, v);
        return @intCast(idx);
    }
    /// Patch the u16 jump operand at byte offset `at` to point at the current end of `code`.
    pub fn patchJumpHere(self: *Chunk, at: usize) void {
        const target: u16 = @intCast(self.code.items.len);
        self.code.items[at] = @truncate(target & 0xff);
        self.code.items[at + 1] = @truncate(target >> 8);
    }
    pub fn here(self: *Chunk) u16 {
        return @intCast(self.code.items.len);
    }
};
