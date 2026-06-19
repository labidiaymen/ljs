//! §`explicit-resource-management` DisposableStack + AsyncDisposableStack — the two stack objects of
//! the Explicit Resource Management proposal. Self-contained: an instance carries a `DisposableData`
//! backing record (`object.zig` `disposable`) with the LIFO [[DisposeCapability]] resource stack and
//! the [[DisposableState]] disposed flag. The use/adopt/defer/dispose/disposeAsync/move methods + the
//! `disposed` getter + the @@dispose / @@asyncDispose aliases all dispatch through the interpreter's
//! `callNative` (`disposable_stack_method` / `async_disposable_stack_method` / …). LIFO disposal +
//! the SuppressedError aggregation mirror §ER DisposeResources (shared shape with the `using` engine).
const std = @import("std");
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const isCallable = interp.isCallable;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const DisposableData = object_mod.DisposableData;
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const interp_async = @import("interp_async.zig");

/// §`sec-newdisposecapability` allocate a fresh [[DisposableState]]=pending stack on `obj`.
pub fn initInstance(it: *Interpreter, obj: *Object, is_async: bool) EvalError!void {
    const dd = try it.arena.create(DisposableData);
    dd.* = .{ .is_async = is_async };
    obj.disposable = dd;
}

/// §`sec-requireinternalslot` brand check — `this` must be an object carrying a `DisposableData` of
/// the matching async-ness (a sync method on an AsyncDisposableStack, or on a plain object, is a
/// TypeError). Returns the backing record or an abrupt TypeError completion.
fn requireStack(it: *Interpreter, this_val: Value, is_async: bool) EvalError!union(enum) { ok: *DisposableData, abrupt: Completion } {
    if (this_val == .object) {
        if (this_val.object.disposable) |dd| {
            if (dd.is_async == is_async) return .{ .ok = dd };
        }
    }
    return .{ .abrupt = try it.throwError("TypeError", "DisposableStack method called on an incompatible receiver") };
}

/// §`sec-getdisposemethod` GetDisposeMethod(V, hint) → GetMethod(V, @@asyncDispose) (falling back to
/// @@dispose for the async hint) / GetMethod(V, @@dispose) (sync hint). undefined/null → no method;
/// a non-callable value → TypeError. Returns the method (or null = no-op disposal).
fn getDisposeMethod(it: *Interpreter, v: Value, is_async: bool) EvalError!union(enum) { method: ?*Object, abrupt: Completion } {
    if (is_async) {
        if (it.wellKnownSymbol("asyncDispose")) |sym| {
            const mc = try it.getSymbolProperty(v, sym);
            if (mc.isAbrupt()) return .{ .abrupt = mc };
            if (mc.normal != .undefined and mc.normal != .null) {
                if (mc.normal != .object or !isCallable(mc.normal.object))
                    return .{ .abrupt = try it.throwError("TypeError", "Symbol.asyncDispose is not a function") };
                return .{ .method = mc.normal.object };
            }
        }
        // async hint fallback: @@dispose.
        if (it.wellKnownSymbol("dispose")) |sym| {
            const mc = try it.getSymbolProperty(v, sym);
            if (mc.isAbrupt()) return .{ .abrupt = mc };
            if (mc.normal != .undefined and mc.normal != .null) {
                if (mc.normal != .object or !isCallable(mc.normal.object))
                    return .{ .abrupt = try it.throwError("TypeError", "Symbol.dispose is not a function") };
                return .{ .method = mc.normal.object };
            }
        }
        return .{ .method = null };
    }
    const sym = it.wellKnownSymbol("dispose") orelse return .{ .method = null };
    const mc = try it.getSymbolProperty(v, sym);
    if (mc.isAbrupt()) return .{ .abrupt = mc };
    if (mc.normal == .undefined or mc.normal == .null) return .{ .method = null };
    if (mc.normal != .object or !isCallable(mc.normal.object))
        return .{ .abrupt = try it.throwError("TypeError", "Symbol.dispose is not a function") };
    return .{ .method = mc.normal.object };
}

