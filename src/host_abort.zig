//! HOST runtime (Node axis — NOT ECMA-262): the WHATWG `AbortController` / `AbortSignal` globals,
//! used by `fetch()` (and Node's own APIs) for cancellation / timeout. Installed host-only as
//! GLOBALS (via `host_setup`); NEVER on the Test262 engine surface, so 0 Test262 regressions by
//! construction.
//!
//! Surface:
//!   • `new AbortController()` → `{ signal, abort([reason]) }`. `.abort()` flips the signal aborted
//!     (reason defaults to a DOMException-ish AbortError) and fires the signal's `'abort'` event ONCE.
//!   • `AbortSignal` — an EventTarget-shaped object: `.aborted`, `.reason`, `.throwIfAborted()`,
//!     `.addEventListener('abort', cb)` / `.removeEventListener` / `.dispatchEvent(ev)`, a settable
//!     `.onabort` handler, and the statics `AbortSignal.abort([reason])`, `AbortSignal.timeout(ms)`,
//!     `AbortSignal.any(signals)`. `new AbortSignal()` THROWS (spec: not constructible) — only the
//!     statics + a controller create signals.
//!
//! Mechanics (mirrors `host_url.zig`'s family-via-`"%kind%"` + `host_events.zig`'s listener registry):
//!   • Every ctor/method is a `.abort_method` native; `"%kind%"` selects the family
//!     (`ac_ctor`/`as_ctor`/`ac`/`as`/`as_static`/`timeout_cb`) and `native_name` the operation.
//!   • An AbortSignal instance carries hidden own slots: `"%aborted%"` (bool), `"%reason%"` (Value),
//!     `"%listeners%"` (a JS Array of the 'abort' listener functions), and `"%onabort%"` (the handler
//!     or undefined). An AbortController carries `"%signal%"` → its signal.
//!   • `AbortSignal.timeout(ms)` schedules a `timeout_cb` native on the interpreter timer queue (the
//!     same mechanism `setTimeout` uses); the callback aborts the captured signal with a TimeoutError.
//!     Inert on the Test262 path (no event loop runs there).
const std = @import("std");
const Value = @import("value.zig").Value;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const host_time = @import("host_time.zig");

const ABORTED_KEY = "%aborted%";
const REASON_KEY = "%reason%";
const LISTENERS_KEY = "%listeners%";
const ONABORT_KEY = "%onabort%";
const SIGNAL_KEY = "%signal%";

// ════════════════════════════════════════════════════════════════════════════
//  install (globals)
// ════════════════════════════════════════════════════════════════════════════

/// Build + declare the `AbortController` / `AbortSignal` globals on `self.globals`, mirroring them
/// onto the reified global object. Called from `host_setup.installHostGlobals`.
pub fn install(self: *Interpreter) EvalError!void {
    const env = self.globals orelse return;
    const ctors = [_]struct { name: []const u8, ctor: *Object }{
        .{ .name = "AbortController", .ctor = try makeAbortControllerCtor(self) },
        .{ .name = "AbortSignal", .ctor = try makeAbortSignalCtor(self) },
    };
    for (ctors) |p| {
        try env.declare(p.name, .{ .object = p.ctor }, true, true);
        if (env.lookup("%GlobalThis%")) |gb| if (gb.value == .object)
            try gb.value.object.defineData(p.name, .{ .object = p.ctor }, true, false, true);
    }
}

// ── constructor / prototype builders ─────────────────────────────────────────

/// Make a `.abort_method` native flagged with `kind` (read off `"%kind%"` in dispatch) and selecting
/// `name` (via `native_name`). Proto-linked to %Function.prototype%, no own `prototype` (a method).
fn makeMethod(self: *Interpreter, kind: []const u8, name: []const u8) EvalError!*Object {
    const fn_obj = try Object.createNative(self.arena, .abort_method, name);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("name", .{ .string = name }, false, false, true);
    try fn_obj.defineData("%kind%", .{ .string = kind }, false, false, true);
    return fn_obj;
}

