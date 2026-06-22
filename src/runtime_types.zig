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
    /// §23.2.5.1 the TypedArray being iterated (CreateArrayIterator over an integer-indexed exotic), or
    /// null otherwise. The `cursor` indexes elements; a read past the (possibly shrunk) length ends the
    /// iteration. Distinct from `array` because element access goes through the typed-array codec.
    typed_array: ?*Object = null,
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

/// §26.2 FinalizationRegistry [[Cells]] + [[CleanupCallback]]. Each cell records a registration's
/// [[WeakRefTarget]] (unused — never collected in the arena model), [[HeldValue]], and the optional
/// [[UnregisterToken]]. `cleanup_callback` is the callable passed to the constructor. GC finalization
/// is unobservable here; this exists only so `register`/`unregister` are spec-correct.
pub const FinalizationRegistryCell = struct {
    held_value: Value,
    unregister_token: ?Value = null, // null ⇒ no token; a Value ⇒ the token (Object/Symbol)
};
pub const FinalizationRegistryData = struct {
    cleanup_callback: *Object,
    cells: std.ArrayListUnmanaged(FinalizationRegistryCell) = .empty,
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
    running: bool = false, // §27.5.3.2: set while the helper's body is executing — a re-entrant
    // `next`/`return` while it is set throws a TypeError ("the generator is currently running").
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

/// §`explicit-resource-management` one entry of a DisposableStack's [[DisposeCapability]] —
/// a DisposableResource Record { [[ResourceValue]], [[Hint]], [[DisposeMethod]] }. `method == null`
/// is a no-op disposal (a null/undefined `use` resource); `value` is the `this` passed to `method`.
pub const DisposeEntry = struct {
    value: Value,
    method: ?*Object,
};

/// §`explicit-resource-management` a DisposableStack / AsyncDisposableStack instance's internal
/// slots: [[DisposableState]] (pending vs disposed, the `disposed` flag) and the
/// [[DisposeCapability]].[[DisposableResourceStack]] (LIFO — disposed in REVERSE push order).
/// `is_async` brands the stack kind (AsyncDisposableStack uses @@asyncDispose + disposeAsync).
/// Present iff `Object.disposable != null`.
pub const DisposableData = struct {
    is_async: bool,
    disposed: bool = false,
    stack: std.ArrayListUnmanaged(DisposeEntry) = .empty,
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

pub const Kind = enum { ordinary, function, array, array_buffer, typed_array, data_view, date };

// ── §25.1 / §23.2 / §25.3 Typed-array data model ────────────────────────────
// Three exotic object kinds back the binary stack. An `array_buffer` owns a heap byte block; a
// `typed_array` and a `data_view` are VIEWS that point at an `array_buffer` Object (shared storage,
// so a write through one view is visible through another / through a DataView). See `typed_array.zig`
// for the `ElemType` element codecs that read/write `ArrayBufferData.bytes`.

/// §25.1.5 the element type tag carried by a TypedArray view (the 11 concrete element types + their
/// byte size / content type). Re-exported from `typed_array.zig` so `object.zig`/`runtime_types.zig`
/// callers reach it as `rt.ElemType`.
pub const ElemType = @import("typed_array.zig").ElemType;

/// §25.1.1 ArrayBuffer internal slots ([[ArrayBufferData]] / [[ArrayBufferByteLength]] /
/// [[ArrayBufferDetachKey]] / [[ArrayBufferMaxByteLength]]). Present iff `Object.array_buffer != null`.
///   • `bytes` — the raw backing block, ALLOCATOR-OWNED (allocated with `Object.arena`, like every
///     other arena-owned slice in the engine; freed at realm teardown, so no per-object free is needed
///     and there is no leak under the testing allocator).
///   • `detached` — §25.1.3.3 DetachArrayBuffer sets this true (and `bytes` becomes length 0); every
///     view read then yields `undefined` and every write is a no-op (Phase 2 surfaces TypeErrors).
///   • `max_byte_length` — §25.1.1 [[ArrayBufferMaxByteLength]] for a RESIZABLE buffer (null = a
///     fixed-length buffer). Phase 1 only allocates fixed buffers; the slot exists for Phase 2-A.
pub const ArrayBufferData = struct {
    bytes: []u8,
    detached: bool = false,
    max_byte_length: ?usize = null,
    /// §25.1.6.x [[ArrayBufferIsImmutable]] — produced by `transferToImmutable`. An immutable buffer
    /// is fixed-length and rejects `resize` / `transfer` (TypeError). Always false for an ordinary or
    /// resizable buffer.
    immutable: bool = false,
};

/// §23.2.5 Integer-Indexed (TypedArray) exotic internal slots ([[ViewedArrayBuffer]] / [[ByteOffset]] /
/// [[ArrayLength]] / [[TypedArrayName]]/[[ContentType]] captured by `elem`). Present iff
/// `Object.typed_array != null`. `buffer` points at an `array_buffer` Object whose `bytes` it views:
/// element `i` occupies `buffer.array_buffer.?.bytes[byte_offset + i*bpe ..][0..bpe]` where
/// `bpe = elem.bytesPerElement()`. The view shares the buffer's storage (correct aliasing for free).
pub const TypedArrayData = struct {
    buffer: *Object,
    byte_offset: usize,
    array_length: usize,
    elem: ElemType,
    /// §10.4.5 [[ArrayLength]] = auto — set true when the view was created over a RESIZABLE
    /// ArrayBuffer with NO explicit length: the observable length then TRACKS the live buffer
    /// (grows/shrinks with `resize`). False for a fixed-length view (the stored `array_length`).
    tracks_length: bool = false,
};

/// §25.3.5 DataView internal slots ([[ViewedArrayBuffer]] / [[ByteOffset]] / [[ByteLength]]). Present
/// iff `Object.data_view != null`. Like a TypedArray it points at a shared `array_buffer` Object, but
/// it reads/writes at explicit byte offsets with explicit endianness (Phase 2-C).
pub const DataViewData = struct {
    buffer: *Object,
    byte_offset: usize,
    byte_length: usize,
    /// §25.3 [[ByteLength]] = auto — set true when the DataView was created over a RESIZABLE
    /// ArrayBuffer with NO explicit byteLength: the observable byteLength then TRACKS the live buffer.
    /// False for a fixed-length view (the stored `byte_length`).
    tracks_length: bool = false,
};

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
    /// The capability (derived-promise record) this reaction settles — its [[Resolve]]/[[Reject]]
    /// are CALLED with the handler result (so a user-subclass `then`/species capability routes
    /// through its own resolving functions). Null for a reaction with no derived promise (e.g. the
    /// internal await reaction, which resumes a thread instead).
    capability: ?*PromiseCapability,
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
    /// The result capability to settle when all inputs have settled (the combinator's returned
    /// promise + its resolve/reject — so a subclass/species result settles through its own functions).
    capability: *PromiseCapability,
    /// One slot per input: the fulfillment value (`all`), the `{status,...}` record (`allSettled`),
    /// or the rejection reason (`any`). Grown as the iterable is consumed.
    values: std.ArrayListUnmanaged(Value) = .empty,
    /// §27.2.4.1.1 [[Remaining]] — inputs not yet settled. The combinator settles when this reaches 0.
    remaining: usize = 1,
};

/// §27.2.1.5 PromiseCapability Record — `{ [[Promise]], [[Resolve]], [[Reject]] }`. Built by
/// NewPromiseCapability(C): `new C(executor)` where the `executor` (a `promise_capability_executor`
/// native) writes the just-passed resolve/reject here. The constructor `C` may be a user subclass
/// (subclassing) or the species result, so the resolve/reject are whatever `C` handed the executor —
/// not necessarily the engine's own resolving functions. Allocated in the realm arena.
pub const PromiseCapability = struct {
    /// The promise produced by `new C(executor)` (`undefined` until the constructor returns).
    promise: Value = .undefined,
    /// The resolve / reject functions captured by the executor (`undefined` until the executor runs;
    /// NewPromiseCapability throws a TypeError if either is still non-callable afterward, §27.2.1.5).
    resolve: Value = .undefined,
    reject: Value = .undefined,
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
    /// HOST (spec 099): a `queueMicrotask(cb)` job — call `cb()` (no args). Same queue as Promise
    /// reactions, so it interleaves FIFO with `.then`. Only ever enqueued by the host global.
    microtask: *Object,
};

/// HOST (Node axis, spec 099 — NOT ECMA-262): one `setImmediate` registration, fired in the event
/// loop's "check" phase (before timers). `cancelled` is set by `clearImmediate`.
pub const ImmediateEntry = struct {
    id: u64,
    callback: *Object,
    args: []const Value,
    cancelled: bool = false,
};

/// HOST (Node axis, spec 100 — NOT ECMA-262): one `process.nextTick(cb, ...args)` registration. The
/// nextTick queue is drained FULLY (including ticks enqueued by running ticks) BEFORE each microtask
/// checkpoint in the event loop, so a tick runs ahead of any Promise reaction scheduled the same turn.
pub const NextTickEntry = struct {
    callback: *Object,
    args: []const Value,
};

/// HOST (Node axis, spec 098 — NOT ECMA-262): one scheduled timer (`setTimeout`/`setInterval`). The
/// host event loop fires `callback(args...)` when the MONOTONIC clock reaches `deadline_ms`; an
/// `interval_ms != null` reschedules (`deadline_ms += interval_ms`), a one-shot is removed.
/// `cancelled` is set by `clearTimeout`/`clearInterval` (the loop skips + compacts it).
pub const TimerEntry = struct {
    id: u64,
    callback: *Object,
    args: []const Value,
    deadline_ms: f64,
    interval_ms: ?f64 = null,
    cancelled: bool = false,
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
    /// §9.2 the active [[PrivateEnvironment]] for private-name resolution inside the body (the
    /// generator/async function's `private_env`); null when defined outside any class body.
    private_env: ?*PrivateEnv = null,
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
    /// §16.2.1.6 ExecuteAsyncModule: set iff this async-body Generator drives a top-level-await MODULE
    /// body (there is no function object — `func` is unused). When set, the body thread runs the
    /// module's top-level StatementList in the module Environment instead of a FunctionBody.
    module_run: ?ModuleRun = null,
};

/// §16.2.1.6 the module-body payload for a top-level-await Generator: the module's top-level
/// statements + its Module Environment Record. The async-body thread runs these in `env`.
pub const ModuleRun = struct {
    statements: []const ast.Stmt,
    env: *Environment,
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
    object_to_locale_string, // §20.1.3.5 Object.prototype.toLocaleString → Invoke(O, "toString")
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
    function_has_instance, // §20.2.3.6 Function.prototype[@@hasInstance] — OrdinaryHasInstance(this, V)
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
    iterator_proto_accessor, // §27.1.4.1/.2 %Iterator.prototype% `constructor` & [@@toStringTag] get/set (native_name selects)
    wrap_for_valid_iterator, // §27.1.3.1.1.1 %WrapForValidIteratorPrototype%.next / .return (native_name selects)
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
    map_group_by, // §24.1.1.2 Map.groupBy(items, callbackfn) — SameValueZero-keyed grouping into a Map
    // §26.1 WeakRef — the constructor (new-only) + deref. §26.2 FinalizationRegistry — the constructor
    // + register/unregister. GC finalization is unobservable in the arena model (targets never cleared).
    weakref_ctor, // new WeakRef(target)
    weakref_deref, // WeakRef.prototype.deref()
    finalization_registry_ctor, // new FinalizationRegistry(cleanupCallback)
    finalization_registry_method, // FinalizationRegistry.prototype.<register|unregister>(...)
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
    regexp_symbol_method, // RegExp.prototype[Symbol.match|matchAll|replace|search|split] (native_name selects)
    regexp_string_iterator_next, // %RegExpStringIteratorPrototype%.next (§22.2.9.2.1)
    regexp_static, // RegExp.escape (§22.2.5.2) — native_name selects the static
    promise_ctor, // new Promise(executor)
    promise_then, // Promise.prototype.then
    promise_catch, // Promise.prototype.catch
    promise_finally, // Promise.prototype.finally
    promise_resolve, // Promise.resolve(x)
    promise_reject, // Promise.reject(x)
    promise_with_resolvers, // §27.2.4.3 Promise.withResolvers() — { promise, resolve, reject }
    /// §27.2.1.5.1 GetCapabilitiesExecutor — the executor passed to `new C(executor)` by
    /// NewPromiseCapability. It captures the just-built resolve/reject into the shared
    /// `PromiseCapability` record (`capability` slot on the function object).
    promise_capability_executor,
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
    error_to_string, // §20.5.3.4 Error.prototype.toString ( ) — `${name}: ${message}` (or one half)
    error_is_error, // §20.5.2.1 Error.isError ( arg ) — true iff arg has an [[ErrorData]] slot
    error_stack_getter, // get Error.prototype.stack — string for [[ErrorData]], undefined otherwise
    error_stack_setter, // set Error.prototype.stack — SetterThatIgnoresPrototypeProperties (string only)
    // §`explicit-resource-management` DisposableStack + AsyncDisposableStack — the constructors, the
    // use/adopt/defer/dispose/disposeAsync/move methods, the `disposed` getter, and the @@dispose /
    // @@asyncDispose aliases. `native_name` selects the method within each family. Backing store is
    // `Object.disposable` (a DisposableData record: the LIFO resource stack + the disposed flag).
    disposable_stack_ctor, // new DisposableStack()
    async_disposable_stack_ctor, // new AsyncDisposableStack()
    disposable_stack_method, // DisposableStack.prototype.<use|adopt|defer|dispose|move>
    async_disposable_stack_method, // AsyncDisposableStack.prototype.<use|adopt|defer|disposeAsync|move>
    disposable_stack_disposed, // get DisposableStack/AsyncDisposableStack.prototype.disposed
    disposable_adopt_wrapper, // the CreateBuiltinFunction closure `adopt` pushes (captures value+onDispose)
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
    /// HOST (Node axis, NOT ECMA-262): the timer globals — `native_name` selects
    /// `setTimeout`/`setInterval`/`clearTimeout`/`clearInterval` (spec 098). Register a callback on the
    /// interpreter's timer queue, fired by the host event loop. Inert on the Test262 path (no loop runs).
    timer_fn,
    /// HOST (Node axis, NOT ECMA-262): `console.log` — write the space-joined ToString of its args
    /// plus a newline to stdout (spec 098, so timer output is observable).
    console_log,
    /// HOST (Node axis, NOT ECMA-262): `Buffer` constructor + statics + prototype methods —
    /// `native_name` selects which (spec 101).
    buffer_fn,
    /// HOST (Node axis, spec 103 — NOT ECMA-262): the `events` core module — the `EventEmitter`
    /// constructor + its prototype methods (`on`/`once`/`emit`/…). `native_name` selects which.
    /// Per-instance listener state lives on a hidden own prop of the instance. Inert on the Test262
    /// path (host core modules are not requireable there).
    events_method,
    /// HOST (Node axis, spec 100 — NOT ECMA-262): a `process` method — `native_name` selects
    /// `cwd`/`exit`/`nextTick`/`stdoutWrite`/`stderrWrite`. Built + installed by `host_setup`; inert on
    /// the Test262 path (host globals are not installed there).
    process_method,
    /// HOST (Node axis, spec 102 — NOT ECMA-262): the per-module `require(specifier)` function. Each
    /// module's `require` is a fresh object carrying its directory as a hidden own `"%dir%"` property
    /// (`callNative` receives `func`, so the dir is read off the receiver). Resolves a specifier to a
    /// core module / file path and returns its cached exports. Inert on the Test262 path.
    require_fn,
    /// HOST (Node axis, spec 102 — NOT ECMA-262): a core-module method (`path`/`fs`/`os`) — the owning
    /// module is selected by a hidden own `"%mod%"` property and the method by `native_name`. Built once
    /// per run by `host_require`; inert on the Test262 path.
    core_module_fn,
    /// HOST (Node axis, spec 103 — NOT ECMA-262): a `util` core-module method (format/inspect/
    /// promisify/inherits/deprecate/types.*) — selected by `native_name`. Inert on the Test262 path.
    util_method,
    /// HOST (Node axis, spec 105 — NOT ECMA-262): a `querystring` core-module method (parse/decode/
    /// stringify/encode/escape/unescape) — selected by `native_name`. Inert on the Test262 path.
    qs_method,
    /// HOST (Node axis, spec 106 — NOT ECMA-262): a `timers` / `timers/promises` core-module method
    /// (`setTimeout`/`setImmediate`/`setInterval` promisified, `scheduler.wait`/`yield`, the legacy
    /// `enroll`/`unenroll`/`active` stubs, and the internal promise-settling timer callback) — selected
    /// by `native_name` + hidden own state. Inert on the Test262 path.
    timers_method,
    /// HOST (Node axis, spec 104 — NOT ECMA-262): an `assert` core-module method (ok/equal/
    /// strictEqual/deepStrictEqual/throws/rejects/match/... + the `AssertionError` constructor and
    /// the rejects/doesNotReject promise-reaction natives) — selected by `native_name` / hidden
    /// per-instance state. Inert on the Test262 path (host core modules are not requireable there).
    assert_method,
    /// HOST (Node axis, spec 103 — NOT ECMA-262): the WHATWG `URL`/`URLSearchParams` + `TextEncoder`/
    /// `TextDecoder`. Family via a hidden own `"%kind%"`, operation via `native_name`. Inert on Test262.
    url_method,
    /// HOST (Node axis, spec 106): `node:test` runner method (test/describe/it/hook/skip/todo/mock).
    nodetest_method,
    /// HOST (Node axis, spec 106): `vm` module fns + `vm.Script` (Script ctor is constructible).
    vm_method,
    /// HOST (Node axis, spec 107): `net` module — statics (`isIP`/`createServer`/`connect`/`Socket`/
    /// `Server`) and Socket/Server instance methods (native_name prefixed `s.`/`v.` to disambiguate).
    /// Backed by libxev TCP; dispatched in `host_net.zig`.
    net_method,
    /// HOST (Node axis, spec 108): minimal `crypto` — `randomBytes`/`randomFillSync`/`randomUUID`/
    /// `getRandomValues`. Dispatched in `host_crypto.zig`.
    crypto_method,
    /// HOST (Node axis): the `stream` module — `Readable`/`Writable`/`Duplex`/`Transform`/
    /// `PassThrough` constructors + their prototype methods (`push`/`read`/`pipe`/`write`/`end`/...).
    /// `native_name` selects the constructor / prefixed instance method / deferred trampoline.
    /// Dispatched in `host_stream.zig`. Inert on the Test262 path.
    stream_method,
    /// HOST (Node axis): the `string_decoder` module — the `StringDecoder` constructor + its
    /// `write`/`end` prototype methods. `native_name` selects which; per-instance encoding + buffered
    /// partial bytes live on hidden own props. Dispatched in `host_string_decoder.zig`. Inert on Test262.
    string_decoder_method,
    /// HOST (Node axis): the `http` module — `createServer`/`Server`/`ServerResponse`/`IncomingMessage`
    /// constructors + their prototype methods + an internal connection trampoline. `native_name` selects
    /// which. Built on the `net` module. Dispatched in `host_http.zig`. Inert on the Test262 path.
    http_method,
    /// HOST (Node/WHATWG): the global `Headers` class. Dispatched in `host_headers.zig`. Inert on Test262.
    headers_method,
    /// HOST (WHATWG fetch): the global `Response`/`Request` classes (Body mixin). Dispatched in
    /// `host_fetch_body.zig`. Inert on Test262.
    fetch_body_method,
    /// HOST (WHATWG): the global `AbortController`/`AbortSignal`. Dispatched in `host_abort.zig`. Inert on Test262.
    abort_method,
    /// §10.4.4.6 %ThrowTypeError% — the unique per-realm function that unconditionally throws a
    /// TypeError. Used as the poison `get`/`set` for `callee` (and historically `caller`) on a
    /// strict / unmapped arguments object. Never returns normally.
    throw_type_error,
    // §25.1 ArrayBuffer — the constructor, the prototype getters, the `slice` method, and the
    // `isView`/`Symbol.species` statics. Phase 1 wires the constructor + `byteLength` getter; the
    // rest are filled by Phase 2-A (same ids, dispatched by `native_name`).
    array_buffer_ctor, // new ArrayBuffer(length[, options])
    array_buffer_proto_getter, // get ArrayBuffer.prototype.<byteLength|maxByteLength|resizable|detached> (native_name selects)
    array_buffer_method, // ArrayBuffer.prototype.<slice|resize|transfer|...> (native_name selects) — Phase 2-A
    array_buffer_static, // ArrayBuffer.<isView> (native_name selects) — Phase 2-A
    // §23.2 TypedArray — the %TypedArray% abstract super, the 11 concrete constructors, the prototype
    // getters/methods, and the `from`/`of`/`Symbol.species` statics. Phase 2-B owns these (ids reserved
    // here so the dispatch table is stable). `native_name` selects the concrete type / method.
    typed_array_ctor, // a concrete `new Int8Array(...)` etc. (native_name = the constructor name)
    typed_array_abstract_ctor, // %TypedArray%() — abstract (direct construction throws)
    typed_array_proto_getter, // get %TypedArray%.prototype.<buffer|byteLength|byteOffset|length|[Symbol.toStringTag]>
    typed_array_method, // %TypedArray%.prototype.<native_name>
    typed_array_static, // %TypedArray%.<from|of>
    // §25.3 DataView — the constructor, the prototype getters, and the getXxx/setXxx accessors.
    // Phase 2-C owns these. `native_name` selects buffer/byteLength/byteOffset / the get/set variant.
    data_view_ctor, // new DataView(buffer[, byteOffset[, byteLength]])
    data_view_proto_getter, // get DataView.prototype.<buffer|byteLength|byteOffset>
    data_view_method, // DataView.prototype.<getInt8|setUint16|...>
    // §21.4 Date — the constructor (new + plain-call), the statics (now/parse/UTC), and the prototype
    // getter/setter/conversion methods. `native_name` selects the concrete method within each family.
    date_ctor, // new Date(...) / Date(...) (plain call → current-time string)
    date_static, // Date.<now|parse|UTC>
    date_proto_method, // Date.prototype.<getTime|setFullYear|toISOString|[Symbol.toPrimitive]|...>
    // The minimal Test262 host object `$262` (NOT ECMA-262): only `detachArrayBuffer`, which the
    // suite uses to drive detached-buffer behavior (an in-scope ECMAScript semantic). Permitted as a
    // test harness, like the module loader; NOT a general Node host API. `native_name` selects.
    dollar262_method, // $262.detachArrayBuffer(buffer)
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
    /// §13.3.7 an arrow lexically captures the enclosing [[ThisBindingStatus]] cell (arrows only; null
    /// otherwise), so `this`/`super()` inside it observes the enclosing constructor's TDZ state.
    captured_this_init_cell: ?*bool = null,
    /// §13.3.5 / §9.2.5 an arrow lexically captures the enclosing [[HomeObject]] (arrows only), so
    /// `super.x` / `super(...)` inside it resolve against the defining method/constructor even when the
    /// arrow is invoked from an unrelated dynamic context. Null for ordinary functions.
    captured_home_object: ?*Object = null,
    /// §9.2 an arrow lexically captures the enclosing [[PrivateEnvironment]] (arrows only), so a
    /// private reference inside it resolves against the defining class even when the arrow is invoked
    /// from an unrelated context. Null for ordinary functions (they install their own `private_env`).
    captured_private_env: ?*PrivateEnv = null,
    /// §15.7.14: a class constructor carries its instance FieldDefinitions; [[Construct]]
    /// (`evalNew`) runs each initializer on the new instance (with `this` = instance) before the
    /// constructor body. Empty for ordinary functions and for non-constructor class methods.
    fields: []const FieldInit = &.{},
    /// §15.7: a class constructor's instance PrivateName elements (fields/methods/accessors), added
    /// to each `new` instance's private slot (the brand) before the field initializers / body run.
    /// Empty for ordinary functions and non-constructor methods. (Static private members are
    /// installed directly on the constructor object at class-definition time, not here.)
    private_elements: []const PrivateElement = &.{},
    /// §9.2 the [[PrivateEnvironment]] captured at this function's definition — the chain of in-scope
    /// Private Names. Set for any function lexically inside a ClassBody (methods, accessors, the
    /// constructor, and instance/static field initializers via the synthesized field-init context);
    /// null otherwise. Re-installed while the body runs so `this.#x` resolves to the right Private
    /// Name (mirrors `home_object`). An arrow captures the enclosing one lexically.
    private_env: ?*PrivateEnv = null,
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
    /// §15.7.14: a SYNTHESIZED default constructor (the class has no explicit `constructor`). A default
    /// derived constructor performs an implicit `super(...args)`; an EXPLICIT empty `constructor(){}`
    /// does NOT (so it leaves `this` uninitialized → ReferenceError). Distinguishes the two (both have
    /// an empty body) for the implicit-super path in `constructNT`.
    is_default_ctor: bool = false,
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
    /// §15.7.14: a PRIVATE instance field (`#x = …`). When true, `key` is the unique Private Name slot
    /// key and the field installs into the instance's private slots (adding its brand AT this point in
    /// declaration order — so a forward `this.#x` reference earlier in the field list throws §13.15
    /// TypeError). `key_symbol` is always null for a private field. False for an ordinary public field.
    is_private: bool = false,
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
    key: []const u8, // the unique per-class-evaluation slot key (see PrivateName.key)
    spelling: []const u8 = "", // the source `#name` (for diagnostics / name property)
    kind: enum { field, method, get, set },
    init: ?*const ast.Node = null, // field initializer
    func: ?*Object = null, // method body / getter / setter (shared, [[HomeObject]] set)
};

/// §8.2.x / §6.2.12 Private Name. Each evaluation of a ClassDefinition mints a FRESH Private Name per
/// declared private element (`#x`, `#m`, `get/set #a`), so two evaluations of the SAME class source —
/// e.g. a class returned twice from a factory, or a class nested in another — carry DISTINCT Private
/// Names even though they share the `#x` spelling. The interpreter keys an object's private slots by
/// `key` (a unique interned string per Private Name), so a `#x` minted by class A is never found on an
/// instance branded by class B's `#x` (→ the §13.15 PrivateFieldGet/Set "no entry" TypeError).
pub const PrivateName = struct {
    /// The source spelling (`#x`, `#` included) — for the §15.7.14 name property and diagnostics.
    spelling: []const u8,
    /// The UNIQUE interned slot key for this Private Name (the spelling plus a per-evaluation counter
    /// suffix). Distinct across class evaluations even for the same spelling; used as the object
    /// private-slot map key everywhere via ResolvePrivateIdentifier.
    key: []const u8,
};

/// §9.2 PrivateEnvironment Record — the lexical chain of in-scope Private Names. Each ClassBody
/// evaluation pushes one frame holding its declared Private Names; `super.#x` / `obj.#x` /
/// `#x in obj` resolve a spelling to the INNERMOST matching Private Name (§8.2.x
/// ResolvePrivateIdentifier), so an inner class's `#x` SHADOWS an outer one. A method/field
/// initializer/constructor captures the PrivateEnvironment active at its class definition and
/// re-installs it while running (mirrors [[HomeObject]]); a direct `eval` inherits the caller's.
pub const PrivateEnv = struct {
    parent: ?*PrivateEnv = null,
    names: []const *PrivateName,

    /// §8.2.x ResolvePrivateIdentifier — innermost-out lookup of `spelling` (`#x`) in the chain.
    pub fn resolve(self: *const PrivateEnv, spelling: []const u8) ?*PrivateName {
        var cur: ?*const PrivateEnv = self;
        while (cur) |pe| : (cur = pe.parent) {
            for (pe.names) |pn| if (std.mem.eql(u8, pn.spelling, spelling)) return pn;
        }
        return null;
    }
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
