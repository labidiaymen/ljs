//! Minimal x86-64 machine-code emitter for the ljs JIT (spec 112 — the "TurboFan-lite" tier). Emits
//! into a growable byte buffer with label/patch support; the JIT (`jit.zig`) drives it to compile the
//! bytecode VM's integer subset to native code that runs in registers (beating V8 on numeric loops —
//! validated: a hand-emitted loop beat Node 1.4×). Windows-x64 only for now (the dev target); the
//! encoder is standard x86-64 so a SysV variant is a later addition.
//!
//! Scope: 64-bit integer ops on the 16 GPRs — mov (reg/imm), xor-zero, add/sub/imul (reg,reg),
//! cmp (reg,reg / reg,imm32), conditional + unconditional jumps (label-patched), push/pop, ret.
//! Memory addressing is intentionally absent: the JIT keeps everything in registers (slots in
//! callee-saved regs, the operand stack in caller-saved regs), which is both faster and avoids SIB.
const std = @import("std");

/// x86-64 general-purpose registers (encoding order; r8–r15 set REX.B/R/X).
pub const Reg = enum(u4) {
    rax = 0,
    rcx = 1,
    rdx = 2,
    rbx = 3,
    rsp = 4,
    rbp = 5,
    rsi = 6,
    rdi = 7,
    r8 = 8,
    r9 = 9,
    r10 = 10,
    r11 = 11,
    r12 = 12,
    r13 = 13,
    r14 = 14,
    r15 = 15,
    fn low(self: Reg) u3 {
        return @truncate(@intFromEnum(self) & 7);
    }
    fn ext(self: Reg) bool {
        return @intFromEnum(self) >= 8;
    }
};

/// Condition codes for `jcc` (the low nibble of the 0x0F 8x opcode).
pub const Cond = enum(u8) {
    e = 0x4, // ==
    ne = 0x5, // !=
    l = 0xC, // <  (signed)
    ge = 0xD, // >=
    le = 0xE, // <=
    g = 0xF, // >
    o = 0x0, // overflow
    a = 0x7, // above (unsigned >)
};