/// Make a constructor (`ctor_kind` selects the family) with a `prototype` object whose `methods` are
/// `.abort_method` natives and `getters` are get-only accessor pairs (flagged `proto_kind`).
fn makeCtor(self: *Interpreter, ctor_kind: []const u8, proto_kind: []const u8, ctor_name: []const u8, methods: []const []const u8, getters: []const []const u8) EvalError!*Object {
    const arena = self.arena;
    const proto = try Object.create(arena, self.objectProto());

    const ctor = try Object.createNative(arena, .abort_method, ctor_name);
    ctor.prototype = self.functionProto();
    try ctor.defineData("name", .{ .string = ctor_name }, false, false, true);
    try ctor.defineData("%kind%", .{ .string = ctor_kind }, false, false, true);
    try ctor.defineData("prototype", .{ .object = proto }, false, false, false);
    try proto.defineData("constructor", .{ .object = ctor }, true, false, true);

    for (methods) |m| {
        const fn_obj = try makeMethod(self, proto_kind, m);
        try proto.defineData(m, .{ .object = fn_obj }, true, false, true);
    }
    for (getters) |g| {
        const getter = try makeMethod(self, proto_kind, g);
        try proto.defineAccessorEx(g, getter, null, false);
    }
    return ctor;
}

fn makeAbortControllerCtor(self: *Interpreter) EvalError!*Object {
    return makeCtor(self, "ac_ctor", "ac", "AbortController", &.{"abort"}, &.{"signal"});
}

fn makeAbortSignalCtor(self: *Interpreter) EvalError!*Object {
    const ctor = try makeCtor(
        self,
        "as_ctor",
        "as",
        "AbortSignal",
        &.{ "throwIfAborted", "addEventListener", "removeEventListener", "dispatchEvent" },
        &.{ "aborted", "reason" },
    );
    // `onabort` is a settable accessor (getter + setter), unlike the read-only getters above.
    const proto = ctor.get("prototype").?.object;
    const onabort_get = try makeMethod(self, "as", "get onabort");
    const onabort_set = try makeMethod(self, "as", "set onabort");
    try proto.defineAccessorEx("onabort", onabort_get, onabort_set, false);

    // Statics: AbortSignal.abort([reason]) / AbortSignal.timeout(ms) / AbortSignal.any(signals).
    for ([_][]const u8{ "abort", "timeout", "any" }) |s| {
        const fn_obj = try makeMethod(self, "as_static", s);
        try ctor.defineData(s, .{ .object = fn_obj }, true, false, true);
    }
    return ctor;
}

// ════════════════════════════════════════════════════════════════════════════
//  dispatch
// ════════════════════════════════════════════════════════════════════════════

/// Dispatch a `.abort_method` native. `func` carries the family in `"%kind%"`; `this_val` is the
/// receiver (the new instance for a ctor, the controller/signal for a method).
pub fn method(self: *Interpreter, func: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const kind = if (func.get("%kind%")) |v| (if (v == .string) v.string else "") else "";
    const name = func.native_name;
    const eq = std.mem.eql;
    if (eq(u8, kind, "ac_ctor")) return acConstruct(self, this_val);
    if (eq(u8, kind, "as_ctor")) return self.throwError("TypeError", "Illegal constructor"); // not constructible
    if (eq(u8, kind, "ac")) return acMethod(self, name, this_val, args);
    if (eq(u8, kind, "as")) return asMethod(self, name, this_val, args);
    if (eq(u8, kind, "as_static")) return asStatic(self, name, args);
    if (eq(u8, kind, "timeout_cb")) return timeoutFire(self, func);
    return .{ .normal = .undefined };
}

// ════════════════════════════════════════════════════════════════════════════
//  AbortSignal — instance construction + accessors
// ════════════════════════════════════════════════════════════════════════════

/// Create a fresh AbortSignal instance (proto = the global %AbortSignal.prototype%) with empty state.
fn makeSignal(self: *Interpreter) EvalError!*Object {
    const proto = self.globalProto("AbortSignal") orelse self.objectProto();
    const sig = try Object.create(self.arena, proto);
    try sig.defineData(ABORTED_KEY, .{ .boolean = false }, true, false, false);
    try sig.defineData(REASON_KEY, .undefined, true, false, false);
    const listeners = try Object.createArray(self.arena, self.arrayProto());
    try sig.defineData(LISTENERS_KEY, .{ .object = listeners }, true, false, false);
    try sig.defineData(ONABORT_KEY, .undefined, true, false, false);
    return sig;
}

