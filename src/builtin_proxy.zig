//! §10.5 / §28.2 Proxy — the constructor, `Proxy.revocable`, the revoke function, and the full
//! handler-trap routing for the object's internal methods. Each internal method either invokes the
//! matching trap on the handler (with the §10.5.x invariant checks) or, when the trap is absent,
//! forwards to the target's ordinary internal method. Regression-safe: the interpreter only routes
//! here when `Object.proxy != null`, which is null for every non-Proxy object.
const std = @import("std");
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Completion = @import("completion.zig").Completion;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const ProxyData = object_mod.ProxyData;
const Descriptor = object_mod.Descriptor;
const PropertyValue = object_mod.PropertyValue;
const builtin_object = @import("builtin_object.zig");
const builtin_reflect = @import("builtin_reflect.zig");
const ops = @import("abstract_ops.zig");
const toBoolean = ops.toBoolean;
const sameValue = ops.sameValue;
const isCallable = interp.isCallable;

/// §28.2.1.1 Proxy ( target, handler ) — both must be objects; build a Proxy exotic whose
/// [[ProxyTarget]] / [[ProxyHandler]] are them. Reached via constructNT (the proxy is `new_obj`).
pub fn construct(it: *Interpreter, new_obj: *Object, args: []const Value) EvalError!Completion {
    return makeProxy(it, new_obj, args);
}

fn makeProxy(it: *Interpreter, new_obj: *Object, args: []const Value) EvalError!Completion {
    const target: Value = if (args.len > 0) args[0] else .undefined;
    const handler: Value = if (args.len > 1) args[1] else .undefined;
    if (target != .object) return it.throwError("TypeError", "Cannot create proxy with a non-object as target");
    if (handler != .object) return it.throwError("TypeError", "Cannot create proxy with a non-object as handler");
    const pd = try it.arena.create(ProxyData);
    pd.* = .{ .target = target.object, .handler = handler.object };
    new_obj.proxy = pd;
    // §10.5.1 step note: a Proxy whose target is callable is itself callable; mark it a function so
    // IsCallable / typeof / [[Call]] route here. Constructability derives from the target (checked
    // in constructNT). Marking `kind = .function` does NOT add an ordinary call body — the interpreter
    // detects `o.proxy != null` first and routes to the apply/construct trap.
    if (target.object.kind == .function) new_obj.kind = .function;
    return .{ .normal = .{ .object = new_obj } };
}

/// §28.2.2.1 Proxy.revocable ( target, handler ) → `{ proxy, revoke }`. The revoke function clears the
/// proxy's [[ProxyTarget]]/[[ProxyHandler]] (revoked), after which every trap throws TypeError.
pub fn revocable(it: *Interpreter, args: []const Value) EvalError!Completion {
    const proxy_obj = try Object.create(it.arena, null); // a Proxy has no own [[Prototype]] slot
    const mc = try makeProxy(it, proxy_obj, args);
    if (mc.isAbrupt()) return mc;
    // The revoker is a native closing over this proxy (via its own `proxy` slot reference).
    const revoke_fn = try Object.createNative(it.arena, .proxy_revoke, "");
    revoke_fn.prototype = it.functionProto();
    // §28.2.2.1.1: the revoke function is an anonymous built-in with no `prototype` own property
    // (it is not a constructor). `createNative` installs one for ordinary natives — remove it here.
    _ = revoke_fn.properties.orderedRemove("prototype");
    revoke_fn.revoke_target = proxy_obj.proxy; // stash the ProxyData so the revoker can clear it
    const result = try Object.create(it.arena, it.objectProto());
    try result.set("proxy", .{ .object = proxy_obj });
    try result.set("revoke", .{ .object = revoke_fn });
    return .{ .normal = .{ .object = result } };
}

/// §28.2.2.1.1 the revoke function — mark the proxy revoked (its trap routing then throws).
pub fn revoke(it: *Interpreter, func: *Object) EvalError!Completion {
    _ = it;
    if (func.revoke_target) |pd| pd.revoked = true;
    return .{ .normal = .undefined };
}

// ── trap acquisition ────────────────────────────────────────────────────────

const TrapResult = union(enum) { method: ?*Object, abrupt: Completion };

