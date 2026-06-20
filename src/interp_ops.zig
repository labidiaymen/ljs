//! Extracted from interpreter.zig (behavior-preserving split). Free functions taking
//! `self: *Interpreter`; thin wrappers remain on the struct for cross-module/native call sites.
const std = @import("std");
const ast = @import("ast.zig");
const Value = @import("value.zig").Value;
const Symbol = @import("value.zig").Symbol;
const Completion = @import("completion.zig").Completion;
const Environment = @import("environment.zig").Environment;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const ops = @import("abstract_ops.zig");
const bigint = @import("bigint.zig");
const builtin_proxy = @import("builtin_proxy.zig");
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const interp_async = @import("interp_async.zig");

const toNumber = ops.toNumber;
const relational = ops.relational;
const strictEquals = ops.strictEquals;
const looseEquals = ops.looseEquals;
const parseIndex = ops.parseIndex;
const numToInt32 = ops.numberToInt32;
const numToUint32 = ops.numberToUint32;

// Shared free helpers + named types (defined in interpreter.zig), aliased for natural call sites.
const isCallable = interpreter.isCallable;
const CoerceResult = Interpreter.CoerceResult;
const PrimHint = Interpreter.PrimHint;

const protoProxy = Interpreter.protoProxy;

/// The realm's well-known `Symbol.toPrimitive` identity (held on the `Symbol` constructor).
/// Null only in a realm-less unit-test eval (no `Symbol`), in which case OrdinaryToPrimitive
/// (valueOf/toString) is still used.
pub fn wellKnownToPrimitive(self: *Interpreter) ?*Symbol {
    const g = self.globals orelse return null;
    const b = g.lookup("Symbol") orelse return null;
    if (b.value != .object) return null;
    const pv = b.value.object.get("toPrimitive") orelse return null;
    return if (pv == .symbol) pv.symbol else null;
}

/// A well-known Symbol identity (`Symbol.<name>`) held on the `Symbol` constructor. Null only in a
/// realm-less unit eval (no `Symbol`). Used by the §ER dispose machinery (`dispose`/`asyncDispose`).
pub fn wellKnownSymbol(self: *Interpreter, name: []const u8) ?*Symbol {
    const g = self.globals orelse return null;
    const b = g.lookup("Symbol") orelse return null;
    if (b.value != .object) return null;
    const pv = b.value.object.get(name) orelse return null;
    return if (pv == .symbol) pv.symbol else null;
}