/// Build a DOMException-ish AbortError (a plain Error with `name === 'AbortError'`). Without a real
/// DOMException class this is a first-cut: an Error instance whose `name`/`message` match.
fn makeAbortError(self: *Interpreter, name: []const u8, msg: []const u8) EvalError!Value {
    const err = try Object.create(self.arena, self.errorProto("Error"));
    err.error_data = true;
    try err.set("name", .{ .string = name });
    try err.set("message", .{ .string = msg });
    return .{ .object = err };
}

/// The backing 'abort' listeners array of a signal (created at `makeSignal`).
fn signalListeners(sig: *Object) ?*Object {
    const v = sig.get(LISTENERS_KEY) orelse return null;
    return if (v == .object) v.object else null;
}

fn isAborted(sig: *Object) bool {
    const v = sig.get(ABORTED_KEY) orelse return false;
    return v == .boolean and v.boolean;
}

/// Fire `sig`'s `onabort` handler then its addEventListener listeners (registration order) with the
/// event `ev_v`, `this` = the signal. Snapshots the array (a listener may mutate it). Shared by
/// `signalAbort` and `dispatchEvent`.
fn fireAbortListeners(self: *Interpreter, sig: *Object, ev_v: Value) EvalError!Completion {
    if (sig.get(ONABORT_KEY)) |h| if (h == .object and h.object.kind == .function) {
        const c = try self.callFunction(h.object, &.{ev_v}, .{ .object = sig });
        if (c.isAbrupt()) return c;
    };
    if (signalListeners(sig)) |arr| {
        const n = arr.array_length;
        var holders = std.ArrayListUnmanaged(*Object).empty;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const h = arr.arrayGet(i);
            if (h == .object and h.object.kind == .function) holders.append(self.arena, h.object) catch return error.OutOfMemory;
        }
        for (holders.items) |cb| {
            const c = try self.callFunction(cb, &.{ev_v}, .{ .object = sig });
            if (c.isAbrupt()) return c;
        }
    }
    return .{ .normal = .undefined };
}

/// Flip `sig` aborted with `reason` (defaulting to an AbortError) and fire its 'abort' listeners +
/// `onabort` handler ONCE. A no-op if already aborted (spec: signalAbort runs at most once).
fn signalAbort(self: *Interpreter, sig: *Object, reason: Value) EvalError!Completion {
    if (isAborted(sig)) return .{ .normal = .undefined };
    const r = if (reason == .undefined) try makeAbortError(self, "AbortError", "The operation was aborted") else reason;
    try sig.defineData(ABORTED_KEY, .{ .boolean = true }, true, false, false);
    try sig.defineData(REASON_KEY, r, true, false, false);

    // Build the 'abort' event object (a minimal `{ type: 'abort', target: sig }`).
    const ev = try Object.create(self.arena, self.objectProto());
    try ev.defineData("type", .{ .string = "abort" }, true, true, true);
    try ev.defineData("target", .{ .object = sig }, true, true, true);
    return fireAbortListeners(self, sig, .{ .object = ev });
}

