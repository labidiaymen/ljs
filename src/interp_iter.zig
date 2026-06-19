//! §7.4 Iterator protocol core — extracted from interpreter.zig as free functions taking
//! `self: *Interpreter` (Zig 0.16 removed `usingnamespace`). Covers GetIterator (sync + async),
//! IteratorStep/IteratorValue, IteratorClose (throw-swallowing and checked variants), and the
//! drain-to-list helper used by spread / array destructuring. Behavior-identical to the original
//! methods; calls to OTHER interpreter methods stay `self.foo(...)` (resolved via interpreter.zig
//! wrappers / remaining methods).
const std = @import("std");
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const Completion = @import("completion.zig").Completion;
const Value = @import("value.zig").Value;
const Symbol = @import("value.zig").Symbol;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const ops = @import("abstract_ops.zig");

const toBoolean = ops.toBoolean;
const IterResult = Interpreter.IterResult;
const StepResult = Interpreter.StepResult;

/// The realm's well-known `Symbol.iterator` identity (held on the `Symbol` constructor).
pub fn wellKnownIterator(self: *Interpreter) ?*Symbol {
    const g = self.globals orelse return null;
    const b = g.lookup("Symbol") orelse return null;
    if (b.value != .object) return null;
    const pv = b.value.object.get("iterator") orelse return null;
    return if (pv == .symbol) pv.symbol else null;
}

/// §7.4.2 GetIterator ( obj ) — read `obj[Symbol.iterator]`, call it with `this` = obj, and
/// require the result to be an object (the iterator). Returns the iterator object, or an abrupt
/// completion (TypeError) if the value is not iterable. Null `iter_sym` (realm-less) → not iterable.
pub fn getIterator(self: *Interpreter, obj: Value) EvalError!IterResult {
    const iter_sym = self.wellKnownIterator() orelse
        return .{ .abrupt = try self.throwError("TypeError", "value is not iterable") };
    const mc = try self.getSymbolProperty(obj, iter_sym);
    if (mc.isAbrupt()) return .{ .abrupt = mc };
    if (mc.normal != .object or mc.normal.object.kind != .function) {
        return .{ .abrupt = try self.throwError("TypeError", "value is not iterable") };
    }
    const rc = try self.callFunction(mc.normal.object, &.{}, obj);
    if (rc.isAbrupt()) return .{ .abrupt = rc };
    if (rc.normal != .object) {
        return .{ .abrupt = try self.throwError("TypeError", "Result of the Symbol.iterator method is not an object") };
    }
    return .{ .iterator = rc.normal.object };
}

/// The realm's well-known `Symbol.asyncIterator` identity (held on the `Symbol` constructor).
pub fn wellKnownAsyncIterator(self: *Interpreter) ?*Symbol {
    const g = self.globals orelse return null;
    const b = g.lookup("Symbol") orelse return null;
    if (b.value != .object) return null;
    const pv = b.value.object.get("asyncIterator") orelse return null;
    return if (pv == .symbol) pv.symbol else null;
}

/// §7.4.3 GetIterator ( obj, async ) — read `obj[Symbol.asyncIterator]`; if present, call it (the
/// result is the async iterator). If ABSENT, fall back to the SYNC iterator (`obj[Symbol.iterator]`)
/// and wrap it in an AsyncFromSyncIterator (§27.1.4.1 CreateAsyncFromSyncIterator) so `for await`
/// can drive a sync iterable. A value with neither → TypeError.
pub fn getAsyncIterator(self: *Interpreter, obj: Value) EvalError!IterResult {
    if (wellKnownAsyncIterator(self)) |async_sym| {
        const mc = try self.getSymbolProperty(obj, async_sym);
        if (mc.isAbrupt()) return .{ .abrupt = mc };
        if (mc.normal == .object and mc.normal.object.kind == .function) {
            const rc = try self.callFunction(mc.normal.object, &.{}, obj);
            if (rc.isAbrupt()) return .{ .abrupt = rc };
            if (rc.normal != .object) {
                return .{ .abrupt = try self.throwError("TypeError", "Result of Symbol.asyncIterator is not an object") };
            }
            return .{ .iterator = rc.normal.object };
        }
        // §7.4.3 step 1.b.i: an undefined/null [Symbol.asyncIterator] (or absent) → use the sync path.
        if (mc.normal != .undefined and mc.normal != .null) {
            return .{ .abrupt = try self.throwError("TypeError", "Symbol.asyncIterator is not callable") };
        }
    }
    // §27.1.4.1 CreateAsyncFromSyncIterator: get the SYNC iterator, wrap it.
    const sync = try getIterator(self, obj);
    const sync_iter: *Object = switch (sync) {
        .abrupt => |c| return .{ .abrupt = c },
        .iterator => |it| it,
    };
    const wrapper = try Object.create(self.arena, self.asyncFromSyncProto());
    wrapper.async_from_sync = sync_iter;
    return .{ .iterator = wrapper };
}

/// §7.4.4 IteratorStep + §7.4.5 IteratorValue — call `iterator.next()`, require an object result,
/// and return its `value` (or `.done` when `done` is truthy). An abrupt completion from `next` (or
/// a non-object result) propagates as `.abrupt`.
pub fn iteratorStep(self: *Interpreter, iterator: *Object) EvalError!StepResult {
    const nc = try self.getProperty(.{ .object = iterator }, "next");
    if (nc.isAbrupt()) return .{ .abrupt = nc };
    if (nc.normal != .object or nc.normal.object.kind != .function) {
        return .{ .abrupt = try self.throwError("TypeError", "iterator.next is not a function") };
    }
    const rc = try self.callFunction(nc.normal.object, &.{}, .{ .object = iterator });
    if (rc.isAbrupt()) return .{ .abrupt = rc };
    if (rc.normal != .object) {
        return .{ .abrupt = try self.throwError("TypeError", "Iterator result is not an object") };
    }
    const result = rc.normal.object;
    const dc = try self.getProperty(.{ .object = result }, "done");
    if (dc.isAbrupt()) return .{ .abrupt = dc };
    if (toBoolean(dc.normal)) return .done;
    const vc = try self.getProperty(.{ .object = result }, "value");
    if (vc.isAbrupt()) return .{ .abrupt = vc };
    return .{ .value = vc.normal };
}

