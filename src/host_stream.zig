//! HOST runtime (Node axis — NOT ECMA-262): a pragmatic subset of Node's `stream` core module.
//! `require('stream')` / `require('node:stream')` → `{ Readable, Writable, Duplex, Transform,
//! PassThrough, Stream }`. HOST-only: streams emit asynchronously and are only useful from `ljs run`
//! (which drives the event loop / nextTick queue); never on the Test262 path.
//!
//! Every stream instance is an EventEmitter — its `[[Prototype]]` chains into
//! `%EventEmitter.prototype%` (from the `events` core module), so `.on`/`.once`/`.emit`/
//! `.removeListener` resolve through the prototype chain. Stream-specific methods live on the
//! per-class prototypes below them.
//!
//! ## Timing model (Node-faithful, simplified)
//! Node never emits `'data'`/`'end'`/`'finish'` synchronously from `push`/`write`/`end`; it defers
//! to `process.nextTick` / microtasks. We do the same via the interpreter's `next_tick_queue`
//! (drained by the host loop). So `r.push(x); r.on('data', f)` works: the buffered chunk is flushed
//! on the next tick, after the listener is attached.
//!
//! ## Per-instance state
//! All state is kept as hidden own properties on the JS instance (created lazily), so subclasses
//! (`class Foo extends stream.Readable`) share the same machinery via `super(opts)`:
//!   "%rbuf%"    Array  — buffered readable chunks awaiting flush (Readable side)
//!   "%flowing%" bool   — flowing mode (a 'data' listener was attached)
//!   "%rended%"  bool   — `push(null)` seen (readable EOF)
//!   "%endEmit%" bool   — the 'end' event has already fired
//!   "%readFn%"  fn?    — the `read` option (Readable `_read`), currently advisory
//!   "%writeFn%" fn?    — the `write` option / `_write` impl (Writable)
//!   "%finalFn%" fn?    — the `final` option (Writable, optional)
//!   "%transFn%" fn?    — the `transform` option (Transform)
//!   "%flushFn%" fn?    — the `flush` option (Transform, optional)
//!   "%wended%"  bool   — `end()` was called (Writable)
//!   "%finEmit%" bool   — the 'finish' event has already fired
//!   "%passthr%" bool   — this is a PassThrough/Transform (push written chunks to readable side)
const std = @import("std");
const Value = @import("value.zig").Value;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const host_require = @import("host_require.zig");
const host_process = @import("host_process.zig");

const RBUF_KEY = "%rbuf%";
const FLOWING_KEY = "%flowing%";
const RENDED_KEY = "%rended%";
const ENDEMIT_KEY = "%endEmit%";
const READFN_KEY = "%readFn%";
const WRITEFN_KEY = "%writeFn%";
const FINALFN_KEY = "%finalFn%";
const TRANSFN_KEY = "%transFn%";
const FLUSHFN_KEY = "%flushFn%";
const WENDED_KEY = "%wended%";
const FINEMIT_KEY = "%finEmit%";
const TRANSFORM_KEY = "%transform%"; // marks a Transform/PassThrough (written → transform → readable)

// ── module construction ────────────────────────────────────────────────────────────