/// §`sec-adddisposableresource` push a resource onto the LIFO stack. With no explicit `method`: a
/// null/undefined sync resource is a no-op (still pushed as a marker for the async-await accounting);
/// otherwise CreateDisposableResource(V, hint) (non-Object → TypeError; missing dispose method →
/// TypeError). With an explicit `method` (adopt/defer), V is undefined and the method is the closure.
fn addResource(it: *Interpreter, dd: *DisposableData, v: Value, explicit_method: ?*Object) EvalError!Completion {
    if (explicit_method) |m| {
        try dd.stack.append(it.arena, .{ .value = .undefined, .method = m });
        return .{ .normal = .undefined };
    }
    // §CreateDisposableResource step 1.a: null/undefined → no-op disposal (still recorded).
    if (v == .null or v == .undefined) {
        try dd.stack.append(it.arena, .{ .value = .undefined, .method = null });
        return .{ .normal = .undefined };
    }
    if (v != .object) return it.throwError("TypeError", "DisposableStack.prototype.use called with a non-object resource");
    const gm = switch (try getDisposeMethod(it, v, dd.is_async)) {
        .method => |m| m,
        .abrupt => |a| return a,
    };
    if (gm == null) {
        return it.throwError("TypeError", "resource has no Symbol.dispose / Symbol.asyncDispose method");
    }
    try dd.stack.append(it.arena, .{ .value = v, .method = gm });
    return .{ .normal = .undefined };
}

/// §ER DisposeResources — dispose every resource in REVERSE (LIFO) order, threading a `completion`.
/// A disposer that throws while a throw is already pending aggregates into a SuppressedError
/// { error: <new>, suppressed: <pending> }. The stack is cleared. Synchronous: each disposer's
/// returned value is NOT awaited here (the async stack's awaiting is handled by the caller / is a
/// known limitation — sync disposers + non-thenable results settle correctly). Returns the final
/// completion (normal undefined, or the throw to propagate).
fn disposeResources(it: *Interpreter, dd: *DisposableData) EvalError!Completion {
    var result: Completion = .{ .normal = .undefined };
    var i = dd.stack.items.len;
    while (i > 0) {
        i -= 1;
        const res = dd.stack.items[i];
        var disp: Completion = .{ .normal = .undefined };
        if (res.method) |m| {
            disp = try it.callFunction(m, &.{}, res.value);
        }
        if (disp == .throw) {
            result = try combineDisposeError(it, disp.throw, result);
        }
    }
    dd.stack.clearRetainingCapacity();
    return result;
}

/// §ER DisposeResources step 1.b: fold a disposer error into the pending completion — a SuppressedError
/// when the pending completion is itself a throw, else the disposer error becomes the throw.
fn combineDisposeError(it: *Interpreter, err: Value, pending: Completion) EvalError!Completion {
    if (pending != .throw) return .{ .throw = err };
    const g = it.globals orelse return .{ .throw = err };
    const ctor_b = g.lookup("SuppressedError") orelse return .{ .throw = err };
    if (ctor_b.value != .object) return .{ .throw = err };
    const sc = try it.callFunction(ctor_b.value.object, &.{ err, pending.throw }, .undefined);
    if (sc.isAbrupt()) return sc;
    return .{ .throw = sc.normal };
}

// ── Method dispatch ──────────────────────────────────────────────────────────