pub const Emitter = struct {
    arena: std.mem.Allocator,
    code: std.ArrayListUnmanaged(u8) = .empty,

    fn byte(self: *Emitter, b: u8) std.mem.Allocator.Error!void {
        try self.code.append(self.arena, b);
    }
    fn rexW(self: *Emitter, reg: Reg, rm: Reg) std.mem.Allocator.Error!void {
        // REX.W=1 (64-bit), REX.R = reg ext, REX.B = rm ext.
        try self.byte(0x48 | (@as(u8, @intFromBool(reg.ext())) << 2) | @intFromBool(rm.ext()));
    }
    fn modrmReg(self: *Emitter, reg: Reg, rm: Reg) std.mem.Allocator.Error!void {
        try self.byte(0xC0 | (@as(u8, reg.low()) << 3) | rm.low()); // mod=11 (reg-direct)
    }

    pub fn here(self: *Emitter) usize {
        return self.code.items.len;
    }

    /// dst = imm (movabs r64, imm64) — 10 bytes.
    pub fn movImm(self: *Emitter, dst: Reg, imm: i64) std.mem.Allocator.Error!void {
        try self.byte(0x48 | @as(u8, @intFromBool(dst.ext()))); // REX.W + REX.B
        try self.byte(0xB8 + @as(u8, dst.low()));
        const u: u64 = @bitCast(imm);
        inline for (0..8) |b| try self.byte(@truncate(u >> (b * 8)));
    }
    /// dst = src.
    pub fn movReg(self: *Emitter, dst: Reg, src: Reg) std.mem.Allocator.Error!void {
        try self.rexW(src, dst); // 89 /r: mov r/m64(dst), r64(src) → reg=src, rm=dst
        try self.byte(0x89);
        try self.modrmReg(src, dst);
    }
    /// dst = 0 (xor dst, dst).
    pub fn zero(self: *Emitter, dst: Reg) std.mem.Allocator.Error!void {
        try self.rexW(dst, dst);
        try self.byte(0x31);
        try self.modrmReg(dst, dst);
    }
    /// dst += src.
    pub fn add(self: *Emitter, dst: Reg, src: Reg) std.mem.Allocator.Error!void {
        try self.rexW(src, dst);
        try self.byte(0x01);
        try self.modrmReg(src, dst);
    }
    /// dst -= src.
    pub fn sub(self: *Emitter, dst: Reg, src: Reg) std.mem.Allocator.Error!void {
        try self.rexW(src, dst);
        try self.byte(0x29);
        try self.modrmReg(src, dst);
    }
    /// dst *= src (imul r64, r/m64 — 0F AF /r).
    pub fn imul(self: *Emitter, dst: Reg, src: Reg) std.mem.Allocator.Error!void {
        try self.rexW(dst, src); // reg=dst, rm=src
        try self.byte(0x0F);
        try self.byte(0xAF);
        try self.modrmReg(dst, src);
    }
    /// compare a - b (sets flags; use jcc after).
    pub fn cmp(self: *Emitter, a: Reg, b: Reg) std.mem.Allocator.Error!void {
        try self.rexW(b, a); // 39 /r: cmp r/m64(a), r64(b)
        try self.byte(0x39);
        try self.modrmReg(b, a);
    }
    /// compare a - imm32 (sign-extended).
    pub fn cmpImm(self: *Emitter, a: Reg, imm: i32) std.mem.Allocator.Error!void {
        try self.byte(0x48 | @as(u8, @intFromBool(a.ext())));
        try self.byte(0x81);
        try self.byte(0xF8 | @as(u8, a.low())); // /7 = cmp
        const u: u32 = @bitCast(imm);
        inline for (0..4) |b| try self.byte(@truncate(u >> (b * 8)));
    }
    // ── 32-bit (SMI) variants: V8-style small-int arithmetic. Overflow is detected with a single
    //    `jo` (the op sets OF on 32-bit overflow), far cheaper than range compares. Values live in the
    //    low 32 bits of the GPRs; `movsxd` sign-extends the final result back to i64 for boxing. ──
    fn rex32(self: *Emitter, reg: Reg, rm: Reg) std.mem.Allocator.Error!void {
        if (reg.ext() or rm.ext()) try self.byte(0x40 | (@as(u8, @intFromBool(reg.ext())) << 2) | @intFromBool(rm.ext()));
    }
    /// dst = imm (mov r32, imm32 — zero-extends to 64). Used for integer constants.
    pub fn movImm32(self: *Emitter, dst: Reg, imm: i32) std.mem.Allocator.Error!void {
        if (dst.ext()) try self.byte(0x41); // REX.B
        try self.byte(0xB8 + @as(u8, dst.low()));
        const u: u32 = @bitCast(imm);
        inline for (0..4) |b| try self.byte(@truncate(u >> (b * 8)));
    }
    pub fn movReg32(self: *Emitter, dst: Reg, src: Reg) std.mem.Allocator.Error!void {
        try self.rex32(src, dst);
        try self.byte(0x89);
        try self.modrmReg(src, dst);
    }
    pub fn add32(self: *Emitter, dst: Reg, src: Reg) std.mem.Allocator.Error!void {
        try self.rex32(src, dst);
        try self.byte(0x01);
        try self.modrmReg(src, dst);
    }
    pub fn sub32(self: *Emitter, dst: Reg, src: Reg) std.mem.Allocator.Error!void {
        try self.rex32(src, dst);
        try self.byte(0x29);
        try self.modrmReg(src, dst);
    }
    pub fn imul32(self: *Emitter, dst: Reg, src: Reg) std.mem.Allocator.Error!void {
        try self.rex32(dst, src);
        try self.byte(0x0F);
        try self.byte(0xAF);
        try self.modrmReg(dst, src);
    }
    pub fn cmp32(self: *Emitter, a: Reg, b: Reg) std.mem.Allocator.Error!void {
        try self.rex32(b, a);
        try self.byte(0x39);
        try self.modrmReg(b, a);
    }
    pub fn cmpImm32(self: *Emitter, a: Reg, imm: i32) std.mem.Allocator.Error!void {
        if (a.ext()) try self.byte(0x41);
        try self.byte(0x81);
        try self.byte(0xF8 | @as(u8, a.low()));
        const u: u32 = @bitCast(imm);
        inline for (0..4) |b| try self.byte(@truncate(u >> (b * 8)));
    }
    /// dst += imm (add r/m32, imm32 — 81 /0). For compiling `x = x + C` straight onto a slot register.
    pub fn addImm32(self: *Emitter, dst: Reg, imm: i32) std.mem.Allocator.Error!void {
        if (dst.ext()) try self.byte(0x41);
        try self.byte(0x81);
        try self.byte(0xC0 | @as(u8, dst.low())); // mod=11, /0 = add
        const u: u32 = @bitCast(imm);
        inline for (0..4) |b| try self.byte(@truncate(u >> (b * 8)));
    }
    /// dst -= imm (sub r/m32, imm32 — 81 /5).
    pub fn subImm32(self: *Emitter, dst: Reg, imm: i32) std.mem.Allocator.Error!void {
        if (dst.ext()) try self.byte(0x41);
        try self.byte(0x81);
        try self.byte(0xE8 | @as(u8, dst.low())); // mod=11, /5 = sub
        const u: u32 = @bitCast(imm);
        inline for (0..4) |b| try self.byte(@truncate(u >> (b * 8)));
    }
    /// dst = src * imm (imul r32, r/m32, imm32 — 69 /r id).
    pub fn imulImm32(self: *Emitter, dst: Reg, src: Reg, imm: i32) std.mem.Allocator.Error!void {
        try self.rex32(dst, src);
        try self.byte(0x69);
        try self.modrmReg(dst, src);
        const u: u32 = @bitCast(imm);
        inline for (0..4) |b| try self.byte(@truncate(u >> (b * 8)));
    }
    // ── 32-bit bitwise ops (JS `& | ^ ~` are ToInt32-based; on i32 SMIs they map directly and the
    //    result is always a clean i32 — no overflow, no -0). ──
    pub fn and32(self: *Emitter, dst: Reg, src: Reg) std.mem.Allocator.Error!void {
        try self.rex32(src, dst);
        try self.byte(0x21);
        try self.modrmReg(src, dst);
    }
    pub fn or32(self: *Emitter, dst: Reg, src: Reg) std.mem.Allocator.Error!void {
        try self.rex32(src, dst);
        try self.byte(0x09);
        try self.modrmReg(src, dst);
    }
    pub fn xor32(self: *Emitter, dst: Reg, src: Reg) std.mem.Allocator.Error!void {
        try self.rex32(src, dst);
        try self.byte(0x31);
        try self.modrmReg(src, dst);
    }
    // ── 32-bit shifts by an immediate count (C1 /r ib). The JIT only uses these for constant-count
    //    shifts, which sidesteps the CL-register constraint of variable shifts. ──
    /// dst <<= imm  (shl r/m32, imm8 — C1 /4).
    pub fn shlImm32(self: *Emitter, dst: Reg, imm: u8) std.mem.Allocator.Error!void {
        if (dst.ext()) try self.byte(0x41);
        try self.byte(0xC1);
        try self.byte(0xE0 | @as(u8, dst.low())); // /4 = shl
        try self.byte(imm);
    }
    /// dst >>= imm, arithmetic / sign-propagating  (sar r/m32, imm8 — C1 /7). JS `>>`.
    pub fn sarImm32(self: *Emitter, dst: Reg, imm: u8) std.mem.Allocator.Error!void {
        if (dst.ext()) try self.byte(0x41);
        try self.byte(0xC1);
        try self.byte(0xF8 | @as(u8, dst.low())); // /7 = sar
        try self.byte(imm);
    }
    /// dst >>= imm (arithmetic, 64-bit). REX.W + C1 /7 ib.
    pub fn sarImm(self: *Emitter, dst: Reg, imm: u8) std.mem.Allocator.Error!void {
        try self.byte(0x48 | @as(u8, @intFromBool(dst.ext())));
        try self.byte(0xC1);
        try self.byte(0xF8 | @as(u8, dst.low())); // /7 = sar
        try self.byte(imm);
    }
    /// dst += imm (64-bit, sign-extended imm32). REX.W + 81 /0 id.
    pub fn addImm(self: *Emitter, dst: Reg, imm: i32) std.mem.Allocator.Error!void {
        try self.byte(0x48 | @as(u8, @intFromBool(dst.ext())));
        try self.byte(0x81);
        try self.byte(0xC0 | @as(u8, dst.low())); // mod=11, /0 = add
        const u: u32 = @bitCast(imm);
        inline for (0..4) |b| try self.byte(@truncate(u >> (b * 8)));
    }
    /// dst -= imm (64-bit, sign-extended imm32). REX.W + 81 /5 id.
    pub fn subImm(self: *Emitter, dst: Reg, imm: i32) std.mem.Allocator.Error!void {
        try self.byte(0x48 | @as(u8, @intFromBool(dst.ext())));
        try self.byte(0x81);
        try self.byte(0xE8 | @as(u8, dst.low())); // mod=11, /5 = sub
        const u: u32 = @bitCast(imm);
        inline for (0..4) |b| try self.byte(@truncate(u >> (b * 8)));
    }
    /// dst *= imm (64-bit, imul r64, r/m64, imm32 — 69 /r id).
    pub fn imulImm(self: *Emitter, dst: Reg, imm: i32) std.mem.Allocator.Error!void {
        try self.rexW(dst, dst);
        try self.byte(0x69);
        try self.modrmReg(dst, dst);
        const u: u32 = @bitCast(imm);
        inline for (0..4) |b| try self.byte(@truncate(u >> (b * 8)));
    }
    /// dst >>>= imm, logical / zero-fill  (shr r/m32, imm8 — C1 /5). JS `>>>` (result is uint32).
    pub fn shrImm32(self: *Emitter, dst: Reg, imm: u8) std.mem.Allocator.Error!void {
        if (dst.ext()) try self.byte(0x41);
        try self.byte(0xC1);
        try self.byte(0xE8 | @as(u8, dst.low())); // /5 = shr
        try self.byte(imm);
    }
    /// dst = -dst  (neg r/m32 — F7 /3). Sets OF if dst == i32_min (the JIT deopts on that).
    pub fn neg32(self: *Emitter, dst: Reg) std.mem.Allocator.Error!void {
        if (dst.ext()) try self.byte(0x41);
        try self.byte(0xF7);
        try self.byte(0xD8 | @as(u8, dst.low())); // mod=11, /3 = neg
    }
    /// dst = -dst (64-bit). REX.W F7 /3.
    pub fn neg(self: *Emitter, dst: Reg) std.mem.Allocator.Error!void {
        try self.byte(0x48 | @as(u8, @intFromBool(dst.ext())));
        try self.byte(0xF7);
        try self.byte(0xD8 | @as(u8, dst.low())); // mod=11, /3 = neg
    }

    /// dst(64) = sign-extend src(32)  (movsxd — REX.W 63 /r). Boxes the i32 SMI result back to i64.
    pub fn movsxd(self: *Emitter, dst: Reg, src: Reg) std.mem.Allocator.Error!void {
        try self.rexW(dst, src);
        try self.byte(0x63);
        try self.modrmReg(dst, src);
    }

    /// dst = [base + disp8]  (mov r64, r/m64 — 8B /r, mod=01 disp8). `base` must not be rsp/rbp/r12/r13
    /// (those need SIB / special encoding); the JIT only uses rcx (the slots pointer) as a base.
    pub fn movFromMem(self: *Emitter, dst: Reg, base: Reg, disp: u8) std.mem.Allocator.Error!void {
        try self.byte(0x48 | (@as(u8, @intFromBool(dst.ext())) << 2) | @intFromBool(base.ext()));
        try self.byte(0x8B);
        try self.byte(0x40 | (@as(u8, dst.low()) << 3) | base.low()); // mod=01, reg=dst, rm=base
        try self.byte(disp);
    }
    /// byte [base] = imm8  (mov r/m8, imm8 — C6 /0, mod=00). Used to set the deopt flag (`*deopt = 1`).
    /// `base` must not be rsp/rbp/r12/r13; the JIT uses r15 (the deopt pointer).
    pub fn movByteImm(self: *Emitter, base: Reg, imm: u8) std.mem.Allocator.Error!void {
        if (base.ext()) try self.byte(0x41); // REX.B
        try self.byte(0xC6);
        try self.byte(base.low()); // mod=00, reg=000 (/0), rm=base
        try self.byte(imm);
    }
    pub fn push(self: *Emitter, r: Reg) std.mem.Allocator.Error!void {
        if (r.ext()) try self.byte(0x41);
        try self.byte(0x50 + @as(u8, r.low()));
    }
    pub fn pop(self: *Emitter, r: Reg) std.mem.Allocator.Error!void {
        if (r.ext()) try self.byte(0x41);
        try self.byte(0x58 + @as(u8, r.low()));
    }
    pub fn ret(self: *Emitter) std.mem.Allocator.Error!void {
        try self.byte(0xC3);
    }

    /// Emit a near jump with a rel32 placeholder; returns the operand offset for patching.
    pub fn jmp(self: *Emitter) std.mem.Allocator.Error!usize {
        try self.byte(0xE9);
        const at = self.code.items.len;
        try self.byte(0);
        try self.byte(0);
        try self.byte(0);
        try self.byte(0);
        return at;
    }
    pub fn jcc(self: *Emitter, cond: Cond) std.mem.Allocator.Error!usize {
        try self.byte(0x0F);
        try self.byte(0x80 + @intFromEnum(cond));
        const at = self.code.items.len;
        try self.byte(0);
        try self.byte(0);
        try self.byte(0);
        try self.byte(0);
        return at;
    }
    /// Patch a rel32 operand (at byte offset `at`, 4 bytes) to jump to absolute code offset `target`.
    pub fn patch(self: *Emitter, at: usize, target: usize) void {
        const rel: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(at + 4)));
        const u: u32 = @bitCast(rel);
        self.code.items[at] = @truncate(u);
        self.code.items[at + 1] = @truncate(u >> 8);
        self.code.items[at + 2] = @truncate(u >> 16);
        self.code.items[at + 3] = @truncate(u >> 24);
    }
};