/// §10.5.x GetMethod(handler, name): null if absent/undefined; TypeError if present but not callable.
fn trapMethod(it: *Interpreter, handler: *Object, name: []const u8) EvalError!TrapResult {
    const tc = try it.getProperty2(.{ .object = handler }, name);
    if (tc.isAbrupt()) return .{ .abrupt = tc };
    if (tc.normal == .undefined or tc.normal == .null) return .{ .method = null };
    if (tc.normal != .object or !isCallable(tc.normal.object)) {
        return .{ .abrupt = try it.throwError("TypeError", "proxy trap is not a function") };
    }
    return .{ .method = tc.normal.object };
}

/// Common preamble for every trap: a revoked proxy throws; otherwise return `(handler, target)`.
fn enter(it: *Interpreter, pd: *ProxyData, op: []const u8) EvalError!union(enum) {
    ok: struct { handler: *Object, target: *Object },
    abrupt: Completion,
} {
    if (pd.revoked) return .{ .abrupt = try throwRevoked(it, op) };
    return .{ .ok = .{ .handler = pd.handler, .target = pd.target } };
}

fn throwRevoked(it: *Interpreter, op: []const u8) EvalError!Completion {
    _ = op;
    return it.throwError("TypeError", "Cannot perform operation on a revoked proxy");
}

// ── §10.5.8 [[Get]] ─────────────────────────────────────────────────────────

pub fn get(it: *Interpreter, pd: *ProxyData, key: Value, receiver: Value) EvalError!Completion {
    const e = switch (try enter(it, pd, "get")) {
        .ok => |x| x,
        .abrupt => |c| return c,
    };
    const trap = switch (try trapMethod(it, e.handler, "get")) {
        .method => |m| m,
        .abrupt => |c| return c,
    };
    if (trap == null) return builtin_reflect.reflectGet(it, .{ .object = e.target }, key, receiver);
    const result = try it.callFunction(trap.?, &.{ .{ .object = e.target }, key, receiver }, .{ .object = e.handler });
    if (result.isAbrupt()) return result;
    // §10.5.8 invariant: a non-configurable, non-writable own DATA property must report SameValue;
    // a non-configurable own accessor with undefined [[Get]] must report undefined.
    const targetDesc = try targetOwnPV(it, e.target, key);
    if (targetDesc.isAbrupt()) return targetDesc.abrupt;
    if (targetDesc.pv) |pv| {
        if (!pv.configurable) {
            switch (pv.payload) {
                .data => |dv| if (!pv.writable and !sameValue(result.normal, dv)) {
                    return it.throwError("TypeError", "proxy [[Get]] inconsistent with non-configurable, non-writable own data property");
                },
                .accessor => |a| if (a.get == null and result.normal != .undefined) {
                    return it.throwError("TypeError", "proxy [[Get]] inconsistent with non-configurable accessor with undefined getter");
                },
            }
        }
    }
    return result;
}

// ── §10.5.9 [[Set]] ─────────────────────────────────────────────────────────

pub fn set(it: *Interpreter, pd: *ProxyData, key: Value, v: Value, receiver: Value) EvalError!Completion {
    const e = switch (try enter(it, pd, "set")) {
        .ok => |x| x,
        .abrupt => |c| return c,
    };
    const trap = switch (try trapMethod(it, e.handler, "set")) {
        .method => |m| m,
        .abrupt => |c| return c,
    };
    if (trap == null) return builtin_reflect.reflectSet(it, .{ .object = e.target }, key, v, receiver);
    const result = try it.callFunction(trap.?, &.{ .{ .object = e.target }, key, v, receiver }, .{ .object = e.handler });
    if (result.isAbrupt()) return result;
    if (!toBoolean(result.normal)) return .{ .normal = .{ .boolean = false } };
    // §10.5.9 invariant: cannot change the value of a non-configurable non-writable own data prop, and
    // cannot set a non-configurable accessor prop whose [[Set]] is undefined.
    const targetDesc = try targetOwnPV(it, e.target, key);
    if (targetDesc.isAbrupt()) return targetDesc.abrupt;
    if (targetDesc.pv) |pv| {
        if (!pv.configurable) switch (pv.payload) {
            .data => |dv| if (!pv.writable and !sameValue(v, dv)) {
                return it.throwError("TypeError", "proxy [[Set]] cannot change a non-configurable, non-writable own data property");
            },
            .accessor => |a| if (a.set == null) {
                return it.throwError("TypeError", "proxy [[Set]] cannot set a non-configurable accessor property with undefined setter");
            },
        };
    }
    return .{ .normal = .{ .boolean = true } };
}

// ── §10.5.7 [[HasProperty]] ─────────────────────────────────────────────────