/// Like `iteratorStep`, but with the `next` method fetched ONCE up front (§7.4.1 GetIterator caches
/// [[NextMethod]]; subsequent IteratorNext calls reuse it — they do NOT re-`Get(iterator, "next")`).
/// Used by the §24.2.3 Set-algebra methods, whose spec captures the keys-iterator's `next` exactly
/// once and observes a single `getting next` regardless of element count.
pub fn iteratorStepWithNext(self: *Interpreter, iterator: *Object, next_method: *Object) EvalError!StepResult {
    const rc = try self.callFunction(next_method, &.{}, .{ .object = iterator });
    if (rc.isAbrupt()) return .{ .abrupt = rc };
    if (rc.normal != .object) {
        return .{ .abrupt = try self.throwError("TypeError", "Iterator result is not an object") };
    }
    const result = rc.normal.object;
    const dc = try self.getProperty(.{ .object = result }, "done");
    if (dc.isAbrupt()) return .{ .abrupt = dc };
    if (toBoolean(dc.normal)) return .done;
    const vc = try self.getProperty(.{ .object = result }, "value");
    if (vc.isAbrupt()) return .{ .abrupt = vc };
    return .{ .value = vc.normal };
}

/// §7.4.11 IteratorClose ( iterator, completion ) — best-effort: call `iterator.return()` if it
/// exists, ignoring its result (the original completion is what matters). Called on an early exit
/// from a for-of loop (`break`/`return`/`throw`). A missing/non-callable `return` is a no-op.
pub fn iteratorClose(self: *Interpreter, iterator: *Object) EvalError!void {
    const rc = try self.getProperty(.{ .object = iterator }, "return");
    if (rc.isAbrupt()) return; // swallow — don't mask the original completion
    if (rc.normal != .object or rc.normal.object.kind != .function) return;
    // A throwing `return()` is swallowed (the original completion wins, §7.4.11 step 4); but an
    // engine error (OOM / step-limit) still propagates via `try`.
    _ = try self.callFunction(rc.normal.object, &.{}, .{ .object = iterator });
}

/// §7.4.11 IteratorClose for a NORMAL (non-throw) incoming completion — the iterator is being
/// closed early on `break` / loop-exiting `continue` / `return`, so a thrown `return()` (or a
/// non-Object `return()` result) MUST propagate (steps 5–6), unlike the throw-completion case
/// (`iteratorClose`, step 4, which swallows). Returns `.normal` on a clean close, else the abrupt
/// completion to propagate. GetMethod semantics: undefined/null `return` → no-op; non-callable →
/// TypeError (§7.3.10).
pub fn iteratorCloseChecked(self: *Interpreter, iterator: *Object) EvalError!Completion {
    const rc = try self.getProperty(.{ .object = iterator }, "return");
    if (rc.isAbrupt()) return rc; // a throwing `return` getter propagates
    if (rc.normal == .undefined or rc.normal == .null) return .{ .normal = .undefined };
    if (rc.normal != .object or rc.normal.object.kind != .function)
        return self.throwError("TypeError", "iterator 'return' is not a function");
    const res = try self.callFunction(rc.normal.object, &.{}, .{ .object = iterator });
    if (res.isAbrupt()) return res; // §7.4.11 step 5: a thrown `return()` propagates
    if (res.normal != .object) return self.throwError("TypeError", "iterator 'return' result is not an object"); // step 6
    return .{ .normal = .undefined };
}

/// §7.4.1 GetIterator + drain — materialize an iterable `value` into a slice of its yielded values
/// via the full Symbol.iterator protocol. Used by spread / array destructuring (which need the
/// whole sequence up front). Arrays/Strings have native iterators (fast), but ANY object with a
/// `[Symbol.iterator]` returning a `next`-having object works. A non-iterable → abrupt TypeError.
pub fn iterateToList(self: *Interpreter, value: Value, out: *std.ArrayListUnmanaged(Value)) EvalError!Completion {
    // Fast path: an Array iterates its `elements` directly (skips the per-element next() call),
    // preserving the hot spread/destructuring path. Strings keep their native code-unit walk.
    if (value == .object and value.object.kind == .array) {
        const arr = value.object;
        const len = arr.arrayLen();
        if (len == arr.elements.items.len) {
            for (arr.elements.items) |el| try out.append(self.arena, el); // pure dense (hot path)
        } else {
            var i: usize = 0; // sparse tail: holes spread as `undefined` (§13.2.4)
            while (i < len) : (i += 1) try out.append(self.arena, arr.arrayGet(i));
        }
        return .{ .normal = .undefined };
    }
    if (value == .string) {
        const s = value.string;
        for (0..s.len) |i| try out.append(self.arena, .{ .string = s[i .. i + 1] });
        return .{ .normal = .undefined };
    }
    const git = try getIterator(self, value);
    switch (git) {
        .abrupt => |c| return c,
        .iterator => |iterator| {
            while (true) {
                try self.tick(); // §reliability: a genuinely infinite iterable fails via the watchdog, never hangs
                const step = try iteratorStep(self, iterator);
                switch (step) {
                    .abrupt => |c| return c,
                    .done => break,
                    .value => |v| try out.append(self.arena, v),
                }
            }
            return .{ .normal = .undefined };
        },
    }
}