// ── executable memory + tests ────────────────────────────────────────────────────
const builtin = @import("builtin");
extern "kernel32" fn VirtualAlloc(addr: ?*anyopaque, size: usize, alloc_type: u32, protect: u32) callconv(.winapi) ?*anyopaque;

/// Copy `code` into freshly-allocated RWX memory and return it as a callable pointer of type `F`.
/// Windows-only (the dev target). Caller keeps the page for the program's life (no free in Phase 0).
pub fn makeExecutable(comptime F: type, code: []const u8) ?F {
    if (builtin.os.tag != .windows) return null;
    const mem = VirtualAlloc(null, code.len, 0x1000 | 0x2000, 0x40) orelse return null; // MEM_COMMIT|RESERVE, PAGE_EXECUTE_READWRITE
    @memcpy(@as([*]u8, @ptrCast(mem))[0..code.len], code);
    return @ptrCast(@alignCast(mem));
}

test "x64 emitter: sum loop runs correctly" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var e = Emitter{ .arena = std.testing.allocator };
    defer e.code.deinit(std.testing.allocator);
    // fn(n:i64) i64 { s=0;i=0; while(i<n){s+=i;i++;} return s; }   (Win64: n in rcx)
    try e.zero(.rax); // s
    try e.zero(.rdx); // i
    const one = blk: {
        try e.movImm(.r8, 1);
        break :blk {};
    };
    _ = one;
    const loop = e.here();
    try e.cmp(.rdx, .rcx); // i - n
    const exit = try e.jcc(.ge); // if i>=n -> exit
    try e.add(.rax, .rdx); // s += i
    try e.add(.rdx, .r8); // i += 1
    const back = try e.jmp();
    e.patch(back, loop);
    e.patch(exit, e.here());
    try e.ret();

    const f = makeExecutable(*const fn (i64) callconv(.c) i64, e.code.items) orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(i64, 12497500), f(5000));
    try std.testing.expectEqual(@as(i64, 0), f(0));
    try std.testing.expectEqual(@as(i64, 45), f(10));
}
