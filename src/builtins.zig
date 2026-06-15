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

pub fn setup(arena: std.mem.Allocator, env: *Environment) std.mem.Allocator.Error!void {
    // §20.5 The Error family — each a native constructor; `name` is the error name.
    for (error_names) |name| {
        const ctor = try Object.createNative(arena, .error_ctor, name);
        // instances carry their own `name`; also expose it on the prototype for completeness.
        if (ctor.get("prototype")) |pv| {
            if (pv == .object) try pv.object.set("name", .{ .string = name });
        }
        try env.declare(name, .{ .object = ctor }, true, true);
    }

    // §22.1 String( x ) — ToString.
    try env.declare("String", .{ .object = try Object.createNative(arena, .string_ctor, "String") }, true, true);

    // §20.1 Object — minimal; Object.prototype.toString provided.
    const object_fn = try Object.createNative(arena, .object_ctor, "Object");
    if (object_fn.get("prototype")) |pv| {
        if (pv == .object) {
            try pv.object.set("toString", .{ .object = try Object.createNative(arena, .object_to_string, "toString") });
        }
    }
    try env.declare("Object", .{ .object = object_fn }, true, true);
}
