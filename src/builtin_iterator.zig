//! §27.1.4 Iterator helpers — the %Iterator.prototype% EAGER consumers (reduce/toArray/forEach/some/
//! every/find) and LAZY helpers (map/filter/take/drop/flatMap), `Iterator.from`, and the lazy Iterator
//! Helper object's own `next`/`return`. Dispatched from the interpreter's `callNative`. Lives in its own
//! file so the interpreter stays the evaluator (mirrors `builtin_array.zig` etc.).
const std = @import("std");
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const ops = @import("abstract_ops.zig");
const object_mod = @import("object.zig");
const Object = object_mod.Object;

const StepResult = Interpreter.StepResult;
const toBoolean = ops.toBoolean;
const isCallable = interp.isCallable;

fn iterNextDirect(it: *Interpreter, iterator: Value, next_fn: Value) EvalError!StepResult {
    if (next_fn != .object or !isCallable(next_fn.object)) {
        return .{ .abrupt = try it.throwError("TypeError", "iterator.next is not a function") };
    }
    const rc = try it.callFunction(next_fn.object, &.{}, iterator);
    if (rc.isAbrupt()) return .{ .abrupt = rc };
    if (rc.normal != .object) return .{ .abrupt = try it.throwError("TypeError", "Iterator result is not an object") };
    const res = rc.normal.object;
    const dc = try it.getProperty2(.{ .object = res }, "done");
    if (dc.isAbrupt()) return .{ .abrupt = dc };
    if (toBoolean(dc.normal)) return .done;
    const vc = try it.getProperty2(.{ .object = res }, "value");
    if (vc.isAbrupt()) return .{ .abrupt = vc };
    return .{ .value = vc.normal };
}

/// §27.1.4 %Iterator.prototype% EAGER consumers: reduce / toArray / forEach / some / every / find.
/// `this` is the iterator (GetIteratorDirect: requires an Object, reads `next` once). The callback
/// (where required) is validated with the iterator CLOSED on failure (IfAbruptCloseIterator); a
/// short-circuit (some/every/find) and a throwing callback also close the iterator.
pub fn iteratorHelper(it: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    const eql = std.mem.eql;
    if (this_val != .object) return it.throwError("TypeError", "Iterator.prototype method called on a non-object");
    const o = this_val.object;
    const nc = try it.getProperty2(this_val, "next"); // GetIteratorDirect: read next once
    if (nc.isAbrupt()) return nc;
    const next_fn = nc.normal;

    if (eql(u8, name, "toArray")) {
        const arr = try Object.createArray(it.arena, it.arrayProto());
        while (true) {
            switch (try iterNextDirect(it, this_val, next_fn)) {
                .done => break,
                .abrupt => |c| return c,
                .value => |v| {
                    try arr.elements.append(it.arena, v);
                    arr.array_length = arr.elements.items.len;
                },
            }
        }
        return .{ .normal = .{ .object = arr } };
    }

    // The remaining helpers all take a callback as args[0]; validate it, closing on failure.
    const cb: Value = if (args.len > 0) args[0] else .undefined;
    if (cb != .object or !isCallable(cb.object)) {
        try it.iteratorClose(o);
        return it.throwError("TypeError", "Iterator helper callback is not callable");
    }

    if (eql(u8, name, "forEach")) {
        var i: f64 = 0;
        while (true) {
            switch (try iterNextDirect(it, this_val, next_fn)) {
                .done => break,
                .abrupt => |c| return c,
                .value => |v| {
                    const r = try it.callFunction(cb.object, &.{ v, .{ .number = i } }, .undefined);
                    if (r.isAbrupt()) {
                        try it.iteratorClose(o);
                        return r;
                    }
                    i += 1;
                },
            }
        }
        return .{ .normal = .undefined };
    }

    if (eql(u8, name, "some") or eql(u8, name, "every") or eql(u8, name, "find")) {
        const is_some = eql(u8, name, "some");
        const is_find = eql(u8, name, "find");
        var i: f64 = 0;
        while (true) {
            switch (try iterNextDirect(it, this_val, next_fn)) {
                .done => break,
                .abrupt => |c| return c,
                .value => |v| {
                    const r = try it.callFunction(cb.object, &.{ v, .{ .number = i } }, .undefined);
                    if (r.isAbrupt()) {
                        try it.iteratorClose(o);
                        return r;
                    }
                    i += 1;
                    const t = toBoolean(r.normal);
                    if (is_find and t) {
                        try it.iteratorClose(o);
                        return .{ .normal = v };
                    }
                    if (is_some and t) {
                        try it.iteratorClose(o);
                        return .{ .normal = .{ .boolean = true } };
                    }
                    if (!is_some and !is_find and !t) { // every: a falsy → false
                        try it.iteratorClose(o);
                        return .{ .normal = .{ .boolean = false } };
                    }
                },
            }
        }
        // exhausted: some→false, every→true, find→undefined
        return .{ .normal = if (is_find) .undefined else .{ .boolean = !is_some } };
    }

    if (eql(u8, name, "reduce")) {
        var have_acc = args.len > 1;
        var acc: Value = if (args.len > 1) args[1] else .undefined;
        var i: f64 = 0;
        while (true) {
            switch (try iterNextDirect(it, this_val, next_fn)) {
                .done => break,
                .abrupt => |c| return c,
                .value => |v| {
                    if (!have_acc) { // §27.1.4.x: first value seeds the accumulator
                        acc = v;
                        have_acc = true;
                        i += 1;
                        continue;
                    }
                    const r = try it.callFunction(cb.object, &.{ acc, v, .{ .number = i } }, .undefined);
                    if (r.isAbrupt()) {
                        try it.iteratorClose(o);
                        return r;
                    }
                    acc = r.normal;
                    i += 1;
                },
            }
        }
        if (!have_acc) return it.throwError("TypeError", "Reduce of empty iterator with no initial value");
        return .{ .normal = acc };
    }

    // ── §27.1.4 LAZY helpers: return a new Iterator Helper object (cb already validated above) ──
    if (eql(u8, name, "map")) return .{ .normal = .{ .object = try makeHelper(it, .map, o, next_fn, cb, 0) } };
    if (eql(u8, name, "filter")) return .{ .normal = .{ .object = try makeHelper(it, .filter, o, next_fn, cb, 0) } };
    if (eql(u8, name, "flatMap")) return .{ .normal = .{ .object = try makeHelper(it, .flat_map, o, next_fn, cb, 0) } };

    unreachable;
}