/// Build the `stream` core-module exports: `{ Readable, Writable, Duplex, Transform, PassThrough,
/// Stream }`. Each class is constructible (`new stream.Readable(opts)`) and subclassable; its
/// prototype carries the class methods and chains into `%EventEmitter.prototype%`.
pub fn build(self: *Interpreter) EvalError!*Object {
    const arena = self.arena;
    const ee_proto = try eventEmitterProto(self);

    // Stream.prototype — the legacy base CLASS, chaining EventEmitter. The concrete classes inherit
    // FROM it (Node: Stream extends EventEmitter; Readable/Writable extend Stream), so
    // `new Readable() instanceof Stream` is true (node-fetch's Body relies on `body instanceof Stream`).
    const stream_proto = try Object.create(arena, ee_proto);
    try defineMethod(self, stream_proto, "pipe", "r.pipe");

    // Readable.prototype.
    const readable_proto = try Object.create(arena, stream_proto);
    for ([_][2][]const u8{
        .{ "push", "r.push" },     .{ "read", "r.read" },
        .{ "pipe", "r.pipe" },     .{ "pause", "r.pause" },
        .{ "resume", "r.resume" }, .{ "_read", "r._read" },
        .{ "unpipe", "r.unpipe" }, .{ "setEncoding", "r.setEncoding" },
        .{ "on", "r.on" },         .{ "addListener", "r.on" },
    }) |pair| try defineMethod(self, readable_proto, pair[0], pair[1]);
    const readable_ctor = try makeCtor(self, "Readable", readable_proto);

    // Writable.prototype.
    const writable_proto = try Object.create(arena, stream_proto);
    for ([_][2][]const u8{
        .{ "write", "w.write" },   .{ "end", "w.end" },
        .{ "_write", "w._write" }, .{ "cork", "w.cork" },
        .{ "uncork", "w.uncork" }, .{ "destroy", "w.destroy" },
    }) |pair| try defineMethod(self, writable_proto, pair[0], pair[1]);
    const writable_ctor = try makeCtor(self, "Writable", writable_proto);

    // Duplex.prototype — inherits the readable side and copies the writable methods onto it, so a
    // Duplex has BOTH the Readable and the Writable surface (Node's Duplex is exactly this).
    const duplex_proto = try Object.create(arena, readable_proto);
    for ([_][2][]const u8{
        .{ "write", "w.write" },   .{ "end", "w.end" },
        .{ "_write", "w._write" }, .{ "cork", "w.cork" },
        .{ "uncork", "w.uncork" }, .{ "destroy", "w.destroy" },
    }) |pair| try defineMethod(self, duplex_proto, pair[0], pair[1]);
    const duplex_ctor = try makeCtor(self, "Duplex", duplex_proto);

    // Transform.prototype — a Duplex whose written chunks pass through `_transform` to the readable
    // side. Adds `_transform`.
    const transform_proto = try Object.create(arena, duplex_proto);
    try defineMethod(self, transform_proto, "_transform", "t._transform");
    const transform_ctor = try makeCtor(self, "Transform", transform_proto);

    // PassThrough.prototype — a Transform with an identity transform.
    const passthrough_proto = try Object.create(arena, transform_proto);
    const passthrough_ctor = try makeCtor(self, "PassThrough", passthrough_proto);

    // In Node `require('stream')` IS the legacy `Stream` base CLASS (a function with a `.prototype`
    // inheriting EventEmitter, plus a `.pipe`), and the concrete classes hang off it as properties —
    // so `util.inherits(X, require('stream'))` (e.g. `send`'s SendStream) works. Return that ctor as
    // the module, not a plain object. `stream_proto` was built above so the concrete classes inherit it.
    const stream_ctor = try makeCtor(self, "Stream", stream_proto);
    try stream_ctor.defineData("Readable", .{ .object = readable_ctor }, true, false, true);
    try stream_ctor.defineData("Writable", .{ .object = writable_ctor }, true, false, true);
    try stream_ctor.defineData("Duplex", .{ .object = duplex_ctor }, true, false, true);
    try stream_ctor.defineData("Transform", .{ .object = transform_ctor }, true, false, true);
    try stream_ctor.defineData("PassThrough", .{ .object = passthrough_ctor }, true, false, true);
    try stream_ctor.defineData("Stream", .{ .object = stream_ctor }, true, false, true); // `stream.Stream === stream`
    return stream_ctor;
}

/// `%EventEmitter.prototype%` from the (cached) `events` core module.
fn eventEmitterProto(self: *Interpreter) EvalError!?*Object {
    const ee = try host_require.loadCoreModulePub(self, "events");
    if (ee.normal == .object) {
        if (ee.normal.object.get("prototype")) |p| if (p == .object) return p.object;
    }
    return self.objectProto();
}

/// Create a `.stream_method` native constructor named `name` with `proto` as its `.prototype`.
fn makeCtor(self: *Interpreter, name: []const u8, proto: *Object) EvalError!*Object {
    const ctor = try Object.createNative(self.arena, .stream_method, name);
    ctor.prototype = self.functionProto();
    try ctor.defineData("name", .{ .string = name }, false, false, true);
    try ctor.defineData("prototype", .{ .object = proto }, false, false, false);
    try proto.defineData("constructor", .{ .object = ctor }, true, false, true);
    return ctor;
}