/// §ER AddDisposableResource / CreateDisposableResource / GetDisposeMethod — push the resource
/// `v` (the initialized `using`/`await using` value) onto the dispose stack. A null/undefined `v`
/// for a sync `using` is a no-op (no resource pushed). Otherwise `v` must be an Object whose
/// `[@@dispose]` (sync) — or `[@@asyncDispose]`, falling back to `[@@dispose]` (async) — is a
/// callable method; a missing or non-callable method is a TypeError. Returns an abrupt completion
/// on that TypeError (or a throw while reading the method); a normal completion when pushed/skipped.
pub fn disposePush(self: *Interpreter, v: Value, is_async: bool) EvalError!Completion {
    // §ER CreateDisposableResource step 1.a: a null/undefined sync-dispose resource is a no-op.
    // (For async-dispose, null/undefined is likewise allowed and disposes to a no-op.)
    if (v == .null or v == .undefined) {
        try self.disposables.append(self.arena, .{ .value = .undefined, .method = null, .is_async = is_async });
        return .{ .normal = .undefined };
    }
    // §ER CreateDisposableResource step 1.b.i: a non-Object resource is a TypeError.
    if (v != .object) return self.throwError("TypeError", "using value is not an object");
    var method: ?*Object = null;
    if (is_async) {
        // §ER GetDisposeMethod (async-dispose): try @@asyncDispose, then fall back to @@dispose.
        if (self.wellKnownSymbol("asyncDispose")) |sym| {
            const mc = try self.getSymbolProperty(v, sym);
            if (mc.isAbrupt()) return mc;
            method = try disposeMethodOf(self, mc.normal);
            if (mc.normal != .undefined and mc.normal != .null and method == null) {
                return self.throwError("TypeError", "Symbol.asyncDispose is not a function");
            }
        }
        if (method == null) {
            if (self.wellKnownSymbol("dispose")) |sym| {
                const mc = try self.getSymbolProperty(v, sym);
                if (mc.isAbrupt()) return mc;
                method = try disposeMethodOf(self, mc.normal);
                if (mc.normal != .undefined and mc.normal != .null and method == null) {
                    return self.throwError("TypeError", "Symbol.dispose is not a function");
                }
            }
        }
        if (method == null) return self.throwError("TypeError", "using value has no Symbol.asyncDispose method");
    } else {
        // §ER GetDisposeMethod (sync-dispose): @@dispose, which must be callable.
        const sym = self.wellKnownSymbol("dispose") orelse return self.throwError("TypeError", "Symbol.dispose unavailable");
        const mc = try self.getSymbolProperty(v, sym);
        if (mc.isAbrupt()) return mc;
        method = try disposeMethodOf(self, mc.normal);
        if (method == null) {
            // §ER GetMethod: undefined/null → no method (then CreateDisposableResource throws),
            // a non-callable value → TypeError directly.
            if (mc.normal == .undefined or mc.normal == .null) {
                return self.throwError("TypeError", "using value has no Symbol.dispose method");
            }
            return self.throwError("TypeError", "Symbol.dispose is not a function");
        }
    }
    try self.disposables.append(self.arena, .{ .value = v, .method = method, .is_async = is_async });
    return .{ .normal = .undefined };
}

/// §7.3.11 GetMethod tail: a callable function value → that function; undefined/null/non-callable
/// → null (the caller decides whether null is a TypeError or a no-op).
pub fn disposeMethodOf(self: *Interpreter, m: Value) EvalError!?*Object {
    _ = self;
    if (m != .object) return null;
    if (!isCallable(m.object)) return null;
    return m.object;
}

/// §ER DisposeResources — at scope exit, dispose every resource pushed since `marker` in REVERSE
/// (LIFO) order, threading `completion` (the body's completion). A disposer that throws while a
/// throw completion is already pending is aggregated into a `SuppressedError { error, suppressed }`
/// (the newest disposer error becomes `.error`, the prior pending completion becomes `.suppressed`);
/// otherwise the disposer's throw simply replaces a previously-normal completion. The popped
/// resources are removed from the stack. For an `await using`, the dispose result is awaited
/// (via the body's await substrate when available). A normal `completion` and no throwing disposer
/// returns `completion` unchanged.
pub fn disposeFrom(self: *Interpreter, marker: usize, completion: Completion) EvalError!Completion {
    var result = completion;
    // Reverse order over the slice pushed since `marker`.
    var i = self.disposables.items.len;
    while (i > marker) {
        i -= 1;
        const res = self.disposables.items[i];
        // §ER Dispose: result ← (method undefined) undefined : Call(method, V). For an `await
        // using`, the result is then Awaited — even when method is undefined (a null/undefined
        // async resource still yields a microtask boundary at disposal).
        var disp: Completion = .{ .normal = .undefined };
        if (res.method) |m| {
            disp = try self.callFunction(m, &.{}, res.value);
        }
        if (res.is_async and !disp.isAbrupt()) {
            disp = try awaitDisposeResult(self, disp.normal);
        }
        if (disp == .throw) {
            result = try combineDisposeError(self, disp.throw, result);
        }
    }
    // Pop the disposed resources.
    self.disposables.items.len = marker;
    return result;
}

