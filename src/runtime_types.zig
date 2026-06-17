//! Runtime type definitions shared across the engine — iterator/collection/helper state, the Promise
//! & generator records, the `NativeId` dispatch enum, function/property/descriptor types. Split out of
//! object.zig to keep files under 1000 lines; object.zig re-exports each of these so existing
//! `@import("object.zig").<Type>` references are unaffected. (`Object` is imported back for the many
//! pointer fields — a type-level circular import Zig resolves since the fields are pointers/enums.)
const std = @import("std");
const ast = @import("ast.zig");
const Value = @import("value.zig").Value;
const Symbol = @import("value.zig").Symbol;
const Environment = @import("environment.zig").Environment;
const Object = @import("object.zig").Object;
const regexp_engine = @import("builtin_regexp_engine.zig");

pub const IterState = struct {
    /// The array being iterated (its `elements`), or null for a string iterator.
    array: ?*Object = null,
    /// The string being iterated (UTF-8 bytes), or null for an array iterator.
    string: ?[]const u8 = null,
    /// The current cursor: the next array index / byte offset to yield.
    cursor: usize = 0,
    /// §24.1.5.1 the Map/Set being iterated, or null for an array/string iterator. The `cursor` then
    /// indexes the collection's `entries` (skipping tombstones); `kind` selects key/value/entry.
    collection: ?*Object = null,
    /// §23.1.5.1 array-iterator kind: `.value` (Array.prototype.values / [Symbol.iterator]),
    /// `.key` (.keys → indices), `.entry` (.entries → `[index, value]` pairs).
    kind: IterKind = .value,
};

pub const IterKind = enum { value, key, entry };

/// §27.1.4 Iterator Helper kind — the lazy transform a helper object applies as it pulls from its
/// underlying iterator. `wrap` is the identity passthrough used by `Iterator.from` (§27.1.3.1.1).
pub const HelperKind = enum { map, filter, take, drop, flat_map, wrap };

/// §27.1.4 Iterator Helper state — present iff this object is a lazy helper (map/filter/…/from wrapper).
/// Its `next` native (`iterator_helper_next`) pulls from `underlying` (via the cached `next_fn`),
/// applies the transform, and tracks per-kind state. Created by the %Iterator.prototype% lazy methods.
/// §28.2 a Proxy exotic object's internal slots: [[ProxyTarget]] + [[ProxyHandler]]. Present iff
/// `Object.proxy != null`; internal methods route through the handler trap (or forward to the target).
pub const ProxyData = struct {
    target: *Object,
    handler: *Object,
    revoked: bool = false,
};

/// §22.2 a RegExp instance's internal slots: [[OriginalSource]] / [[OriginalFlags]] + the parsed flag
/// booleans. `last_index` is mirrored as an own writable `lastIndex` data property. Present iff
/// `Object.regexp != null`. (M1: source/flags/getters/toString; the matcher arrives in M2.)
pub const RegExpData = struct {
    source: []const u8,
    flags: []const u8, // canonical-order flag string (d,g,i,m,s,u,v,y)
    global: bool = false,
    ignore_case: bool = false,
    multiline: bool = false,
    dot_all: bool = false,
    unicode: bool = false,
    unicode_sets: bool = false,
    sticky: bool = false,
    has_indices: bool = false,
    /// The compiled pattern (parser → bytecode), built by `makeRegExp` via `regexp_engine.compile`.
    /// Null only on the bare %RegExp.prototype% (no [[RegExpMatcher]]); every real instance has one.
    program: ?*const regexp_engine.Program = null,
};

pub const HelperState = struct {
    kind: HelperKind,
    underlying: *Object,
    next_fn: Value,
    callback: Value = .undefined, // map / filter / flatMap mapper
    counter: f64 = 0, // index argument passed to the callback
    remaining: f64 = 0, // take / drop limit (counts down)
    inner: ?*Object = null, // flatMap: the current inner iterator being flattened
    inner_next: Value = .undefined,
    started: bool = false, // drop: whether the initial skip has run
    done: bool = false, // latched once the helper is exhausted/closed
};

