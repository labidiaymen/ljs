//! Ordinary objects (ECMA-262 §10.1) and function objects (§10.2). M1 subset: a property map
//! (name → Value), a `[[Prototype]]` link, ordinary `[[Get]]`/`[[Set]]`, and — for function
//! objects — an AST closure (`FunctionData`) invoked by the interpreter's `[[Call]]`. Property
//! descriptors, accessors, and array/error kinds arrive later. Allocated in the realm arena.
const std = @import("std");
const ast = @import("ast.zig");
const Value = @import("value.zig").Value;
const Environment = @import("environment.zig").Environment;

pub const Kind = enum { ordinary, function };

/// The closure captured by a function object: parameter names, body, and defining scope.
pub const FunctionData = struct {
    params: []const []const u8,
    body: []const ast.Stmt,
    closure: *Environment,
};

pub const Object = struct {
    arena: std.mem.Allocator,
    properties: std.StringHashMapUnmanaged(Value),
    prototype: ?*Object,
    kind: Kind = .ordinary,
    call: ?FunctionData = null, // present iff kind == .function

    pub fn create(arena: std.mem.Allocator, prototype: ?*Object) std.mem.Allocator.Error!*Object {
        const obj = try arena.create(Object);
        obj.* = .{ .arena = arena, .properties = .{}, .prototype = prototype };
        return obj;
    }

    pub fn createFunction(arena: std.mem.Allocator, data: FunctionData) std.mem.Allocator.Error!*Object {
        const obj = try create(arena, null);
        obj.kind = .function;
        obj.call = data;
        return obj;
    }

    /// §10.1.8 OrdinaryGet — own property, else walk the prototype chain. `null` ⇒ undefined.
    pub fn get(self: *Object, key: []const u8) ?Value {
        var obj: ?*Object = self;
        while (obj) |o| {
            if (o.properties.get(key)) |v| return v;
            obj = o.prototype;
        }
        return null;
    }

    /// §10.1.9 OrdinarySet — create/update an own data property (M1: always writable).
    pub fn set(self: *Object, key: []const u8, value: Value) std.mem.Allocator.Error!void {
        try self.properties.put(self.arena, key, value);
    }
};