/// §ER DisposeResources step 1.b: fold a disposer error into the pending completion. If the
/// pending completion is itself a throw, build a SuppressedError `{ error: <new>, suppressed:
/// <pending> }`; otherwise the disposer error becomes the (new) throw completion.
pub fn combineDisposeError(self: *Interpreter, err: Value, pending: Completion) EvalError!Completion {
    if (pending != .throw) return .{ .throw = err };
    // SuppressedError { error: err, suppressed: pending.throw }.
    const g = self.globals orelse return .{ .throw = err };
    const ctor_b = g.lookup("SuppressedError") orelse return .{ .throw = err };
    if (ctor_b.value != .object) return .{ .throw = err };
    const sc = try self.callFunction(ctor_b.value.object, &.{ err, pending.throw }, .undefined);
    if (sc.isAbrupt()) return sc;
    return .{ .throw = sc.normal };
}

/// §7.1.1 ToPrimitive ( input, hint ) — convert a value to a primitive. Primitives pass through
/// unchanged (the hot path: no allocation, no method calls). For an Object: if it has an
/// `@@toPrimitive` method, call it with the hint string and require a primitive result; otherwise
/// run §7.1.1.1 OrdinaryToPrimitive with the effective hint (a `default` hint behaves as `number`).
/// Returns the primitive Value, or an abrupt `.throw` completion on a TypeError / a thrown method.
pub fn toPrimitive(self: *Interpreter, v: Value, hint: PrimHint) EvalError!Completion {
    if (v != .object) return .{ .normal = v };
    const o = v.object;
    // §7.1.1 step 2.a: exoticToPrim = GetMethod(input, @@toPrimitive).
    if (wellKnownToPrimitive(self)) |sym| {
        const mc = try self.getSymbolProperty(v, sym);
        if (mc.isAbrupt()) return mc;
        const m = mc.normal;
        if (m != .undefined and m != .null) {
            if (m != .object or !isCallable(m.object)) {
                return self.throwError("TypeError", "Symbol.toPrimitive is not a function");
            }
            const rc = try self.callFunction(m.object, &.{.{ .string = hint.str() }}, v);
            if (rc.isAbrupt()) return rc;
            // §7.1.1 step 2.c.iii: the result must be a primitive.
            if (rc.normal == .object) {
                return self.throwError("TypeError", "Cannot convert object to primitive value");
            }
            return .{ .normal = rc.normal };
        }
    }
    // §7.1.1 step 3: no @@toPrimitive → OrdinaryToPrimitive; a `default` hint means `number`.
    const eff: PrimHint = if (hint == .string) .string else .number;
    return ordinaryToPrimitive(self, o, eff);
}

/// §7.1.1.1 OrdinaryToPrimitive ( O, hint ) — try `valueOf` then `toString` (or the reverse for a
/// `string` hint); the first callable method whose result is a primitive wins. A TypeError if
/// neither yields a primitive.
pub fn ordinaryToPrimitive(self: *Interpreter, o: *Object, hint: PrimHint) EvalError!Completion {
    const names: [2][]const u8 = if (hint == .string)
        .{ "toString", "valueOf" }
    else
        .{ "valueOf", "toString" };
    for (names) |name| {
        const mc = try self.getProperty(.{ .object = o }, name);
        if (mc.isAbrupt()) return mc;
        const m = mc.normal;
        if (m == .object and isCallable(m.object)) {
            const rc = try self.callFunction(m.object, &.{}, .{ .object = o });
            if (rc.isAbrupt()) return rc;
            if (rc.normal != .object) return .{ .normal = rc.normal }; // primitive → done
        }
    }
    return self.throwError("TypeError", "Cannot convert object to primitive value");
}

/// §7.1.4 ToNumber in a coercion context: ToPrimitive (number hint) an object, then the pure
/// numeric conversion. Primitives skip straight to the pure `toNumber` (hot path). A Symbol is a
/// TypeError per §7.1.4 (surfaced here, not the pure helper's NaN).
pub fn toNumberV(self: *Interpreter, v: Value) EvalError!Completion {
    const prim = switch (v) {
        .object => blk: {
            const pc = try self.toPrimitive(v, .number);
            if (pc.isAbrupt()) return pc;
            break :blk pc.normal;
        },
        else => v,
    };
    if (prim == .symbol) return self.throwError("TypeError", "Cannot convert a Symbol value to a number");
    // §7.1.4 step 2: ToNumber(BigInt) throws a TypeError (it does NOT silently become NaN).
    if (prim == .bigint) return self.throwError("TypeError", "Cannot convert a BigInt value to a number");
    return .{ .normal = .{ .number = toNumber(prim) } };
}