/// §24.1 / §24.2 / §24.3 / §24.4 the keyed-collection backing store, attached to an ordinary object
/// via `Object.collection` (null for every non-collection object → zero cost). Entries are kept in
/// INSERTION ORDER; a delete leaves a tombstone (`present=false`) so an iterator created earlier still
/// advances correctly (§24.1.5.2). Key equality is SameValueZero (`abstract_ops.sameValueZero`); a
/// stored key normalizes `-0 → +0`. Lookup is a linear scan (correctness-first). For a Set/WeakSet the
/// `value` field mirrors `key` (§24.2.3.1 step 6 stores the value as both).
pub const CollectionKind = enum { map, set, weakmap, weakset };

pub const CollectionEntry = struct {
    key: Value,
    value: Value,
    present: bool = true,
};

pub const Collection = struct {
    kind: CollectionKind,
    entries: std.ArrayListUnmanaged(CollectionEntry) = .empty,
    /// Count of present (non-tombstone) entries — the observable `size`.
    size: usize = 0,
};

/// §6.1.7.1 one symbol-keyed own property: the Symbol identity plus its value/attribute payload.
/// Symbol-keyed properties live in a SEPARATE store from the string-keyed `properties` map so the
/// hot string get/set path is untouched; they are also (correctly) never surfaced by for-in /
/// Object.keys / getOwnPropertyNames (§7.3.23 OrdinaryOwnPropertyKeys lists Symbol keys last and
/// those reflection ops filter them out). Few per object → a linear-scan list (keyed by pointer
/// identity), not a hash map.
pub const SymbolProperty = struct {
    key: *Symbol,
    pv: PropertyValue,
};

pub const Kind = enum { ordinary, function, array };

/// §27.2.6 [[PromiseState]] — a Promise is pending until settled, then fulfilled or rejected (once).
pub const PromiseState = enum { pending, fulfilled, rejected };

/// §27.2.1.2 a PromiseReaction record — one handler queued on a (still-pending) promise's fulfill or
/// reject list. When the promise settles, each reaction becomes a Job (§27.2.2.1 NewPromiseReactionJob)
/// enqueued on the realm Job queue. `handler` is the user `onFulfilled`/`onRejected` (null ⇒ the default
/// "identity"/"thrower" pass-through, §27.2.4.7.1/.2); `capability` is the derived promise this reaction
/// resolves/rejects (its resolve/reject functions), so `then` can chain.
pub const PromiseReaction = struct {
    /// Whether this reaction fires on fulfillment or rejection of the promise it's attached to.
    kind: enum { fulfill, reject },
    /// The user-supplied handler (`onFulfilled` / `onRejected`), or null for the default pass-through.
    handler: ?*Object,
    /// The capability (derived promise) this reaction settles. Null for a reaction with no derived
    /// promise (e.g. the internal await reaction, which resumes a thread instead).
    capability: ?*Object,
    /// §27.7 await: when set, running this reaction resumes the async body thread `gen` with the
    /// settlement value (fulfill → `.next(value)`; reject → `.throw(value)`) instead of calling a
    /// handler / settling a capability. `capability`/`handler` are null in that case.
    await_gen: ?*Generator = null,
};

/// §27.2.6 [[PromiseFulfillReactions]] / [[PromiseRejectReactions]] / [[PromiseResult]] state, present
/// iff an Object is a Promise (`Object.promise != null`). Allocated in the realm arena.
pub const PromiseData = struct {
    state: PromiseState = .pending,
    /// The settled value (fulfillment value or rejection reason); undefined while pending.
    result: Value = .undefined,
    /// §27.2.1.3.1 [[AlreadyResolved]] — a Promise's resolve/reject pair fires at most once. Set the
    /// first time the promise is resolved OR rejected (through its resolving functions / then-adoption).
    already_resolved: bool = false,
    /// §27.2.6 the reaction records queued while pending; flushed (→ Jobs) on settlement, then cleared.
    fulfill_reactions: std.ArrayListUnmanaged(PromiseReaction) = .empty,
    reject_reactions: std.ArrayListUnmanaged(PromiseReaction) = .empty,
};

