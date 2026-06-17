//! §28.1 Reflect — thin wrappers over the engine's reflection internals (the same ops backing
//! `Object.*` / `[[Get]]` / `[[Set]]` / `in` / delete / [[Construct]]). Dispatched from the
//! interpreter's `callNative` (`reflect_method`). Lives in its own file so the interpreter stays the
//! evaluator (mirrors `builtin_array.zig` etc.).
const std = @import("std");
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const builtin_object = @import("builtin_object.zig");
const ops = @import("abstract_ops.zig");
const numberToString = ops.numberToString;
const sameRef = interp.sameRef;

const isCallable = interp.isCallable;
const isConstructor = interp.isConstructor;

pub fn reflectMethod(it: *Interpreter, name: []const u8, args: []const Value) EvalError!Completion {
    const arg0 = if (args.len > 0) args[0] else .undefined;
    const arg1 = if (args.len > 1) args[1] else .undefined;
    const arg2 = if (args.len > 2) args[2] else .undefined;

    // §28.1.1 Reflect.apply ( target, thisArgument, argumentsList )
    if (std.mem.eql(u8, name, "apply")) {
        if (arg0 != .object or !isCallable(arg0.object)) return it.throwError("TypeError", "Reflect.apply target is not callable");
        const list = try it.createListFromArrayLike(arg2);
        switch (list) {
            .abrupt => |c| return c,
            .list => |l| return it.callFunction(arg0.object, l, arg1),
        }
    }

    // §28.1.2 Reflect.construct ( target, argumentsList [ , newTarget ] )
    if (std.mem.eql(u8, name, "construct")) {
        if (arg0 != .object or !isConstructor(arg0.object)) return it.throwError("TypeError", "Reflect.construct target is not a constructor");
        // §28.1.2 step 2–3: newTarget defaults to target; if supplied it must be a constructor.
        var new_target = arg0.object;
        if (args.len > 2) {
            if (arg2 != .object or !isConstructor(arg2.object)) return it.throwError("TypeError", "Reflect.construct newTarget is not a constructor");
            new_target = arg2.object;
        }
        const list = try it.createListFromArrayLike(arg1);
        switch (list) {
            .abrupt => |c| return c,
            .list => |l| return it.constructNT(arg0.object, l, new_target),
        }
    }

    // Every remaining method requires `target` (arg0) be an Object (§28.1.x step 1).
    if (arg0 != .object) return it.throwError("TypeError", "Reflect target must be an object");
    const target = arg0.object;

    // §28.1.6 Reflect.get ( target, propertyKey [ , receiver ] )
    if (std.mem.eql(u8, name, "get")) {
        const receiver: Value = if (args.len > 2) arg2 else arg0;
        return reflectGet(it, arg0, arg1, receiver);
    }
    // §28.1.13 Reflect.set ( target, propertyKey, V [ , receiver ] )
    if (std.mem.eql(u8, name, "set")) {
        const v = if (args.len > 2) arg2 else .undefined;
        const receiver: Value = if (args.len > 3) args[3] else arg0;
        return reflectSet(it, arg0, arg1, v, receiver);
    }
    // §28.1.9 Reflect.has ( target, propertyKey ) → the `in` operation (proto-chain walk).
    if (std.mem.eql(u8, name, "has")) {
        const has = try it.hasPropertyV(arg0, arg1);
        return .{ .normal = .{ .boolean = has } };
    }
    // §28.1.4 Reflect.deleteProperty ( target, propertyKey ) → boolean.
    if (std.mem.eql(u8, name, "deleteProperty")) {
        if (arg1 == .symbol) {
            const ok = target.deleteSymbol(arg1.symbol);
            return .{ .normal = .{ .boolean = ok } };
        }
        const key = try it.toPropertyKeyString(arg1);
        const c = try it.deleteProperty(arg0, key);
        return c;
    }
    // §28.1.11 Reflect.ownKeys ( target ) → own string keys (Array indices, then string props),
    // then own symbol keys, as an Array.
    if (std.mem.eql(u8, name, "ownKeys")) {
        return reflectOwnKeys(it, target);
    }
    // §28.1.8 Reflect.getPrototypeOf ( target ) — the [[Prototype]] (object or null).
    if (std.mem.eql(u8, name, "getPrototypeOf")) {
        return .{ .normal = if (target.prototype) |p| .{ .object = p } else .null };
    }
    // §28.1.14 Reflect.setPrototypeOf ( target, proto ) → boolean (false on a rejected change).
    if (std.mem.eql(u8, name, "setPrototypeOf")) {
        const new_proto: ?*Object = switch (arg1) {
            .null => null,
            .object => |p| p,
            else => return it.throwError("TypeError", "Reflect.setPrototypeOf called with an invalid prototype"),
        };
        if (target.prototype == new_proto) return .{ .normal = .{ .boolean = true } };
        if (!target.extensible) return .{ .normal = .{ .boolean = false } }; // §10.4.7.1: reject, don't throw
        target.prototype = new_proto;
        return .{ .normal = .{ .boolean = true } };
    }
    // §28.1.10 Reflect.isExtensible ( target ) → boolean.
    if (std.mem.eql(u8, name, "isExtensible")) {
        return .{ .normal = .{ .boolean = target.extensible } };
    }
    // §28.1.12 Reflect.preventExtensions ( target ) → boolean (always succeeds here).
    if (std.mem.eql(u8, name, "preventExtensions")) {
        target.extensible = false;
        return .{ .normal = .{ .boolean = true } };
    }
    // §28.1.3 Reflect.defineProperty ( target, propertyKey, attributes ) → boolean (NO throw on a
    // failed define — returns false, unlike Object.defineProperty).
    if (std.mem.eql(u8, name, "defineProperty")) {
        const r = try it.toPropertyDescriptor(arg2);
        switch (r) {
            .abrupt => |c| return c,
            .desc => |d| {
                if (arg1 == .symbol) {
                    const ok = try target.defineSymbol(arg1.symbol, d);
                    return .{ .normal = .{ .boolean = ok } };
                }
                const key = try it.toPropertyKeyString(arg1);
                const ok = try target.defineProperty(key, d);
                return .{ .normal = .{ .boolean = ok } };
            },
        }
    }
    // §28.1.7 Reflect.getOwnPropertyDescriptor ( target, propertyKey ) → descriptor object or undefined.
    if (std.mem.eql(u8, name, "getOwnPropertyDescriptor")) {
        if (arg1 == .symbol) {
            for (target.symbol_props.items) |*sp| {
                if (sp.key == arg1.symbol) return builtin_object.fromPropertyValue(it, sp.pv);
            }
            return .{ .normal = .undefined };
        }
        return builtin_object.objectGetOwnPropertyDescriptor(it, &.{ arg0, arg1 });
    }

    return it.throwError("TypeError", "unknown Reflect method");
}