/// §7.1.5 ToIntegerOrInfinity — ToNumber, then NaN→0, truncate toward zero, ±Inf preserved. Returns
/// the integral (or ±Inf) value as a Number; propagates an abrupt ToNumber completion.
pub fn toIntegerOrInfinity(self: *Interpreter, v: Value) EvalError!Completion {
    const nc = try self.toNumberV(v);
    if (nc.isAbrupt()) return nc;
    const n = nc.normal.number;
    if (std.math.isNan(n)) return .{ .normal = .{ .number = 0 } };
    if (std.math.isInf(n)) return .{ .normal = .{ .number = n } };
    return .{ .normal = .{ .number = std.math.trunc(n) } };
}

/// §7.1.17 ToString in a coercion context: ToPrimitive (string hint) an object, then ToString.
/// A Symbol is a TypeError (§7.1.17 step 3). Used by string `+` and template substitution.
pub fn toStringCoerceV(self: *Interpreter, v: Value) EvalError!CoerceResult {
    const prim = switch (v) {
        .object => blk: {
            const pc = try self.toPrimitive(v, .string);
            if (pc.isAbrupt()) return .{ .abrupt = pc };
            break :blk pc.normal;
        },
        else => v,
    };
    if (prim == .symbol) return .{ .abrupt = try self.throwError("TypeError", "Cannot convert a Symbol value to a string") };
    return .{ .string = try self.toString(prim) };
}

/// §7.1.17 ToString as a Completion — public wrapper for the built-in libraries (JSON, etc.):
/// `.normal` holds the coerced string Value; a Symbol argument is an abrupt TypeError.
pub fn toStringValuePub(self: *Interpreter, v: Value) EvalError!Completion {
    return switch (try toStringCoerceV(self, v)) {
        .string => |s| .{ .normal = .{ .string = s } },
        .abrupt => |c| c,
    };
}

/// Public §7.1.4 ToNumber (throwing) for built-in modules — a Symbol/BigInt operand throws a
/// TypeError, an object runs ToPrimitive(number). Used by Array methods whose arg coercion must be
/// observable (e.g. `copyWithin(0, Symbol())` → TypeError).
pub fn toNumberThrowing(self: *Interpreter, v: Value) EvalError!Completion {
    return self.toNumberV(v);
}

/// Public §7.1.5 ToIntegerOrInfinity for built-in modules (e.g. `with` / `flat` index/depth args).
pub fn toIntegerOrInfinityPub(self: *Interpreter, v: Value) EvalError!Completion {
    return self.toIntegerOrInfinity(v);
}

/// §27.7.5.3 the `await x` runtime — on the async body thread: hand `x` (the awaited value) out via
/// the ping-pong handoff (`transfer_kind = .yield`, reusing `doYieldRaw`), park until the caller's
/// reaction Job resumes us with the settlement (`.next` value → await result; `.throw` reason →
/// throw at the await point). Only runs on an async body thread (`current_gen.is_async`).
/// §ER Dispose step 3.a — `Await(result)` of an `await using` disposer's return value. Only an
/// async body thread can suspend on an await; when running there (`current_gen.is_async`) we await
/// via the normal handoff, so a thenable disposal result is adopted. Outside an async body (which
/// `await using` should never be, but guard defensively) the value passes through unawaited.
pub fn awaitDisposeResult(self: *Interpreter, value: Value) EvalError!Completion {
    const cg = self.current_gen orelse return .{ .normal = value };
    if (!cg.is_async) return .{ .normal = value };
    return interp_async.doAwait(self, value);
}