/// §27.2.4.1.2/.2.2/.3.2 the shared state of one Promise combinator (`all`/`allSettled`/`any`) call,
/// captured by each per-element resolve/reject closure. The combinator seeds `values` (one slot per
/// input promise), a `remaining` counter (the number of inputs not yet settled, started at 1 and
/// decremented as each settles + once after the loop, §27.2.4.1.1), and the result `capability` to
/// settle when `remaining` hits 0. `errors`/`values` double as the AggregateError list for `any`.
/// Allocated in the realm arena; pointed at by each element closure (so they share one counter/array).
pub const CombinatorState = struct {
    /// The result promise to settle when all inputs have settled (the combinator's returned promise).
    capability: *Object,
    /// One slot per input: the fulfillment value (`all`), the `{status,...}` record (`allSettled`),
    /// or the rejection reason (`any`). Grown as the iterable is consumed.
    values: std.ArrayListUnmanaged(Value) = .empty,
    /// §27.2.4.1.1 [[Remaining]] — inputs not yet settled. The combinator settles when this reaches 0.
    remaining: usize = 1,
};

/// §9.5 a Job enqueued on the realm Job (microtask) queue. The engine drains the queue once the
/// execution stack is empty. Two kinds (the two HostEnqueuePromiseJob callers in §27.2):
///   • `.reaction` — §27.2.2.1 NewPromiseReactionJob: run a settled promise's reaction (call its
///     handler / resume an awaiting body, then settle the derived capability).
///   • `.thenable` — §27.2.2.2 NewPromiseResolveThenableJob: a promise was resolved with a thenable,
///     so call `thenable.then(resolve, reject)` to adopt its eventual state.
pub const Job = union(enum) {
    reaction: struct {
        reaction: PromiseReaction,
        /// The settlement value passed to the handler / used to resume the awaiting body.
        argument: Value,
    },
    thenable: struct {
        /// The promise being resolved (whose resolving functions are handed to `then`).
        promise: *Object,
        /// The thenable object resolved-with.
        thenable: Value,
        /// Its `then` method (already extracted, §27.2.1.3.2).
        then_fn: *Object,
    },
};

/// §27.5 Generator object internal state ([[GeneratorState]]). A generator created by calling a
/// `function*` starts `suspended_start`; `.next` spawns the body thread and runs it to the first
/// `yield`/return (→ `suspended_yield` / `completed`); each subsequent `.next` resumes from a parked
/// `yield`. `executing` guards against re-entrant `.next` on a running generator (§27.5.3.3).
pub const GeneratorState = enum { suspended_start, suspended_yield, executing, completed };

/// What the consumer is asking a parked `yield` to do on resume (§27.5.3.3 GeneratorResume /
/// §27.5.3.4 GeneratorResumeAbrupt): a normal `.next(v)` (the yield evaluates to `v`), or an abrupt
/// `.return(v)` / `.throw(e)` injected at the suspension point.
pub const ResumeKind = enum { next, ret, throw };

/// The gen→caller transfer: what the body thread handed back at a suspension/completion point.
pub const TransferKind = enum { yield, ret, throw };