fn defineMethod(self: *Interpreter, target: *Object, key: []const u8, native_name: []const u8) EvalError!void {
    const fn_obj = try Object.createNative(self.arena, .stream_method, native_name);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("name", .{ .string = key }, false, false, true);
    try target.defineData(key, .{ .object = fn_obj }, true, false, true);
}

// ── dispatch ───────────────────────────────────────────────────────────────────────

/// Dispatch a `.stream_method` native by `func.native_name`. Constructors are bare class names;
/// instance methods are prefixed `r.` (Readable), `w.` (Writable), `t.` (Transform).
pub fn method(self: *Interpreter, func: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const name = func.native_name;
    const eq = std.mem.eql;

    // ── constructors ──
    if (eq(u8, name, "Readable")) return readableCtor(self, this_val, args);
    if (eq(u8, name, "Writable")) return writableCtor(self, this_val, args);
    if (eq(u8, name, "Duplex")) return duplexCtor(self, this_val, args);
    if (eq(u8, name, "Transform")) return transformCtor(self, this_val, args);
    if (eq(u8, name, "PassThrough")) return transformCtor(self, this_val, args);

    // ── instance (prototype) methods, prefixed by class ──
    if (std.mem.startsWith(u8, name, "r.")) {
        if (this_val != .object) return self.throwError("TypeError", "Stream method called on non-object");
        return readableMethod(self, this_val.object, name[2..], this_val, args);
    }
    if (std.mem.startsWith(u8, name, "w.")) {
        if (this_val != .object) return self.throwError("TypeError", "Stream method called on non-object");
        return writableMethod(self, this_val.object, name[2..], this_val, args);
    }
    if (std.mem.startsWith(u8, name, "t.")) {
        if (this_val != .object) return self.throwError("TypeError", "Stream method called on non-object");
        return transformMethod(name[2..], this_val);
    }

    // ── prefix-less trampoline natives (nextTick targets / pipe listeners / write-done) — the
    //    receiver is carried on the native's hidden "%self%" prop, not `this_val`.
    return trampoline(self, func, args);
}

// ── state helpers ────────────────────────────────────────────────────────────────

fn getBool(js: *Object, key: []const u8) bool {
    if (js.get(key)) |v| if (v == .boolean) return v.boolean;
    return false;
}

fn setBool(js: *Object, key: []const u8, val: bool) EvalError!void {
    try js.defineData(key, .{ .boolean = val }, true, false, false);
}

fn getFn(js: *Object, key: []const u8) ?*Object {
    if (js.get(key)) |v| if (v == .object and v.object.kind == .function) return v.object;
    return null;
}

fn setFn(js: *Object, key: []const u8, fn_obj: *Object) EvalError!void {
    try js.defineData(key, .{ .object = fn_obj }, true, false, false);
}

/// The readable buffer Array for `js`, creating it (lazily) if absent.
fn ensureRBuf(self: *Interpreter, js: *Object) EvalError!*Object {
    if (js.get(RBUF_KEY)) |v| if (v == .object) return v.object;
    const arr = Object.createArray(self.arena, self.arrayProto()) catch return error.OutOfMemory;
    try js.defineData(RBUF_KEY, .{ .object = arr }, true, false, false);
    return arr;
}

/// Read an options-object property `key` and, if it's a function, store it under `state_key`.
fn captureFnOpt(js: *Object, opts: Value, key: []const u8, state_key: []const u8) EvalError!void {
    if (opts != .object) return;
    if (opts.object.get(key)) |v| if (v == .object and v.object.kind == .function)
        try setFn(js, state_key, v.object);
}

// ── nextTick scheduling ─────────────────────────────────────────────────────────────