/// §`sec-disposablestack.prototype.<m>` / §`sec-asyncdisposablestack.prototype.<m>` — the
/// use/adopt/defer/dispose/move methods. `is_async` selects the kind; `disposeAsync` is handled by
/// `asyncDisposeMethod`. Brand-checked on `this`.
pub fn method(it: *Interpreter, name: []const u8, this_val: Value, args: []const Value, is_async: bool) EvalError!Completion {
    const dd = switch (try requireStack(it, this_val, is_async)) {
        .ok => |d| d,
        .abrupt => |a| return a,
    };
    const a0: Value = if (args.len > 0) args[0] else .undefined;
    const a1: Value = if (args.len > 1) args[1] else .undefined;

    if (std.mem.eql(u8, name, "use")) {
        // §.use(value): throw ReferenceError if disposed; AddDisposableResource(value, hint); return value.
        if (dd.disposed) return it.throwError("ReferenceError", "DisposableStack is already disposed");
        const ac = try addResource(it, dd, a0, null);
        if (ac.isAbrupt()) return ac;
        return .{ .normal = a0 };
    }
    if (std.mem.eql(u8, name, "adopt")) {
        // §.adopt(value, onDispose): disposed → ReferenceError; onDispose must be callable; push a
        // wrapper closure that calls onDispose(value); return value.
        if (dd.disposed) return it.throwError("ReferenceError", "DisposableStack is already disposed");
        if (a1 != .object or !isCallable(a1.object)) return it.throwError("TypeError", "onDispose is not a function");
        const wrap = try Object.createNative(it.arena, .disposable_adopt_wrapper, "");
        wrap.prototype = it.functionProto();
        _ = wrap.properties.orderedRemove("prototype");
        try wrap.defineData("length", .{ .number = 0 }, false, false, true);
        try wrap.defineData("name", .{ .string = "" }, false, false, true);
        wrap.adopt_value = a0;
        wrap.adopt_on_dispose = a1.object;
        const ac = try addResource(it, dd, .undefined, wrap);
        if (ac.isAbrupt()) return ac;
        return .{ .normal = a0 };
    }
    if (std.mem.eql(u8, name, "defer")) {
        // §.defer(onDispose): disposed → ReferenceError; onDispose must be callable; push it directly.
        if (dd.disposed) return it.throwError("ReferenceError", "DisposableStack is already disposed");
        if (a0 != .object or !isCallable(a0.object)) return it.throwError("TypeError", "onDispose is not a function");
        const ac = try addResource(it, dd, .undefined, a0.object);
        if (ac.isAbrupt()) return ac;
        return .{ .normal = .undefined };
    }
    if (std.mem.eql(u8, name, "move")) {
        // §.move(): disposed → ReferenceError; create a NEW DisposableStack with this stack's
        // resources; set this to disposed; return the new stack.
        if (dd.disposed) return it.throwError("ReferenceError", "DisposableStack is already disposed");
        const proto = if (is_async) it.asyncDisposableStackProto() else it.disposableStackProto();
        const new_obj = try Object.create(it.arena, proto);
        const ndd = try it.arena.create(DisposableData);
        ndd.* = .{ .is_async = is_async, .stack = dd.stack };
        new_obj.disposable = ndd;
        // This stack hands off its capability and becomes disposed with a fresh empty stack.
        dd.stack = .empty;
        dd.disposed = true;
        return .{ .normal = .{ .object = new_obj } };
    }
    if (std.mem.eql(u8, name, "dispose")) {
        // §.dispose(): disposed → return undefined; else set disposed and DisposeResources.
        if (dd.disposed) return .{ .normal = .undefined };
        dd.disposed = true;
        const dc = try disposeResources(it, dd);
        if (dc.isAbrupt()) return dc;
        return .{ .normal = .undefined };
    }
    return it.throwError("TypeError", "unknown DisposableStack method");
}

/// §`sec-asyncdisposablestack.prototype.disposeAsync` — returns a Promise. Brand failure / already
/// disposed are reported through the promise (reject / resolve undefined). On a pending stack, run
/// DisposeResources synchronously and settle the promise with the result (resolved undefined, or
/// rejected with the propagated error / SuppressedError). NOTE: per-disposer Await interleaving is
/// not modelled — sync disposers and non-thenable results settle correctly; a disposer that returns
/// a rejected thenable is not adopted (a documented limitation).
pub fn asyncDisposeMethod(it: *Interpreter, this_val: Value) EvalError!Completion {
    const promise = try it.newPromise();
    // §step 3: missing [[AsyncDisposableState]] → reject with a TypeError.
    const dd: *DisposableData = blk: {
        if (this_val == .object) if (this_val.object.disposable) |d| if (d.is_async) break :blk d;
        const tc = try it.throwError("TypeError", "AsyncDisposableStack.prototype.disposeAsync called on an incompatible receiver");
        try interp_async.rejectPromise(it, promise, tc.throw);
        return .{ .normal = .{ .object = promise } };
    };
    // §step 4: already disposed → resolve undefined.
    if (dd.disposed) {
        try interp_async.fulfillPromise(it, promise, .undefined);
        return .{ .normal = .{ .object = promise } };
    }
    dd.disposed = true;
    const dc = try disposeResources(it, dd);
    if (dc == .throw) {
        try interp_async.rejectPromise(it, promise, dc.throw);
    } else {
        try interp_async.fulfillPromise(it, promise, .undefined);
    }
    return .{ .normal = .{ .object = promise } };
}

/// get DisposableStack/AsyncDisposableStack.prototype.disposed — true iff [[DisposableState]] is
/// disposed. Brand-checked (TypeError if `this` lacks the slot / is the wrong kind).
pub fn disposedGetter(it: *Interpreter, this_val: Value, is_async: bool) EvalError!Completion {
    const dd = switch (try requireStack(it, this_val, is_async)) {
        .ok => |d| d,
        .abrupt => |a| return a,
    };
    return .{ .normal = .{ .boolean = dd.disposed } };
}

/// The `adopt` wrapper closure: captures (value, onDispose); when disposed, calls onDispose(value).
pub fn adoptWrapper(it: *Interpreter, func: *Object) EvalError!Completion {
    const on_dispose = func.adopt_on_dispose orelse return .{ .normal = .undefined };
    return it.callFunction(on_dispose, &.{func.adopt_value}, .undefined);
}