pub fn has(it: *Interpreter, pd: *ProxyData, key: Value) EvalError!Completion {
    const e = switch (try enter(it, pd, "has")) {
        .ok => |x| x,
        .abrupt => |c| return c,
    };
    const trap = switch (try trapMethod(it, e.handler, "has")) {
        .method => |m| m,
        .abrupt => |c| return c,
    };
    if (trap == null) {
        const h = try it.hasPropertyV(.{ .object = e.target }, key);
        return .{ .normal = .{ .boolean = h } };
    }
    const result = try it.callFunction(trap.?, &.{ .{ .object = e.target }, key }, .{ .object = e.handler });
    if (result.isAbrupt()) return result;
    const b = toBoolean(result.normal);
    if (!b) {
        // §10.5.7 invariant: cannot report an existing non-configurable own key, nor an existing own
        // key of a non-extensible target, as absent.
        const targetDesc = try targetOwnPV(it, e.target, key);
        if (targetDesc.isAbrupt()) return targetDesc.abrupt;
        if (targetDesc.pv) |pv| {
            if (!pv.configurable) return it.throwError("TypeError", "proxy [[Has]] cannot report a non-configurable own property as absent");
            const ext = switch (try it.ordinaryIsExtensible(e.target)) {
                .ext => |x| x,
                .abrupt => |c| return c,
            };
            if (!ext) return it.throwError("TypeError", "proxy [[Has]] cannot report an own property of a non-extensible target as absent");
        }
    }
    return .{ .normal = .{ .boolean = b } };
}

// ── §10.5.10 [[Delete]] ─────────────────────────────────────────────────────

pub fn deleteProperty(it: *Interpreter, pd: *ProxyData, key: Value) EvalError!Completion {
    const e = switch (try enter(it, pd, "deleteProperty")) {
        .ok => |x| x,
        .abrupt => |c| return c,
    };
    const trap = switch (try trapMethod(it, e.handler, "deleteProperty")) {
        .method => |m| m,
        .abrupt => |c| return c,
    };
    if (trap == null) {
        return switch (key) {
            .symbol => |s| .{ .normal = .{ .boolean = e.target.deleteSymbol(s) } },
            else => it.deleteProperty(.{ .object = e.target }, key.string),
        };
    }
    const result = try it.callFunction(trap.?, &.{ .{ .object = e.target }, key }, .{ .object = e.handler });
    if (result.isAbrupt()) return result;
    if (!toBoolean(result.normal)) return .{ .normal = .{ .boolean = false } };
    // §10.5.10 invariant: cannot report a non-configurable own property as deleted; cannot delete an
    // own property of a non-extensible target.
    const targetDesc = try targetOwnPV(it, e.target, key);
    if (targetDesc.isAbrupt()) return targetDesc.abrupt;
    if (targetDesc.pv) |pv| {
        if (!pv.configurable) return it.throwError("TypeError", "proxy [[Delete]] cannot delete a non-configurable own property");
        const ext = switch (try it.ordinaryIsExtensible(e.target)) {
            .ext => |x| x,
            .abrupt => |c| return c,
        };
        if (!ext) return it.throwError("TypeError", "proxy [[Delete]] cannot delete an own property of a non-extensible target");
    }
    return .{ .normal = .{ .boolean = true } };
}

// ── §10.5.5 [[GetOwnProperty]] ──────────────────────────────────────────────

