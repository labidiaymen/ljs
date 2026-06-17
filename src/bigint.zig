//! §6.1.6.2 The BigInt Type — arbitrary-precision integers, backed by `std.math.big.int`.
//! A BigInt value is a `*const std.math.big.int.Const` whose `limbs` slice is owned by the realm
//! arena (so it lives as long as every other arena-allocated value; no manual free). This module
//! wraps the std `Managed` arithmetic and snapshots each result into such an arena-owned `Const`,
//! implementing the JS-specific semantics (BigInt::* abstract ops, §6.1.6.2): truncating division,
//! sign-following remainder, `**` with a non-negative exponent, two's-complement bitwise ops, the
//! `>>>`-is-a-TypeError rule (enforced by the caller), and ToString in an arbitrary radix.
const std = @import("std");
const big = std.math.big.int;
const Const = big.Const;
const Managed = big.Managed;
const Limb = std.math.big.Limb;

/// Errors a BigInt op can surface to the interpreter (turned into the matching JS exception there).
pub const Error = error{
    OutOfMemory,
    /// §6.1.6.2.* — `1n / 0n`, `1n % 0n` (RangeError "Division by zero").
    DivisionByZero,
    /// §6.1.6.2.3 BigInt::exponentiate — a negative exponent (RangeError).
    NegativeExponent,
    /// §6.1.6.2.9/.10 BigInt::leftShift with a huge/negative shift we cannot represent (RangeError).
    ShiftRange,
    /// `BigInt(nonInteger)` / `BigInt(Infinity)` (RangeError "not an integer").
    NotAnInteger,
    /// `BigInt("xyz")` / `1n + {}` style parse failure (SyntaxError "Cannot convert ... to a BigInt").
    InvalidString,
};

/// Snapshot a (possibly temporary) `Managed` into an arena-owned immutable `*const Const`. The
/// `Managed`'s limbs slice is copied so the result is self-contained and outlives the `Managed`.
fn snapshot(arena: std.mem.Allocator, m: Managed) Error!*const Const {
    const c = m.toConst();
    const limbs = try arena.alloc(Limb, c.limbs.len);
    @memcpy(limbs, c.limbs);
    const out = try arena.create(Const);
    out.* = .{ .limbs = limbs, .positive = c.positive };
    return out;
}

/// A BigInt holding the value `0`.
pub fn zero(arena: std.mem.Allocator) Error!*const Const {
    const out = try arena.create(Const);
    const limbs = try arena.alloc(Limb, 1);
    limbs[0] = 0;
    out.* = .{ .limbs = limbs, .positive = true };
    return out;
}

/// `from i64` — exact (used for Boolean→BigInt and small constants).
pub fn fromI64(arena: std.mem.Allocator, v: i64) Error!*const Const {
    var m = try Managed.initSet(arena, v);
    defer m.deinit();
    return snapshot(arena, m);
}

/// §12.9.3.2 the numeric value of a digit string in `base` (2/8/10/16). The string must already be
/// stripped of any prefix / separators (digits only); an empty string is `0`. `negative` applies a
/// sign. Invalid digits → `InvalidString`.
pub fn fromDigits(arena: std.mem.Allocator, digits: []const u8, base: u8, negative: bool) Error!*const Const {
    var m = Managed.init(arena) catch return Error.OutOfMemory;
    defer m.deinit();
    if (digits.len == 0) {
        m.set(0) catch return Error.OutOfMemory;
    } else {
        m.setString(base, digits) catch return Error.InvalidString;
    }
    if (negative and !m.eqlZero()) m.negate();
    return snapshot(arena, m);
}

/// §21.2.1.1 StringToBigInt — parse a full StringNumericLiteral (whitespace-trimmed by the caller):
/// optional sign, `0x`/`0o`/`0b` radix prefix, else decimal. Empty/whitespace → `0n`. Invalid → null.
pub fn fromString(arena: std.mem.Allocator, src: []const u8) Error!?*const Const {
    const t = std.mem.trim(u8, src, " \t\r\n\x0b\x0c\u{00a0}\u{feff}");
    if (t.len == 0) return try zero(arena);
    var s = t;
    var negative = false;
    var base: u8 = 10;
    // A radix prefix may NOT carry a sign (§12.9.3.2: only decimal allows a leading +/-).
    if (s.len >= 2 and s[0] == '0') {
        switch (s[1]) {
            'x', 'X' => {
                base = 16;
                s = s[2..];
            },
            'o', 'O' => {
                base = 8;
                s = s[2..];
            },
            'b', 'B' => {
                base = 2;
                s = s[2..];
            },
            else => {},
        }
    }
    if (base == 10) {
        if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
            negative = s[0] == '-';
            s = s[1..];
        }
    }
    if (s.len == 0) return null;
    for (s) |ch| {
        const dv: u8 = switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => ch - 'a' + 10,
            'A'...'F' => ch - 'A' + 10,
            else => return null,
        };
        if (dv >= base) return null;
    }
    return try fromDigits(arena, s, base, negative);
}

