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
    function_ctor, // Function(...) — minimal (the `.prototype` carrier for call/apply/bind)
    // §20.1.2 Object static reflection
    object_define_property, // Object.defineProperty
    object_define_properties, // Object.defineProperties
    object_get_own_property_descriptor, // Object.getOwnPropertyDescriptor
    object_get_own_property_names, // Object.getOwnPropertyNames
    // §20.1.3 Object.prototype reflection
    object_has_own_property, // Object.prototype.hasOwnProperty
    object_property_is_enumerable, // Object.prototype.propertyIsEnumerable
    object_is_prototype_of, // Object.prototype.isPrototypeOf
    // §20.2.3 Function.prototype methods (Cycle 2)
    function_method, // Function.prototype.<native_name> (call/apply/bind)
    function_proto_noop, // %Function.prototype% itself — a callable that returns undefined (§20.2.3)
    // §21.3 Math — `native_name` is the method (`pow`/`floor`/…). The Math namespace object holds these.
    math_method, // Math.<native_name>
};

/// §10.4.1 A Bound Function Exotic Object's internal slots: the wrapped target, the bound `this`, and
/// the prepended bound arguments. When called, the target runs with `this` = [[BoundThis]] and args =
/// [[BoundArguments]] ++ callArgs; when constructed (`new`), [[BoundThis]] is ignored and the target is
/// the [[Construct]] callee. Present iff the object is a bound function (`Object.bound != null`).
pub const BoundData = struct {
    target: *Object,
    bound_this: Value,
    bound_args: []const Value,
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
    /// §15.7: a class constructor's instance PrivateName elements (fields/methods/accessors), added
    /// to each `new` instance's private slot (the brand) before the field initializers / body run.
    /// Empty for ordinary functions and non-constructor methods. (Static private members are
    /// installed directly on the constructor object at class-definition time, not here.)
    private_elements: []const PrivateElement = &.{},
    /// §15.7: a class constructor (explicit or default) is flagged so a plain `C()` call (without
    /// `new`) throws a TypeError per §15.7.14 ([[Call]] of a class constructor is not allowed).
    is_class_ctor: bool = false,
    /// §15.7: a private METHOD `#m(){}` (vs a private field holding a function). A private method slot
    /// is read-only — `this.#m = …` is a TypeError (a brand on the instance, not a mutable field).
    is_private_method: bool = false,
    /// §9.2.5 / §15.7.14 [[HomeObject]]: for a class/object method the object the method is defined
    /// on — its `.prototype` (instance method) or the constructor (static method). `super.x` inside
    /// the method resolves against `home_object.[[Prototype]]`. Null for ordinary functions/arrows.
    home_object: ?*Object = null,
    /// §15.7.14: a derived class constructor (one whose class has an `extends` heritage). `super(...)`
    /// is only legal here; `super_ctor` is the superclass constructor object to invoke. Default
    /// derived constructor (no explicit `constructor`) forwards its args to `super(...)`.
    is_derived_ctor: bool = false,
    super_ctor: ?*Object = null,
};

/// §15.7.14 one resolved instance FieldDefinition: the property key (computed keys are evaluated at
/// class-definition time and stored here as a string) and the optional `= expr` initializer
/// (evaluated per instance in the class's defining scope).
pub const FieldInit = struct {
    key: []const u8,
    init: ?*const ast.Node,
};

/// §15.7 one instance PrivateName element to install on each `new` instance (adding its brand).
///   • `.field` — a private field `#x = init` / `#x` (per-instance value via `init`, run with
///     `this` = the instance, like an ordinary instance field).
///   • `.method` — a private method `#m(){}`: the SHARED method object (`func`), copied into each
///     instance's private slot as a data value (so `this.#m` reads the same function on every
///     instance, matching the spec's per-instance brand of a shared method).
///   • `.get`/`.set` — a private accessor `get/set #x(){}`: the shared getter/setter objects merged
///     into one accessor descriptor in the instance's private slot.
pub const PrivateElement = struct {
    key: []const u8, // the `#name` (the `#` is part of the key)
    kind: enum { field, method, get, set },
    init: ?*const ast.Node = null, // field initializer
    func: ?*Object = null, // method body / getter / setter (shared, [[HomeObject]] set)
};