/// Schedule `cb(args...)` to run on the next event-loop tick (Node defers stream events). `cb` and
/// `args` must be arena-stable. No-op if `cb` isn't callable.
fn scheduleTick(self: *Interpreter, cb: *Object, tick_args: []const Value) EvalError!void {
    const dup = self.arena.dupe(Value, tick_args) catch return error.OutOfMemory;
    self.next_tick_queue.append(self.arena, .{ .callback = cb, .args = dup }) catch return error.OutOfMemory;
}

/// A `.stream_method` native bound to a specific receiver + op, used as a deferred (nextTick)
/// trampoline. We reuse the native machinery: the trampoline native carries its receiver via a hidden
/// "%self%" prop and its operation via `native_name` ("flush"/"emitEnd"/"emitFinish").
fn makeTrampoline(self: *Interpreter, op: []const u8, receiver: *Object) EvalError!*Object {
    const fn_obj = try Object.createNative(self.arena, .stream_method, op);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("%self%", .{ .object = receiver }, true, false, false);
    return fn_obj;
}

// ── Readable ─────────────────────────────────────────────────────────────────────

fn readableCtor(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (self.native_new_target == .undefined or this_val != .object) return .{ .normal = .undefined };
    const js = this_val.object;
    const opts = if (args.len > 0) args[0] else .undefined;
    _ = try ensureRBuf(self, js);
    try captureFnOpt(js, opts, "read", READFN_KEY);
    return .{ .normal = this_val };
}

fn readableMethod(self: *Interpreter, js: *Object, op: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    const eq = std.mem.eql;
    if (eq(u8, op, "on") or eq(u8, op, "addListener")) {
        // Delegate to EventEmitter.prototype.on, then auto-resume on a 'data' listener — Node switches a
        // paused stream to flowing the moment a 'data' handler is attached (node-fetch relies on this).
        if (try eventEmitterProto(self)) |eep| {
            if (eep.get("on")) |onf| {
                if (onf == .object) _ = try self.callFunction(onf.object, args, this_val);
            }
        }
        if (args.len > 0 and args[0] == .string and eq(u8, args[0].string, "data")) {
            try setBool(js, FLOWING_KEY, true);
            try scheduleFlush(self, js);
        }
        return .{ .normal = this_val };
    }
    if (eq(u8, op, "push")) return rPush(self, js, this_val, args);
    if (eq(u8, op, "read")) return rRead(self, js, args);
    if (eq(u8, op, "pipe")) return rPipe(self, js, this_val, args);
    if (eq(u8, op, "resume")) return rResume(self, js, this_val);
    if (eq(u8, op, "setEncoding")) return .{ .normal = this_val }; // accepted, no-op (we keep chunks raw)
    if (eq(u8, op, "pause")) {
        try setBool(js, FLOWING_KEY, false);
        return .{ .normal = this_val };
    }
    if (eq(u8, op, "_read")) return .{ .normal = .undefined }; // default no-op
    if (eq(u8, op, "unpipe")) return .{ .normal = this_val };
    return .{ .normal = .undefined };
}

/// `readable.push(chunk)` — `null` signals EOF. Buffers the chunk; if flowing, schedules a flush.
fn rPush(self: *Interpreter, js: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const chunk = if (args.len > 0) args[0] else .undefined;
    if (chunk == .null) {
        // EOF.
        try setBool(js, RENDED_KEY, true);
        try scheduleFlush(self, js);
        return .{ .normal = .{ .boolean = false } };
    }
    if (chunk == .undefined) return .{ .normal = .{ .boolean = true } };
    const buf = try ensureRBuf(self, js);
    try buf.arraySet(self.arena, buf.array_length, chunk);
    // Always schedule a flush; the tick re-checks effective-flowing (an explicit resume / pipe, OR an
    // attached 'data' listener — Node switches a stream to flowing the moment a 'data' listener lands).
    try scheduleFlush(self, js);
    _ = this_val;
    return .{ .normal = .{ .boolean = true } };
}

/// A stream is effectively flowing if `pause`/`resume`/`pipe` set the flag, OR (Node semantics) a
/// `'data'` listener has been attached. Queried by calling the JS `listenerCount('data')`.
fn isFlowing(self: *Interpreter, js: *Object) bool {
    if (getBool(js, FLOWING_KEY)) return true;
    const lc = js.get("listenerCount") orelse return false;
    if (lc != .object or lc.object.kind != .function) return false;
    const c = self.callFunction(lc.object, &.{.{ .string = "data" }}, .{ .object = js }) catch return false;
    if (c == .normal and c.normal == .number) return c.normal.number > 0;
    return false;
}