/// Returns a descriptor OBJECT (FromPropertyDescriptor) or undefined.
pub fn getOwnProperty(it: *Interpreter, pd: *ProxyData, key: Value) EvalError!Completion {
    const e = switch (try enter(it, pd, "getOwnPropertyDescriptor")) {
        .ok => |x| x,
        .abrupt => |c| return c,
    };
    const trap = switch (try trapMethod(it, e.handler, "getOwnPropertyDescriptor")) {
        .method => |m| m,
        .abrupt => |c| return c,
    };
    if (trap == null) {
        const tpv = try targetOwnPV(it, e.target, key);
        if (tpv.isAbrupt()) return tpv.abrupt;
        if (tpv.pv) |pv| return builtin_object.fromPropertyValue(it, pv);
        return .{ .normal = .undefined };
    }
    const result = try it.callFunction(trap.?, &.{ .{ .object = e.target }, key }, .{ .object = e.handler });
    if (result.isAbrupt()) return result;
    if (result.normal != .object and result.normal != .undefined) {
        return it.throwError("TypeError", "proxy getOwnPropertyDescriptor trap must return an object or undefined");
    }
    const tpv = try targetOwnPV(it, e.target, key);
    if (tpv.isAbrupt()) return tpv.abrupt;
    const ext = switch (try it.ordinaryIsExtensible(e.target)) {
        .ext => |x| x,
        .abrupt => |c| return c,
    };
    if (result.normal == .undefined) {
        // §10.5.5 step 9: undefined → the target must have no such non-configurable / mandatory prop.
        if (tpv.pv) |pv| {
            if (!pv.configurable) return it.throwError("TypeError", "proxy getOwnPropertyDescriptor cannot report a non-configurable own property as non-existent");
            if (!ext) return it.throwError("TypeError", "proxy getOwnPropertyDescriptor cannot report an own property of a non-extensible target as non-existent");
        }
        return .{ .normal = .undefined };
    }
    // The trap returned a descriptor object: ToPropertyDescriptor + CompletePropertyDescriptor.
    const r = try it.toPropertyDescriptor(result.normal);
    const trap_desc = switch (r) {
        .desc => |d| d,
        .abrupt => |c| return c,
    };
    const valid = isCompatibleDescriptor(ext, trap_desc, tpv.pv);
    if (!valid) return it.throwError("TypeError", "proxy getOwnPropertyDescriptor returned a descriptor incompatible with the target");
    // §10.5.5 step 17: a non-configurable result requires a matching non-configurable target prop.
    const result_configurable = trap_desc.configurable orelse false;
    if (!result_configurable) {
        if (tpv.pv == null or tpv.pv.?.configurable) {
            return it.throwError("TypeError", "proxy getOwnPropertyDescriptor reported a non-configurable descriptor for a configurable or non-existent property");
        }
        // §10.5.5 step 17.b.i: a non-configurable, non-writable data result requires the target prop
        // also be non-writable.
        if (trap_desc.isData() and (trap_desc.writable orelse false) == false) {
            if (tpv.pv) |pv| if (pv.payload == .data and pv.writable) {
                return it.throwError("TypeError", "proxy getOwnPropertyDescriptor reported a non-configurable non-writable descriptor for a writable target property");
            };
        }
    }
    // Return a completed descriptor object (FromPropertyDescriptor of the trap's, defaults filled).
    return fromCompletedDescriptor(it, trap_desc);
}

/// §6.2.6 FromPropertyDescriptor with CompletePropertyDescriptor defaults applied.
fn fromCompletedDescriptor(it: *Interpreter, d: Descriptor) EvalError!Completion {
    const obj = try Object.create(it.arena, it.objectProto());
    if (d.isAccessor()) {
        try obj.set("get", if (d.get) |g| (if (g) |gg| .{ .object = gg } else .undefined) else .undefined);
        try obj.set("set", if (d.set) |s| (if (s) |ss| .{ .object = ss } else .undefined) else .undefined);
    } else {
        try obj.set("value", if (d.has_value) d.value.? else .undefined);
        try obj.set("writable", .{ .boolean = d.writable orelse false });
    }
    try obj.set("enumerable", .{ .boolean = d.enumerable orelse false });
    try obj.set("configurable", .{ .boolean = d.configurable orelse false });
    return .{ .normal = .{ .object = obj } };
}

// ── §10.5.6 [[DefineOwnProperty]] ───────────────────────────────────────────