/// A property's value half (§6.1.7.1): a data value, or an §10.2 getter/setter accessor pair. The
/// hot data-property read switches on this single tag (see `get`/`getProp`); attributes live beside
/// it in `PropertyValue` and are NOT branched on for plain reads.
pub const Payload = union(enum) {
    data: Value,
    accessor: struct { get: ?*Object = null, set: ?*Object = null }, // §10.2 getter/setter functions
};

/// A complete own property (§6.1.7.1 Property Attributes): the value/accessor payload plus the three
/// attribute flags. `writable` is meaningful only for a data payload (accessor descriptors have no
/// [[Writable]]). Ordinary creation (assignment / object-literal / class field / array element)
/// defaults all three to true; `Object.defineProperty` of a NEW property defaults omitted attrs to
/// false. The map stores this by value; the hot path reads `.payload` (a single switch) and ignores
/// the bools for plain reads.
pub const PropertyValue = struct {
    payload: Payload,
    writable: bool = true,
    enumerable: bool = true,
    configurable: bool = true,

    /// A plain data property with all attributes true — the ordinary-creation default.
    pub fn dataDefault(value: Value) PropertyValue {
        return .{ .payload = .{ .data = value } };
    }
};

/// §6.2.6 a Property Descriptor as supplied to [[DefineOwnProperty]] — each field is present-or-absent.
/// A present `value`/`writable` marks a data descriptor; a present `get`/`set` an accessor descriptor.
pub const Descriptor = struct {
    value: ?Value = null,
    has_value: bool = false,
    get: ??*Object = null, // outer null = absent; inner null = `get: undefined`
    set: ??*Object = null,
    writable: ?bool = null,
    enumerable: ?bool = null,
    configurable: ?bool = null,

    pub fn isAccessor(self: Descriptor) bool {
        return self.get != null or self.set != null;
    }
    pub fn isData(self: Descriptor) bool {
        return self.has_value or self.writable != null;
    }
};