/// Schedule a flush of the readable buffer on the next tick (idempotent enough — a flush drains all
/// currently-buffered chunks, so multiple schedules just find an empty buffer).
fn scheduleFlush(self: *Interpreter, js: *Object) EvalError!void {
    const tramp = try makeTrampoline(self, "flush", js);
    try scheduleTick(self, tramp, &.{});
}

/// Drain the readable buffer to 'data' listeners (flowing mode). After draining, if EOF was seen and
/// the buffer is empty, schedule the 'end' emission.
fn rFlush(self: *Interpreter, js: *Object) EvalError!Completion {
    if (!isFlowing(self, js)) return .{ .normal = .undefined };
    const buf = (try ensureRBuf(self, js));
    // Emit each buffered chunk as a 'data' event, in order. A listener may push more / pause; re-check
    // flowing each iteration.
    while (buf.array_length > 0 and isFlowing(self, js)) {
        const chunk = buf.arrayGet(0);
        // shift the buffer left by one.
        var i: usize = 0;
        while (i + 1 < buf.array_length) : (i += 1) try buf.arraySet(self.arena, i, buf.arrayGet(i + 1));
        try buf.arraySetLen(buf.array_length - 1);
        const c = try host_process.emitEvent(self, .{ .object = js }, "data", &.{chunk});
        if (c == .throw) return c;
    }
    // EOF reached and fully drained → schedule 'end'.
    if (getBool(js, RENDED_KEY) and buf.array_length == 0 and !getBool(js, ENDEMIT_KEY)) {
        const tramp = try makeTrampoline(self, "emitEnd", js);
        try scheduleTick(self, tramp, &.{});
    }
    return .{ .normal = .undefined };
}

fn rEmitEnd(self: *Interpreter, js: *Object) EvalError!Completion {
    if (getBool(js, ENDEMIT_KEY)) return .{ .normal = .undefined };
    const buf = try ensureRBuf(self, js);
    if (buf.array_length > 0) return .{ .normal = .undefined }; // not actually drained yet
    try setBool(js, ENDEMIT_KEY, true);
    const c = try host_process.emitEvent(self, .{ .object = js }, "end", &.{});
    if (c == .throw) return c;
    return .{ .normal = .undefined };
}

/// Enter flowing mode (a 'data' listener implies this in Node). Schedules a flush of any buffered
/// chunks.
fn rResume(self: *Interpreter, js: *Object, this_val: Value) EvalError!Completion {
    try setBool(js, FLOWING_KEY, true);
    try scheduleFlush(self, js);
    return .{ .normal = this_val };
}

/// `readable.read()` — paused-mode pull: returns the next buffered chunk, or null if none.
fn rRead(self: *Interpreter, js: *Object, args: []const Value) EvalError!Completion {
    _ = args;
    const buf = try ensureRBuf(self, js);
    if (buf.array_length == 0) {
        if (getBool(js, RENDED_KEY) and !getBool(js, ENDEMIT_KEY)) {
            const tramp = try makeTrampoline(self, "emitEnd", js);
            try scheduleTick(self, tramp, &.{});
        }
        return .{ .normal = .null };
    }
    const chunk = buf.arrayGet(0);
    var i: usize = 0;
    while (i + 1 < buf.array_length) : (i += 1) try buf.arraySet(self.arena, i, buf.arrayGet(i + 1));
    try buf.arraySetLen(buf.array_length - 1);
    return .{ .normal = chunk };
}