pub inline fn evalBinary(self: *Interpreter, op: ast.BinaryOp, ln: *const ast.Node, rn: *const ast.Node, env: *Environment) EvalError!Completion {
    const lc = try self.evalExpr(ln, env);
    if (lc.isAbrupt()) return lc;
    const rc = try self.evalExpr(rn, env);
    if (rc.isAbrupt()) return rc;
    const l = lc.normal;
    const r = rc.normal;

    switch (op) {
        .add, .sub, .mul, .div, .mod, .exp, .bit_and, .bit_or, .bit_xor, .shl, .shr, .shr_un =>
        // §13.15.3 the string-or-numeric / numeric binary operators — shared with compound
        // assignment (`+=`, `*=`, …) via `applyNumericOrStringOp`.
        return applyNumericOrStringOp(self, op, l, r),
        .in_op => { // §13.10.2 `key in obj`
            if (r != .object) return self.throwError("TypeError", "Cannot use 'in' operator to search in a non-object");
            if (r.object.proxy != null) { // §10.5.7 [[HasProperty]] via the proxy trap (key may be a Symbol)
                const pk = try self.coercePropertyKey(l);
                if (pk.isAbrupt()) return pk;
                return self.hasPropertyVC(r, pk.normal);
            }
            const key = try self.toString(l);
            const o = r.object;
            const has = blk: {
                if (o.kind == .array) {
                    if (std.mem.eql(u8, key, "length")) break :blk true;
                    if (parseIndex(key)) |i| if (o.arrayHas(i)) break :blk true;
                }
                if (o.getProp(key) != null) break :blk true;
                // §13.10.1 step 5.b: a Proxy on the prototype chain handles the rest via its trap.
                if (protoProxy(o)) |pp| {
                    const c = try builtin_proxy.has(self, pp, .{ .string = key });
                    if (c.isAbrupt()) return c;
                    break :blk c.normal.boolean;
                }
                break :blk false;
            };
            return .{ .normal = .{ .boolean = has } };
        },
        .lt => return relationalV(self, l, r, .lt),
        .gt => return relationalV(self, l, r, .gt),
        .le => return relationalV(self, l, r, .le),
        .ge => return relationalV(self, l, r, .ge),
        .instanceof_ => return instanceofOperator(self, l, r),
        .eq => {
            const c = try looseEqualsV(self, l, r);
            if (c.isAbrupt()) return c;
            return .{ .normal = .{ .boolean = c.normal.boolean } };
        },
        .ne => {
            const c = try looseEqualsV(self, l, r);
            if (c.isAbrupt()) return c;
            return .{ .normal = .{ .boolean = !c.normal.boolean } };
        },
        .seq => return .{ .normal = .{ .boolean = strictEquals(l, r) } },
        .sne => return .{ .normal = .{ .boolean = !strictEquals(l, r) } },
    }
}

/// §13.10 / §7.3.22 InstanceofOperator ( V, target ). `V instanceof target`:
///  1. If target is not an Object, throw a TypeError.
///  2. instOfHandler = GetMethod(target, @@hasInstance).
///  3. If instOfHandler is not undefined, return ToBoolean(Call(instOfHandler, target, «V»)).
///  4. If IsCallable(target) is false, throw a TypeError.
///  5. Return OrdinaryHasInstance(target, V).
/// Note ordinary Function objects carry Function.prototype[@@hasInstance], so the @@hasInstance
/// branch normally handles them; the OrdinaryHasInstance fallback covers a realm without that
/// method installed. `ordinaryHasInstance` already performs the §7.3.21 `Get(C,"prototype")`
/// (firing getters) and the non-object-prototype TypeError.
pub fn instanceofOperator(self: *Interpreter, v: Value, target: Value) EvalError!Completion {
    // §7.3.22 step 1: target must be an Object.
    if (target != .object) return self.throwError("TypeError", "Right-hand side of 'instanceof' is not an object");
    // §7.3.22 step 2: instOfHandler = GetMethod(target, @@hasInstance). The getter may throw.
    if (self.wellKnownSymbol("hasInstance")) |sym| {
        const hc = try self.getSymbolProperty(target, sym);
        if (hc.isAbrupt()) return hc;
        const handler = hc.normal;
        // §7.3.22 step 3: a non-undefined/non-null handler is invoked; GetMethod requires it be
        // callable, else TypeError (a present-but-non-callable @@hasInstance is an error).
        if (handler != .undefined and handler != .null) {
            if (handler != .object or !isCallable(handler.object)) {
                return self.throwError("TypeError", "Symbol.hasInstance method is not callable");
            }
            // §7.3.22 step 3: Return ToBoolean(? Call(instOfHandler, target, «V»)).
            const rc = try self.callFunction(handler.object, &.{v}, target);
            if (rc.isAbrupt()) return rc;
            return .{ .normal = .{ .boolean = ops.toBoolean(rc.normal) } };
        }
    }
    // §7.3.22 step 4: with no @@hasInstance, target must be callable.
    if (!isCallable(target.object)) return self.throwError("TypeError", "Right-hand side of 'instanceof' is not callable");
    // §7.3.22 step 5: Return OrdinaryHasInstance(target, V).
    return self.ordinaryHasInstance(target, v);
}