pub fn defineProperty(it: *Interpreter, pd: *ProxyData, key: Value, desc: Descriptor) EvalError!Completion {
    const e = switch (try enter(it, pd, "defineProperty")) {
        .ok => |x| x,
        .abrupt => |c| return c,
    };
    const trap = switch (try trapMethod(it, e.handler, "defineProperty")) {
        .method => |m| m,
        .abrupt => |c| return c,
    };
    if (trap == null) {
        switch (key) {
            .symbol => |s| return switch (try it.ordinaryDefineOwnPropertySymbol(e.target, s, desc)) {
                .ok => |ok| .{ .normal = .{ .boolean = ok } },
                .abrupt => |c| c,
            },
            else => return switch (try it.ordinaryDefineOwnProperty(e.target, key.string, desc)) {
                .ok => |ok| .{ .normal = .{ .boolean = ok } },
                .abrupt => |c| c,
            },
        }
    }
    // Build a descriptor object to hand the trap (FromPropertyDescriptor of the supplied desc).
    const desc_obj = try descriptorToObject(it, desc);
    const result = try it.callFunction(trap.?, &.{ .{ .object = e.target }, key, .{ .object = desc_obj } }, .{ .object = e.handler });
    if (result.isAbrupt()) return result;
    if (!toBoolean(result.normal)) return .{ .normal = .{ .boolean = false } };
    // §10.5.6 invariants.
    const tpv = try targetOwnPV(it, e.target, key);
    if (tpv.isAbrupt()) return tpv.abrupt;
    const ext = switch (try it.ordinaryIsExtensible(e.target)) {
        .ext => |x| x,
        .abrupt => |c| return c,
    };
    const setting_nonconfig = (desc.configurable orelse true) == false;
    if (tpv.pv == null) {
        if (!ext) return it.throwError("TypeError", "proxy defineProperty cannot add a property to a non-extensible target");
        if (setting_nonconfig) return it.throwError("TypeError", "proxy defineProperty cannot define a non-configurable property that does not exist on the target");
    } else {
        if (!isCompatibleDescriptor(ext, desc, tpv.pv)) {
            return it.throwError("TypeError", "proxy defineProperty defined an incompatible descriptor");
        }
        if (setting_nonconfig and tpv.pv.?.configurable) {
            return it.throwError("TypeError", "proxy defineProperty cannot make a configurable target property non-configurable");
        }
        // §10.5.6 step 16.c.i: a non-configurable, WRITABLE target data prop cannot be redefined as
        // non-writable via the proxy (would hide an observable mutation).
        if (!tpv.pv.?.configurable and tpv.pv.?.payload == .data and tpv.pv.?.writable) {
            if (desc.isData() and desc.writable != null and desc.writable.? == false) {
                return it.throwError("TypeError", "proxy defineProperty cannot make a non-configurable writable property non-writable");
            }
        }
    }
    return .{ .normal = .{ .boolean = true } };
}

fn descriptorToObject(it: *Interpreter, d: Descriptor) EvalError!*Object {
    const obj = try Object.create(it.arena, it.objectProto());
    if (d.has_value) try obj.set("value", d.value.?);
    if (d.writable) |w| try obj.set("writable", .{ .boolean = w });
    if (d.get) |g| try obj.set("get", if (g) |gg| .{ .object = gg } else .undefined);
    if (d.set) |s| try obj.set("set", if (s) |ss| .{ .object = ss } else .undefined);
    if (d.enumerable) |en| try obj.set("enumerable", .{ .boolean = en });
    if (d.configurable) |c| try obj.set("configurable", .{ .boolean = c });
    return obj;
}

// ── §10.5.1 [[GetPrototypeOf]] ──────────────────────────────────────────────

pub fn getPrototypeOf(it: *Interpreter, pd: *ProxyData) EvalError!Completion {
    const e = switch (try enter(it, pd, "getPrototypeOf")) {
        .ok => |x| x,
        .abrupt => |c| return c,
    };
    const trap = switch (try trapMethod(it, e.handler, "getPrototypeOf")) {
        .method => |m| m,
        .abrupt => |c| return c,
    };
    if (trap == null) {
        return switch (try it.ordinaryGetPrototypeOf(e.target)) {
            .proto => |p| .{ .normal = if (p) |pp| .{ .object = pp } else .null },
            .abrupt => |c| c,
        };
    }
    const result = try it.callFunction(trap.?, &.{.{ .object = e.target }}, .{ .object = e.handler });
    if (result.isAbrupt()) return result;
    if (result.normal != .object and result.normal != .null) {
        return it.throwError("TypeError", "proxy getPrototypeOf trap must return an object or null");
    }
    // §10.5.1 invariant: a non-extensible target's [[GetPrototypeOf]] must match the target's proto.
    const ext = switch (try it.ordinaryIsExtensible(e.target)) {
        .ext => |x| x,
        .abrupt => |c| return c,
    };
    if (!ext) {
        const tproto = switch (try it.ordinaryGetPrototypeOf(e.target)) {
            .proto => |p| p,
            .abrupt => |c| return c,
        };
        const rproto: ?*Object = if (result.normal == .object) result.normal.object else null;
        if (tproto != rproto) return it.throwError("TypeError", "proxy getPrototypeOf returned a prototype inconsistent with a non-extensible target");
    }
    return result;
}

// ── §10.5.2 [[SetPrototypeOf]] ──────────────────────────────────────────────

