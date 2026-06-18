//! Ordinary objects (ECMA-262 §10.1) and function objects (§10.2). M1 subset: a property map
//! (name → Value), a `[[Prototype]]` link, ordinary `[[Get]]`/`[[Set]]`, and — for function
//! objects — an AST closure (`FunctionData`) invoked by the interpreter's `[[Call]]`. Property
//! descriptors, accessors, and array/error kinds arrive later. Allocated in the realm arena.
const std = @import("std");
const Value = @import("value.zig").Value;
const Symbol = @import("value.zig").Symbol;

// Runtime type definitions live in runtime_types.zig (split out to keep this file < 1000 lines);
// re-exported here so `@import("object.zig").<Type>` keeps working unchanged.
const rt = @import("runtime_types.zig");
const Environment = @import("environment.zig").Environment;

/// §10.4.4 [[ParameterMap]] backing for a mapped `arguments` object: the live parameter environment
/// plus, per integer index, the parameter name it aliases (`""` = an index that is not mapped).
pub const MappedParams = struct {
    env: *Environment,
    /// `names[i]` = the parameter name aliased by index `i`, or `""` once that index leaves the map
    /// (its property was deleted or redefined non-writable / as an accessor). Mutable for that shedding.
    names: [][]const u8,
};
pub const IterState = rt.IterState;
pub const IterKind = rt.IterKind;
pub const HelperKind = rt.HelperKind;
pub const HelperState = rt.HelperState;
pub const ProxyData = rt.ProxyData;
pub const RegExpData = rt.RegExpData;
pub const CollectionKind = rt.CollectionKind;
pub const CollectionEntry = rt.CollectionEntry;
pub const Collection = rt.Collection;
pub const SymbolProperty = rt.SymbolProperty;
pub const Kind = rt.Kind;
pub const PromiseState = rt.PromiseState;
pub const PromiseReaction = rt.PromiseReaction;
pub const PromiseData = rt.PromiseData;
pub const CombinatorState = rt.CombinatorState;
pub const Job = rt.Job;
pub const GeneratorState = rt.GeneratorState;
pub const ResumeKind = rt.ResumeKind;
pub const TransferKind = rt.TransferKind;
pub const Generator = rt.Generator;
pub const AsyncGeneratorState = rt.AsyncGeneratorState;
pub const AsyncGenRequest = rt.AsyncGenRequest;
pub const AsyncGenerator = rt.AsyncGenerator;
pub const NativeId = rt.NativeId;
pub const BoundData = rt.BoundData;
pub const FunctionData = rt.FunctionData;
pub const FieldInit = rt.FieldInit;
pub const PrivateElement = rt.PrivateElement;
pub const Payload = rt.Payload;
pub const PropertyValue = rt.PropertyValue;
pub const Descriptor = rt.Descriptor;
pub const Object = struct {
    arena: std.mem.Allocator,
    /// §10.1.11.1 OrdinaryOwnPropertyKeys requires own string keys in *insertion order* (integer keys
    /// ascending is handled by the Array exotic's `elements`). An ArrayHashMap preserves insertion
    /// order with the same get/put/iterator API as a StringHashMap; `for-in`/`Object.keys`/spread thus
    /// observe creation order, matching the spec and the many Test262 tests that assert it.
    properties: std.StringArrayHashMapUnmanaged(PropertyValue),
    prototype: ?*Object,
    kind: Kind = .ordinary,
    call: ?FunctionData = null, // present iff kind == .function (and native == .none)
    native: NativeId = .none,
    native_name: []const u8 = "",
    /// §10.4.1 set iff this is a Bound Function Exotic Object (made by `Function.prototype.bind`).
    /// `kind` stays `.function` so `typeof` / callability checks pass; [[Call]]/[[Construct]] detect
    /// this slot and forward to `target` with the bound `this`/args prepended.
    bound: ?BoundData = null,
    /// §10.1 [[Extensible]] — whether new own properties may be added (§20.1.2 preventExtensions /
    /// seal / freeze clear it). Ordinary objects start extensible. The hot `set` data path checks it
    /// only when CREATING a new property (existing-property writes skip the branch), so updates to
    /// already-present data properties pay nothing.
    extensible: bool = true,
    /// §23.1 Array exotic backing store (iff kind == .array). The DENSE prefix: indices
    /// `0 .. elements.items.len` live here. `array_length` is the array's `[[Length]]` and may EXCEED
    /// `elements.items.len` (the suffix `[elements.items.len, array_length)` are holes, except any
    /// present in `sparse`). A far-out index write (`a[1e9]=x`) lands in `sparse` instead of
    /// materializing millions of holes — this keeps `arr.length = HUGE` O(1) and avoids the
    /// conformance-run OOM. Small/contiguous arrays (literals, `push`) stay purely dense.
    elements: std.ArrayListUnmanaged(Value) = .empty,
    /// §23.1 [[Length]] — tracked separately from the dense store so it can exceed it (sparse arrays).
    /// Meaningful iff `kind == .array`. Always `>= elements.items.len`.
    array_length: usize = 0,
    /// §23.1 / §7.3.16 element & `length` writability for an Array exotic. Set by `Object.freeze` on an
    /// array (alongside `extensible=false`): a frozen array's present indices AND `length` become
    /// non-writable, so any element/length write — through `[[Set]]` or a mutating method — is rejected
    /// (TypeError in strict / from a method's Throw=true Set). `seal`/`preventExtensions` clear only
    /// `extensible` (elements stay writable; a NEW index is rejected). Meaningful iff `kind == .array`;
    /// `false` for the common array (the hot index-set path is `extensible and !array_frozen`).
    array_frozen: bool = false,
    /// §23.1 the `length` own data property's [[Writable]] attribute for an Array exotic. Cleared by
    /// `Object.defineProperty(arr, "length", { writable:false })` and by `Object.freeze`. When false a
    /// length change (grow or shrink) through `[[Set]]` is rejected (§10.4.2.4 ArraySetLength step 17).
    /// `true` for the common array. Meaningful iff `kind == .array`.
    array_length_writable: bool = true,
    /// §23.1 sparse overflow: integer index → value for indices beyond the dense prefix that are too
    /// far to materialize densely. Lazily allocated (null until the first far write). `null` for the
    /// common dense array (zero cost).
    sparse: ?*std.AutoHashMapUnmanaged(usize, Value) = null,
    /// §23.1 the set of DENSE-prefix indices that are holes (made by `delete arr[i]` on an index inside
    /// the dense region, or an array-literal elision). A dense slot in this set reads as `undefined` and
    /// is "absent" for [[HasOwnProperty]] / `in` / forEach-family skipping / sort/reduce hole handling.
    /// Lazily allocated (null → no holes in the dense region, the common case → zero cost).
    holes: ?*std.AutoHashMapUnmanaged(usize, void) = null,
    /// §15.7 PrivateName slots — a per-object map keyed by the `#name` (the `#` is part of the key,
    /// so private names never collide with string-keyed properties). Distinct from `properties` so a
    /// PrivateName is NEVER reachable via `[[Get]]`/`[[Set]]`/`in`/enumeration (privacy by storage).
    /// Lazily populated (only objects with private members ever allocate it) so the ordinary property
    /// path pays nothing. A private method/accessor stores a function descriptor here; a field stores
    /// data. Accessing a private name on an object missing the brand is a runtime TypeError (caller).
    private_fields: std.StringHashMapUnmanaged(PropertyValue) = .{},
    /// §6.1.7 Symbol-keyed own properties (e.g. `obj[Symbol.iterator]`). Stored SEPARATELY from the
    /// string-keyed `properties` map so the string get/set hot path never branches on symbols; only a
    /// computed `[expr]` / index whose key evaluates to a Symbol touches this list. Lazily populated
    /// (most objects have none → zero cost). Never enumerated by for-in / Object.keys (correct per spec).
    symbol_props: std.ArrayListUnmanaged(SymbolProperty) = .empty,
    /// §22.1.5/§23.1.5 native Array/String Iterator state — present iff this object is such an iterator
    /// (its `next` native reads/advances it). Null for every ordinary object (zero cost).
    iter: ?IterState = null,
    /// §24.1/§24.2/§24.3/§24.4 keyed-collection backing store — present iff this object is a
    /// Map/Set/WeakMap/WeakSet instance. Null for every other object (zero cost).
    collection: ?*Collection = null,
    /// §27.1.4 Iterator Helper state — present iff this object is a lazy iterator helper (a result of
    /// `map`/`filter`/`take`/`drop`/`flatMap` or `Iterator.from`'s wrapper). Null otherwise (zero cost).
    iter_helper: ?*HelperState = null,
    /// §28.2 Proxy state — present iff this object is a Proxy exotic. Every internal method routes
    /// through its handler trap (or forwards to the target). Null for every other object (zero cost).
    proxy: ?*ProxyData = null,
    /// §28.2.2.1.1 the captured Proxy a `proxy_revoke` native closes over (set ONLY on that revoker
    /// function — never on a real Proxy). Kept separate from `proxy` so the revoker stays an ordinary
    /// callable function and is not mistaken for a Proxy exotic. Null for every other object.
    revoke_target: ?*ProxyData = null,
    /// §22.2 RegExp state — present iff this object is a RegExp instance. Null otherwise (zero cost).
    regexp: ?*RegExpData = null,
    /// §27.5 Generator state — present iff this object is a Generator (made by calling a `function*`).
    /// Holds the suspendable-execution machinery (body thread + ping-pong semaphores). Null for every
    /// other object (zero cost). The %GeneratorPrototype% `next`/`return`/`throw` natives drive it.
    generator: ?*Generator = null,
    /// §27.6 AsyncGenerator state — present iff this object is an async generator (made by calling an
    /// `async function*`). Holds the underlying Generator (thread) + the request queue + state. Null for
    /// every other object (zero cost). The %AsyncGeneratorPrototype% next/return/throw natives drive it.
    async_generator: ?*AsyncGenerator = null,
    /// §27.1.4 AsyncFromSyncIterator state — present iff this object wraps a SYNC iterator for async
    /// consumption (built by GetIterator(obj, async) when `obj` has no `[Symbol.asyncIterator]`). Its
    /// next/return/throw natives promise-wrap + await each sync step. Null for every other object.
    async_from_sync: ?*Object = null,
    /// §27.2.6 Promise state — present iff this object is a Promise (`new Promise`, `Promise.resolve`,
    /// the result of `then`/`catch`/`finally`, or an async function's returned promise). Null for
    /// every other object (zero cost). The %PromisePrototype% / Promise statics + the Job queue read it.
    promise: ?*PromiseData = null,
    /// §27.2.1.3 the promise a `promise_resolve_fn`/`promise_reject_fn` native settles — set on those
    /// function objects only. (For a `promise_finally_thunk` it instead carries the captured constant
    /// via `finally_value`.) Null for every other object.
    promise_slot: ?*Object = null,
    /// §27.2.5.3.1 the captured `onFinally` callback for a `promise_finally_thunk` native (or the
    /// captured constant value to re-yield). Null elsewhere.
    finally_value: ?*Object = null,
    /// §27.2.4.1.2 the shared combinator state a `promise_combinator_element` closure settles into
    /// (its `values`/`remaining`/`capability`). Set on those function objects only; null elsewhere.
    combinator: ?*CombinatorState = null,
    /// §27.2.4.1.2 [[Index]] — which `combinator.values` slot this element closure writes. Meaningful
    /// only when `combinator != null`. The combinator's [[AlreadyCalled]] guard rides on this closure
    /// firing at most once: a second settle of the same input promise is a no-op (`already_called`).
    combinator_index: usize = 0,
    /// §27.2.4.1.2 [[AlreadyCalled]] — a combinator element closure runs at most once (a promise can
    /// settle once, but a malicious thenable could call its callbacks repeatedly). Guards double-count.
    already_called: bool = false,
    /// §27.1.4.4 the captured `done` flag for an `async_from_sync_wrap` continuation closure (it wraps
    /// the awaited value into `{ value, done: afs_done }`). Meaningful only on that native.
    afs_done: bool = false,
    /// §21.1.4.1/§22.1.4.1/§20.3.4.1 [[NumberData]]/[[StringData]]/[[BooleanData]] — the wrapped
    /// primitive of a `new Number(x)` / `new String(x)` / `new Boolean(x)` exotic object. Null for every
    /// ordinary object. `Number.prototype.valueOf` etc. (and thus ToPrimitive's valueOf) read it, so a
    /// wrapper object coerces back to its primitive in operator/coercion contexts.
    primitive: ?Value = null,
    /// §20.5 [[ErrorData]] — set iff this object is an Error instance (one of the Error-family
    /// constructors, or the engine's internal `throwError`). Read ONLY by §20.1.3.6
    /// Object.prototype.toString to yield the `"Error"` builtin tag. Null/false for every other object.
    error_data: bool = false,
    /// §10.4.4 [[ParameterMap]] presence — set iff this object is an `arguments` exotic. The M-subset
    /// arguments object is otherwise ordinary; this flag exists only so §20.1.3.6 Object.prototype.toString
    /// yields the `"Arguments"` builtin tag.
    is_arguments: bool = false,
    /// §10.4.4 [[ParameterMap]] — present for a MAPPED arguments object (a sloppy function with a simple
    /// parameter list). An integer index `i < names.len` with a non-empty `names[i]` aliases the
    /// parameter binding of that name in `env`: reading/writing `arguments[i]` reads/writes the live
    /// parameter (and vice-versa). Null for an unmapped (strict / non-simple-params) arguments object.
    mapped_params: ?MappedParams = null,

    pub fn create(arena: std.mem.Allocator, prototype: ?*Object) std.mem.Allocator.Error!*Object {
        const obj = try arena.create(Object);
        obj.* = .{ .arena = arena, .properties = .{}, .prototype = prototype };
        return obj;
    }

    pub fn createFunction(arena: std.mem.Allocator, data: FunctionData) std.mem.Allocator.Error!*Object {
        const obj = try create(arena, null);
        obj.kind = .function;
        obj.call = data;
        // §10.2.4 MakeConstructor decides who gets a `.prototype`. Only a "constructor" function does:
        //   • a plain FunctionDeclaration/Expression (§15.2) — YES.
        //   • a GeneratorFunction / AsyncGeneratorFunction (§15.5/§15.6) — YES (the *generator* prototype).
        //   • an ArrowFunction (§15.3) — NO (not a constructor).
        //   • an AsyncFunction (§15.8, non-generator) — NO (MakeConstructor is not called).
        //   • a MethodDefinition (§15.4 — plain/async method, getter, setter) — NO (§10.2.5 MakeMethod).
        // So: a generator (sync or async) always gets one; otherwise only a non-arrow, non-async,
        // non-method (i.e. a plain function) does.
        const wants_prototype = data.is_generator or
            (!data.is_arrow and !data.is_async and !data.is_method);
        if (wants_prototype) {
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

    // (No dense gap-fill: a write at exactly the dense end appends densely; ANY gap spills to `sparse`
    // so the intervening slots stay true HOLES — never materialized as `undefined`. This both avoids
    // the OOM on `a[1e9]=x` and keeps hole semantics exact for sort/reduce/forEach/`in`/delete.)

    /// §23.1 the array's [[Length]]. Derived as `max(array_length, dense prefix len)` so that the
    /// MANY call sites that build an array by appending directly to `elements` (literals, push, spread,
    /// slice/map outputs, Array ctor, …) never need to also touch `array_length`: a dense append
    /// implicitly grows the length, while a sparse/length set records a larger `array_length`
    /// explicitly. The invariant `array_length >= elements.items.len` is restored on the next set.
    pub fn arrayLen(self: *const Object) usize {
        return @max(self.array_length, self.elements.items.len);
    }

    /// §23.1 Array index [[Get]]: the dense slot (unless a dense hole), else the sparse map, else
    /// `undefined` (a hole). The hot dense path is a single bounds check + slice index.
    pub fn arrayGet(self: *const Object, i: usize) Value {
        if (i < self.elements.items.len) {
            if (self.holes) |h| if (h.contains(i)) return .undefined;
            return self.elements.items[i];
        }
        if (self.sparse) |s| {
            if (s.get(i)) |v| return v;
        }
        return .undefined;
    }

    /// §23.1 does index `i` hold a value (own property present, not a hole)?
    pub fn arrayHas(self: *const Object, i: usize) bool {
        if (i < self.elements.items.len) {
            if (self.holes) |h| if (h.contains(i)) return false;
            return true;
        }
        if (self.sparse) |s| return s.contains(i);
        return false;
    }

    /// §10.4.2.1 [[Delete]] of an index — leave a true hole. A dense slot is recorded in `holes`; a
    /// sparse slot is removed from the map. (The dense slot's stored value is untouched but masked.)
    pub fn arrayDelete(self: *Object, i: usize) std.mem.Allocator.Error!void {
        if (i < self.elements.items.len) {
            const h = if (self.holes) |h| h else blk: {
                const m = try self.arena.create(std.AutoHashMapUnmanaged(usize, void));
                m.* = .{};
                self.holes = m;
                break :blk m;
            };
            try h.put(self.arena, i, {});
        } else if (self.sparse) |s| {
            _ = s.remove(i);
        }
    }

    /// §23.1 Array index [[Set]] (assigns and bumps [[Length]] like the exotic [[DefineOwnProperty]]).
    /// A write inside or exactly at the end of the dense prefix stays dense (the hot sequential path);
    /// any write that would leave a GAP spills to `sparse`, so the skipped slots remain true holes.
    pub fn arraySet(self: *Object, arena: std.mem.Allocator, i: usize, v: Value) std.mem.Allocator.Error!void {
        if (i < self.elements.items.len) {
            self.elements.items[i] = v;
            if (self.holes) |h| _ = h.remove(i); // writing fills a former hole
            return;
        }
        if (i == self.elements.items.len) {
            // Contiguous append — keep dense. If a sparse tail exists it stays beyond this index.
            try self.elements.append(arena, v);
            // A previously-sparse entry at this exact index (now densified) is superseded; drop it.
            if (self.sparse) |s| _ = s.remove(i);
            // A stale hole record at this index (e.g. left after a delete then a length shrink that
            // didn't reach it) must be cleared — the slot now holds a real value.
            if (self.holes) |h| _ = h.remove(i);
        } else {
            const s = try self.sparseMap(arena);
            try s.put(arena, i, v);
        }
        if (i + 1 > self.array_length) self.array_length = i + 1;
    }

    /// §23.1 set [[Length]] to `n`: shrink → truncate the dense prefix and drop sparse entries `>= n`;
    /// grow → just record the new length (no fill — the suffix is holes).
    pub fn arraySetLen(self: *Object, n: usize) std.mem.Allocator.Error!void {
        if (n < self.elements.items.len) self.elements.shrinkRetainingCapacity(n);
        if (self.holes) |h| { // drop hole records at/after the new length (and any now-truncated slot)
            if (n < self.array_length) {
                var to_remove: std.ArrayListUnmanaged(usize) = .empty;
                defer to_remove.deinit(self.arena);
                var it = h.keyIterator();
                while (it.next()) |k| {
                    if (k.* >= n) try to_remove.append(self.arena, k.*);
                }
                for (to_remove.items) |k| _ = h.remove(k);
            }
        }
        if (self.sparse) |s| {
            if (n < self.array_length) {
                var to_remove: std.ArrayListUnmanaged(usize) = .empty;
                defer to_remove.deinit(self.arena);
                var it = s.iterator();
                while (it.next()) |entry| {
                    if (entry.key_ptr.* >= n) try to_remove.append(self.arena, entry.key_ptr.*);
                }
                for (to_remove.items) |k| _ = s.remove(k);
            }
        }
        self.array_length = n;
    }

    /// §23.1 append a value to the end (dense), keeping [[Length]] in sync. The primitive behind
    /// array-literal construction, `push`, spread collection, etc. (Only valid when there is no sparse
    /// tail beyond the dense prefix, which holds for all append-style construction.)
    pub fn arrayPush(self: *Object, arena: std.mem.Allocator, v: Value) std.mem.Allocator.Error!void {
        // If length already runs past the dense prefix (sparse tail), append at `array_length`.
        if (self.array_length > self.elements.items.len) {
            return self.arraySet(arena, self.array_length, v);
        }
        try self.elements.append(arena, v);
        self.array_length = self.elements.items.len;
    }

    /// §10.4.2.x own integer-index keys in ascending numeric order: the dense prefix `0..dense_len`
    /// then any sparse indices, sorted. Used by reflection (getOwnPropertyNames / for-in / Object.keys).
    /// Caller owns the returned slice (allocated in `arena`).
    pub fn arrayIndices(self: *const Object, arena: std.mem.Allocator) std.mem.Allocator.Error![]usize {
        const dense = self.elements.items.len;
        const sparse_count: usize = if (self.sparse) |s| s.count() else 0;
        var out: std.ArrayListUnmanaged(usize) = .empty;
        try out.ensureTotalCapacity(arena, dense + sparse_count);
        var i: usize = 0;
        while (i < dense) : (i += 1) {
            if (self.holes) |h| if (h.contains(i)) continue; // a dense hole is not an own key
            out.appendAssumeCapacity(i);
        }
        if (self.sparse) |s| {
            const base = out.items.len;
            var it = s.keyIterator();
            while (it.next()) |k| out.appendAssumeCapacity(k.*);
            std.mem.sort(usize, out.items[base..], {}, std.sort.asc(usize));
        }
        return out.items;
    }

    fn sparseMap(self: *Object, arena: std.mem.Allocator) std.mem.Allocator.Error!*std.AutoHashMapUnmanaged(usize, Value) {
        if (self.sparse) |s| return s;
        const s = try arena.create(std.AutoHashMapUnmanaged(usize, Value));
        s.* = .{};
        self.sparse = s;
        return s;
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

    /// §20.2.4.1 the `length` of a built-in function (count of expected args). For a family dispatched
    /// by `native_name` (array/string/math/… methods) the length keys off the spec method name; for a
    /// single-purpose native it is fixed by `id`. Returns null for an unknown/internal native (→ no
    /// `length` property, exactly as before — purely additive, so no test can regress).
    fn nativeLength(id: NativeId, name: []const u8) ?f64 {
        const L = struct {
            fn pick(n: []const u8, comptime pairs: anytype) ?f64 {
                inline for (pairs) |p| if (std.mem.eql(u8, n, p[0])) return p[1];
                return null;
            }
        };
        return switch (id) {
            // ── constructors ──
            .object_ctor, .array_ctor, .string_ctor, .number_ctor, .boolean_ctor, .function_ctor, .bigint_ctor, .promise_ctor, .error_ctor => 1,
            .aggregate_error_ctor => 2,
            .suppressed_error_ctor => 3,
            .symbol_ctor, .map_ctor, .set_ctor, .weakmap_ctor, .weakset_ctor => 0,
            .proxy_ctor => 2, // §28.2.1.1 Proxy ( target, handler )
            .proxy_revocable => 2, // §28.2.2.1 Proxy.revocable ( target, handler )
            .proxy_revoke => 0, // §28.2.2.1.1 the revoke function takes no arguments
            // ── Object statics / prototype (each its own id) ──
            .object_define_property => 3,
            .object_assign, .object_create, .object_define_properties, .object_get_own_property_descriptor, .object_is, .object_set_prototype_of, .object_has_own, .object_group_by => 2,
            .object_entries, .object_values, .object_keys, .object_freeze, .object_from_entries, .object_get_own_property_descriptors, .object_get_own_property_names, .object_get_own_property_symbols, .object_get_prototype_of, .object_is_extensible, .object_is_frozen, .object_is_sealed, .object_prevent_extensions, .object_seal => 1,
            .object_has_own_property, .object_property_is_enumerable, .object_is_prototype_of, .object_proto_setter => 1,
            .object_to_string, .object_value_of, .object_proto_getter => 0,
            // ── eval / globals ──
            .eval_fn => 1,
            .global_fn => L.pick(name, .{ .{ "isNaN", 1 }, .{ "isFinite", 1 }, .{ "parseFloat", 1 }, .{ "parseInt", 2 }, .{ "decodeURI", 1 }, .{ "decodeURIComponent", 1 }, .{ "encodeURI", 1 }, .{ "encodeURIComponent", 1 } }),
            // ── Function.prototype ──
            .function_method => L.pick(name, .{ .{ "apply", 2 }, .{ "bind", 1 }, .{ "call", 1 } }),
            .function_proto_noop => 0,
            // ── Math / Reflect ──
            .math_method => L.pick(name, .{ .{ "atan2", 2 }, .{ "pow", 2 }, .{ "max", 2 }, .{ "min", 2 }, .{ "hypot", 2 }, .{ "imul", 2 } }) orelse 1,
            .reflect_method => L.pick(name, .{ .{ "apply", 3 }, .{ "construct", 2 }, .{ "defineProperty", 3 }, .{ "deleteProperty", 2 }, .{ "get", 2 }, .{ "getOwnPropertyDescriptor", 2 }, .{ "getPrototypeOf", 1 }, .{ "has", 2 }, .{ "isExtensible", 1 }, .{ "ownKeys", 1 }, .{ "preventExtensions", 1 }, .{ "set", 3 }, .{ "setPrototypeOf", 2 } }),
            // ── Number / Boolean / BigInt ──
            .number_static => L.pick(name, .{ .{ "isNaN", 1 }, .{ "isFinite", 1 }, .{ "isInteger", 1 }, .{ "isSafeInteger", 1 }, .{ "parseFloat", 1 }, .{ "parseInt", 2 } }),
            .number_method => L.pick(name, .{ .{ "toExponential", 1 }, .{ "toFixed", 1 }, .{ "toPrecision", 1 }, .{ "toString", 1 }, .{ "toLocaleString", 0 }, .{ "valueOf", 0 } }),
            .boolean_method => 0,
            .bigint_static => 2, // asIntN / asUintN
            .bigint_method => 0, // toString / valueOf / toLocaleString
            // ── Symbol ──
            .symbol_static => 1, // for / keyFor
            .symbol_to_string => L.pick(name, .{.{ "[Symbol.toPrimitive]", 1 }}) orelse 0,
            .symbol_description => 0,
            // ── Promise ──
            .promise_then => 2,
            .promise_catch, .promise_finally, .promise_resolve, .promise_reject, .promise_all, .promise_all_settled, .promise_any, .promise_race => 1,
            // ── iterators / generators ──
            .generator_method, .async_generator_method, .async_from_sync_method => 1, // next/return/throw
            .iterator_next => 0,
            // §27.1.3 Iterator constructor (abstract) — length 0; §27.1.3.1.1 Iterator.from — length 1.
            .iterator_ctor => 0,
            .iterator_from => 1,
            // §27.1.4 %Iterator.prototype% helpers (all share the `.iterator_helper` id, keyed by the
            // spec method name): the lazy + eager helpers each take one argument (length 1); `toArray`
            // takes none (length 0).
            .iterator_helper => L.pick(name, .{.{ "toArray", 0 }}) orelse 1,
            // An Iterator Helper object's own `next`/`return` (§27.1.4.x): `next` takes no argument,
            // `return` takes one (the value forwarded to the underlying iterator's close).
            .iterator_helper_next => L.pick(name, .{.{ "return", 1 }}) orelse 0,
            .array_values, .array_keys, .array_entries, .string_iterator, .generator_iterator, .async_generator_iterator, .species_getter => 0,
            // ── collections ──
            .collection_size, .collection_iterator => 0,
            .map_method => L.pick(name, .{ .{ "get", 1 }, .{ "set", 2 }, .{ "has", 1 }, .{ "delete", 1 }, .{ "clear", 0 }, .{ "forEach", 1 } }),
            .set_method => L.pick(name, .{ .{ "add", 1 }, .{ "has", 1 }, .{ "delete", 1 }, .{ "clear", 0 }, .{ "forEach", 1 }, .{ "union", 1 }, .{ "intersection", 1 }, .{ "difference", 1 }, .{ "symmetricDifference", 1 }, .{ "isSubsetOf", 1 }, .{ "isSupersetOf", 1 }, .{ "isDisjointFrom", 1 } }),
            .weakmap_method => L.pick(name, .{ .{ "get", 1 }, .{ "set", 2 }, .{ "has", 1 }, .{ "delete", 1 } }),
            .weakset_method => L.pick(name, .{ .{ "add", 1 }, .{ "has", 1 }, .{ "delete", 1 } }),
            // ── JSON ──
            .json_parse => 2,
            .json_stringify => 3,
            // ── Array / String (dispatched by method name) ──
            .array_static => L.pick(name, .{ .{ "from", 1 }, .{ "of", 0 }, .{ "fromAsync", 1 } }),
            .array_method => L.pick(name, .{
                .{ "isArray", 1 },  .{ "at", 1 },             .{ "concat", 1 },     .{ "copyWithin", 2 }, .{ "entries", 0 },
                .{ "every", 1 },    .{ "fill", 1 },           .{ "filter", 1 },     .{ "find", 1 },       .{ "findIndex", 1 },
                .{ "findLast", 1 }, .{ "findLastIndex", 1 },  .{ "flat", 0 },       .{ "flatMap", 1 },    .{ "forEach", 1 },
                .{ "includes", 1 }, .{ "indexOf", 1 },        .{ "join", 1 },       .{ "keys", 0 },       .{ "lastIndexOf", 1 },
                .{ "map", 1 },      .{ "pop", 0 },            .{ "push", 1 },       .{ "reduce", 1 },     .{ "reduceRight", 1 },
                .{ "reverse", 0 },  .{ "shift", 0 },          .{ "slice", 2 },      .{ "some", 1 },       .{ "sort", 1 },
                .{ "splice", 2 },   .{ "toLocaleString", 0 }, .{ "toReversed", 0 }, .{ "toSorted", 1 },   .{ "toSpliced", 2 },
                .{ "toString", 0 }, .{ "unshift", 1 },        .{ "values", 0 },     .{ "with", 2 },
            }),
            .string_static => L.pick(name, .{ .{ "fromCharCode", 1 }, .{ "fromCodePoint", 1 }, .{ "raw", 1 } }),
            .string_method => L.pick(name, .{
                .{ "at", 1 },          .{ "charAt", 1 },            .{ "charCodeAt", 1 },        .{ "codePointAt", 1 },  .{ "concat", 1 },
                .{ "endsWith", 1 },    .{ "includes", 1 },          .{ "indexOf", 1 },           .{ "lastIndexOf", 1 },  .{ "localeCompare", 1 },
                .{ "match", 1 },       .{ "matchAll", 1 },          .{ "normalize", 0 },         .{ "padEnd", 1 },       .{ "padStart", 1 },
                .{ "repeat", 1 },      .{ "replace", 2 },           .{ "replaceAll", 2 },        .{ "search", 1 },       .{ "slice", 2 },
                .{ "split", 2 },       .{ "startsWith", 1 },        .{ "substr", 2 },            .{ "substring", 2 },    .{ "toLowerCase", 0 },
                .{ "toUpperCase", 0 }, .{ "toLocaleLowerCase", 0 }, .{ "toLocaleUpperCase", 0 }, .{ "trim", 0 },         .{ "trimEnd", 0 },
                .{ "trimStart", 0 },   .{ "toString", 0 },          .{ "valueOf", 0 },           .{ "isWellFormed", 0 }, .{ "toWellFormed", 0 },
            }),
            else => null, // internal natives (resolving functions, combinator elements, test hooks)
        };
    }

    /// A built-in function object (kind=function, dispatched by `native` id).
    pub fn createNative(arena: std.mem.Allocator, id: NativeId, name: []const u8) std.mem.Allocator.Error!*Object {
        const obj = try create(arena, null);
        obj.kind = .function;
        obj.native = id;
        obj.native_name = name;
        const proto = try create(arena, null);
        try obj.set("prototype", .{ .object = proto });
        // §20.2.4.1: a built-in function's `length` own property (the count of expected arguments) —
        // non-enumerable, non-writable, configurable. Defined BEFORE `name` so OrdinaryOwnPropertyKeys
        // lists `length` first (matching the spec's property order). `null` ⇒ unknown native ⇒ omit it
        // (no regression — the property was simply absent before). `defineMethod` may pass a more
        // specific `native_name` (e.g. "map:keys") so the per-name lookup keys off the spec method name.
        if (nativeLength(id, name)) |len| try obj.defineData("length", .{ .number = len }, false, false, true);
        // §20.2.4.2: a built-in function's `name` own property (non-enumerable, non-writable,
        // configurable). For a method installed via `defineMethod` this is overwritten with the
        // property key; for a constructor / standalone native this name (the passed identifier) is
        // already the spec name.
        try obj.defineData("name", .{ .string = name }, false, false, true);
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
    ///
    /// Enforcement (§10.1.9.2 OrdinarySetWithOwnDescriptor): an existing non-writable data property is
    /// not overwritten, and a new property is not added to a non-extensible object — both silent
    /// no-ops in the M-subset (strict-mode TypeError is deferred; `Object.isFrozen`/`isSealed` still
    /// report correctly). The hot path (writing an existing writable data prop) takes the single
    /// `writable` branch and skips the `[[Extensible]]` check entirely.
    pub fn set(self: *Object, key: []const u8, value: Value) std.mem.Allocator.Error!void {
        if (self.properties.getPtr(key)) |pv| switch (pv.payload) {
            .data => {
                if (!pv.writable) return; // §10.1.9.2: a non-writable data property rejects the write
                pv.payload = .{ .data = value };
                return;
            },
            .accessor => {}, // fall through: replace with an all-true data property
        } else if (!self.extensible) return; // §10.1.5/§10.1.9: no new props on a non-extensible object
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

    // ── §6.1.7 Symbol-keyed own properties ──────────────────────────────────────
    // A separate own-property store keyed by Symbol identity (pointer). Walks the prototype chain like
    // the string-keyed ops; never enumerated. Linear scan (few symbol keys per object).

    /// §10.1.8 [[Get]] for a Symbol key — own symbol property, else walk the prototype chain. Returns
    /// the full descriptor + holder so the interpreter can invoke an accessor with the receiver.
    pub fn getSymbolProp(self: *Object, key: *Symbol) ?Located {
        var obj: ?*Object = self;
        while (obj) |o| {
            for (o.symbol_props.items) |*sp| {
                if (sp.key == key) return .{ .pv = sp.pv, .holder = o };
            }
            obj = o.prototype;
        }
        return null;
    }

    /// §10.1.9 [[Set]]/define for a Symbol key — overwrite an existing own symbol data property
    /// (honoring [[Writable]]) or append a new all-true data property. Accessor handling for symbol
    /// keys is via the located descriptor (interpreter), mirroring the string path.
    pub fn setSymbol(self: *Object, key: *Symbol, value: Value) std.mem.Allocator.Error!void {
        for (self.symbol_props.items) |*sp| {
            if (sp.key == key) {
                switch (sp.pv.payload) {
                    .data => {
                        if (!sp.pv.writable) return; // §10.1.9.2: non-writable data rejects the write
                        sp.pv.payload = .{ .data = value };
                        return;
                    },
                    .accessor => {}, // replaced by an all-true data property below
                }
                sp.pv = PropertyValue.dataDefault(value);
                return;
            }
        }
        if (!self.extensible) return; // §10.1.9: no new props on a non-extensible object
        try self.symbol_props.append(self.arena, .{ .key = key, .pv = PropertyValue.dataDefault(value) });
    }

    /// Create/replace a symbol-keyed own property with explicit attributes — used to install
    /// well-known-symbol methods (e.g. `Array.prototype[Symbol.iterator]`, non-enumerable).
    pub fn defineSymbolData(self: *Object, key: *Symbol, value: Value, writable: bool, enumerable: bool, configurable: bool) std.mem.Allocator.Error!void {
        const pv: PropertyValue = .{ .payload = .{ .data = value }, .writable = writable, .enumerable = enumerable, .configurable = configurable };
        for (self.symbol_props.items) |*sp| {
            if (sp.key == key) {
                sp.pv = pv;
                return;
            }
        }
        try self.symbol_props.append(self.arena, .{ .key = key, .pv = pv });
    }

    /// §13.2.5.6 a symbol-keyed accessor (`{ get [sym](){} }`) — merge `get`/`set` into the symbol slot
    /// (mirrors `defineAccessor` for the string map). Object-literal: enumerable + configurable.
    pub fn defineSymbolAccessor(self: *Object, key: *Symbol, getter: ?*Object, setter: ?*Object) std.mem.Allocator.Error!void {
        return self.defineSymbolAccessorEx(key, getter, setter, true);
    }

    /// §13.2.5.6 / §15.7.x a symbol-keyed accessor with explicit [[Enumerable]] — object-literal
    /// accessors are enumerable; class accessors are non-enumerable. Always configurable, no
    /// [[Writable]] (accessor descriptor). Merges with an existing get/set half on the same key.
    pub fn defineSymbolAccessorEx(self: *Object, key: *Symbol, getter: ?*Object, setter: ?*Object, enumerable: bool) std.mem.Allocator.Error!void {
        var acc: struct { get: ?*Object = null, set: ?*Object = null } = .{};
        for (self.symbol_props.items) |*sp| {
            if (sp.key == key) {
                if (sp.pv.payload == .accessor) acc = .{ .get = sp.pv.payload.accessor.get, .set = sp.pv.payload.accessor.set };
                break;
            }
        }
        if (getter) |g| acc.get = g;
        if (setter) |s| acc.set = s;
        const pv: PropertyValue = .{ .payload = .{ .accessor = .{ .get = acc.get, .set = acc.set } }, .enumerable = enumerable, .configurable = true };
        for (self.symbol_props.items) |*sp| {
            if (sp.key == key) {
                sp.pv = pv;
                return;
            }
        }
        try self.symbol_props.append(self.arena, .{ .key = key, .pv = pv });
    }

    /// §10.1.6 [[DefineOwnProperty]] for a SYMBOL key — applies a §6.2.6 Descriptor to the own
    /// symbol-keyed property `key`, mirroring the string-keyed `defineProperty` (same false-default fill
    /// for a new property, same non-configurable redefinition guards). Returns false (the caller — e.g.
    /// `Reflect.defineProperty` — reports it) on an incompatible redefinition / a new prop on a
    /// non-extensible object.
    pub fn defineSymbol(self: *Object, key: *Symbol, d: Descriptor) std.mem.Allocator.Error!bool {
        var existing: ?*PropertyValue = null;
        for (self.symbol_props.items) |*sp| {
            if (sp.key == key) {
                existing = &sp.pv;
                break;
            }
        }
        if (existing == null and !self.extensible) return false; // §10.1.6.3 step 2.a
        if (existing) |cur| {
            if (!cur.configurable) {
                if (d.configurable orelse false) return false;
                if (d.enumerable) |e| if (e != cur.enumerable) return false;
                const cur_is_accessor = cur.payload == .accessor;
                if (d.isAccessor() and !cur_is_accessor) return false;
                if (d.isData() and cur_is_accessor) return false;
                if (!cur_is_accessor and !cur.writable) {
                    if (d.writable orelse false) return false;
                    if (d.has_value) {
                        if (!sameValueLoose(cur.payload.data, d.value.?)) return false;
                    }
                }
            }
        }
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
            if (d.writable) |w| writable = w;
            if (d.has_value) {
                payload = .{ .data = d.value.? };
            } else if (payload == .accessor) {
                payload = .{ .data = .undefined };
            }
        }
        const pv: PropertyValue = .{ .payload = payload, .writable = writable, .enumerable = enumerable, .configurable = configurable };
        if (existing) |cur| {
            cur.* = pv;
        } else {
            try self.symbol_props.append(self.arena, .{ .key = key, .pv = pv });
        }
        return true;
    }

    /// §10.1.10 [[Delete]] for a SYMBOL key → true if the property was absent or successfully removed;
    /// false if it exists but is non-configurable (§10.1.10.1 step 4).
    pub fn deleteSymbol(self: *Object, key: *Symbol) bool {
        for (self.symbol_props.items, 0..) |*sp, i| {
            if (sp.key == key) {
                if (!sp.pv.configurable) return false;
                _ = self.symbol_props.orderedRemove(i);
                return true;
            }
        }
        return true;
    }

    /// §13.2.5.6 PropertyDefinitionEvaluation for an accessor — merge `get`/`set` into the own
    /// property `key`, preserving the other half if it was already defined this literal. Object-literal
    /// accessors are enumerable + configurable (and have no [[Writable]]).
    pub fn defineAccessor(self: *Object, key: []const u8, getter: ?*Object, setter: ?*Object) std.mem.Allocator.Error!void {
        return self.defineAccessorEx(key, getter, setter, true);
    }

    /// §13.2.5.6 / §15.7.x an accessor with explicit [[Enumerable]] — object-literal accessors are
    /// enumerable; class accessors are non-enumerable. Always configurable, no [[Writable]]. Merges
    /// with an existing get/set half already defined for the same key.
    pub fn defineAccessorEx(self: *Object, key: []const u8, getter: ?*Object, setter: ?*Object, enumerable: bool) std.mem.Allocator.Error!void {
        var acc: struct { get: ?*Object = null, set: ?*Object = null } = .{};
        if (self.properties.get(key)) |existing| switch (existing.payload) {
            .accessor => |a| acc = .{ .get = a.get, .set = a.set },
            .data => {},
        };
        if (getter) |g| acc.get = g;
        if (setter) |s| acc.set = s;
        try self.properties.put(self.arena, key, .{
            .payload = .{ .accessor = .{ .get = acc.get, .set = acc.set } },
            .enumerable = enumerable,
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
    /// §10.1.6.3 ValidateAndApplyPropertyDescriptor — merge `d` onto `existing` (null = a new property),
    /// returning the resulting PropertyValue, or null if the (re)definition must be REJECTED. Shared by
    /// the string-keyed (`defineProperty`) and Symbol-keyed (`defineSymbolProperty`) paths.
    fn applyDescriptor(existing: ?PropertyValue, d: Descriptor, extensible: bool) ?PropertyValue {
        // §10.1.6.3 step 2.a: a property absent from a non-extensible object cannot be added.
        if (existing == null and !extensible) return null;
        if (existing) |cur| {
            // §10.1.6.3 step 2–4: a non-configurable current property restricts the redefinition.
            if (!cur.configurable) {
                if (d.configurable orelse false) return null; // can't make it configurable
                if (d.enumerable) |e| if (e != cur.enumerable) return null;
                const cur_is_accessor = cur.payload == .accessor;
                if (d.isAccessor() and !cur_is_accessor) return null;
                if (d.isData() and cur_is_accessor) return null;
                if (!cur_is_accessor and !cur.writable) {
                    if (d.writable orelse false) return null; // can't make it writable
                    if (d.has_value) {
                        // a non-writable, non-configurable data prop: only an identical value is allowed
                        if (!sameValueLoose(cur.payload.data, d.value.?)) return null;
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
        return .{ .payload = payload, .writable = writable, .enumerable = enumerable, .configurable = configurable };
    }

    pub fn defineProperty(self: *Object, key: []const u8, d: Descriptor) std.mem.Allocator.Error!bool {
        const existing: ?PropertyValue = if (self.properties.getPtr(key)) |p| p.* else null;
        const merged = applyDescriptor(existing, d, self.extensible) orelse return false;
        try self.properties.put(self.arena, key, merged);
        return true;
    }

    /// §10.1.6 [[DefineOwnProperty]] for a Symbol key — mirrors `defineProperty` over the `symbol_props`
    /// store (keyed by Symbol identity). Used by `Object.defineProperty(o, sym, desc)` / `Reflect`.
    pub fn defineSymbolProperty(self: *Object, key: *Symbol, d: Descriptor) std.mem.Allocator.Error!bool {
        var existing: ?PropertyValue = null;
        var idx: ?usize = null;
        for (self.symbol_props.items, 0..) |*sp, i| {
            if (sp.key == key) {
                existing = sp.pv;
                idx = i;
                break;
            }
        }
        const merged = applyDescriptor(existing, d, self.extensible) orelse return false;
        if (idx) |i| {
            self.symbol_props.items[i].pv = merged;
        } else {
            try self.symbol_props.append(self.arena, .{ .key = key, .pv = merged });
        }
        return true;
    }

    // ── §20.1.2 Integrity levels (preventExtensions / seal / freeze) ────────────

    /// §7.3.16 SetIntegrityLevel("sealed") — clear [[Extensible]] and make every own property
    /// non-configurable. (Array exotic `length`/indices are M-subset: the flag is cleared so new
    /// properties are rejected, but per-index attribute mutation is not separately tracked.)
    pub fn sealObject(self: *Object) void {
        self.extensible = false;
        var it = self.properties.iterator();
        while (it.next()) |entry| entry.value_ptr.configurable = false;
    }

    /// §7.3.16 SetIntegrityLevel("frozen") — clear [[Extensible]], make every own property
    /// non-configurable, and every own DATA property non-writable (accessors keep their get/set). For an
    /// Array exotic, also mark the integer indices + `length` non-writable via `array_frozen` (those
    /// slots are not in `properties`), so a later element/length write is rejected.
    pub fn freezeObject(self: *Object) void {
        self.extensible = false;
        if (self.kind == .array) {
            self.array_frozen = true;
            self.array_length_writable = false;
        }
        var it = self.properties.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.configurable = false;
            if (entry.value_ptr.payload == .data) entry.value_ptr.writable = false;
        }
    }

    /// §7.3.17 TestIntegrityLevel — `frozen`: non-extensible AND every own property non-configurable
    /// AND every data property non-writable. A non-extensible object with no own properties is frozen.
    /// An Array with present elements is frozen only if `array_frozen` (its indices are non-writable);
    /// an empty array (no present indices) is frozen as soon as it is non-extensible.
    pub fn isFrozenObject(self: *Object) bool {
        if (self.extensible) return false;
        if (self.kind == .array and !self.array_frozen and self.arrayLen() > 0) {
            // a present index would be a writable, configurable data property → not frozen
            if (self.elements.items.len > 0) return false;
            if (self.sparse) |s| if (s.count() > 0) return false;
        }
        var it = self.properties.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.configurable) return false;
            if (entry.value_ptr.payload == .data and entry.value_ptr.writable) return false;
        }
        return true;
    }

    /// §7.3.17 TestIntegrityLevel — `sealed`: non-extensible AND every own property non-configurable.
    /// (Array indices are always configurable=false once non-extensible in the M-subset — there is no
    /// separate per-index configurability — so a non-extensible array is sealed.)
    pub fn isSealedObject(self: *Object) bool {
        if (self.extensible) return false;
        var it = self.properties.iterator();
        while (it.next()) |entry| if (entry.value_ptr.configurable) return false;
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
        .bigint => |x| b == .bigint and x.eql(b.bigint.*),
        .symbol => |x| b == .symbol and b.symbol == x,
        .object => |x| b == .object and b.object == x,
    };
}
