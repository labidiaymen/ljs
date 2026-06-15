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
    /// §15.7.14: a class constructor carries its instance FieldDefinitions; [[Construct]]
    /// (`evalNew`) runs each initializer on the new instance (with `this` = instance) before the
    /// constructor body. Empty for ordinary functions and for non-constructor class methods.
    fields: []const FieldInit = &.{},
    /// §15.7: a class constructor (explicit or default) is flagged so a plain `C()` call (without
    /// `new`) throws a TypeError per §15.7.14 ([[Call]] of a class constructor is not allowed).
    is_class_ctor: bool = false,
};

/// §15.7.14 one resolved instance FieldDefinition: the property key (computed keys are evaluated at
/// class-definition time and stored here as a string) and the optional `= expr` initializer
/// (evaluated per instance in the class's defining scope).
pub const FieldInit = struct {
    key: []const u8,
    init: ?*const ast.Node,
};

/// A property's stored shape (§6.1.7.1 Property Attributes, M3 subset). Most properties are plain
/// data (`{ value }`); §13.2.5.6 getters/setters are accessor pairs. The map stores this tagged
/// union so the hot data-property path stays a single branch (see `get`/`getAccessor`/`set`).
pub const PropertyValue = union(enum) {
    data: Value,
    accessor: struct { get: ?*Object = null, set: ?*Object = null }, // §10.2 getter/setter functions
};

pub const Object = struct {
    arena: std.mem.Allocator,
    properties: std.StringHashMapUnmanaged(PropertyValue),
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

    /// §10.1.8 OrdinaryGet (data fast path) — own property, else walk the prototype chain.
    /// Returns the value for a *data* property; an accessor yields its current `get`-less form
    /// (`undefined` when there's no getter) so callers that don't invoke accessors stay correct.
    /// Hot path: a direct `value` field read with no accessor branch on the common case.
    /// Callers that must invoke getters use `getProp` (returns the full descriptor + holder).
    pub fn get(self: *Object, key: []const u8) ?Value {
        var obj: ?*Object = self;
        while (obj) |o| {
            if (o.properties.get(key)) |pv| switch (pv) {
                .data => |v| return v,
                .accessor => return .undefined, // an accessor read without a receiver → undefined
            };
            obj = o.prototype;
        }
        return null;
    }

    /// A located property: the stored descriptor plus the object on the prototype chain that owns
    /// it. Returned by `getProp` so the interpreter can invoke a getter/setter with the receiver.
    pub const Located = struct { pv: PropertyValue, holder: *Object };

    /// §10.1.8 [[GetOwnProperty]] walk — find `key` on the chain, returning the raw descriptor
    /// (data or accessor) and its holder. `null` ⇒ absent. The interpreter invokes accessors.
    pub fn getProp(self: *Object, key: []const u8) ?Located {
        var obj: ?*Object = self;
        while (obj) |o| {
            if (o.properties.getPtr(key)) |pv| return .{ .pv = pv.*, .holder = o };
            obj = o.prototype;
        }
        return null;
    }

    /// §10.1.9 OrdinarySet — create/update an own data property (M3: always writable). Replaces
    /// any accessor with a data property (the simple definition path).
    pub fn set(self: *Object, key: []const u8, value: Value) std.mem.Allocator.Error!void {
        try self.properties.put(self.arena, key, .{ .data = value });
    }

    /// §13.2.5.6 PropertyDefinitionEvaluation for an accessor — merge `get`/`set` into the own
    /// property `key`, preserving the other half if it was already defined this literal.
    pub fn defineAccessor(self: *Object, key: []const u8, getter: ?*Object, setter: ?*Object) std.mem.Allocator.Error!void {
        var acc: struct { get: ?*Object = null, set: ?*Object = null } = .{};
        if (self.properties.get(key)) |existing| switch (existing) {
            .accessor => |a| acc = .{ .get = a.get, .set = a.set },
            .data => {},
        };
        if (getter) |g| acc.get = g;
        if (setter) |s| acc.set = s;
        try self.properties.put(self.arena, key, .{ .accessor = .{ .get = acc.get, .set = acc.set } });
    }
};
