//! §26.1 WeakRef + §26.2 FinalizationRegistry. In ljs's arena model nothing is ever garbage-collected,
//! so a WeakRef's target is never cleared (`deref` always returns it) and a FinalizationRegistry's
//! cleanup callback is never invoked. Only the OBSERVABLE, non-GC surface is implemented: the
//! constructors (target/callback validation, prototype-from-newtarget), `WeakRef.prototype.deref`, and
//! `FinalizationRegistry.prototype.register`/`unregister` (cell bookkeeping). This matches what the
//! Test262 WeakRef/FinalizationRegistry corpus asserts without a real collector (the GC-timing cases
//! are inherently unobservable here). Dispatched from `callNative` / `constructNT` in the interpreter.
const std = @import("std");
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const ops = @import("abstract_ops.zig");
const builtin_collection = @import("builtin_collection.zig");

const canBeHeldWeakly = builtin_collection.canBeHeldWeakly;

/// §26.1.1.1 WeakRef ( target ) — NewTarget must be defined (handled upstream by `constructNT`);
/// `target` must be weak-holdable (Object or non-registered Symbol), else TypeError. The referent is
/// stored in the `weak_ref` slot. `new_obj` already has `new_target.prototype` from constructNT.
pub fn constructWeakRef(it: *Interpreter, new_obj: *Object, args: []const Value) EvalError!Completion {
    const target: Value = if (args.len > 0) args[0] else .undefined;
    if (!canBeHeldWeakly(target)) return it.throwError("TypeError", "WeakRef: target cannot be held weakly");
    new_obj.weak_ref = target;
    return .{ .normal = .{ .object = new_obj } };
}

/// §26.1.3.2 WeakRef.prototype.deref ( ) — brand-check the receiver ([[WeakRefTarget]] slot), then
/// return the target. (Never empty in the arena model: the referent is never reclaimed.)
pub fn deref(it: *Interpreter, this_val: Value) EvalError!Completion {
    if (this_val != .object or this_val.object.weak_ref == null) {
        return it.throwError("TypeError", "WeakRef.prototype.deref called on an incompatible receiver");
    }
    return .{ .normal = this_val.object.weak_ref.? };
}

/// §26.2.1.1 FinalizationRegistry ( cleanupCallback ) — NewTarget defined (upstream); `cleanupCallback`
/// must be callable, else TypeError. The (empty) cell list + callback are stored in the
/// `finalization_registry` slot. `new_obj` already carries `new_target.prototype`.
pub fn constructFinalizationRegistry(it: *Interpreter, new_obj: *Object, args: []const Value) EvalError!Completion {
    const cb: Value = if (args.len > 0) args[0] else .undefined;
    if (cb != .object or !interp.isCallable(cb.object)) {
        return it.throwError("TypeError", "FinalizationRegistry: cleanup callback is not callable");
    }
    const data = try it.arena.create(object_mod.FinalizationRegistryData);
    data.* = .{ .cleanup_callback = cb.object };
    new_obj.finalization_registry = data;
    return .{ .normal = .{ .object = new_obj } };
}

/// §26.2.3 FinalizationRegistry.prototype dispatch — `register` / `unregister`.
pub fn method(it: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    const eql = std.mem.eql;
    if (this_val != .object or this_val.object.finalization_registry == null) {
        return it.throwError("TypeError", "method called on an incompatible FinalizationRegistry receiver");
    }
    const data = this_val.object.finalization_registry.?;

    if (eql(u8, name, "register")) {
        // §26.2.3.1 register ( target, heldValue [ , unregisterToken ] )
        const target: Value = if (args.len > 0) args[0] else .undefined;
        const held: Value = if (args.len > 1) args[1] else .undefined;
        const token: Value = if (args.len > 2) args[2] else .undefined;
        if (!canBeHeldWeakly(target)) return it.throwError("TypeError", "FinalizationRegistry.register: target cannot be held weakly");
        // §26.2.3.1 step 4: SameValue(target, heldValue) is a TypeError (a cell holding its own target alive).
        if (ops.sameValue(target, held)) return it.throwError("TypeError", "FinalizationRegistry.register: heldValue must not be the target");
        // §26.2.3.1 step 5: an unregisterToken that is present (not undefined) must be weak-holdable.
        var tok: ?Value = null;
        if (token != .undefined) {
            if (!canBeHeldWeakly(token)) return it.throwError("TypeError", "FinalizationRegistry.register: unregisterToken cannot be held weakly");
            tok = token;
        }
        try data.cells.append(it.arena, .{ .held_value = held, .unregister_token = tok });
        return .{ .normal = .undefined };
    }

    if (eql(u8, name, "unregister")) {
        // §26.2.3.2 unregister ( unregisterToken ) — the token must be weak-holdable; remove every cell
        // whose [[UnregisterToken]] SameValue-matches it. Returns whether at least one cell was removed.
        const token: Value = if (args.len > 0) args[0] else .undefined;
        if (!canBeHeldWeakly(token)) return it.throwError("TypeError", "FinalizationRegistry.unregister: unregisterToken cannot be held weakly");
        var removed = false;
        var i: usize = 0;
        while (i < data.cells.items.len) {
            const cell = data.cells.items[i];
            if (cell.unregister_token) |ct| {
                if (ops.sameValue(ct, token)) {
                    _ = data.cells.orderedRemove(i);
                    removed = true;
                    continue; // do not advance i (the next cell shifted into this slot)
                }
            }
            i += 1;
        }
        return .{ .normal = .{ .boolean = removed } };
    }

    unreachable;
}
