//! Global built-ins seeded into a realm's global environment (ECMA-262 §19/§20, M1 subset).
//! Built-ins are function objects tagged with a `NativeId`; their behavior lives in the
//! interpreter's callNative. M1 provides the Error family, `String`, and a minimal `Object`.
//! Deferred (failure-path only for the Test262 harness): `Array`, `Function.prototype.call`,
//! `Object.prototype.toString.call`.
const std = @import("std");
const Object = @import("object.zig").Object;
const Environment = @import("environment.zig").Environment;

pub const error_names = [_][]const u8{
    "Error",       "TypeError", "RangeError", "ReferenceError",
    "SyntaxError", "EvalError", "URIError",
};

const NativeId = @import("object.zig").NativeId;

/// Install a non-enumerable built-in method on `target` (§17 built-in methods are writable +
/// configurable but NON-enumerable — load-bearing so `for (k in {})` / `Object.keys` don't surface
/// prototype methods, the propertyHelper.js unblock).
fn defineMethod(arena: std.mem.Allocator, target: *Object, name: []const u8, id: NativeId, native_name: []const u8) std.mem.Allocator.Error!void {
    const fn_obj = try Object.createNative(arena, id, native_name);
    try target.defineData(name, .{ .object = fn_obj }, true, false, true);
}

pub fn setup(arena: std.mem.Allocator, env: *Environment) std.mem.Allocator.Error!void {
    // §19.1 Value properties of the global object — `undefined`/`NaN`/`Infinity`. These are
    // non-writable, non-configurable in the spec, so we declare them immutable. Many programs
    // (and the Test262 `assert` harness, e.g. `message === undefined`) depend on these.
    try env.declare("undefined", .undefined, false, true); // §19.1.4
    try env.declare("NaN", .{ .number = std.math.nan(f64) }, false, true); // §19.1.1
    try env.declare("Infinity", .{ .number = std.math.inf(f64) }, false, true); // §19.1.2

    // §20.1 Object — constructor + Object.prototype reflection (§20.1.3) + Object static reflection
    // (§20.1.2). Built FIRST so every other built-in prototype can chain its [[Prototype]] to
    // %Object.prototype% (§23.1.3 / §22.1.3 / §20.5.3.1: Array/String/Error prototypes inherit from
    // it), making `hasOwnProperty`/`isPrototypeOf`/`toString` resolve on arrays, strings, errors, etc.
    // All prototype/static methods are non-enumerable (so the chained inheritance doesn't surface in
    // for-in / Object.keys — the propertyHelper.js unblock).
    const object_fn = try Object.createNative(arena, .object_ctor, "Object");
    const object_proto: ?*Object = blk: {
        const pv = object_fn.get("prototype") orelse break :blk null;
        break :blk if (pv == .object) pv.object else null;
    };
    if (object_proto) |op| {
        try defineMethod(arena, op, "toString", .object_to_string, "toString");
        try defineMethod(arena, op, "hasOwnProperty", .object_has_own_property, "hasOwnProperty");
        try defineMethod(arena, op, "propertyIsEnumerable", .object_property_is_enumerable, "propertyIsEnumerable");
        try defineMethod(arena, op, "isPrototypeOf", .object_is_prototype_of, "isPrototypeOf");
    }
    try defineMethod(arena, object_fn, "defineProperty", .object_define_property, "defineProperty");
    try defineMethod(arena, object_fn, "defineProperties", .object_define_properties, "defineProperties");
    try defineMethod(arena, object_fn, "getOwnPropertyDescriptor", .object_get_own_property_descriptor, "getOwnPropertyDescriptor");
    try defineMethod(arena, object_fn, "getOwnPropertyNames", .object_get_own_property_names, "getOwnPropertyNames");
    try env.declare("Object", .{ .object = object_fn }, true, true);

    // §20.5 The Error family — each a native constructor; `name` is the error name.
    for (error_names) |name| {
        const ctor = try Object.createNative(arena, .error_ctor, name);
        // instances carry their own `name`; also expose it on the prototype for completeness.
        if (ctor.get("prototype")) |pv| {
            if (pv == .object) {
                pv.object.prototype = object_proto; // §20.5.3.1 Error.prototype inherits %Object.prototype%
                try pv.object.set("name", .{ .string = name });
            }
        }
        try env.declare(name, .{ .object = ctor }, true, true);
    }

    // §22.1 String( x ) — ToString; String.prototype methods (boxing finds them via getProperty).
    const string_fn = try Object.createNative(arena, .string_ctor, "String");
    if (string_fn.get("prototype")) |pv| {
        if (pv == .object) {
            pv.object.prototype = object_proto; // §22.1.3 String.prototype inherits %Object.prototype%
            const string_methods = [_][]const u8{
                "charAt",    "charCodeAt",  "indexOf",     "includes", "slice",
                "substring", "toUpperCase", "toLowerCase", "split",
            };
            for (string_methods) |m| try defineMethod(arena, pv.object, m, .string_method, m);
        }
    }
    try env.declare("String", .{ .object = string_fn }, true, true);

    // §20.2 Function — minimal constructor; its `.prototype` is the carrier for call/apply/bind
    // (installed in Cycle 2). Present now so `Function` resolves and ordinary functions can later
    // proto-link to it. for-in/enumeration stops at it (isBuiltinProto).
    const function_fn = try Object.createNative(arena, .function_ctor, "Function");
    if (function_fn.get("prototype")) |pv| {
        if (pv == .object) pv.object.prototype = object_proto; // §20.2.3 Function.prototype inherits %Object.prototype%
    }
    try env.declare("Function", .{ .object = function_fn }, true, true);

    // §23.1 Array — constructor, Array.prototype methods, Array.isArray. Array literals
    // proto-link to this Array.prototype (interpreter.arrayProto looks it up here).
    const array_fn = try Object.createNative(arena, .array_ctor, "Array");
    const array_methods = [_][]const u8{ "push", "pop", "indexOf", "includes", "join", "slice", "forEach", "map" };
    if (array_fn.get("prototype")) |pv| {
        if (pv == .object) {
            pv.object.prototype = object_proto; // §23.1.3 Array.prototype inherits %Object.prototype%
            for (array_methods) |m| try defineMethod(arena, pv.object, m, .array_method, m);
        }
    }
    try defineMethod(arena, array_fn, "isArray", .array_method, "isArray");
    try env.declare("Array", .{ .object = array_fn }, true, true);
}