pub const Object = struct {
    arena: std.mem.Allocator,
    properties: std.StringHashMapUnmanaged(PropertyValue),
    prototype: ?*Object,
    kind: Kind = .ordinary,
    call: ?FunctionData = null, // present iff kind == .function (and native == .none)
    native: NativeId = .none,
    native_name: []const u8 = "",
    /// §10.4.1 set iff this is a Bound Function Exotic Object (made by `Function.prototype.bind`).
    /// `kind` stays `.function` so `typeof` / callability checks pass; [[Call]]/[[Construct]] detect
    /// this slot and forward to `target` with the bound `this`/args prepended.
    bound: ?BoundData = null,
    elements: std.ArrayListUnmanaged(Value) = .empty, // backing store iff kind == .array
    /// §15.7 PrivateName slots — a per-object map keyed by the `#name` (the `#` is part of the key,
    /// so private names never collide with string-keyed properties). Distinct from `properties` so a
    /// PrivateName is NEVER reachable via `[[Get]]`/`[[Set]]`/`in`/enumeration (privacy by storage).
    /// Lazily populated (only objects with private members ever allocate it) so the ordinary property
    /// path pays nothing. A private method/accessor stores a function descriptor here; a field stores
    /// data. Accessing a private name on an object missing the brand is a runtime TypeError (caller).
    private_fields: std.StringHashMapUnmanaged(PropertyValue) = .{},

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

    /// §10.4.1.3 BoundFunctionCreate — a Bound Function Exotic Object wrapping `target` with a fixed
    /// `this` and prepended args. `kind = .function` (so it is callable / `typeof "function"`), but it
    /// carries no `call`/`native`; [[Call]]/[[Construct]] detect `.bound` and forward to the target.
    /// The caller proto-links it to %Function.prototype%.
    pub fn createBound(arena: std.mem.Allocator, prototype: ?*Object, data: BoundData) std.mem.Allocator.Error!*Object {
        const obj = try create(arena, prototype);
        obj.kind = .function;
        obj.bound = data;
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
            if (o.properties.get(key)) |pv| switch (pv.payload) {
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

    /// §10.1.9 OrdinarySet / the ordinary-creation define — set the own data property `key`. A NEW
    /// property is created with all attributes true (§6.1.7.1 ordinary creation); an EXISTING data
    /// property keeps its attributes (only `value` changes); an existing accessor is replaced by a
    /// fresh all-true data property (the simple definition path — callers route accessor writes
    /// through `getProp`/the setter, so reaching here means a plain data write).
    pub fn set(self: *Object, key: []const u8, value: Value) std.mem.Allocator.Error!void {
        if (self.properties.getPtr(key)) |pv| switch (pv.payload) {
            .data => {
                pv.payload = .{ .data = value };
                return;
            },
            .accessor => {}, // fall through: replace with an all-true data property
        };
        try self.properties.put(self.arena, key, PropertyValue.dataDefault(value));
    }

    /// Create/replace an own data property with explicit attributes (§6.1.7.1) — used by built-in
    /// installation (non-enumerable methods) and array-element bookkeeping.
    pub fn defineData(self: *Object, key: []const u8, value: Value, writable: bool, enumerable: bool, configurable: bool) std.mem.Allocator.Error!void {
        try self.properties.put(self.arena, key, .{
            .payload = .{ .data = value },
            .writable = writable,
            .enumerable = enumerable,
            .configurable = configurable,
        });
    }

    /// §13.2.5.6 PropertyDefinitionEvaluation for an accessor — merge `get`/`set` into the own
    /// property `key`, preserving the other half if it was already defined this literal. Object-literal
    /// accessors are enumerable + configurable (and have no [[Writable]]).
    pub fn defineAccessor(self: *Object, key: []const u8, getter: ?*Object, setter: ?*Object) std.mem.Allocator.Error!void {
        var acc: struct { get: ?*Object = null, set: ?*Object = null } = .{};
        if (self.properties.get(key)) |existing| switch (existing.payload) {
            .accessor => |a| acc = .{ .get = a.get, .set = a.set },
            .data => {},
        };
        if (getter) |g| acc.get = g;
        if (setter) |s| acc.set = s;
        try self.properties.put(self.arena, key, .{
            .payload = .{ .accessor = .{ .get = acc.get, .set = acc.set } },
            .enumerable = true,
            .configurable = true,
        });
    }

    /// True iff own property `key` exists and is enumerable (§6.1.7.1 [[Enumerable]]). Used by for-in,
    /// object spread, and `Object.keys`-style enumeration. Array indices / String chars are enumerable
    /// (handled by callers); `length` is not stored here so it is correctly absent.
    pub fn isEnumerable(self: *Object, key: []const u8) bool {
        return if (self.properties.get(key)) |pv| pv.enumerable else false;
    }

    /// §10.1.6 [[DefineOwnProperty]] — apply a §6.2.6 Descriptor to own property `key`. A NEW property
    /// fills omitted attributes from `false` defaults (per §10.1.6.3 step 4.a.i); an EXISTING property
    /// keeps unstated fields. Returns false (the caller throws a TypeError) on an incompatible
    /// redefinition of a non-configurable property (basic guard — the full §10.1.6.3 invariant matrix
    /// is M-subset-deferred). Data↔accessor and value/flag changes are allowed when configurable.
    pub fn defineProperty(self: *Object, key: []const u8, d: Descriptor) std.mem.Allocator.Error!bool {
        const existing = self.properties.getPtr(key);
        if (existing) |cur| {
            // §10.1.6.3 step 2–4: a non-configurable current property restricts the redefinition.
            if (!cur.configurable) {
                if (d.configurable orelse false) return false; // can't make it configurable
                if (d.enumerable) |e| if (e != cur.enumerable) return false;
                const cur_is_accessor = cur.payload == .accessor;
                if (d.isAccessor() and !cur_is_accessor) return false;
                if (d.isData() and cur_is_accessor) return false;
                if (!cur_is_accessor and !cur.writable) {
                    if (d.writable orelse false) return false; // can't make it writable
                    if (d.has_value) {
                        // a non-writable, non-configurable data prop: only an identical value is allowed
                        if (!sameValueLoose(cur.payload.data, d.value.?)) return false;
                    }
                }
            }
        }
        // Build the resulting property: start from the existing attrs (or false defaults for a new one).
        var writable = if (existing) |c| c.writable else false;
        var enumerable = if (existing) |c| c.enumerable else false;
        var configurable = if (existing) |c| c.configurable else false;
        if (d.enumerable) |e| enumerable = e;
        if (d.configurable) |c| configurable = c;
        var payload: Payload = if (existing) |c| c.payload else .{ .data = .undefined };
        if (d.isAccessor()) {
            var g: ?*Object = null;
            var s: ?*Object = null;
            if (payload == .accessor) {
                g = payload.accessor.get;
                s = payload.accessor.set;
            }
            if (d.get) |gv| g = gv;
            if (d.set) |sv| s = sv;
            payload = .{ .accessor = .{ .get = g, .set = s } };
        } else {
            // a data descriptor (or attributes-only on an existing data prop)
            if (d.writable) |w| writable = w;
            if (d.has_value) {
                payload = .{ .data = d.value.? };
            } else if (payload == .accessor) {
                payload = .{ .data = .undefined }; // accessor→data with no value: value defaults undefined
            }
        }
        try self.properties.put(self.arena, key, .{
            .payload = payload,
            .writable = writable,
            .enumerable = enumerable,
            .configurable = configurable,
        });
        return true;
    }

    // ── §15.7 PrivateName slots (Cycle 4) ──────────────────────────────────────
    // Private members live ONLY on the object that has the brand (never the prototype chain): a
    // PrivateName is added per-instance at construction. So lookups are own-slot only (no chain walk).

    /// True iff `self` carries the PrivateName `key` (the `#name`, `#` included) — the brand check.
    pub fn hasPrivate(self: *Object, key: []const u8) bool {
        return self.private_fields.contains(key);
    }

    /// The stored descriptor for PrivateName `key` (own slot only), or null if the brand is absent.
    pub fn getPrivate(self: *Object, key: []const u8) ?PropertyValue {
        return self.private_fields.get(key);
    }

    /// Install/replace the data slot for PrivateName `key`. Used for private fields (per-instance)
    /// and private methods (the shared method object, copied into each instance's slot).
    pub fn setPrivate(self: *Object, key: []const u8, value: Value) std.mem.Allocator.Error!void {
        try self.private_fields.put(self.arena, key, PropertyValue.dataDefault(value));
    }

    /// Install a private descriptor verbatim (data or accessor) — for private accessors `get/set #x`.
    pub fn definePrivate(self: *Object, key: []const u8, pv: PropertyValue) std.mem.Allocator.Error!void {
        try self.private_fields.put(self.arena, key, pv);
    }

    /// Merge a private `get`/`set` accessor half into the private slot `key` (mirrors `defineAccessor`
    /// for the private map): a matching get+set pair becomes one accessor descriptor.
    pub fn definePrivateAccessor(self: *Object, key: []const u8, getter: ?*Object, setter: ?*Object) std.mem.Allocator.Error!void {
        var acc: struct { get: ?*Object = null, set: ?*Object = null } = .{};
        if (self.private_fields.get(key)) |existing| switch (existing.payload) {
            .accessor => |a| acc = .{ .get = a.get, .set = a.set },
            .data => {},
        };
        if (getter) |g| acc.get = g;
        if (setter) |s| acc.set = s;
        try self.private_fields.put(self.arena, key, .{ .payload = .{ .accessor = .{ .get = acc.get, .set = acc.set } } });
    }
};

/// A loose value equality for the non-configurable redefinition guard (§10.1.6.3): primitives compare
/// by value, objects by identity. This is simpler than §7.2.11 SameValue (NaN/±0 corner cases) but
/// sufficient for the basic "redefine a frozen prop to its current value is allowed" check.
fn sameValueLoose(a: Value, b: Value) bool {
    return switch (a) {
        .undefined => b == .undefined,
        .null => b == .null,
        .boolean => |x| b == .boolean and b.boolean == x,
        .number => |x| b == .number and (x == b.number or (std.math.isNan(x) and std.math.isNan(b.number))),
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .object => |x| b == .object and b.object == x,
    };
}