/// §7.1.19 ToPropertyKey for the string path (a Symbol is handled by the caller's symbol branch).
pub fn toPropertyKeyString(it: *Interpreter, key: Value) EvalError![]const u8 {
    return it.toString(key);
}

/// §28.1.6 [[Get]] with an explicit receiver — locate `key` (string or symbol) on `target`'s chain;
/// a data property returns its value, an accessor invokes its getter with `this` = receiver.
fn reflectGet(it: *Interpreter, target: Value, key: Value, receiver: Value) EvalError!Completion {
    const o = target.object;
    if (key == .symbol) {
        const loc = o.getSymbolProp(key.symbol) orelse return it.getSymbolProperty(target, key.symbol);
        switch (loc.pv.payload) {
            .data => |v| return .{ .normal = v },
            .accessor => |a| {
                const getter = a.get orelse return .{ .normal = .undefined };
                return it.callFunction(getter, &.{}, receiver);
            },
        }
    }
    const ks = try it.toPropertyKeyString(key);
    // Reuse the ordinary [[Get]] for the receiver == target common case (Array/String-exotic aware).
    if (sameRef(target, receiver)) return it.getProperty(target, ks);
    const loc = o.getProp(ks) orelse return it.getProperty(target, ks);
    switch (loc.pv.payload) {
        .data => |v| return .{ .normal = v },
        .accessor => |a| {
            const getter = a.get orelse return .{ .normal = .undefined };
            return it.callFunction(getter, &.{}, receiver);
        },
    }
}

/// §28.1.13 [[Set]] with an explicit receiver → boolean. An inherited/own accessor invokes its
/// setter with `this` = receiver; a data write defines/overwrites on the target (M-subset: the
/// receiver-divergent OrdinarySet redirection is the common receiver == target model).
fn reflectSet(it: *Interpreter, target: Value, key: Value, value: Value, receiver: Value) EvalError!Completion {
    const o = target.object;
    if (key == .symbol) {
        if (o.getSymbolProp(key.symbol)) |loc| if (loc.pv.payload == .accessor) {
            const setter = loc.pv.payload.accessor.set orelse return .{ .normal = .{ .boolean = false } };
            const sc = try it.callFunction(setter, &.{value}, receiver);
            if (sc.isAbrupt()) return sc;
            return .{ .normal = .{ .boolean = true } };
        };
        if (!o.extensible and o.getSymbolProp(key.symbol) == null) return .{ .normal = .{ .boolean = false } };
        try o.setSymbol(key.symbol, value);
        return .{ .normal = .{ .boolean = true } };
    }
    const ks = try it.toPropertyKeyString(key);
    // §10.1.9: a non-writable own data property or a getter-only accessor rejects (→ false).
    if (o.getProp(ks)) |loc| {
        if (loc.pv.payload == .accessor) {
            const setter = loc.pv.payload.accessor.set orelse return .{ .normal = .{ .boolean = false } };
            const sc = try it.callFunction(setter, &.{value}, receiver);
            if (sc.isAbrupt()) return sc;
            return .{ .normal = .{ .boolean = true } };
        }
        if (loc.holder == o and !loc.pv.writable) return .{ .normal = .{ .boolean = false } };
    }
    const sc = try it.setProperty(target, ks, value);
    if (sc.isAbrupt()) return sc;
    return .{ .normal = .{ .boolean = true } };
}

/// §28.1.11 Reflect.ownKeys — own string keys (Array indices in numeric order, then `length` for an
/// Array, then ordinary own string keys in insertion order), then own symbol keys, as an Array.
fn reflectOwnKeys(it: *Interpreter, target: *Object) EvalError!Completion {
    const arr = try Object.createArray(it.arena, it.arrayProto());
    if (target.kind == .array) {
        for (try target.arrayIndices(it.arena)) |i| {
            try arr.elements.append(it.arena, .{ .string = try numberToString(it.arena, @floatFromInt(i)) });
        }
        try arr.elements.append(it.arena, .{ .string = "length" });
    }
    var pit = target.properties.iterator();
    while (pit.next()) |entry| try arr.elements.append(it.arena, .{ .string = entry.key_ptr.* });
    // §28.1.11 step 3.b: own symbol keys follow the string keys.
    for (target.symbol_props.items) |sp| try arr.elements.append(it.arena, .{ .symbol = sp.key });
    arr.array_length = arr.elements.items.len;
    return .{ .normal = .{ .object = arr } };
}