pub fn setPrototypeOf(it: *Interpreter, pd: *ProxyData, proto: ?*Object) EvalError!Completion {
    const e = switch (try enter(it, pd, "setPrototypeOf")) {
        .ok => |x| x,
        .abrupt => |c| return c,
    };
    const trap = switch (try trapMethod(it, e.handler, "setPrototypeOf")) {
        .method => |m| m,
        .abrupt => |c| return c,
    };
    if (trap == null) {
        return switch (try it.ordinarySetPrototypeOf(e.target, proto)) {
            .ok => |ok| .{ .normal = .{ .boolean = ok } },
            .abrupt => |c| c,
        };
    }
    const proto_val: Value = if (proto) |p| .{ .object = p } else .null;
    const result = try it.callFunction(trap.?, &.{ .{ .object = e.target }, proto_val }, .{ .object = e.handler });
    if (result.isAbrupt()) return result;
    if (!toBoolean(result.normal)) return .{ .normal = .{ .boolean = false } };
    // §10.5.2 invariant: on a non-extensible target the new proto must equal the target's proto.
    const ext = switch (try it.ordinaryIsExtensible(e.target)) {
        .ext => |x| x,
        .abrupt => |c| return c,
    };
    if (!ext) {
        const tproto = switch (try it.ordinaryGetPrototypeOf(e.target)) {
            .proto => |p| p,
            .abrupt => |c| return c,
        };
        if (tproto != proto) return it.throwError("TypeError", "proxy setPrototypeOf cannot change the prototype of a non-extensible target");
    }
    return .{ .normal = .{ .boolean = true } };
}

// ── §10.5.3 [[IsExtensible]] ────────────────────────────────────────────────

pub fn isExtensible(it: *Interpreter, pd: *ProxyData) EvalError!Completion {
    const e = switch (try enter(it, pd, "isExtensible")) {
        .ok => |x| x,
        .abrupt => |c| return c,
    };
    const trap = switch (try trapMethod(it, e.handler, "isExtensible")) {
        .method => |m| m,
        .abrupt => |c| return c,
    };
    if (trap == null) {
        return switch (try it.ordinaryIsExtensible(e.target)) {
            .ext => |x| .{ .normal = .{ .boolean = x } },
            .abrupt => |c| c,
        };
    }
    const result = try it.callFunction(trap.?, &.{.{ .object = e.target }}, .{ .object = e.handler });
    if (result.isAbrupt()) return result;
    const b = toBoolean(result.normal);
    // §10.5.3 invariant: the result must equal the target's [[IsExtensible]].
    const tex = switch (try it.ordinaryIsExtensible(e.target)) {
        .ext => |x| x,
        .abrupt => |c| return c,
    };
    if (b != tex) return it.throwError("TypeError", "proxy isExtensible report must match the target's extensibility");
    return .{ .normal = .{ .boolean = b } };
}

// ── §10.5.4 [[PreventExtensions]] ───────────────────────────────────────────

pub fn preventExtensions(it: *Interpreter, pd: *ProxyData) EvalError!Completion {
    const e = switch (try enter(it, pd, "preventExtensions")) {
        .ok => |x| x,
        .abrupt => |c| return c,
    };
    const trap = switch (try trapMethod(it, e.handler, "preventExtensions")) {
        .method => |m| m,
        .abrupt => |c| return c,
    };
    if (trap == null) {
        return switch (try it.ordinaryPreventExtensions(e.target)) {
            .ok => |ok| .{ .normal = .{ .boolean = ok } },
            .abrupt => |c| c,
        };
    }
    const result = try it.callFunction(trap.?, &.{.{ .object = e.target }}, .{ .object = e.handler });
    if (result.isAbrupt()) return result;
    const b = toBoolean(result.normal);
    if (b) {
        // §10.5.4 invariant: a true report requires the target be non-extensible.
        const tex = switch (try it.ordinaryIsExtensible(e.target)) {
            .ext => |x| x,
            .abrupt => |c| return c,
        };
        if (tex) return it.throwError("TypeError", "proxy preventExtensions cannot report success while the target is still extensible");
    }
    return .{ .normal = .{ .boolean = b } };
}

// ── §10.5.11 [[OwnPropertyKeys]] ────────────────────────────────────────────