/// §27.1.4 take/drop — separate from `iteratorHelper` because their argument is a numeric limit
/// (not a callback): ToNumber(limit) → NaN throws RangeError, negative throws RangeError; both close
/// the underlying iterator on the abrupt path. Returns a lazy helper that yields the first / skips
/// the first `limit` values.
pub fn iteratorLimitHelper(it: *Interpreter, kind: object_mod.HelperKind, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object) return it.throwError("TypeError", "Iterator.prototype method called on a non-object");
    const o = this_val.object;
    const nc = try it.getProperty2(this_val, "next");
    if (nc.isAbrupt()) return nc;
    const next_fn = nc.normal;
    const arg0: Value = if (args.len > 0) args[0] else .undefined;
    const numc = try it.toNumberV(arg0);
    if (numc.isAbrupt()) {
        try it.iteratorClose(o);
        return numc;
    }
    if (std.math.isNan(numc.normal.number)) {
        try it.iteratorClose(o);
        return it.throwError("RangeError", "limit must not be NaN");
    }
    const ic = try it.toIntegerOrInfinityPub(numc.normal);
    if (ic.isAbrupt()) return ic;
    const lim = ic.normal.number;
    if (lim < 0) {
        try it.iteratorClose(o);
        return it.throwError("RangeError", "limit must be non-negative");
    }
    return .{ .normal = .{ .object = try makeHelper(it, kind, o, next_fn, .undefined, lim) } };
}

/// Create a lazy Iterator Helper object (proto = %Iterator.prototype%) wrapping `underlying`, with
/// its own `next` / `return` natives (`iterator_helper_next`).
fn makeHelper(it: *Interpreter, kind: object_mod.HelperKind, underlying: *Object, next_fn: Value, callback: Value, remaining: f64) EvalError!*Object {
    const st = try it.arena.create(object_mod.HelperState);
    st.* = .{ .kind = kind, .underlying = underlying, .next_fn = next_fn, .callback = callback, .remaining = remaining };
    const h = try Object.create(it.arena, it.iteratorProto());
    h.iter_helper = st;
    const next_native = try Object.createNative(it.arena, .iterator_helper_next, "next");
    next_native.prototype = it.functionProto();
    try h.defineData("next", .{ .object = next_native }, true, false, true);
    const ret_native = try Object.createNative(it.arena, .iterator_helper_next, "return");
    ret_native.prototype = it.functionProto();
    try h.defineData("return", .{ .object = ret_native }, true, false, true);
    return h;
}

