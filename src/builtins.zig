//! Global built-ins seeded into a realm's global environment (ECMA-262 §19/§20).
//! Built-ins are function objects tagged with a `NativeId`; their behavior lives in the
//! interpreter's callNative. Provides the Error family, `String`, `Object` (+ reflection), `Array`,
//! `Function` (with %Function.prototype% carrying `call`/`apply`/`bind`, §20.2.3), and a minimal
//! `Math` (§21.3). Every function object proto-links to %Function.prototype% so `fn.call`/`.bind`
//! resolve universally (M6 Cycle 2 — the propertyHelper.js unblock).
const std = @import("std");
const Object = @import("object.zig").Object;
const Symbol = @import("value.zig").Symbol;
const Environment = @import("environment.zig").Environment;

/// Process-global Symbol id source — purely for display/debug; Symbol identity is by pointer.
var symbol_id_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);

/// §6.1.5 mint a fresh unique Symbol with an optional description, allocated in the realm arena.
pub fn newSymbol(arena: std.mem.Allocator, description: ?[]const u8) std.mem.Allocator.Error!*Symbol {
    const s = try arena.create(Symbol);
    s.* = .{ .id = symbol_id_counter.fetchAdd(1, .monotonic), .description = description };
    return s;
}

pub const error_names = [_][]const u8{
    "Error",       "TypeError", "RangeError", "ReferenceError",
    "SyntaxError", "EvalError", "URIError",
};

const NativeId = @import("object.zig").NativeId;

/// %Function.prototype% — the [[Prototype]] of every function object (§20.2.3). Captured during
/// `setup` and stamped onto each native function object so `fn.call`/`.apply`/`.bind` resolve.
/// Reassigned at the very top of `setup` (before any `defineMethod` runs) so a fresh realm rebuilds
/// it; the realm-arena-scoped function objects then link to the current realm's prototype.
var function_proto: ?*Object = null;

/// Install a non-enumerable built-in method on `target` (§17 built-in methods are writable +
/// configurable but NON-enumerable — load-bearing so `for (k in {})` / `Object.keys` don't surface
/// prototype methods, the propertyHelper.js unblock). The created function object proto-links to
/// %Function.prototype% so `someBuiltin.call`/`.bind` resolve (§20.2.3).
fn defineMethod(arena: std.mem.Allocator, target: *Object, name: []const u8, id: NativeId, native_name: []const u8) std.mem.Allocator.Error!void {
    const fn_obj = try Object.createNative(arena, id, native_name);
    fn_obj.prototype = function_proto;
    // §20.2.4.2: a built-in method's `name` own property is its property key (non-enumerable,
    // non-writable, configurable). (`length` per-native is deferred — see specs/015 spec.md.)
    try fn_obj.defineData("name", .{ .string = name }, false, false, true);
    try target.defineData(name, .{ .object = fn_obj }, true, false, true);
}

/// §19/§20.x.3 — install the `constructor` back-reference on a constructor's `.prototype`:
/// `<Ctor>.prototype.constructor === <Ctor>`, descriptor `{ writable:true, enumerable:false,
/// configurable:true }`. NON-enumerable is load-bearing (a stray enumerable `constructor` would
/// surface in for-in / Object.keys). A no-op if the constructor has no object `.prototype`.
fn defineConstructorBackref(ctor: *Object) std.mem.Allocator.Error!void {
    const pv = ctor.get("prototype") orelse return;
    if (pv != .object) return;
    try pv.object.defineData("constructor", .{ .object = ctor }, true, false, true);
}