/// Returns an Array of own keys (strings + symbols).
pub fn ownKeys(it: *Interpreter, pd: *ProxyData) EvalError!Completion {
    const e = switch (try enter(it, pd, "ownKeys")) {
        .ok => |x| x,
        .abrupt => |c| return c,
    };
    const trap = switch (try trapMethod(it, e.handler, "ownKeys")) {
        .method => |m| m,
        .abrupt => |c| return c,
    };
    if (trap == null) {
        const keys = switch (try it.ordinaryOwnKeys(e.target)) {
            .keys => |k| k,
            .abrupt => |c| return c,
        };
        return keysToArray(it, keys);
    }
    const result = try it.callFunction(trap.?, &.{.{ .object = e.target }}, .{ .object = e.handler });
    if (result.isAbrupt()) return result;
    if (result.normal != .object) return it.throwError("TypeError", "proxy ownKeys trap must return an array-like object");
    // §10.5.11 step 7: CreateListFromArrayLike with element-type {String, Symbol}.
    const trap_keys = switch (try createKeyList(it, result.normal.object)) {
        .keys => |k| k,
        .abrupt => |c| return c,
    };
    // §10.5.11 step 8: the list must contain no duplicate entries.
    if (try hasDuplicateKey(it, trap_keys)) return it.throwError("TypeError", "proxy ownKeys trap returned duplicate keys");
    const ext = switch (try it.ordinaryIsExtensible(e.target)) {
        .ext => |x| x,
        .abrupt => |c| return c,
    };
    const target_keys = switch (try it.ordinaryOwnKeys(e.target)) {
        .keys => |k| k,
        .abrupt => |c| return c,
    };
    // §10.5.11 steps 13–23: partition the target keys into non-configurable and configurable own keys.
    // Every non-configurable target key MUST appear in the trap result. If the target is non-extensible,
    // the trap result must be exactly the target's keys (no extra, none missing).
    var missing_nonconfig = false;
    var missing_config = false;
    for (target_keys) |tk| {
        const tpv = try targetOwnPV(it, e.target, tk);
        if (tpv.isAbrupt()) return tpv.abrupt;
        const present = keyInList(tk, trap_keys);
        if (tpv.pv) |pv| {
            if (!pv.configurable and !present) missing_nonconfig = true;
            if (pv.configurable and !present and !ext) missing_config = true;
        }
    }
    if (missing_nonconfig) return it.throwError("TypeError", "proxy ownKeys trap omitted a non-configurable own key");
    if (!ext) {
        if (missing_config) return it.throwError("TypeError", "proxy ownKeys trap omitted an own key of a non-extensible target");
        // No extra keys beyond the target's own keys when non-extensible.
        for (trap_keys) |rk| {
            if (!keyInList(rk, target_keys)) return it.throwError("TypeError", "proxy ownKeys trap reported an extra key for a non-extensible target");
        }
    }
    return keysToArray(it, trap_keys);
}

fn keysToArray(it: *Interpreter, keys: []const Value) EvalError!Completion {
    const arr = try Object.createArray(it.arena, it.arrayProto());
    for (keys) |k| try arr.elements.append(it.arena, k);
    arr.array_length = arr.elements.items.len;
    return .{ .normal = .{ .object = arr } };
}

const KeyList = union(enum) { keys: []Value, abrupt: Completion };

/// §7.3.18 CreateListFromArrayLike restricted to {String, Symbol} — used for the ownKeys trap result.
fn createKeyList(it: *Interpreter, arrayLike: *Object) EvalError!KeyList {
    const lc = try it.getProperty2(.{ .object = arrayLike }, "length");
    if (lc.isAbrupt()) return .{ .abrupt = lc };
    // §7.3.20 LengthOfArrayLike = ToLength(Get(obj, "length")): clamp to [0, 2^53-1].
    const raw = ops.toNumber(lc.normal);
    const n = if (std.math.isNan(raw)) 0 else @trunc(raw);
    const len: usize = if (n > 0) (if (n > 9007199254740991.0) 9007199254740991 else @intFromFloat(n)) else 0;
    var out: std.ArrayListUnmanaged(Value) = .empty;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const idx_key = try std.fmt.allocPrint(it.arena, "{d}", .{i});
        const ev = try it.getProperty2(.{ .object = arrayLike }, idx_key);
        if (ev.isAbrupt()) return .{ .abrupt = ev };
        if (ev.normal != .string and ev.normal != .symbol) {
            return .{ .abrupt = try it.throwError("TypeError", "proxy ownKeys trap returned a non-key element") };
        }
        try out.append(it.arena, ev.normal);
    }
    return .{ .keys = try out.toOwnedSlice(it.arena) };
}

fn keyInList(k: Value, list: []const Value) bool {
    for (list) |x| if (sameKey(k, x)) return true;
    return false;
}

fn hasDuplicateKey(it: *Interpreter, keys: []const Value) EvalError!bool {
    _ = it;
    for (keys, 0..) |k, i| {
        var j: usize = i + 1;
        while (j < keys.len) : (j += 1) {
            if (sameKey(k, keys[j])) return true;
        }
    }
    return false;
}

