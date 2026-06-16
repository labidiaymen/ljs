//! Ordinary objects (ECMA-262 §10.1) and function objects (§10.2). M1 subset: a property map
//! (name → Value), a `[[Prototype]]` link, ordinary `[[Get]]`/`[[Set]]`, and — for function
//! objects — an AST closure (`FunctionData`) invoked by the interpreter's `[[Call]]`. Property
//! descriptors, accessors, and array/error kinds arrive later. Allocated in the realm arena.
const std = @import("std");
const ast = @import("ast.zig");
const Value = @import("value.zig").Value;
const Symbol = @import("value.zig").Symbol;
const Environment = @import("environment.zig").Environment;

/// §22.1.5 / §23.1.5 native iterator state for an Array/String Iterator object produced by
/// `Array.prototype[Symbol.iterator]` / `String.prototype[Symbol.iterator]`. The `next` native
/// reads/advances this slot. Present iff the object is such a native iterator (`Object.iter` != null).
pub const IterState = struct {
    /// The array being iterated (its `elements`), or null for a string iterator.
    array: ?*Object = null,
    /// The string being iterated (UTF-8 bytes), or null for an array iterator.
    string: ?[]const u8 = null,
    /// The current cursor: the next array index / byte offset to yield.
    cursor: usize = 0,
    /// §23.1.5.1 array-iterator kind: `.value` (Array.prototype.values / [Symbol.iterator]),
    /// `.key` (.keys → indices), `.entry` (.entries → `[index, value]` pairs).
    kind: IterKind = .value,
};

pub const IterKind = enum { value, key, entry };

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
    string_method, // String.prototype.<native_name>
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
    // §21.1 Number / §20.3 Boolean — the constructors (callable conversion) + Number statics.
    number_ctor, // Number( x ) — ToNumber (Number() → 0)
    boolean_ctor, // Boolean( x ) — ToBoolean
    number_static, // Number.<native_name> (isNaN/isFinite/isInteger/isSafeInteger/parseInt/parseFloat)
    number_method, // Number.prototype.<native_name> (toString/valueOf)
    boolean_method, // Boolean.prototype.<native_name> (toString/valueOf)
    // §20.4 Symbol (M8) — the constructor + Symbol.prototype.toString + the iterator natives.
    symbol_ctor, // Symbol([description]) — callable, not a constructor
    symbol_to_string, // Symbol.prototype.toString / Symbol.prototype.valueOf (native_name selects)
    array_values, // Array.prototype[Symbol.iterator] / .values — returns an Array Iterator
    array_keys, // Array.prototype.keys — Array Iterator over indices (§23.1.3.18)
    array_entries, // Array.prototype.entries — Array Iterator over [index, value] (§23.1.3.7)
    string_iterator, // String.prototype[Symbol.iterator] — returns a String Iterator
    iterator_next, // %ArrayIteratorPrototype%.next / %StringIteratorPrototype%.next (native_name selects)
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
    // §27.2 Promise — the constructor, prototype methods, and statics.
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
    elements: std.ArrayListUnmanaged(Value) = .empty, // backing store iff kind == .array
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
        // §20.2.4.2: a built-in function's `name` own property (non-enumerable, non-writable,
        // configurable). For a method installed via `defineMethod` this is overwritten with the
        // property key; for a constructor / standalone native this name (the passed identifier) is
        // already the spec name. (Per-native `length` is deferred — see specs/015.)
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
    pub fn defineProperty(self: *Object, key: []const u8, d: Descriptor) std.mem.Allocator.Error!bool {
        const existing = self.properties.getPtr(key);
        // §10.1.6.3 step 2.a: a property absent from a non-extensible object cannot be added.
        if (existing == null and !self.extensible) return false;
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
    /// non-configurable, and every own DATA property non-writable (accessors keep their get/set).
    pub fn freezeObject(self: *Object) void {
        self.extensible = false;
        var it = self.properties.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.configurable = false;
            if (entry.value_ptr.payload == .data) entry.value_ptr.writable = false;
        }
    }

    /// §7.3.17 TestIntegrityLevel — `frozen`: non-extensible AND every own property non-configurable
    /// AND every data property non-writable. A non-extensible object with no own properties is frozen.
    pub fn isFrozenObject(self: *Object) bool {
        if (self.extensible) return false;
        var it = self.properties.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.configurable) return false;
            if (entry.value_ptr.payload == .data and entry.value_ptr.writable) return false;
        }
        return true;
    }

    /// §7.3.17 TestIntegrityLevel — `sealed`: non-extensible AND every own property non-configurable.
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
        .symbol => |x| b == .symbol and b.symbol == x,
        .object => |x| b == .object and b.object == x,
    };
}
