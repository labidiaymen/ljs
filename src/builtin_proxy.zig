//! §28.2 Proxy — the constructor, `Proxy.revocable`, the revoke function, and the handler-trap
//! routing for the object's internal methods. Each trap is either invoked on the handler or, when
//! absent, forwarded to the target. Regression-safe: the interpreter only routes here when
//! `Object.proxy != null`, which is null for every non-Proxy object. (M59: get; set/has/delete and the
//! reflection + apply/construct traps follow.)
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const ProxyData = object_mod.ProxyData;
const isCallable = interp.isCallable;

/// §28.2.1.1 Proxy ( target, handler ) — both must be objects; build a Proxy exotic whose [[ProxyTarget]]
/// / [[ProxyHandler]] are them. Reached via constructNT (the proxy instance is `new_obj`).
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
    revoke_fn.proxy = proxy_obj.proxy; // stash the ProxyData so the revoker can clear it
    const result = try Object.create(it.arena, it.objectProto());
    try result.set("proxy", .{ .object = proxy_obj });
    try result.set("revoke", .{ .object = revoke_fn });
    return .{ .normal = .{ .object = result } };
}

/// §28.2.2.1.1 the revoke function — mark the proxy revoked (its trap routing then throws).
pub fn revoke(it: *Interpreter, func: *Object) EvalError!Completion {
    _ = it;
    if (func.proxy) |pd| pd.revoked = true;
    return .{ .normal = .undefined };
}

/// §10.5.x GetMethod(handler, name) for a trap: null if absent/undefined; TypeError if not callable.
fn trapMethod(it: *Interpreter, handler: *Object, name: []const u8) EvalError!union(enum) { method: ?*Object, abrupt: Completion } {
    const tc = try it.getProperty2(.{ .object = handler }, name);
    if (tc.isAbrupt()) return .{ .abrupt = tc };
    if (tc.normal == .undefined or tc.normal == .null) return .{ .method = null };
    if (tc.normal != .object or !isCallable(tc.normal.object)) {
        return .{ .abrupt = try it.throwError("TypeError", "proxy trap is not a function") };
    }
    return .{ .method = tc.normal.object };
}

/// §28.2.5.4 [[Get]] ( P, Receiver ) — call the `get` trap (target, P, receiver), or forward to the
/// target's [[Get]]. `key` is the property key as a Value (string or symbol).
pub fn get(it: *Interpreter, pd: *ProxyData, key: Value, receiver: Value) EvalError!Completion {
    if (pd.revoked) return it.throwError("TypeError", "Cannot perform 'get' on a revoked proxy");
    const trap = switch (try trapMethod(it, pd.handler, "get")) {
        .method => |m| m,
        .abrupt => |c| return c,
    };
    if (trap) |t| {
        return it.callFunction(t, &.{ .{ .object = pd.target }, key, receiver }, .{ .object = pd.handler });
    }
    // No trap → forward to the target's [[Get]].
    return switch (key) {
        .symbol => |s| it.getSymbolProperty(.{ .object = pd.target }, s),
        else => it.getProperty2(.{ .object = pd.target }, key.string),
    };
}