/// §27.5 A Generator object's suspendable-execution state. Because a tree-walker recurses on the
/// native stack and cannot suspend mid-evaluation, the body runs on its OWN `std.Thread`, alternating
/// strictly with the consumer (ping-pong: exactly ONE side runs at a time — the two semaphores
/// establish happens-before, so the shared realm arena is touched by only one thread at a time and
/// stays safe). The two sides hand control back and forth through `resume_gen` (caller→body) and
/// `to_caller` (body→caller); the slots carry the transferred values.
///
/// Allocated in the realm arena (lives as long as the realm). A generator that is never fully
/// consumed leaves its body thread parked forever on `resume_gen` — acceptable for the short-lived
/// Test262 harness; `Interpreter.cleanupGenerators` signals such threads to exit at realm teardown.
pub const Generator = struct {
    /// The generator function object (its `call` FunctionData carries body + closure + flags).
    func: *Object,
    /// The argument values the generator was called with (bound to the params when the body starts).
    args: []const Value,
    /// The `this` binding the generator was called with (the body runs with this `this`).
    this_val: Value,
    /// The active [[HomeObject]] for `super` resolution inside the body (null for plain generators).
    home_object: ?*Object,
    /// §15.5.2 / §15.6.2: for a sync/async GENERATOR, FunctionDeclarationInstantiation (binding the
    /// params — incl. destructuring patterns and default-value expressions — and the `arguments`
    /// object) runs EAGERLY on the CALLER thread when the generator object is created, so a param
    /// destructuring/default error throws at the call site (before the first `.next`). The resulting
    /// environment is stashed here for the body thread to run statements in. Null for async functions
    /// (whose params are bound on the body thread, since a param error rejects the returned promise).
    call_env: ?*Environment = null,
    state: GeneratorState = .suspended_start,
    /// The body thread (spawned on the first `.next`). Null until then; joined on completion.
    thread: ?std.Thread = null,
    /// Caller→body handoff: posted by `.next`/`.return`/`.throw` to resume the parked body. The
    /// Generator is arena-allocated (stable address), so the body thread may hold `&gen.resume_gen`.
    resume_gen: std.Io.Semaphore = .{},
    /// Body→caller handoff: posted by the body at each `yield` and on completion.
    to_caller: std.Io.Semaphore = .{},
    /// gen→caller slot: the value yielded/returned/thrown and which it was.
    transfer_value: Value = .undefined,
    transfer_kind: TransferKind = .yield,
    /// caller→gen slot: the value sent into the resumed `yield` (or the return/throw payload).
    sent_value: Value = .undefined,
    resume_kind: ResumeKind = .next,
    /// Set by the realm at teardown: instructs a parked body thread to unwind and exit (best-effort
    /// cleanup so a never-consumed generator's thread does not linger). The body checks this after
    /// each resume and abandons execution if set.
    abandon: bool = false,
    /// §27.7 set iff this suspension drives an ASYNC FUNCTION body (vs a `function*` generator). The
    /// body suspends at each `await` via the same ping-pong handoff, but: (a) calling the function
    /// runs the body immediately (to the first await / completion), it is NOT a lazy iterator; (b) the
    /// terminal completion resolves/rejects `promise` instead of producing an IteratorResult; (c) a
    /// suspension carries the awaited value out (so the caller can register reactions on it) rather
    /// than yielding to a `.next` consumer.
    is_async: bool = false,
    /// §27.7 the Promise returned by the async function call — resolved on normal return, rejected on
    /// an uncaught throw. Null for ordinary generators.
    promise: ?*Object = null,
    /// §27.6 set iff this body drives an ASYNC GENERATOR (`async function*`). Both `is_async` and this
    /// are set. The body may suspend at an `await` (carry the awaited value out, register reactions to
    /// resume — like a plain async fn) OR at a `yield` (carry the yielded value out, settle the current
    /// AsyncGeneratorRequest); `transfer_await` discriminates which a given `.yield` transfer is. The
    /// terminal completion settles the current request (done:true / rejection) instead of `promise`.
    is_async_gen: bool = false,
    /// §27.6.3.8 discriminates an async-generator `.yield`-kind suspension: `true` ⇒ the body is
    /// AWAITing `transfer_value` (the servicer registers fulfill/reject reactions that resume it);
    /// `false` ⇒ the body YIELDed `transfer_value` (the servicer settles the current request with
    /// `{value, done:false}`). Meaningless unless `is_async_gen` and `transfer_kind == .yield`.
    transfer_await: bool = false,
    /// §27.6 back-pointer to the owning AsyncGenerator (its request queue + state), so the body thread
    /// and the servicer share it. Null for plain generators / async functions.
    async_gen: ?*AsyncGenerator = null,
};

/// §27.6.1 [[AsyncGeneratorState]] — an async generator's lifecycle. `suspended_start` (body not yet
/// run) / `suspended_yield` (parked at a `yield`) / `executing` (body running between suspensions) /
/// `awaiting_return` (a `.return` is being awaited before completion, §27.6.3.10) / `completed`.
pub const AsyncGeneratorState = enum { suspended_start, suspended_yield, executing, awaiting_return, completed };