/// §7.4.x GetIteratorFlattenable ( obj, primitiveHandling ) — used by `Iterator.from` (strings
/// allowed) and `flatMap` (primitives rejected). Returns the iterator object + its cached `next`.
fn getIteratorFlattenable(it: *Interpreter, obj: Value, allow_string: bool) EvalError!union(enum) { it: struct { obj: *Object, next_fn: Value }, abrupt: Completion } {
    if (obj != .object) {
        if (!(allow_string and obj == .string)) {
            return .{ .abrupt = try it.throwError("TypeError", "value is not iterable / not an object") };
        }
    }
    // method = Get(obj, @@iterator); if undefined/null and obj is an Object → use obj directly.
    const iter_sym = it.wellKnownIterator() orelse return .{ .abrupt = try it.throwError("TypeError", "no Symbol.iterator") };
    const mc = try it.getSymbolProperty(obj, iter_sym);
    if (mc.isAbrupt()) return .{ .abrupt = mc };
    const iterator: Value = if (mc.normal == .undefined or mc.normal == .null)
        obj // an absent @@iterator → obj is itself the iterator record's [[Iterator]]
    else blk: {
        if (mc.normal != .object or !isCallable(mc.normal.object)) {
            return .{ .abrupt = try it.throwError("TypeError", "Symbol.iterator is not callable") };
        }
        const rc = try it.callFunction(mc.normal.object, &.{}, obj);
        if (rc.isAbrupt()) return .{ .abrupt = rc };
        break :blk rc.normal;
    };
    if (iterator != .object) return .{ .abrupt = try it.throwError("TypeError", "iterator is not an object") };
    const nc = try it.getProperty2(iterator, "next");
    if (nc.isAbrupt()) return .{ .abrupt = nc };
    return .{ .it = .{ .obj = iterator.object, .next_fn = nc.normal } };
}

/// §27.1.3.1.1 Iterator.from ( O ) — wrap O's iterator so it inherits %Iterator.prototype%. If the
/// iterator already does, it is returned as-is; otherwise a `wrap` helper delegates to it.
pub fn iteratorFrom(it: *Interpreter, args: []const Value) EvalError!Completion {
    const obj: Value = if (args.len > 0) args[0] else .undefined;
    const flat = switch (try getIteratorFlattenable(it, obj, true)) {
        .it => |x| x,
        .abrupt => |c| return c,
    };
    // If the iterator already inherits %Iterator.prototype%, return it directly (no wrapper).
    const iproto = it.iteratorProto();
    var p: ?*Object = flat.obj.prototype;
    while (p) |pp| : (p = pp.prototype) {
        if (pp == iproto) return .{ .normal = .{ .object = flat.obj } };
    }
    return .{ .normal = .{ .object = try makeHelper(it, .wrap, flat.obj, flat.next_fn, .undefined, 0) } };
}