/// §21.2.1.1.1 NumberToBigInt — an integral, finite Number converts exactly; a non-integer or
/// non-finite Number → `NotAnInteger`.
pub fn fromF64(arena: std.mem.Allocator, n: f64) Error!*const Const {
    if (!std.math.isFinite(n) or @floor(n) != n) return Error.NotAnInteger;
    var m = Managed.init(arena) catch return Error.OutOfMemory;
    defer m.deinit();
    const negative = n < 0;
    var mag = @abs(n);
    // Accumulate the (integral) magnitude base-2^53-safe: split into 32-bit chunks.
    if (mag < 9007199254740992.0) { // <= 2^53: fits exactly via i64
        m.set(@as(i64, @intFromFloat(n))) catch return Error.OutOfMemory;
        return snapshot(arena, m);
    }
    // Large integral double: build from the mantissa/exponent via repeated *2 (exact, no rounding).
    var acc = Managed.initSet(arena, 0) catch return Error.OutOfMemory;
    defer acc.deinit();
    // Decompose mag into chunks of 32 bits from the top using frexp-like scaling.
    var chunks: [40]u32 = undefined;
    var count: usize = 0;
    while (mag >= 1.0) : (count += 1) {
        const low = @mod(mag, 4294967296.0);
        chunks[count] = @intFromFloat(low);
        mag = @floor(mag / 4294967296.0);
    }
    // chunks[0] is the least-significant 32 bits. Rebuild acc = sum chunks[i] * 2^(32*i).
    var i: usize = count;
    while (i > 0) {
        i -= 1;
        // acc = acc * 2^32 + chunks[i]
        acc.shiftLeft(&acc, 32) catch return Error.OutOfMemory;
        var c = Managed.initSet(arena, chunks[i]) catch return Error.OutOfMemory;
        defer c.deinit();
        acc.add(&acc, &c) catch return Error.OutOfMemory;
    }
    if (negative and !acc.eqlZero()) acc.negate();
    return snapshot(arena, acc);
}

fn toManaged(arena: std.mem.Allocator, a: *const Const) Error!Managed {
    return a.toManaged(arena) catch Error.OutOfMemory;
}

pub fn add(arena: std.mem.Allocator, a: *const Const, b: *const Const) Error!*const Const {
    var ma = try toManaged(arena, a);
    defer ma.deinit();
    var mb = try toManaged(arena, b);
    defer mb.deinit();
    var r = Managed.init(arena) catch return Error.OutOfMemory;
    defer r.deinit();
    r.add(&ma, &mb) catch return Error.OutOfMemory;
    return snapshot(arena, r);
}

pub fn sub(arena: std.mem.Allocator, a: *const Const, b: *const Const) Error!*const Const {
    var ma = try toManaged(arena, a);
    defer ma.deinit();
    var mb = try toManaged(arena, b);
    defer mb.deinit();
    var r = Managed.init(arena) catch return Error.OutOfMemory;
    defer r.deinit();
    r.sub(&ma, &mb) catch return Error.OutOfMemory;
    return snapshot(arena, r);
}

pub fn mul(arena: std.mem.Allocator, a: *const Const, b: *const Const) Error!*const Const {
    var ma = try toManaged(arena, a);
    defer ma.deinit();
    var mb = try toManaged(arena, b);
    defer mb.deinit();
    var r = Managed.init(arena) catch return Error.OutOfMemory;
    defer r.deinit();
    r.mul(&ma, &mb) catch return Error.OutOfMemory;
    return snapshot(arena, r);
}