/// §13.15.3 ApplyStringOrNumericBinaryOperator for the value-level operators shared by binary
/// expressions and compound assignment (`+ - * / % ** & | ^ << >> >>>`). `+` is string-or-numeric
/// (ToPrimitive default, concat if either is a String); the rest are purely numeric.
pub fn applyNumericOrStringOp(self: *Interpreter, op: ast.BinaryOp, l: Value, r: Value) EvalError!Completion {
    if (op == .add) {
        // §13.15.3: ToPrimitive(default) both operands (left then right), then concat if either is a
        // String, else numeric. An object's @@toPrimitive/valueOf/toString runs here.
        const lpc = try self.toPrimitive(l, .default);
        if (lpc.isAbrupt()) return lpc;
        const rpc = try self.toPrimitive(r, .default);
        if (rpc.isAbrupt()) return rpc;
        const lp = lpc.normal;
        const rp = rpc.normal;
        if (lp == .string or rp == .string) {
            if (lp == .symbol or rp == .symbol) return self.throwError("TypeError", "Cannot convert a Symbol value to a string");
            const ls = try self.toString(lp);
            const rs = try self.toString(rp);
            return .{ .normal = .{ .string = try std.mem.concat(self.arena, u8, &.{ ls, rs }) } };
        }
        if (lp == .bigint or rp == .bigint) return bigintBinary(self, lp, rp, .add);
        if (lp == .symbol or rp == .symbol) return self.throwError("TypeError", "Cannot convert a Symbol value to a number");
        return .{ .normal = .{ .number = toNumber(lp) + toNumber(rp) } };
    }
    return numericBinary(self, l, r, op);
}