/// §27.6.3.1 AsyncGeneratorRequest — one queued `.next(v)` / `.return(v)` / `.throw(e)`. Each carries
/// the completion (`kind` + `value`) to resume the body with and the Promise capability (`promise` +
/// its resolve/reject functions) to settle when this request produces a result. Serviced FIFO, one at
/// a time (§27.6.3.4 AsyncGeneratorDrainQueue).
pub const AsyncGenRequest = struct {
    kind: ResumeKind,
    value: Value,
    /// The promise returned to the caller by the `.next/.return/.throw` that enqueued this request.
    promise: *Object,
    /// The resolve / reject functions of `promise` (so the servicer can settle it with the IteratorResult
    /// or reject it on a thrown completion), §27.2.1.3.
    resolve: *Object,
    reject: *Object,
};

/// §27.6.1 An AsyncGenerator object's state: the underlying suspendable `Generator` (thread + handoff),
/// the [[AsyncGeneratorState]], and the [[AsyncGeneratorQueue]] of pending requests. Present iff an
/// Object is an async generator (`Object.async_generator != null`). Arena-allocated.
pub const AsyncGenerator = struct {
    /// The thread substrate (reused from §27.5 generators) on which the body runs, suspending at each
    /// `await` / `yield`. Its `is_async`+`is_async_gen` are set; its `async_gen` points back here.
    gen: *Generator,
    state: AsyncGeneratorState = .suspended_start,
    /// §27.6.3.1 [[AsyncGeneratorQueue]] — pending requests serviced FIFO. `head` is the index of the
    /// request currently being serviced (the front); entries before it are done.
    queue: std.ArrayListUnmanaged(AsyncGenRequest) = .empty,
    head: usize = 0,
};

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
    object_value_of, // §20.1.3.7 Object.prototype.valueOf (returns ToObject(this) — the receiver)
    array_ctor, // Array(...)
    array_method, // Array.prototype.<native_name> / Array.isArray
    array_static, // §23.1.2 Array.from / Array.of
    string_method, // String.prototype.<native_name>
    string_static, // §22.1.2 String.fromCharCode / String.fromCodePoint / String.raw
    function_ctor, // Function(...) — minimal (the `.prototype` carrier for call/apply/bind)
    // §20.1.2 Object static reflection
    object_define_property, // Object.defineProperty
    object_define_properties, // Object.defineProperties
    object_get_own_property_descriptor, // Object.getOwnPropertyDescriptor
    object_get_own_property_descriptors, // Object.getOwnPropertyDescriptors (§20.1.2.9)
    object_get_own_property_names, // Object.getOwnPropertyNames
    object_keys, // Object.keys (§20.1.2.19)
    object_values, // Object.values (§20.1.2.23)
    object_entries, // Object.entries (§20.1.2.6)
    object_create, // Object.create (§20.1.2.2)
    object_assign, // Object.assign (§20.1.2.1)
    object_from_entries, // Object.fromEntries (§20.1.2.7)
    object_has_own, // Object.hasOwn (§20.1.2.13)
    object_get_own_property_symbols, // Object.getOwnPropertySymbols (§20.1.2.10)
    object_group_by, // Object.groupBy (§20.1.2.11)
    object_proto_getter, // §B.2.2.1.1 get Object.prototype.__proto__
    object_proto_setter, // §B.2.2.1.2 set Object.prototype.__proto__
    // §B.2.2.2–.5 legacy accessor-definition methods on Object.prototype. `native_name` selects.
    object_legacy_accessor, // __defineGetter__ / __defineSetter__ / __lookupGetter__ / __lookupSetter__
    object_get_prototype_of, // Object.getPrototypeOf (§20.1.2.12)
    object_set_prototype_of, // Object.setPrototypeOf (§20.1.2.22)
    object_is, // Object.is (§20.1.2.14)
    object_freeze, // Object.freeze (§20.1.2.7)
    object_is_frozen, // Object.isFrozen (§20.1.2.16)
    object_seal, // Object.seal (§20.1.2.21)
    object_is_sealed, // Object.isSealed (§20.1.2.17)
    object_prevent_extensions, // Object.preventExtensions (§20.1.2.20)
    object_is_extensible, // Object.isExtensible (§20.1.2.15)
    // §20.1.3 Object.prototype reflection
    object_has_own_property, // Object.prototype.hasOwnProperty
    object_property_is_enumerable, // Object.prototype.propertyIsEnumerable
    object_is_prototype_of, // Object.prototype.isPrototypeOf
    // §20.2.3 Function.prototype methods (Cycle 2)
    function_method, // Function.prototype.<native_name> (call/apply/bind)
    function_proto_noop, // %Function.prototype% itself — a callable that returns undefined (§20.2.3)
    // §21.3 Math — `native_name` is the method (`pow`/`floor`/…). The Math namespace object holds these.
    math_method, // Math.<native_name>
    // §28.1 Reflect — `native_name` is the method (`get`/`apply`/…). The Reflect namespace object holds these.
    reflect_method, // Reflect.<native_name>
    // §21.1 Number / §20.3 Boolean — the constructors (callable conversion) + Number statics.
    number_ctor, // Number( x ) — ToNumber (Number() → 0)
    boolean_ctor, // Boolean( x ) — ToBoolean
    number_static, // Number.<native_name> (isNaN/isFinite/isInteger/isSafeInteger/parseInt/parseFloat)
    number_method, // Number.prototype.<native_name> (toString/valueOf)
    boolean_method, // Boolean.prototype.<native_name> (toString/valueOf)
    // §21.2 BigInt (M36) — the constructor (callable, NOT new), prototype methods, and statics.
    bigint_ctor, // BigInt( x ) — ToBigInt; `new BigInt` → TypeError
    bigint_method, // BigInt.prototype.<native_name> (toString/valueOf)
    bigint_static, // BigInt.<native_name> (asIntN/asUintN)
    // §20.4 Symbol (M8) — the constructor + Symbol.prototype.toString + the iterator natives.
    symbol_ctor, // Symbol([description]) — callable, not a constructor
    symbol_to_string, // Symbol.prototype.toString / valueOf / [Symbol.toPrimitive] (native_name selects)
    symbol_static, // §20.4.2 Symbol.for(key) / Symbol.keyFor(sym) (native_name selects)
    symbol_description, // §20.4.3.2 get Symbol.prototype.description
    species_getter, // §23.1.2.5 get Array[Symbol.species] — returns `this` (the receiver constructor)
    array_values, // Array.prototype[Symbol.iterator] / .values — returns an Array Iterator
    array_keys, // Array.prototype.keys — Array Iterator over indices (§23.1.3.18)
    array_entries, // Array.prototype.entries — Array Iterator over [index, value] (§23.1.3.7)
    string_iterator, // String.prototype[Symbol.iterator] — returns a String Iterator
    iterator_next, // %ArrayIteratorPrototype%.next / %StringIteratorPrototype%.next (native_name selects)
    // §27.1 Iterator — the abstract constructor, `Iterator.from`, and the %Iterator.prototype% helper
    // methods. Eager consumers (M55): reduce/toArray/forEach/some/every/find. `native_name` selects.
    iterator_ctor, // §27.1.3.1 new Iterator() — abstract (direct construction throws)
    iterator_from, // §27.1.3.1.1 Iterator.from(O)
    iterator_helper, // %Iterator.prototype%.<native_name>
    iterator_helper_next, // §27.1.4.x an Iterator Helper object's own `next` (drives the lazy transform)
    // §27.5 Generator — %GeneratorPrototype% methods + [Symbol.iterator].
    generator_method, // %GeneratorPrototype%.next / .return / .throw (native_name selects)
    generator_iterator, // %GeneratorPrototype%[Symbol.iterator] — returns `this`
    // §27.6 AsyncGenerator — %AsyncGeneratorPrototype% methods (each returns a promise) + asyncIterator.
    async_generator_method, // %AsyncGeneratorPrototype%.next / .return / .throw (native_name selects)
    async_generator_iterator, // %AsyncGeneratorPrototype%[Symbol.asyncIterator] — returns `this`
    // §27.1.4 AsyncFromSyncIterator — next/return/throw promise-wrapping the wrapped sync iterator.
    async_from_sync_method, // %AsyncFromSyncIteratorPrototype%.next / .return / .throw (native_name selects)
    /// §27.1.4.4 AsyncFromSyncIteratorContinuation onFulfilled — wraps an awaited value `v` into a fresh
    /// IteratorResult `{ value: v, done }`. `afs_done` carries the captured `done` flag.
    async_from_sync_wrap,
    // §24.1/§24.2/§24.3/§24.4 keyed collections — constructors (new-only), prototype methods, the
    // `size` accessor, and the collection-iterator factories. `native_name` selects the method.
    map_ctor, // new Map([iterable])
    set_ctor, // new Set([iterable])
    weakmap_ctor, // new WeakMap([iterable])
    weakset_ctor, // new WeakSet([iterable])
    map_method, // Map.prototype.<native_name> (get/set/has/delete/clear/forEach)
    set_method, // Set.prototype.<native_name> (add/has/delete/clear/forEach)
    weakmap_method, // WeakMap.prototype.<native_name> (get/set/has/delete)
    weakset_method, // WeakSet.prototype.<native_name> (add/has/delete)
    collection_size, // get Map.prototype.size / get Set.prototype.size
    collection_iterator, // Map/Set.prototype.keys/values/entries — returns a collection iterator
    // §25.5 JSON — the namespace object's two methods.
    json_parse, // JSON.parse(text[, reviver])
    json_stringify, // JSON.stringify(value[, replacer[, space]])
    // §27.2 Promise — the constructor, prototype methods, and statics.
    // §28.2 Proxy — the constructor, Proxy.revocable, and the per-revocable revoke function.
    proxy_ctor, // new Proxy(target, handler)
    proxy_revocable, // Proxy.revocable(target, handler)
    proxy_revoke, // the revoker returned by Proxy.revocable (clears target/handler)
    // §22.2 RegExp — the constructor, the prototype accessor getters, and toString.
    regexp_ctor, // new RegExp(pattern, flags) / RegExp(...)
    regexp_proto_getter, // get RegExp.prototype.<source|flags|global|ignoreCase|...> (native_name selects)
    regexp_to_string, // RegExp.prototype.toString
    regexp_exec, // RegExp.prototype.exec
    regexp_test, // RegExp.prototype.test
    promise_ctor, // new Promise(executor)
    promise_then, // Promise.prototype.then
    promise_catch, // Promise.prototype.catch
    promise_finally, // Promise.prototype.finally
    promise_resolve, // Promise.resolve(x)
    promise_reject, // Promise.reject(x)
    promise_all, // Promise.all(iterable) (§27.2.4.1)
    promise_all_settled, // Promise.allSettled(iterable) (§27.2.4.2)
    promise_any, // Promise.any(iterable) (§27.2.4.3)
    promise_race, // Promise.race(iterable) (§27.2.4.6)
    /// §27.2.4.1.2/.2.2/.3.2 a combinator per-element resolve/reject closure. `combinator` carries its
    /// shared state (the result array, the remaining counter, the capability); `combinator_index` is
    /// this element's slot. The same id backs `all`'s resolve, `allSettled`'s onFulfilled/onRejected,
    /// and `any`'s reject — `native_name` selects the variant.
    promise_combinator_element,
    aggregate_error_ctor, // §20.5.7 AggregateError(errors, message) — thrown by Promise.any when all reject
    suppressed_error_ctor, // §20.5.8 SuppressedError(error, suppressed, message) — §ER DisposeResources aggregation
    /// §27.2.1.3 the resolve / reject functions passed to an executor (and to a thenable's `then`).
    /// `promise_slot` (on the function object) is the promise they settle; `native_name` selects
    /// "resolve" vs "reject". These also back the finally-handler thunks (native_name "finally_*").
    promise_resolve_fn,
    promise_reject_fn,
    /// §27.2.5.3.1 the `finally` then-onFinally wrappers (value-thunk / thrower-thunk). `promise_slot`
    /// carries the captured onFinally function via its `bound`-like slot; `native_name` selects which.
    promise_finally_thunk,
    /// Runner-injected `$DONE` (Test262 async completion callback). Not part of ECMA-262 — installed
    /// only by the conformance runner to drive [async] tests; ordinary evals never see it.
    test_done,
    /// §19.2.1 the global `eval` intrinsic (%eval%). A native function object so it is reachable both
    /// as the `eval` global binding and as `globalThis.eval`. When invoked through `callNative` this is
    /// the INDIRECT path (global env, global `this`); the interpreter's `evalCall` intercepts the DIRECT
    /// case (callee is the IdentifierReference `eval` resolving to this intrinsic) before dispatch.
    eval_fn,
    /// §19.2 the global function intrinsics — `native_name` selects which: `isNaN`/`isFinite`
    /// (§19.2.2/.3, COERCING), `parseInt`/`parseFloat` (§19.2.5/.4), and the four URI handlers
    /// `encodeURI`/`encodeURIComponent`/`decodeURI`/`decodeURIComponent` (§19.2.6). Installed on the
    /// global env (and thus mirrored onto globalThis as non-enumerable own properties).
    global_fn,
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
    /// §15.5: this function is a generator (`function* g(){}`). Calling it returns a §27.5 Generator
    /// object (it does NOT run the body); `yield` inside the body is the §14.4 yield operator. Ordinary
    /// functions and arrows leave this false (the hot call path is unchanged — no thread, no overhead).
    is_generator: bool = false,
    /// §15.8: this function is async (`async function f(){}`, `async () => …`, `async m(){}`). Calling
    /// it returns a Promise and runs the body on the generator thread substrate, suspending at each
    /// `await` (§27.7; M11 Cycle 2). Ordinary functions/arrows leave this false (the hot call path takes
    /// one extra optional-field branch after the `is_generator` check — no thread, no overhead).
    is_async: bool = false,
    /// §15.4 MethodDefinition — this function object was created with `kind: method` (a class/object
    /// method, getter, setter, or async method). Per §10.2.5 MakeMethod it is NOT a constructor and has
    /// NO own `prototype` property, UNLESS it is a generator/async-generator method (which still gets
    /// its generator `prototype`). Mirrors `ast.Function.is_method`; ordinary functions leave it false.
    is_method: bool = false,
    /// §9.2.5 / §15.7.14 [[HomeObject]]: for a class/object method the object the method is defined
    /// on — its `.prototype` (instance method) or the constructor (static method). `super.x` inside
    /// the method resolves against `home_object.[[Prototype]]`. Null for ordinary functions/arrows.
    home_object: ?*Object = null,
    /// §15.7.14: a derived class constructor (one whose class has an `extends` heritage). `super(...)`
    /// is only legal here; `super_ctor` is the superclass constructor object to invoke. Default
    /// derived constructor (no explicit `constructor`) forwards its args to `super(...)`.
    is_derived_ctor: bool = false,
    super_ctor: ?*Object = null,
    /// §11.2.2 strict-mode flag of this function's body (from `ast.Function.strict`): inherited strict,
    /// an own `"use strict"` prologue, or a class member (always strict). The interpreter restores its
    /// runtime strict state to this around the body, so §6.2.5.6 PutValue to an unresolved name throws
    /// ReferenceError (strict) instead of creating a global property (sloppy). Class constructors are
    /// always strict (§15.7) — set true when synthesizing the constructor's FunctionData.
    strict: bool = false,
};

/// §15.7.14 one resolved instance FieldDefinition: the property key (computed keys are evaluated at
/// class-definition time and stored here as a string) and the optional `= expr` initializer
/// (evaluated per instance in the class's defining scope).
pub const FieldInit = struct {
    key: []const u8,
    init: ?*const ast.Node,
    /// §15.7.14: a computed FieldDefinition whose name evaluated to a Symbol (`[sym] = …`). When set,
    /// the field is installed under this Symbol key (and `key` is unused); null for ordinary string keys.
    key_symbol: ?*Symbol = null,
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