/// §6.1.6.2.5 BigInt::divide — truncating (toward zero) integer division. ÷0n → DivisionByZero.
pub fn div(arena: std.mem.Allocator, a: *const Const, b: *const Const) Error!*const Const {
    if (b.eqlZero()) return Error.DivisionByZero;
    var ma = try toManaged(arena, a);
    defer ma.deinit();
    var mb = try toManaged(arena, b);
    defer mb.deinit();
    var q = Managed.init(arena) catch return Error.OutOfMemory;
    defer q.deinit();
    var r = Managed.init(arena) catch return Error.OutOfMemory;
    defer r.deinit();
    q.divTrunc(&r, &ma, &mb) catch return Error.OutOfMemory;
    return snapshot(arena, q);
}

/// §6.1.6.2.6 BigInt::remainder — the remainder has the sign of the dividend (`divTrunc`). %0n → err.
pub fn rem(arena: std.mem.Allocator, a: *const Const, b: *const Const) Error!*const Const {
    if (b.eqlZero()) return Error.DivisionByZero;
    var ma = try toManaged(arena, a);
    defer ma.deinit();
    var mb = try toManaged(arena, b);
    defer mb.deinit();
    var q = Managed.init(arena) catch return Error.OutOfMemory;
    defer q.deinit();
    var r = Managed.init(arena) catch return Error.OutOfMemory;
    defer r.deinit();
    q.divTrunc(&r, &ma, &mb) catch return Error.OutOfMemory;
    return snapshot(arena, r);
}

/// §6.1.6.2.3 BigInt::exponentiate — `base ** exp`, exp >= 0 (negative exponent → NegativeExponent).
pub fn pow(arena: std.mem.Allocator, a: *const Const, b: *const Const) Error!*const Const {
    if (!b.positive and !b.eqlZero()) return Error.NegativeExponent;
    // `Managed.pow` takes a u32 exponent. A larger exponent would need astronomically much memory;
    // reject it as a range error rather than OOM-crashing.
    const exp: u32 = b.toInt(u32) catch return Error.ShiftRange;
    var ma = try toManaged(arena, a);
    defer ma.deinit();
    var r = Managed.init(arena) catch return Error.OutOfMemory;
    defer r.deinit();
    r.pow(&ma, exp) catch return Error.OutOfMemory;
    return snapshot(arena, r);
}

pub fn bitAnd(arena: std.mem.Allocator, a: *const Const, b: *const Const) Error!*const Const {
    var ma = try toManaged(arena, a);
    defer ma.deinit();
    var mb = try toManaged(arena, b);
    defer mb.deinit();
    var r = Managed.init(arena) catch return Error.OutOfMemory;
    defer r.deinit();
    r.bitAnd(&ma, &mb) catch return Error.OutOfMemory;
    return snapshot(arena, r);
}

pub fn bitOr(arena: std.mem.Allocator, a: *const Const, b: *const Const) Error!*const Const {
    var ma = try toManaged(arena, a);
    defer ma.deinit();
    var mb = try toManaged(arena, b);
    defer mb.deinit();
    var r = Managed.init(arena) catch return Error.OutOfMemory;
    defer r.deinit();
    r.bitOr(&ma, &mb) catch return Error.OutOfMemory;
    return snapshot(arena, r);
}

pub fn bitXor(arena: std.mem.Allocator, a: *const Const, b: *const Const) Error!*const Const {
    var ma = try toManaged(arena, a);
    defer ma.deinit();
    var mb = try toManaged(arena, b);
    defer mb.deinit();
    var r = Managed.init(arena) catch return Error.OutOfMemory;
    defer r.deinit();
    r.bitXor(&ma, &mb) catch return Error.OutOfMemory;
    return snapshot(arena, r);
}

/// §6.1.6.2.9/.10 BigInt::leftShift / signedRightShift. A positive shift count shifts left; a
/// negative one shifts right (arithmetic, sign-propagating) — i.e. `a << b` with `b < 0` is `a >> -b`.
/// `shr` is the same with the count negated. The std `shiftRight` converges to -1 for negatives,
/// matching JS's infinite-two's-complement arithmetic shift.
pub fn shl(arena: std.mem.Allocator, a: *const Const, b: *const Const) Error!*const Const {
    return shiftBy(arena, a, b, true);
}

pub fn shr(arena: std.mem.Allocator, a: *const Const, b: *const Const) Error!*const Const {
    return shiftBy(arena, a, b, false);
}