/// §27.1.4.x an Iterator Helper's own `next` / `return` — drives the lazy transform, pulling from
/// the underlying iterator (via the cached next) and applying the per-kind logic. `return` closes
/// the underlying (and any in-flight inner iterator) and marks the helper done.
pub fn helperNext(it: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object or this_val.object.iter_helper == null) {
        return it.throwError("TypeError", "not an Iterator Helper");
    }
    const st = this_val.object.iter_helper.?;

    if (std.mem.eql(u8, name, "return")) {
        if (!st.done) {
            st.done = true;
            if (st.inner) |inner| try it.iteratorClose(inner);
            try it.iteratorClose(st.underlying);
        }
        const v: Value = if (args.len > 0) args[0] else .undefined;
        return iterResultObjectC(it, v, true);
    }

    if (st.done) return iterResultObjectC(it, .undefined, true);
    const under: Value = .{ .object = st.underlying };

    switch (st.kind) {
        .wrap => {
            switch (try iterNextDirect(it, under, st.next_fn)) {
                .done => {
                    st.done = true;
                    return iterResultObjectC(it, .undefined, true);
                },
                .abrupt => |c| return c,
                .value => |v| return iterResultObjectC(it, v, false),
            }
        },
        .map => {
            switch (try iterNextDirect(it, under, st.next_fn)) {
                .done => {
                    st.done = true;
                    return iterResultObjectC(it, .undefined, true);
                },
                .abrupt => |c| return c,
                .value => |v| {
                    const r = try it.callFunction(st.callback.object, &.{ v, .{ .number = st.counter } }, .undefined);
                    st.counter += 1;
                    if (r.isAbrupt()) {
                        st.done = true;
                        try it.iteratorClose(st.underlying);
                        return r;
                    }
                    return iterResultObjectC(it, r.normal, false);
                },
            }
        },
        .filter => {
            while (true) {
                switch (try iterNextDirect(it, under, st.next_fn)) {
                    .done => {
                        st.done = true;
                        return iterResultObjectC(it, .undefined, true);
                    },
                    .abrupt => |c| return c,
                    .value => |v| {
                        const r = try it.callFunction(st.callback.object, &.{ v, .{ .number = st.counter } }, .undefined);
                        st.counter += 1;
                        if (r.isAbrupt()) {
                            st.done = true;
                            try it.iteratorClose(st.underlying);
                            return r;
                        }
                        if (toBoolean(r.normal)) return iterResultObjectC(it, v, false);
                    },
                }
            }
        },
        .take => {
            if (st.remaining <= 0) {
                st.done = true;
                try it.iteratorClose(st.underlying);
                return iterResultObjectC(it, .undefined, true);
            }
            st.remaining -= 1;
            switch (try iterNextDirect(it, under, st.next_fn)) {
                .done => {
                    st.done = true;
                    return iterResultObjectC(it, .undefined, true);
                },
                .abrupt => |c| return c,
                .value => |v| return iterResultObjectC(it, v, false),
            }
        },
        .drop => {
            if (!st.started) {
                st.started = true;
                while (st.remaining > 0) : (st.remaining -= 1) {
                    switch (try iterNextDirect(it, under, st.next_fn)) {
                        .done => {
                            st.done = true;
                            return iterResultObjectC(it, .undefined, true);
                        },
                        .abrupt => |c| return c,
                        .value => {},
                    }
                }
            }
            switch (try iterNextDirect(it, under, st.next_fn)) {
                .done => {
                    st.done = true;
                    return iterResultObjectC(it, .undefined, true);
                },
                .abrupt => |c| return c,
                .value => |v| return iterResultObjectC(it, v, false),
            }
        },
        .flat_map => {
            while (true) {
                if (st.inner) |inner| {
                    switch (try iterNextDirect(it, .{ .object = inner }, st.inner_next)) {
                        .done => st.inner = null,
                        .abrupt => |c| {
                            st.done = true;
                            try it.iteratorClose(st.underlying);
                            return c;
                        },
                        .value => |v| return iterResultObjectC(it, v, false),
                    }
                } else {
                    switch (try iterNextDirect(it, under, st.next_fn)) {
                        .done => {
                            st.done = true;
                            return iterResultObjectC(it, .undefined, true);
                        },
                        .abrupt => |c| return c,
                        .value => |v| {
                            const mapped = try it.callFunction(st.callback.object, &.{ v, .{ .number = st.counter } }, .undefined);
                            st.counter += 1;
                            if (mapped.isAbrupt()) {
                                st.done = true;
                                try it.iteratorClose(st.underlying);
                                return mapped;
                            }
                            switch (try getIteratorFlattenable(it, mapped.normal, false)) {
                                .abrupt => |c| {
                                    st.done = true;
                                    try it.iteratorClose(st.underlying);
                                    return c;
                                },
                                .it => |x| {
                                    st.inner = x.obj;
                                    st.inner_next = x.next_fn;
                                },
                            }
                        },
                    }
                }
            }
        },
    }
}

/// Build a fresh `{ value, done }` IteratorResult as a Completion (helper-result convenience).
fn iterResultObjectC(it: *Interpreter, value: Value, done: bool) EvalError!Completion {
    const r = try Object.create(it.arena, it.objectProto());
    try r.set("value", value);
    try r.set("done", .{ .boolean = done });
    return .{ .normal = .{ .object = r } };
}