/// §13.15.3 ApplyStringOrNumericBinaryOperator for the purely numeric operators (everything but
/// `+`): ToNumber (via ToPrimitive number-hint) both operands left-to-right, then the IEEE-754 /
/// Int32 / UInt32 operation. A Symbol operand → TypeError (raised by `toNumberV`).
pub fn numericBinary(self: *Interpreter, l: Value, r: Value, op: ast.BinaryOp) EvalError!Completion {
    // §13.15.3 / §7.1.3 ToNumeric: process the operands STRICTLY in order — ToNumeric(lhs) fully
    // (ToPrimitive + the Symbol→TypeError check) BEFORE ToNumeric(rhs) begins, so the side-effect
    // ordering matches the spec (a Symbol lhs throws before rhs's valueOf runs). A BigInt primitive
    // is left as-is for the operator step (which enforces the no-mixing TypeError).
    const lpc = try self.toPrimitive(l, .number);
    if (lpc.isAbrupt()) return lpc;
    const lp = lpc.normal;
    if (lp == .symbol) return self.throwError("TypeError", "Cannot convert a Symbol value to a number");
    const rpc = try self.toPrimitive(r, .number);
    if (rpc.isAbrupt()) return rpc;
    const rp = rpc.normal;
    if (rp == .symbol) return self.throwError("TypeError", "Cannot convert a Symbol value to a number");
    if (lp == .bigint or rp == .bigint) return bigintBinary(self, lp, rp, op);
    const a = toNumber(lp);
    const b = toNumber(rp);
    return switch (op) {
        .sub => .{ .normal = .{ .number = a - b } },
        .mul => .{ .normal = .{ .number = a * b } },
        .div => .{ .normal = .{ .number = a / b } },
        .mod => .{ .normal = .{ .number = @rem(a, b) } },
        .exp => .{ .normal = .{ .number = std.math.pow(f64, a, b) } }, // §13.6
        .bit_and => .{ .normal = .{ .number = @floatFromInt(numToInt32(a) & numToInt32(b)) } }, // §13.12
        .bit_or => .{ .normal = .{ .number = @floatFromInt(numToInt32(a) | numToInt32(b)) } },
        .bit_xor => .{ .normal = .{ .number = @floatFromInt(numToInt32(a) ^ numToInt32(b)) } },
        .shl => blk: { // §13.9 — wrap via u32, result is int32
            const sh: u5 = @intCast(numToUint32(b) & 31);
            const res: i32 = @bitCast(numToUint32(a) << sh);
            break :blk .{ .normal = .{ .number = @floatFromInt(res) } };
        },
        .shr => blk: { // arithmetic (sign-propagating)
            const sh: u5 = @intCast(numToUint32(b) & 31);
            break :blk .{ .normal = .{ .number = @floatFromInt(numToInt32(a) >> sh) } };
        },
        .shr_un => blk: { // logical (zero-fill), result is uint32
            const sh: u5 = @intCast(numToUint32(b) & 31);
            break :blk .{ .normal = .{ .number = @floatFromInt(numToUint32(a) >> sh) } };
        },
        else => unreachable,
    };
}

/// §13.15.3 / §6.1.6.2 — the binary operators with at least one BigInt primitive operand. Both
/// MUST be BigInt (mixing a BigInt with a Number/String/etc. in an arithmetic or bitwise op is a
/// TypeError); `>>>` (UnsignedRightShift) is itself a TypeError for BigInt. Maps each op to the
/// `bigint` module and turns its error tags into the matching JS exception.
pub fn bigintBinary(self: *Interpreter, l: Value, r: Value, op: ast.BinaryOp) EvalError!Completion {
    if (op == .shr_un) return self.throwError("TypeError", "BigInts have no unsigned right shift, use >> instead");
    if (l != .bigint or r != .bigint) {
        return self.throwError("TypeError", "Cannot mix BigInt and other types, use explicit conversions");
    }
    const a = l.bigint;
    const b = r.bigint;
    const res = switch (op) {
        .add => bigint.add(self.arena, a, b),
        .sub => bigint.sub(self.arena, a, b),
        .mul => bigint.mul(self.arena, a, b),
        .div => bigint.div(self.arena, a, b),
        .mod => bigint.rem(self.arena, a, b),
        .exp => bigint.pow(self.arena, a, b),
        .bit_and => bigint.bitAnd(self.arena, a, b),
        .bit_or => bigint.bitOr(self.arena, a, b),
        .bit_xor => bigint.bitXor(self.arena, a, b),
        .shl => bigint.shl(self.arena, a, b),
        .shr => bigint.shr(self.arena, a, b),
        else => unreachable,
    } catch |e| return self.bigintError(e);
    return .{ .normal = .{ .bigint = res } };
}

/// Map a `bigint.Error` to the right JS exception (or propagate OutOfMemory).
pub fn bigintError(self: *Interpreter, e: bigint.Error) EvalError!Completion {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.DivisionByZero => self.throwError("RangeError", "Division by zero"),
        error.NegativeExponent => self.throwError("RangeError", "Exponent must be non-negative"),
        error.ShiftRange => self.throwError("RangeError", "BigInt is too large"),
        error.NotAnInteger => self.throwError("RangeError", "The number is not a safe integer"),
        error.InvalidString => self.throwError("SyntaxError", "Cannot convert string to a BigInt"),
    };
}