/// Dispatch an AbortSignal prototype method / accessor.
fn asMethod(self: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    const eq = std.mem.eql;
    if (this_val != .object) return self.throwError("TypeError", "AbortSignal method called on non-object");
    const sig = this_val.object;

    // Accessor getters/setters.
    if (eq(u8, name, "aborted")) return .{ .normal = .{ .boolean = isAborted(sig) } };
    if (eq(u8, name, "reason")) return .{ .normal = sig.get(REASON_KEY) orelse .undefined };
    if (eq(u8, name, "get onabort")) return .{ .normal = sig.get(ONABORT_KEY) orelse .undefined };
    if (eq(u8, name, "set onabort")) {
        const h: Value = if (args.len > 0) args[0] else .undefined;
        try sig.defineData(ONABORT_KEY, h, true, false, false);
        return .{ .normal = .undefined };
    }

    if (eq(u8, name, "throwIfAborted")) {
        if (isAborted(sig)) return .{ .throw = sig.get(REASON_KEY) orelse .undefined };
        return .{ .normal = .undefined };
    }
    if (eq(u8, name, "addEventListener")) {
        // addEventListener(type, callback): only the 'abort' type is meaningful here.
        const type_c = try self.toStringValuePub(if (args.len > 0) args[0] else .undefined);
        if (type_c.isAbrupt()) return type_c;
        const cb: Value = if (args.len > 1) args[1] else .undefined;
        if (!std.mem.eql(u8, type_c.normal.string, "abort")) return .{ .normal = .undefined };
        if (cb != .object or cb.object.kind != .function) return .{ .normal = .undefined };
        const arr = signalListeners(sig) orelse return .{ .normal = .undefined };
        // De-dupe: addEventListener ignores an identical (type, callback) re-registration.
        const n = arr.array_length;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const h = arr.arrayGet(i);
            if (h == .object and h.object == cb.object) return .{ .normal = .undefined };
        }
        try arr.arraySet(self.arena, arr.array_length, cb);
        return .{ .normal = .undefined };
    }
    if (eq(u8, name, "removeEventListener")) {
        const type_c = try self.toStringValuePub(if (args.len > 0) args[0] else .undefined);
        if (type_c.isAbrupt()) return type_c;
        const cb: Value = if (args.len > 1) args[1] else .undefined;
        if (cb != .object) return .{ .normal = .undefined };
        const arr = signalListeners(sig) orelse return .{ .normal = .undefined };
        const n = arr.array_length;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const h = arr.arrayGet(i);
            if (h == .object and h.object == cb.object) {
                var j: usize = i;
                while (j + 1 < n) : (j += 1) try arr.arraySet(self.arena, j, arr.arrayGet(j + 1));
                try arr.arraySetLen(n - 1);
                return .{ .normal = .undefined };
            }
        }
        return .{ .normal = .undefined };
    }
    if (eq(u8, name, "dispatchEvent")) {
        // Minimal: only a `{ type: 'abort' }` event drives the listeners; mirrors signalAbort's firing
        // WITHOUT changing the aborted state (dispatchEvent does not itself abort). Returns true.
        const ev: Value = if (args.len > 0) args[0] else .undefined;
        var is_abort = false;
        if (ev == .object) {
            const tc = try self.getProperty(ev, "type");
            if (tc.isAbrupt()) return tc;
            if (tc.normal == .string and std.mem.eql(u8, tc.normal.string, "abort")) is_abort = true;
        }
        if (is_abort) {
            const c = try fireAbortListeners(self, sig, ev);
            if (c.isAbrupt()) return c;
        }
        return .{ .normal = .{ .boolean = true } };
    }
    return .{ .normal = .undefined };
}

// ════════════════════════════════════════════════════════════════════════════
//  AbortSignal statics: abort / timeout / any
// ════════════════════════════════════════════════════════════════════════════