fn shiftBy(arena: std.mem.Allocator, a: *const Const, b: *const Const, left: bool) Error!*const Const {
    // Effective shift amount = b for `<<`, -b for `>>`. A 0 shift returns a unchanged.
    if (b.eqlZero()) return a;
    const shift_left = if (left) b.positive else !b.positive;
    const amount: usize = b.abs().toInt(usize) catch {
        // A shift magnitude that doesn't fit in usize: left → astronomical (RangeError);
        // right by such an amount → 0 (or -1 for negatives) — collapse to that.
        if (shift_left) return Error.ShiftRange;
        return if (a.positive or a.eqlZero()) try zero(arena) else try fromI64(arena, -1);
    };
    var ma = try toManaged(arena, a);
    defer ma.deinit();
    var r = Managed.init(arena) catch return Error.OutOfMemory;
    defer r.deinit();
    if (shift_left) {
        r.shiftLeft(&ma, amount) catch return Error.OutOfMemory;
    } else {
        r.shiftRight(&ma, amount) catch return Error.OutOfMemory;
    }
    return snapshot(arena, r);
}

/// §6.1.6.2.1 BigInt::unaryMinus.
pub fn neg(arena: std.mem.Allocator, a: *const Const) Error!*const Const {
    const out = try arena.create(Const);
    const limbs = try arena.alloc(Limb, a.limbs.len);
    @memcpy(limbs, a.limbs);
    out.* = .{ .limbs = limbs, .positive = if (a.eqlZero()) true else !a.positive };
    return out;
}

/// §6.1.6.2.2 BigInt::bitwiseNOT — `~a == -(a + 1)`, the two's-complement bitwise complement.
pub fn bitNot(arena: std.mem.Allocator, a: *const Const) Error!*const Const {
    var ma = try toManaged(arena, a);
    defer ma.deinit();
    var one = Managed.initSet(arena, 1) catch return Error.OutOfMemory;
    defer one.deinit();
    var r = Managed.init(arena) catch return Error.OutOfMemory;
    defer r.deinit();
    r.add(&ma, &one) catch return Error.OutOfMemory;
    r.negate();
    return snapshot(arena, r);
}

/// §6.1.6.2.13 BigInt::equal — exact numeric equality.
pub fn eql(a: *const Const, b: *const Const) bool {
    return a.eql(b.*);
}

/// §6.1.6.2.12 BigInt::lessThan — `a < b`. Returns the std order so callers map to lt/gt/le/ge.
pub fn order(a: *const Const, b: *const Const) std.math.Order {
    return a.order(b.*);
}

pub fn isZero(a: *const Const) bool {
    return a.eqlZero();
}

/// True iff the value is negative (sign-magnitude, zero is non-negative).
pub fn isNegative(a: *const Const) bool {
    return !a.positive and !a.eqlZero();
}

/// §6.1.6.2.23 BigInt::toString in `radix` (2..36). Lowercase digits, leading '-' for negatives.
pub fn toStringRadix(arena: std.mem.Allocator, a: *const Const, radix: u8) Error![]const u8 {
    const digits = a.abs().toStringAlloc(arena, radix, .lower) catch return Error.OutOfMemory;
    if (isNegative(a)) {
        return std.mem.concat(arena, u8, &.{ "-", digits }) catch Error.OutOfMemory;
    }
    return digits;
}

/// Convert to f64 (for cross-type `<`/`==` with a Number). Rounds to nearest; magnitude beyond f64
/// range becomes ±Infinity, which is the correct comparison behavior.
pub fn toF64(a: *const Const) f64 {
    const r = a.toFloat(f64, .nearest_even);
    return r[0];
}

/// §21.2.2.1 BigInt.asIntN(bits, x) — wrap `x` to a `bits`-wide signed two's-complement value.
pub fn asIntN(arena: std.mem.Allocator, bits: usize, a: *const Const) Error!*const Const {
    return wrapTwosComp(arena, bits, a, .signed);
}

/// §21.2.2.2 BigInt.asUintN(bits, x) — wrap `x` to a `bits`-wide unsigned value.
pub fn asUintN(arena: std.mem.Allocator, bits: usize, a: *const Const) Error!*const Const {
    return wrapTwosComp(arena, bits, a, .unsigned);
}

fn wrapTwosComp(arena: std.mem.Allocator, bits: usize, a: *const Const, signedness: std.builtin.Signedness) Error!*const Const {
    if (bits == 0) return try zero(arena);
    var ma = try toManaged(arena, a);
    defer ma.deinit();
    var r = Managed.init(arena) catch return Error.OutOfMemory;
    defer r.deinit();
    // truncate(x, bits, signedness): reduce x to its low `bits`, interpreting per signedness.
    r.truncate(&ma, signedness, bits) catch return Error.OutOfMemory;
    return snapshot(arena, r);
}