/// `readable.pipe(dest)` — for each 'data' chunk write to `dest`; on 'end' call `dest.end()`. Returns
/// `dest`. Implemented by attaching JS-level listeners that call dest.write / dest.end.
fn rPipe(self: *Interpreter, js: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const dest = if (args.len > 0) args[0] else .undefined;
    if (dest != .object) return self.throwError("TypeError", "pipe destination must be a stream");

    // Build a 'data' listener: a trampoline that writes chunk → dest.write(chunk).
    const on_data = try makePipeListener(self, "pipeData", dest.object);
    const on_end = try makePipeListener(self, "pipeEnd", dest.object);

    // Attach via the JS `on` method so the standard EventEmitter store is used; attaching 'data'
    // switches us to flowing.
    try jsOn(self, js, "data", on_data);
    try jsOn(self, js, "end", on_end);
    try setBool(js, FLOWING_KEY, true);
    try scheduleFlush(self, js);
    _ = this_val;
    return .{ .normal = dest };
}

/// A pipe listener is a `.stream_method` native carrying its `dest` via "%self%"; `native_name` is
/// "pipeData" (writes the received chunk) or "pipeEnd" (calls dest.end()).
fn makePipeListener(self: *Interpreter, op: []const u8, dest: *Object) EvalError!*Object {
    const fn_obj = try Object.createNative(self.arena, .stream_method, op);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("%self%", .{ .object = dest }, true, false, false);
    return fn_obj;
}

/// Register `listener` for `event` on `js` via its JS `on` method.
fn jsOn(self: *Interpreter, js: *Object, event: []const u8, listener: *Object) EvalError!void {
    const on_v = js.get("on") orelse return;
    if (on_v != .object) return;
    _ = try self.callFunction(on_v.object, &.{ .{ .string = event }, .{ .object = listener } }, .{ .object = js });
}

// ── Writable ─────────────────────────────────────────────────────────────────────

fn writableCtor(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (self.native_new_target == .undefined or this_val != .object) return .{ .normal = .undefined };
    const js = this_val.object;
    const opts = if (args.len > 0) args[0] else .undefined;
    try captureFnOpt(js, opts, "write", WRITEFN_KEY);
    try captureFnOpt(js, opts, "final", FINALFN_KEY);
    return .{ .normal = this_val };
}

fn writableMethod(self: *Interpreter, js: *Object, op: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    const eq = std.mem.eql;
    if (eq(u8, op, "write")) return wWrite(self, js, this_val, args);
    if (eq(u8, op, "end")) return wEnd(self, js, this_val, args);
    if (eq(u8, op, "_write")) return .{ .normal = .undefined }; // default no-op impl
    if (eq(u8, op, "cork") or eq(u8, op, "uncork")) return .{ .normal = .undefined };
    if (eq(u8, op, "destroy")) return .{ .normal = this_val };
    return .{ .normal = .undefined };
}

/// `writable.write(chunk[, enc][, cb])` — invokes the `_write` impl (the captured `write` option, or a
/// subclass `_write` method) with `(chunk, enc, done)`. Returns `true`. The optional `cb` is called
/// after the write completes.
fn wWrite(self: *Interpreter, js: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    if (getBool(js, WENDED_KEY)) {
        // write-after-end → emit 'error' (Node emits ERR_STREAM_WRITE_AFTER_END). We surface it.
        const err = try makeError(self, "write after end");
        const c = try host_process.emitEvent(self, .{ .object = js }, "error", &.{err});
        if (c == .throw) return c;
        return .{ .normal = .{ .boolean = false } };
    }
    const chunk = if (args.len > 0) args[0] else .undefined;
    // Detect trailing callback (last arg is a function) and encoding (a string before it).
    var enc: Value = .undefined;
    var cb: ?*Object = null;
    if (args.len >= 3) {
        enc = args[1];
        if (args[2] == .object and args[2].object.kind == .function) cb = args[2].object;
    } else if (args.len == 2) {
        if (args[1] == .object and args[1].object.kind == .function) cb = args[1].object else enc = args[1];
    }
    try doWrite(self, js, this_val, chunk, enc, cb);
    return .{ .normal = .{ .boolean = true } };
}