fn asStatic(self: *Interpreter, name: []const u8, args: []const Value) EvalError!Completion {
    const eq = std.mem.eql;
    if (eq(u8, name, "abort")) {
        // AbortSignal.abort([reason]) → an ALREADY-aborted signal (listeners never fire — there can be
        // none yet). The reason defaults to an AbortError.
        const sig = try makeSignal(self);
        const reason: Value = if (args.len > 0) args[0] else .undefined;
        const r = if (reason == .undefined) try makeAbortError(self, "AbortError", "The operation was aborted") else reason;
        try sig.defineData(ABORTED_KEY, .{ .boolean = true }, true, false, false);
        try sig.defineData(REASON_KEY, r, true, false, false);
        return .{ .normal = .{ .object = sig } };
    }
    if (eq(u8, name, "timeout")) {
        // AbortSignal.timeout(ms) → a signal that aborts after `ms` with a TimeoutError. Scheduled on
        // the host timer queue (inert on the Test262 path — no event loop runs there).
        const nd = try self.toNumberV(if (args.len > 0) args[0] else .undefined);
        if (nd.isAbrupt()) return nd;
        var delay = nd.normal.number;
        if (std.math.isNan(delay) or delay < 0) delay = 0;
        const sig = try makeSignal(self);
        // The timer callback is a `timeout_cb` native carrying the signal on a hidden own slot.
        const cb = try makeMethod(self, "timeout_cb", "timeoutAbort");
        try cb.defineData(SIGNAL_KEY, .{ .object = sig }, false, false, false);
        const id = self.next_timer_id;
        self.next_timer_id += 1;
        self.timers.append(self.arena, .{
            .id = id,
            .callback = cb,
            .args = &.{},
            .deadline_ms = host_time.monotonicMs() + delay,
            .interval_ms = null,
        }) catch return error.OutOfMemory;
        return .{ .normal = .{ .object = sig } };
    }
    if (eq(u8, name, "any")) {
        // AbortSignal.any(signals) → a signal aborted when ANY input signal aborts (or already is). If
        // an input is already aborted, the result is created already-aborted with that reason.
        const result = try makeSignal(self);
        const iterable: Value = if (args.len > 0) args[0] else .undefined;
        if (iterable != .object) return self.throwError("TypeError", "AbortSignal.any expects an iterable of signals");

        const ir = try self.getIterator(iterable);
        const iter = switch (ir) {
            .abrupt => |c| return c,
            .iterator => |x| x,
        };
        // Collect the input signals; if any is already aborted, abort the result immediately with its
        // reason and stop. Otherwise register a forwarding listener on each so the first to abort wins.
        var inputs = std.ArrayListUnmanaged(*Object).empty;
        while (true) {
            const step = try self.iteratorStep(iter);
            const sv = switch (step) {
                .abrupt => |c| return c,
                .done => break,
                .value => |v| v,
            };
            if (sv != .object) continue;
            const s = sv.object;
            if (isAborted(s)) {
                const r = s.get(REASON_KEY) orelse .undefined;
                try result.defineData(ABORTED_KEY, .{ .boolean = true }, true, false, false);
                try result.defineData(REASON_KEY, r, true, false, false);
                return .{ .normal = .{ .object = result } };
            }
            inputs.append(self.arena, s) catch return error.OutOfMemory;
        }
        // Register a forwarding listener on each source: when it fires, abort `result` with the
        // source's reason. The forwarder is a `timeout_cb` native carrying both signals.
        for (inputs.items) |s| {
            const fwd = try makeMethod(self, "timeout_cb", "anyForward");
            try fwd.defineData(SIGNAL_KEY, .{ .object = result }, false, false, false);
            try fwd.defineData("%source%", .{ .object = s }, false, false, false);
            const arr = signalListeners(s) orelse continue;
            try arr.arraySet(self.arena, arr.array_length, .{ .object = fwd });
        }
        return .{ .normal = .{ .object = result } };
    }
    return .{ .normal = .undefined };
}

/// The scheduled / forwarded `timeout_cb` native: abort its captured signal. For `AbortSignal.timeout`
/// the reason is a fresh TimeoutError; for an `AbortSignal.any` forwarder it is the source's reason.
fn timeoutFire(self: *Interpreter, func: *Object) EvalError!Completion {
    const sv = func.get(SIGNAL_KEY) orelse return .{ .normal = .undefined };
    if (sv != .object) return .{ .normal = .undefined };
    // An `any` forwarder carries the source signal → propagate its reason.
    if (func.get("%source%")) |src| if (src == .object) {
        const reason = src.object.get(REASON_KEY) orelse .undefined;
        return signalAbort(self, sv.object, reason);
    };
    const reason = try makeAbortError(self, "TimeoutError", "The operation timed out");
    return signalAbort(self, sv.object, reason);
}

// ════════════════════════════════════════════════════════════════════════════
//  AbortController
// ════════════════════════════════════════════════════════════════════════════

/// `new AbortController()` — create the instance, attach a fresh signal on a hidden slot (surfaced via
/// the `signal` getter).
fn acConstruct(self: *Interpreter, this_val: Value) EvalError!Completion {
    if (this_val != .object) return self.throwError("TypeError", "AbortController constructor requires `new`");
    const inst = this_val.object;
    const sig = try makeSignal(self);
    try inst.defineData(SIGNAL_KEY, .{ .object = sig }, true, false, false);
    return .{ .normal = .{ .object = inst } };
}

fn acMethod(self: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object) return self.throwError("TypeError", "AbortController method called on non-object");
    const inst = this_val.object;
    if (std.mem.eql(u8, name, "signal")) {
        return .{ .normal = inst.get(SIGNAL_KEY) orelse .undefined };
    }
    if (std.mem.eql(u8, name, "abort")) {
        const sv = inst.get(SIGNAL_KEY) orelse return .{ .normal = .undefined };
        if (sv != .object) return .{ .normal = .undefined };
        const reason: Value = if (args.len > 0) args[0] else .undefined;
        return signalAbort(self, sv.object, reason);
    }
    return .{ .normal = .undefined };
}