/// §7.2.13 IsLessThan / §13.10 relational comparison with object coercion: ToPrimitive(number) each
/// operand (left first), then the pure comparison (string-vs-string is lexical, else numeric).
pub fn relationalV(self: *Interpreter, l: Value, r: Value, op: ops.RelOp) EvalError!Completion {
    // §13.10.1: in `a < b` LeftFirst, ToPrimitive(a) THEN ToPrimitive(b). (`numToPrimNumber`
    // is a no-op on primitives, so the common number/string case keeps its fast path.)
    const lpc = try self.toPrimitive(l, .number);
    if (lpc.isAbrupt()) return lpc;
    const rpc = try self.toPrimitive(r, .number);
    if (rpc.isAbrupt()) return rpc;
    const lp = lpc.normal;
    const rp = rpc.normal;
    // §7.2.13: a Symbol primitive operand → ToNumber throws (unless both are strings, handled in `relational`).
    if (!(lp == .string and rp == .string)) {
        if (lp == .symbol or rp == .symbol) return self.throwError("TypeError", "Cannot convert a Symbol value to a number");
    }
    return .{ .normal = .{ .boolean = relational(lp, rp, op) } };
}

/// §7.2.15 IsLooselyEqual (`==`) with object coercion: when one side is an Object and the other a
/// Number/String/Symbol primitive, ToPrimitive(object, default) and retry; otherwise the pure
/// primitive comparison. (object == object is reference equality, handled by the pure helper.)
pub fn looseEqualsV(self: *Interpreter, l: Value, r: Value) EvalError!Completion {
    // §7.2.15 step 10/11: Object vs primitive (number/string/symbol/bigint) → coerce the object.
    const l_obj = l == .object;
    const r_obj = r == .object;
    if (l_obj != r_obj) { // exactly one is an object
        const other = if (l_obj) r else l;
        if (other == .undefined or other == .null) {
            return .{ .normal = .{ .boolean = false } }; // §7.2.15: Object == null/undefined is false
        }
        if (l_obj) {
            const pc = try self.toPrimitive(l, .default);
            if (pc.isAbrupt()) return pc;
            return looseEqualsV(self, pc.normal, r);
        } else {
            const pc = try self.toPrimitive(r, .default);
            if (pc.isAbrupt()) return pc;
            return looseEqualsV(self, l, pc.normal);
        }
    }
    return .{ .normal = .{ .boolean = looseEquals(l, r) } };
}

/// §7.1.17 ToString — delegates to the abstract operation (handles Array join). Used for property
/// keys and engine-internal stringification, where a Symbol never reaches it (computed keys route
/// to the symbol store first). The user-facing string COERCION contexts (template / `+`) use
/// `toStringCoerce`, which throws on a Symbol per spec.
pub fn toString(self: *Interpreter, v: Value) EvalError![]const u8 {
    return ops.toString(self.arena, v);
}

/// §7.1.17 ToString — the FULL throwing form (ToPrimitive(string) on an object, TypeError on a
/// Symbol). Public so the string library (§22.1.3) can coerce `this`/arguments with the observable
/// abrupt completions the spec mandates (e.g. `"".endsWith(Symbol())` → TypeError). Returns the
/// string, or the abrupt completion when coercion throws.
pub fn toStringThrowing(self: *Interpreter, v: Value) EvalError!Completion {
    return switch (try toStringCoerceV(self, v)) {
        .string => |s| .{ .normal = .{ .string = s } },
        .abrupt => |c| c,
    };
}

/// §7.1.17 ToString in a coercion context (template substitution, string `+`): a Symbol is a
/// TypeError (§7.1.17 step 3) — it must NOT be silently stringified. All other types delegate to
/// the ordinary ToString.
pub fn toStringCoerce(self: *Interpreter, v: Value) EvalError!CoerceResult {
    if (v == .symbol) return .{ .abrupt = try self.throwError("TypeError", "Cannot convert a Symbol value to a string") };
    return .{ .string = try self.toString(v) };
}