/// Invoke the stream's write impl for one chunk. For a Transform/PassThrough, the impl pushes the
/// (optionally transformed) chunk onto its OWN readable side. For a plain Writable, the impl is the
/// captured `write` option / the subclass `_write` method.
fn doWrite(self: *Interpreter, js: *Object, this_val: Value, chunk: Value, enc: Value, cb: ?*Object) EvalError!void {
    // A `done(err)` callback the impl calls when finished — wired to the user `cb` if present.
    const done = try makeDone(self, js, cb);
    const enc_v: Value = if (enc == .undefined) .{ .string = "buffer" } else enc;

    if (getBool(js, TRANSFORM_KEY)) {
        // Transform / PassThrough: run `_transform(chunk, enc, cb)` if provided, else identity-push.
        if (getFn(js, TRANSFN_KEY)) |tf| {
            const c = try self.callFunction(tf, &.{ chunk, enc_v, .{ .object = done } }, this_val);
            if (c == .throw) {
                const ec = try host_process.emitEvent(self, .{ .object = js }, "error", &.{c.throw});
                _ = ec;
            }
        } else {
            // identity: push straight to the readable side, then signal done.
            _ = try rPush(self, js, this_val, &.{chunk});
            _ = try self.callFunction(done, &.{}, .undefined);
        }
        return;
    }

    // Plain Writable: prefer the captured `write` option, else a subclass `_write` method.
    const impl: ?*Object = getFn(js, WRITEFN_KEY) orelse blk: {
        if (js.get("_write")) |wv| if (wv == .object and wv.object.kind == .function) break :blk wv.object;
        break :blk null;
    };
    if (impl) |f| {
        const c = try self.callFunction(f, &.{ chunk, enc_v, .{ .object = done } }, this_val);
        if (c == .throw) {
            const ec = try host_process.emitEvent(self, .{ .object = js }, "error", &.{c.throw});
            _ = ec;
        }
    } else {
        // No impl → just signal completion.
        _ = try self.callFunction(done, &.{}, .undefined);
    }
}

/// Build the `done` callback handed to a `_write`/`_transform` impl. When called, it invokes the
/// user write-callback (if any). Errors passed to `done(err)` are emitted as 'error'.
fn makeDone(self: *Interpreter, js: *Object, user_cb: ?*Object) EvalError!*Object {
    const fn_obj = try Object.createNative(self.arena, .stream_method, "writeDone");
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("%self%", .{ .object = js }, true, false, false);
    if (user_cb) |cb| try fn_obj.defineData("%cb%", .{ .object = cb }, true, false, false);
    return fn_obj;
}

fn makeError(self: *Interpreter, msg: []const u8) EvalError!Value {
    const err = Object.create(self.arena, self.errorProto("Error")) catch return error.OutOfMemory;
    err.error_data = true;
    try err.set("name", .{ .string = "Error" });
    try err.set("message", .{ .string = msg });
    return .{ .object = err };
}

/// `writable.end([chunk][, enc][, cb])` — writes a final chunk if given, marks ended, then schedules
/// the 'finish' emission.
fn wEnd(self: *Interpreter, js: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    if (getBool(js, WENDED_KEY)) return .{ .normal = this_val };
    // end(chunk) — write the trailing chunk first (unless it's a callback).
    if (args.len > 0 and args[0] != .undefined and
        !(args[0] == .object and args[0].object.kind == .function))
    {
        _ = try wWrite(self, js, this_val, args);
    }
    try setBool(js, WENDED_KEY, true);
    // For a Transform/PassThrough, ending the writable side also EOFs the readable side.
    if (getBool(js, TRANSFORM_KEY)) {
        try setBool(js, RENDED_KEY, true);
        try scheduleFlush(self, js);
    }
    // Schedule 'finish' on the next tick (after pending writes' done-callbacks).
    const tramp = try makeTrampoline(self, "emitFinish", js);
    try scheduleTick(self, tramp, &.{});
    return .{ .normal = this_val };
}

fn wEmitFinish(self: *Interpreter, js: *Object) EvalError!Completion {
    if (getBool(js, FINEMIT_KEY)) return .{ .normal = .undefined };
    try setBool(js, FINEMIT_KEY, true);
    // Run an optional `final` hook before 'finish' (best-effort, synchronous).
    if (getFn(js, FINALFN_KEY)) |ff| {
        const noop = try makeDone(self, js, null);
        const c = try self.callFunction(ff, &.{.{ .object = noop }}, .{ .object = js });
        if (c == .throw) return c;
    }
    const c = try host_process.emitEvent(self, .{ .object = js }, "finish", &.{});
    if (c == .throw) return c;
    return .{ .normal = .undefined };
}

