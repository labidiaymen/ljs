//! Ordinary objects (ECMA-262 §10.1) and function objects (§10.2). M1 subset: a property map
//! (name → Value), a `[[Prototype]]` link, ordinary `[[Get]]`/`[[Set]]`, and — for function
//! objects — an AST closure (`FunctionData`) invoked by the interpreter's `[[Call]]`. Property
//! descriptors, accessors, and array/error kinds arrive later. Allocated in the realm arena.
const std = @import("std");
const ast = @import("ast.zig");
const Value = @import("value.zig").Value;
const Environment = @import("environment.zig").Environment;

pub const Kind = enum { ordinary, function, array };

/// Built-in (Zig-implemented) function identity. Dispatched by the interpreter's callNative;
/// `none` means an ordinary AST-closure function. Avoids an fn-pointer ↔ interpreter import
/// cycle — the behavior lives in the interpreter, keyed by this id (+ `native_name` within a
/// family, e.g. array_method "push").
pub const NativeId = enum {
    none,
    error_ctor, // Error / TypeError / … — `native_name` is the error name
    string_ctor, // String(x)
    object_ctor, // Object()
    object_to_string, // Object.prototype.toString
    array_ctor, // Array(...)
    array_method, // Array.prototype.<native_name> / Array.isArray
    string_method, // String.prototype.<native_name>
};

/// The closure captured by a function object: parameter patterns, body, and defining scope.
/// §15.3 arrows additionally capture the enclosing `this` at creation (lexical `this`) and are
/// flagged so [[Call]] bypasses `this` rebinding and [[Construct]] is rejected.
pub const FunctionData = struct {
    params: []const ast.Param,
    rest: ?*const ast.Pattern = null,
    body: []const ast.Stmt,
    closure: *Environment,
    is_arrow: bool = false,
    captured_this: Value = .undefined, // §15.3: the enclosing `this` (arrows only)
};

pub const Object = struct {
    arena: std.mem.Allocator,
    properties: std.StringHashMapUnmanaged(Value),
    prototype: ?*Object,
    kind: Kind = .ordinary,
    call: ?FunctionData = null, // present iff kind == .function (and native == .none)
    native: NativeId = .none,
    native_name: []const u8 = "",
    elements: std.ArrayListUnmanaged(Value) = .empty, // backing store iff kind == .array

    pub fn create(arena: std.mem.Allocator, prototype: ?*Object) std.mem.Allocator.Error!*Object {
        const obj = try arena.create(Object);
        obj.* = .{ .arena = arena, .properties = .{}, .prototype = prototype };
        return obj;
    }

    pub fn createFunction(arena: std.mem.Allocator, data: FunctionData) std.mem.Allocator.Error!*Object {
        const obj = try create(arena, null);
        obj.kind = .function;
        obj.call = data;
        // §10.2.4: every ordinary function gets a `.prototype` object (used by `new`/`instanceof`).
        // §15.3: arrow functions are not constructors and have no own `.prototype`.
        if (!data.is_arrow) {
            const proto = try create(arena, null);
            try obj.set("prototype", .{ .object = proto });
        }
        return obj;
    }

    /// §23.1 An Array exotic object (backed by `elements`), proto-linked to Array.prototype.
    pub fn createArray(arena: std.mem.Allocator, prototype: ?*Object) std.mem.Allocator.Error!*Object {
        const obj = try create(arena, prototype);
        obj.kind = .array;
        return obj;
    }

    /// A built-in function object (kind=function, dispatched by `native` id).
    pub fn createNative(arena: std.mem.Allocator, id: NativeId, name: []const u8) std.mem.Allocator.Error!*Object {
        const obj = try create(arena, null);
        obj.kind = .function;
        obj.native = id;
        obj.native_name = name;
        const proto = try create(arena, null);
        try obj.set("prototype", .{ .object = proto });
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