pub fn setup(arena: std.mem.Allocator, env: *Environment) std.mem.Allocator.Error!void {
    // §19.1 Value properties of the global object — `undefined`/`NaN`/`Infinity`. These are
    // non-writable, non-configurable in the spec, so we declare them immutable. Many programs
    // (and the Test262 `assert` harness, e.g. `message === undefined`) depend on these.
    try env.declare("undefined", .undefined, false, true); // §19.1.4
    try env.declare("NaN", .{ .number = std.math.nan(f64) }, false, true); // §19.1.1
    try env.declare("Infinity", .{ .number = std.math.inf(f64) }, false, true); // §19.1.2

    // §20.2 Function — built FIRST so %Function.prototype% exists before any other built-in function
    // object is created: `defineMethod` proto-links every native it makes to %Function.prototype%, and
    // ordinary AST closures / classes / bound functions link to it too (interpreter.functionProto), so
    // `fn.call`/`.apply`/`.bind` resolve on EVERY callable (§20.2.3). %Function.prototype% is itself a
    // callable that returns undefined (§20.2.3); its `.prototype` carrier holds call/apply/bind.
    // (Its own [[Prototype]] is %Object.prototype%, linked below once that exists.)
    const function_fn = try Object.createNative(arena, .function_ctor, "Function");
    function_proto = blk: {
        const pv = function_fn.get("prototype") orelse break :blk null;
        break :blk if (pv == .object) pv.object else null;
    };
    if (function_proto) |fp| {
        fp.native = .function_proto_noop; // §20.2.3: %Function.prototype% is itself callable (→ undefined)
        fp.prototype = function_proto; // self-link placeholder; reset to %Object.prototype% below
        try defineMethod(arena, fp, "call", .function_method, "call");
        try defineMethod(arena, fp, "apply", .function_method, "apply");
        try defineMethod(arena, fp, "bind", .function_method, "bind");
    }
    function_fn.prototype = function_proto;
    try defineConstructorBackref(function_fn); // §20.2.3.2 %Function.prototype%.constructor === Function
    try env.declare("Function", .{ .object = function_fn }, true, true);

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
    object_fn.prototype = function_proto; // §20.2.3 every function object (incl. ctors) → %Function.prototype%
    if (function_proto) |fp| fp.prototype = object_proto; // §20.2.3 %Function.prototype% → %Object.prototype%
    if (object_proto) |op| {
        try defineMethod(arena, op, "toString", .object_to_string, "toString");
        try defineMethod(arena, op, "valueOf", .object_value_of, "valueOf"); // §20.1.3.7
        try defineMethod(arena, op, "hasOwnProperty", .object_has_own_property, "hasOwnProperty");
        try defineMethod(arena, op, "propertyIsEnumerable", .object_property_is_enumerable, "propertyIsEnumerable");
        try defineMethod(arena, op, "isPrototypeOf", .object_is_prototype_of, "isPrototypeOf");
    }
    try defineMethod(arena, object_fn, "defineProperty", .object_define_property, "defineProperty");
    try defineMethod(arena, object_fn, "defineProperties", .object_define_properties, "defineProperties");
    try defineMethod(arena, object_fn, "getOwnPropertyDescriptor", .object_get_own_property_descriptor, "getOwnPropertyDescriptor");
    try defineMethod(arena, object_fn, "getOwnPropertyDescriptors", .object_get_own_property_descriptors, "getOwnPropertyDescriptors");
    try defineMethod(arena, object_fn, "getOwnPropertyNames", .object_get_own_property_names, "getOwnPropertyNames");
    // §20.1.2 enumeration / creation / extensibility statics (M6 Cycle 3).
    try defineMethod(arena, object_fn, "keys", .object_keys, "keys");
    try defineMethod(arena, object_fn, "values", .object_values, "values");
    try defineMethod(arena, object_fn, "entries", .object_entries, "entries");
    try defineMethod(arena, object_fn, "create", .object_create, "create");
    try defineMethod(arena, object_fn, "assign", .object_assign, "assign");
    try defineMethod(arena, object_fn, "getPrototypeOf", .object_get_prototype_of, "getPrototypeOf");
    try defineMethod(arena, object_fn, "setPrototypeOf", .object_set_prototype_of, "setPrototypeOf");
    try defineMethod(arena, object_fn, "is", .object_is, "is");
    try defineMethod(arena, object_fn, "freeze", .object_freeze, "freeze");
    try defineMethod(arena, object_fn, "isFrozen", .object_is_frozen, "isFrozen");
    try defineMethod(arena, object_fn, "seal", .object_seal, "seal");
    try defineMethod(arena, object_fn, "isSealed", .object_is_sealed, "isSealed");
    try defineMethod(arena, object_fn, "preventExtensions", .object_prevent_extensions, "preventExtensions");
    try defineMethod(arena, object_fn, "isExtensible", .object_is_extensible, "isExtensible");
    try defineConstructorBackref(object_fn); // §20.1.2.1 Object.prototype.constructor === Object
    try env.declare("Object", .{ .object = object_fn }, true, true);

    // §20.5 The Error family — each a native constructor; `name` is the error name.
    for (error_names) |name| {
        const ctor = try Object.createNative(arena, .error_ctor, name);
        ctor.prototype = function_proto; // §20.2.3 the constructor function object → %Function.prototype%
        // instances carry their own `name`; also expose it on the prototype for completeness.
        if (ctor.get("prototype")) |pv| {
            if (pv == .object) {
                pv.object.prototype = object_proto; // §20.5.3.1 Error.prototype inherits %Object.prototype%
                try pv.object.set("name", .{ .string = name });
            }
        }
        try defineConstructorBackref(ctor); // §20.5.3.1 / §20.5.6.3.1 <Error>.prototype.constructor === <Error>
        try env.declare(name, .{ .object = ctor }, true, true);
    }

    // §22.1 String( x ) — ToString; String.prototype methods (boxing finds them via getProperty).
    const string_fn = try Object.createNative(arena, .string_ctor, "String");
    string_fn.prototype = function_proto; // §20.2.3 the String constructor → %Function.prototype%
    if (string_fn.get("prototype")) |pv| {
        if (pv == .object) {
            pv.object.prototype = object_proto; // §22.1.3 String.prototype inherits %Object.prototype%
            const string_methods = [_][]const u8{
                "charAt",    "charCodeAt",  "indexOf",     "includes", "slice",
                "substring", "toUpperCase", "toLowerCase", "split",
                // §22.1.3.28/.32: toString/valueOf return the [[StringData]] (so a `new String(x)` wrapper
                // and ToPrimitive recover the string primitive).
                   "toString",
                "valueOf",
            };
            for (string_methods) |m| try defineMethod(arena, pv.object, m, .string_method, m);
        }
    }
    try defineConstructorBackref(string_fn); // §22.1.3.1 String.prototype.constructor === String
    try env.declare("String", .{ .object = string_fn }, true, true);

    // §21.1 Number( x ) — ToNumber (Number() → 0); constants + static predicates.
    const number_fn = try Object.createNative(arena, .number_ctor, "Number");
    number_fn.prototype = function_proto;
    if (number_fn.get("prototype")) |pv| {
        if (pv == .object) {
            pv.object.prototype = object_proto; // §21.1.3 Number.prototype inherits %Object.prototype%
            try defineMethod(arena, pv.object, "toString", .number_method, "toString");
            try defineMethod(arena, pv.object, "valueOf", .number_method, "valueOf");
        }
    }
    // §21.1.2 Number value properties (non-writable / non-enumerable / non-configurable).
    try number_fn.defineData("MAX_SAFE_INTEGER", .{ .number = 9007199254740991 }, false, false, false);
    try number_fn.defineData("MIN_SAFE_INTEGER", .{ .number = -9007199254740991 }, false, false, false);
    try number_fn.defineData("MAX_VALUE", .{ .number = 1.7976931348623157e308 }, false, false, false);
    try number_fn.defineData("MIN_VALUE", .{ .number = 5e-324 }, false, false, false);
    try number_fn.defineData("POSITIVE_INFINITY", .{ .number = std.math.inf(f64) }, false, false, false);
    try number_fn.defineData("NEGATIVE_INFINITY", .{ .number = -std.math.inf(f64) }, false, false, false);
    try number_fn.defineData("NaN", .{ .number = std.math.nan(f64) }, false, false, false);
    try number_fn.defineData("EPSILON", .{ .number = 2.220446049250313e-16 }, false, false, false);
    for ([_][]const u8{ "isNaN", "isFinite", "isInteger", "isSafeInteger" }) |m| {
        try defineMethod(arena, number_fn, m, .number_static, m); // §21.1.2.2–.5 (no coercion)
    }
    try defineConstructorBackref(number_fn); // §21.1.3.1 Number.prototype.constructor === Number
    try env.declare("Number", .{ .object = number_fn }, true, true);

    // §20.3 Boolean( x ) — ToBoolean.
    const boolean_fn = try Object.createNative(arena, .boolean_ctor, "Boolean");
    boolean_fn.prototype = function_proto;
    if (boolean_fn.get("prototype")) |pv| {
        if (pv == .object) {
            pv.object.prototype = object_proto;
            try defineMethod(arena, pv.object, "toString", .boolean_method, "toString");
            try defineMethod(arena, pv.object, "valueOf", .boolean_method, "valueOf");
        }
    }
    try defineConstructorBackref(boolean_fn); // §20.3.3.1 Boolean.prototype.constructor === Boolean
    try env.declare("Boolean", .{ .object = boolean_fn }, true, true);

    // §23.1 Array — constructor, Array.prototype methods, Array.isArray. Array literals
    // proto-link to this Array.prototype (interpreter.arrayProto looks it up here).
    const array_fn = try Object.createNative(arena, .array_ctor, "Array");
    array_fn.prototype = function_proto; // §20.2.3 the Array constructor → %Function.prototype%
    const array_methods = [_][]const u8{ "push", "pop", "indexOf", "includes", "join", "slice", "forEach", "map", "toString" };
    if (array_fn.get("prototype")) |pv| {
        if (pv == .object) {
            pv.object.prototype = object_proto; // §23.1.3 Array.prototype inherits %Object.prototype%
            for (array_methods) |m| try defineMethod(arena, pv.object, m, .array_method, m);
        }
    }
    try defineMethod(arena, array_fn, "isArray", .array_method, "isArray");
    try defineConstructorBackref(array_fn); // §23.1.3.1 Array.prototype.constructor === Array
    try env.declare("Array", .{ .object = array_fn }, true, true);

    // §20.4 Symbol — the constructor (callable, NOT a constructor: `new Symbol` throws, §20.4.1) plus
    // the well-known symbols held as own data properties (`Symbol.iterator`, …, §20.4.2). Each
    // well-known symbol is a fresh unique identity; user code reads `Symbol.iterator` as an ordinary
    // property, and the engine's GetIterator resolves the SAME identity (interpreter.wellKnownIterator).
    const symbol_fn = try Object.createNative(arena, .symbol_ctor, "Symbol");
    symbol_fn.prototype = function_proto; // §20.2.3 the Symbol constructor → %Function.prototype%
    // §20.4.2 well-known symbols — installed non-writable/non-enumerable/non-configurable per spec.
    const well_known = [_][]const u8{ "iterator", "asyncIterator", "toStringTag", "hasInstance", "toPrimitive" };
    for (well_known) |name| {
        const desc = try std.fmt.allocPrint(arena, "Symbol.{s}", .{name});
        const sym = try newSymbol(arena, desc);
        try symbol_fn.defineData(name, .{ .symbol = sym }, false, false, false);
    }
    // §20.4.3 Symbol.prototype — `toString`/`valueOf` (the only Symbol→string conversions allowed).
    if (symbol_fn.get("prototype")) |pv| {
        if (pv == .object) {
            pv.object.prototype = object_proto; // §20.4.3 Symbol.prototype inherits %Object.prototype%
            try defineMethod(arena, pv.object, "toString", .symbol_to_string, "toString");
            try defineMethod(arena, pv.object, "valueOf", .symbol_to_string, "valueOf");
        }
    }
    try defineConstructorBackref(symbol_fn); // §20.4.3.1 Symbol.prototype.constructor === Symbol
    try env.declare("Symbol", .{ .object = symbol_fn }, true, true);

    // §23.1.5.1 / §22.1.5.1 install the iteration protocol on Array.prototype / String.prototype:
    // a `[Symbol.iterator]` method (non-enumerable) returning a native iterator object. Keyed by the
    // SAME `Symbol.iterator` identity created above, so `arr[Symbol.iterator]` and the engine's
    // GetIterator both find it. Array.prototype also exposes `.values` (the same native).
    const iter_pv = symbol_fn.get("iterator") orelse unreachable; // just installed above
    const iter_sym: *Symbol = iter_pv.symbol;
    if (array_fn.get("prototype")) |pv| {
        if (pv == .object) {
            const values_fn = try Object.createNative(arena, .array_values, "[Symbol.iterator]");
            values_fn.prototype = function_proto;
            try pv.object.defineSymbolData(iter_sym, .{ .object = values_fn }, true, false, true);
            try defineMethod(arena, pv.object, "values", .array_values, "values"); // §23.1.3.34
            try defineMethod(arena, pv.object, "keys", .array_keys, "keys"); // §23.1.3.18
            try defineMethod(arena, pv.object, "entries", .array_entries, "entries"); // §23.1.3.7
        }
    }
    if (string_fn.get("prototype")) |pv| {
        if (pv == .object) {
            const siter_fn = try Object.createNative(arena, .string_iterator, "[Symbol.iterator]");
            siter_fn.prototype = function_proto;
            try pv.object.defineSymbolData(iter_sym, .{ .object = siter_fn }, true, false, true);
        }
    }

    // §27.5 %GeneratorPrototype% — the [[Prototype]] of every Generator object (made by calling a
    // `function*`). Carries `next`/`return`/`throw` (§27.5.1.2/.4/.5) and `[Symbol.iterator]()` (which
    // returns `this`, §27.5.1.1) so a generator is iterable through the M8 §7.4 protocol (for-of /
    // spread / destructuring). Stashed under a sentinel global name (not a valid identifier, so user
    // code can't reach or shadow it); `interpreter.generatorProto` resolves it. Its [[Prototype]] is
    // %Object.prototype% (the M-subset elides the intermediate %IteratorPrototype%).
    const gen_proto = try Object.create(arena, object_proto);
    try defineMethod(arena, gen_proto, "next", .generator_method, "next"); // §27.5.1.2
    try defineMethod(arena, gen_proto, "return", .generator_method, "return"); // §27.5.1.4
    try defineMethod(arena, gen_proto, "throw", .generator_method, "throw"); // §27.5.1.5
    {
        // §27.5.1.1 %GeneratorPrototype%[Symbol.iterator]() returns `this` — keyed by the SAME
        // Symbol.iterator identity, so GetIterator(gen) finds it and for-of/spread consume the generator.
        const giter_fn = try Object.createNative(arena, .generator_iterator, "[Symbol.iterator]");
        giter_fn.prototype = function_proto;
        try gen_proto.defineSymbolData(iter_sym, .{ .object = giter_fn }, true, false, true);
    }
    try env.declare("%GeneratorPrototype%", .{ .object = gen_proto }, false, true);

    // §27.6.1 %AsyncGeneratorPrototype% — the [[Prototype]] of every AsyncGenerator object (made by
    // calling an `async function*`). Carries `next`/`return`/`throw` (§27.6.1.2/.3/.4, each returns a
    // PROMISE of {value,done}) and `[Symbol.asyncIterator]()` (returns `this`, §27.6.1.5), so an async
    // generator is consumed through §14.7.5 `for await`. Stashed under a sentinel global name;
    // `interpreter.asyncGeneratorProto` resolves it. [[Prototype]] is %Object.prototype% (the M-subset
    // elides the intermediate %AsyncIteratorPrototype%).
    const async_iter_pv = symbol_fn.get("asyncIterator") orelse unreachable; // installed in well_known above
    const async_iter_sym: *Symbol = async_iter_pv.symbol;
    const agen_proto = try Object.create(arena, object_proto);
    try defineMethod(arena, agen_proto, "next", .async_generator_method, "next"); // §27.6.1.2
    try defineMethod(arena, agen_proto, "return", .async_generator_method, "return"); // §27.6.1.3
    try defineMethod(arena, agen_proto, "throw", .async_generator_method, "throw"); // §27.6.1.4
    {
        // §27.6.1.5 %AsyncGeneratorPrototype%[Symbol.asyncIterator]() returns `this` — keyed by the SAME
        // Symbol.asyncIterator identity, so GetIterator(agen, async) finds it and `for await` consumes it.
        const agiter_fn = try Object.createNative(arena, .async_generator_iterator, "[Symbol.asyncIterator]");
        agiter_fn.prototype = function_proto;
        try agen_proto.defineSymbolData(async_iter_sym, .{ .object = agiter_fn }, true, false, true);
    }
    try env.declare("%AsyncGeneratorPrototype%", .{ .object = agen_proto }, false, true);

    // §27.1.4.2 %AsyncFromSyncIteratorPrototype% — the [[Prototype]] of an AsyncFromSyncIterator (built
    // by GetIterator(obj, async) when `obj` is only SYNC-iterable). Its next/return/throw drive the
    // wrapped sync iterator and promise-wrap + await each `{value,done}` result so a sync iterable is
    // consumed as if async (§14.7.5 `for await` over a sync iterable, e.g. `[Promise.resolve(1), 2]`).
    const afs_proto = try Object.create(arena, object_proto);
    try defineMethod(arena, afs_proto, "next", .async_from_sync_method, "next"); // §27.1.4.2.1
    try defineMethod(arena, afs_proto, "return", .async_from_sync_method, "return"); // §27.1.4.2.2
    try defineMethod(arena, afs_proto, "throw", .async_from_sync_method, "throw"); // §27.1.4.2.3
    {
        const afsiter_fn = try Object.createNative(arena, .async_generator_iterator, "[Symbol.asyncIterator]");
        afsiter_fn.prototype = function_proto;
        try afs_proto.defineSymbolData(async_iter_sym, .{ .object = afsiter_fn }, true, false, true);
    }
    try env.declare("%AsyncFromSyncIteratorPrototype%", .{ .object = afs_proto }, false, true);

    // §27.2 Promise — the constructor + %PromisePrototype% (then/catch/finally) + the statics
    // (resolve/reject). `new Promise(executor)` / `Promise.resolve` / `.then` produce Promise objects
    // (proto = Promise.prototype); the async-function runtime + the microtask Job queue (interpreter)
    // drive settlement. The constructor's `.prototype` IS %PromisePrototype% — also stashed under the
    // sentinel global name so `interpreter.promiseProto` resolves it for engine-created promises.
    const promise_fn = try Object.createNative(arena, .promise_ctor, "Promise");
    promise_fn.prototype = function_proto; // §20.2.3 the Promise constructor → %Function.prototype%
    if (promise_fn.get("prototype")) |pv| {
        if (pv == .object) {
            pv.object.prototype = object_proto; // §27.2.3.2 Promise.prototype inherits %Object.prototype%
            try defineMethod(arena, pv.object, "then", .promise_then, "then"); // §27.2.5.4
            try defineMethod(arena, pv.object, "catch", .promise_catch, "catch"); // §27.2.5.1
            try defineMethod(arena, pv.object, "finally", .promise_finally, "finally"); // §27.2.5.3
            try env.declare("%PromisePrototype%", .{ .object = pv.object }, false, true);
        }
    }
    try defineMethod(arena, promise_fn, "resolve", .promise_resolve, "resolve"); // §27.2.4.5
    try defineMethod(arena, promise_fn, "reject", .promise_reject, "reject"); // §27.2.4.4
    try defineConstructorBackref(promise_fn); // §27.2.5.2 Promise.prototype.constructor === Promise
    try env.declare("Promise", .{ .object = promise_fn }, true, true);

    // §19.2.1 eval — the global `eval` intrinsic (%eval%). A native function object so it is reachable
    // both as the `eval` global binding and (mirrored below) as `globalThis.eval`. Its behavior lives in
    // the interpreter: `callNative(.eval_fn)` is INDIRECT eval (global env, global this); the
    // interpreter's `evalCall` intercepts the DIRECT case (callee is the IdentifierReference `eval`).
    const eval_fn = try Object.createNative(arena, .eval_fn, "eval");
    eval_fn.prototype = function_proto; // §20.2.3 every function object → %Function.prototype%
    try env.declare("eval", .{ .object = eval_fn }, true, true);

    // §21.3 Math — a namespace object (not a constructor): non-enumerable function-valued methods
    // (proto = %Object.prototype%). The minimal subset the harness needs: propertyHelper.js's
    // `Math.pow(2, 32)` (§21.3.2.26); the common companions round out a usable surface for tests.
    const math_obj = try Object.create(arena, object_proto);
    const math_methods = [_][]const u8{ "pow", "floor", "ceil", "abs", "round", "trunc", "sign", "sqrt", "max", "min" };
    for (math_methods) |m| try defineMethod(arena, math_obj, m, .math_method, m);
    try env.declare("Math", .{ .object = math_obj }, true, true);

    // §27.2.4 Promise combinators — installed after the iterator protocol is wired (they consume an
    // iterable via §7.4 GetIterator) and the Promise constructor exists. `Promise.all`/`race`/
    // `allSettled`/`any` are static, non-enumerable methods on the Promise constructor.
    if (env.lookup("Promise")) |b| if (b.value == .object) {
        const pf = b.value.object;
        try defineMethod(arena, pf, "all", .promise_all, "all"); // §27.2.4.1
        try defineMethod(arena, pf, "allSettled", .promise_all_settled, "allSettled"); // §27.2.4.2
        try defineMethod(arena, pf, "any", .promise_any, "any"); // §27.2.4.3
        try defineMethod(arena, pf, "race", .promise_race, "race"); // §27.2.4.6
    };

    // §20.5.7 AggregateError — the error thrown by `Promise.any` when every input rejects. A native
    // constructor carrying its rejection list in `errors`; proto-linked like the other Error ctors.
    {
        const ctor = try Object.createNative(arena, .aggregate_error_ctor, "AggregateError");
        ctor.prototype = function_proto; // §20.2.3 the constructor function object → %Function.prototype%
        if (ctor.get("prototype")) |pv| {
            if (pv == .object) {
                pv.object.prototype = object_proto; // §20.5.7.3 AggregateError.prototype inherits %Object.prototype%
                try pv.object.set("name", .{ .string = "AggregateError" });
            }
        }
        try defineConstructorBackref(ctor); // §20.5.7.3.1 AggregateError.prototype.constructor === AggregateError
        try env.declare("AggregateError", .{ .object = ctor }, true, true);
    }

    // §19.3 / §9.3.4 globalThis — a reified global object whose own properties MIRROR the global
    // bindings (every standard global declared above), so `globalThis.Object === Object`, etc. The
    // engine resolves ordinary identifiers through the Environment (unchanged — the hot path is
    // untouched); the global object exists so `globalThis` and property access through it work and so
    // the harness's `asyncTest` (which checks `Object.prototype.hasOwnProperty.call(globalThis,"$DONE")`)
    // sees `$DONE` as an own property (the runner installs it on this object too). Its [[Prototype]] is
    // %Object.prototype%. Built LAST so every standard binding is present to mirror.
    const global_obj = try Object.create(arena, object_proto);
    {
        // Mirror every global binding as an own (writable/non-enumerable/configurable) property —
        // EXCEPT the engine-internal sentinels (names that aren't valid identifiers, e.g.
        // `%PromisePrototype%`), which user code must never reach. `globalThis` itself is added below.
        var it = env.vars.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (name.len > 0 and name[0] == '%') continue; // skip %...% sentinels
            try global_obj.defineData(name, entry.value_ptr.value, true, false, true);
        }
    }
    // §19.3.1 globalThis is a writable, non-enumerable, configurable own property of the global object
    // (and a global binding) that refers to the global object itself.
    try global_obj.defineData("globalThis", .{ .object = global_obj }, true, false, true);
    try env.declare("globalThis", .{ .object = global_obj }, true, true);
    // Stash under a sentinel so the engine (and the async runner) can reach the global object.
    try env.declare("%GlobalThis%", .{ .object = global_obj }, false, true);
}