fn sameKey(a: Value, b: Value) bool {
    if (a == .symbol and b == .symbol) return a.symbol == b.symbol;
    if (a == .string and b == .string) return std.mem.eql(u8, a.string, b.string);
    return false;
}

// ── §10.5.12 [[Call]] / §10.5.13 [[Construct]] ──────────────────────────────

pub fn apply(it: *Interpreter, pd: *ProxyData, args: []const Value, this_val: Value) EvalError!Completion {
    const e = switch (try enter(it, pd, "apply")) {
        .ok => |x| x,
        .abrupt => |c| return c,
    };
    const trap = switch (try trapMethod(it, e.handler, "apply")) {
        .method => |m| m,
        .abrupt => |c| return c,
    };
    if (trap == null) return it.callFunction(e.target, args, this_val);
    const args_array = try makeArgArray(it, args);
    return it.callFunction(trap.?, &.{ .{ .object = e.target }, this_val, .{ .object = args_array } }, .{ .object = e.handler });
}

pub fn proxyConstruct(it: *Interpreter, pd: *ProxyData, args: []const Value, new_target: *Object) EvalError!Completion {
    const e = switch (try enter(it, pd, "construct")) {
        .ok => |x| x,
        .abrupt => |c| return c,
    };
    const trap = switch (try trapMethod(it, e.handler, "construct")) {
        .method => |m| m,
        .abrupt => |c| return c,
    };
    if (trap == null) return it.constructNT(e.target, args, new_target);
    const args_array = try makeArgArray(it, args);
    const result = try it.callFunction(trap.?, &.{ .{ .object = e.target }, .{ .object = args_array }, .{ .object = new_target } }, .{ .object = e.handler });
    if (result.isAbrupt()) return result;
    // §10.5.13 invariant: the construct trap must return an Object.
    if (result.normal != .object) return it.throwError("TypeError", "proxy construct trap must return an object");
    return result;
}

fn makeArgArray(it: *Interpreter, args: []const Value) EvalError!*Object {
    const arr = try Object.createArray(it.arena, it.arrayProto());
    for (args) |a| try arr.elements.append(it.arena, a);
    arr.array_length = arr.elements.items.len;
    return arr;
}

// ── shared invariant helpers ────────────────────────────────────────────────

const TargetPV = union(enum) {
    pv: ?PropertyValue,
    abrupt: Completion,
    fn isAbrupt(self: TargetPV) bool {
        return self == .abrupt;
    }
};

/// The target's own descriptor for `key` (string or symbol) as a PropertyValue, or null when absent.
fn targetOwnPV(it: *Interpreter, target: *Object, key: Value) EvalError!TargetPV {
    switch (key) {
        .symbol => |s| return switch (try it.ordinaryGetOwnPropertySymbol(target, s)) {
            .pv => |pv| .{ .pv = pv },
            .abrupt => |c| .{ .abrupt = c },
        },
        else => return switch (try it.ordinaryGetOwnProperty(target, key.string)) {
            .pv => |pv| .{ .pv = pv },
            .abrupt => |c| .{ .abrupt = c },
        },
    }
}

/// §10.5.6 IsCompatiblePropertyDescriptor(extensible, Desc, current) — ValidateAndApplyPropertyDescriptor
/// with no side effects. `current` null ⇒ the property is absent on the target.
fn isCompatibleDescriptor(extensible: bool, desc: Descriptor, current: ?PropertyValue) bool {
    const cur = current orelse {
        // Absent: allowed iff the target is extensible (caller also checks non-config separately).
        return extensible;
    };
    // current present.
    if (!cur.configurable) {
        if (desc.configurable orelse false) return false;
        if (desc.enumerable) |en| {
            if (en != cur.enumerable) return false;
        }
        const desc_is_accessor = desc.isAccessor();
        const cur_is_accessor = cur.payload == .accessor;
        if (desc.isData() or desc_is_accessor) {
            if (desc_is_accessor != cur_is_accessor) return false;
        }
        if (cur_is_accessor) {
            // both accessor: get/set must match if specified.
            if (desc.get) |g| {
                const cg = cur.payload.accessor.get;
                if ((g orelse null) != cg) return false;
            }
            if (desc.set) |s| {
                const cs = cur.payload.accessor.set;
                if ((s orelse null) != cs) return false;
            }
        } else {
            // both data, non-configurable.
            if (!cur.writable) {
                if (desc.writable orelse false) return false;
                if (desc.has_value) {
                    if (!sameValue(desc.value.?, cur.payload.data)) return false;
                }
            }
        }
    }
    return true;
}
