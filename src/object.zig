//! Ordinary objects (ECMA-262 §10.1). M1 subset: a property map (name → Value), a
//! `[[Prototype]]` link, and ordinary `[[Get]]`/`[[Set]]` (prototype walk on get, own-property
//! write on set). Property descriptors (writable/enumerable/configurable), accessors, and
//! function/array/error kinds arrive in later cycles. Allocated in the realm arena.
const std = @import("std");
const Value = @import("value.zig").Value;

pub const Kind = enum { ordinary };

pub const Object = struct {
    arena: std.mem.Allocator,
    properties: std.StringHashMapUnmanaged(Value),
    prototype: ?*Object,
    kind: Kind = .ordinary,

    pub fn create(arena: std.mem.Allocator, prototype: ?*Object) std.mem.Allocator.Error!*Object {
        const obj = try arena.create(Object);
        obj.* = .{ .arena = arena, .properties = .{}, .prototype = prototype };
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