// ── Duplex / Transform / PassThrough ─────────────────────────────────────────────

fn duplexCtor(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (self.native_new_target == .undefined or this_val != .object) return .{ .normal = .undefined };
    const js = this_val.object;
    const opts = if (args.len > 0) args[0] else .undefined;
    _ = try ensureRBuf(self, js);
    try captureFnOpt(js, opts, "read", READFN_KEY);
    try captureFnOpt(js, opts, "write", WRITEFN_KEY);
    try captureFnOpt(js, opts, "final", FINALFN_KEY);
    return .{ .normal = this_val };
}

fn transformCtor(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (self.native_new_target == .undefined or this_val != .object) return .{ .normal = .undefined };
    const js = this_val.object;
    const opts = if (args.len > 0) args[0] else .undefined;
    _ = try ensureRBuf(self, js);
    try setBool(js, TRANSFORM_KEY, true);
    try captureFnOpt(js, opts, "transform", TRANSFN_KEY);
    try captureFnOpt(js, opts, "flush", FLUSHFN_KEY);
    // Transform also accepts read/write/final options like a Duplex.
    try captureFnOpt(js, opts, "write", WRITEFN_KEY);
    try captureFnOpt(js, opts, "final", FINALFN_KEY);
    return .{ .normal = this_val };
}

fn transformMethod(op: []const u8, this_val: Value) EvalError!Completion {
    if (std.mem.eql(u8, op, "_transform")) return .{ .normal = .undefined }; // default no-op
    return .{ .normal = this_val };
}

// ── trampoline dispatch (writeDone / pipeData / pipeEnd / push helpers) ──────────────
//
// These reuse `.stream_method` but are reached as plain calls (not via the prototype map); the
// receiver is carried on a hidden "%self%" own prop. They're dispatched in `method` above via
// `func.native_name`, but since they have no `r.`/`w.`/`t.` prefix they fall through to here. We
// route them by checking the un-prefixed names in `method`. To keep `method` lean, handle them here:

/// Re-entry point for the prefix-less trampoline natives. Called from `method` before the
/// non-object guard for those that need the receiver from "%self%".
pub fn trampoline(self: *Interpreter, func: *Object, args: []const Value) EvalError!Completion {
    const name = func.native_name;
    const eq = std.mem.eql;
    const self_v = func.get("%self%") orelse return .{ .normal = .undefined };
    if (self_v != .object) return .{ .normal = .undefined };
    const recv = self_v.object;

    if (eq(u8, name, "flush")) return rFlush(self, recv);
    if (eq(u8, name, "emitEnd")) return rEmitEnd(self, recv);
    if (eq(u8, name, "emitFinish")) return wEmitFinish(self, recv);
    if (eq(u8, name, "pipeData")) {
        // dest.write(chunk)
        const chunk = if (args.len > 0) args[0] else .undefined;
        const w = recv.get("write") orelse return .{ .normal = .undefined };
        if (w == .object and w.object.kind == .function)
            _ = try self.callFunction(w.object, &.{chunk}, .{ .object = recv });
        return .{ .normal = .undefined };
    }
    if (eq(u8, name, "pipeEnd")) {
        // dest.end()
        const e = recv.get("end") orelse return .{ .normal = .undefined };
        if (e == .object and e.object.kind == .function)
            _ = try self.callFunction(e.object, &.{}, .{ .object = recv });
        return .{ .normal = .undefined };
    }
    if (eq(u8, name, "writeDone")) {
        // call the user write-callback, if any, with the (optional) error arg.
        if (func.get("%cb%")) |cv| if (cv == .object and cv.object.kind == .function) {
            const err: Value = if (args.len > 0) args[0] else .null;
            _ = try self.callFunction(cv.object, &.{err}, .undefined);
        };
        return .{ .normal = .undefined };
    }
    return .{ .normal = .undefined };
}
