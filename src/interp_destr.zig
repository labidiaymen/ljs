//! Extracted from interpreter.zig (behavior-preserving split). Free functions taking
//! `self: *Interpreter`; thin wrappers remain on the struct for cross-module/native call sites.
const std = @import("std");
const ast = @import("ast.zig");
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const Environment = @import("environment.zig").Environment;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const interp_stmt = @import("interp_stmt.zig");
const interp_expr = @import("interp_expr.zig");

// Shared free helpers + named types (defined in interpreter.zig), aliased for natural call sites.
const ArrayDestr = Interpreter.ArrayDestr;

/// §8.6.2 BindingInitialization / §13.15.5.2 — destructure `value` into the bindings of
/// `pattern`, declaring each leaf binding in `env`. Used by both declarations (§14.3) and
/// parameter binding (§15.1). `mutable` is false for `const` targets.
pub fn bindPattern(self: *Interpreter, pattern: *const ast.Pattern, value: Value, env: *Environment, mutable: bool) EvalError!Completion {
    switch (pattern.*) {
        .identifier => |name| {
            // §8.6.2 single-name binding — InitializeBoundName.
            try env.declare(name, value, mutable, true);
            return .{ .normal = .undefined };
        },
        .array => |ap| {
            // §8.5.2 IteratorBindingInitialization — GetIterator(value) ONCE, then step the iterator
            // exactly once per element (Arrays/Strings fast-pathed). When the pattern is satisfied
            // without a rest element and the iterator is not done, IteratorClose it (§7.4.11). An
            // abrupt completion mid-destructuring also closes a not-done iterator before propagating.
            const opened = try destrOpen(self, value);
            var rec: ArrayDestr = switch (opened) {
                .abrupt => |c| return c,
                .driver => |d| d,
            };
            for (ap.elements) |el| {
                // §8.5.2: each element (incl. an elision) advances the iterator exactly once.
                const sc = try destrStep(self, &rec);
                if (sc.isAbrupt()) return sc; // IteratorStep threw → already done, no close needed
                if (el.target == null) continue; // elision / hole — value consumed, bound nowhere
                var v: Value = sc.normal;
                if (v == .undefined) {
                    if (el.default) |dn| { // §8.6.2 apply the `= default` when undefined
                        const dc = self.evalExpr(dn, env) catch |e| {
                            try destrClose(self, rec); // engine error mid-pattern → close, then propagate
                            return e;
                        };
                        if (dc.isAbrupt()) {
                            try destrClose(self, rec); // §8.5.2: abrupt default closes a not-done iterator
                            return dc;
                        }
                        v = dc.normal;
                        // §8.6.2 SingleNameBinding step 6.d: an anonymous fn/class default initializer
                        // bound to a single identifier takes that identifier as its `name`.
                        if (el.target.?.* == .identifier)
                            try self.maybeSetAnonName(dn, v, el.target.?.identifier);
                    }
                }
                const bc = bindPattern(self, el.target.?, v, env, mutable) catch |e| {
                    try destrClose(self, rec);
                    return e;
                };
                if (bc.isAbrupt()) {
                    try destrClose(self, rec); // §8.5.2: a throwing sub-pattern closes the iterator
                    return bc;
                }
            }
            if (ap.rest) |rest_pat| {
                // §13.15.5.3 BindingRestElement — drain the REMAINDER into a fresh Array (consumes to
                // completion; step-bounded so an infinite iterable fails via the watchdog).
                const rest = try destrRest(self, &rec);
                const rest_arr = switch (rest) {
                    .abrupt => |c| return c, // a throwing next() during the drain (iterator now done)
                    .array => |a| a,
                };
                const bc = try bindPattern(self, rest_pat, .{ .object = rest_arr }, env, mutable);
                if (bc.isAbrupt()) return bc;
            } else {
                // §13.15.5.3: pattern satisfied with no rest → close the iterator if not done. A
                // NORMAL completion close (§7.4.11): a throwing `return()` / non-object propagates.
                const cc = try destrCloseChecked(self, rec);
                if (cc.isAbrupt()) return cc;
            }
            return .{ .normal = .undefined };
        },
        .object => |op| {
            // §13.15.5.5 ObjectBindingPattern — requires a coercible value (§13.15.5.4).
            if (value == .undefined or value == .null) {
                return self.throwError("TypeError", "Cannot destructure null or undefined");
            }
            // §14.3.3 with a BindingRestProperty: the set of property keys bound by the explicit
            // properties is excluded from the rest. A ComputedPropertyName is evaluated ONCE (in
            // source order, before its value is read) — record the resolved string key so the rest
            // excludes it too (a symbol-valued computed key never collides with the string rest copy).
            var excluded: std.ArrayList([]const u8) = .empty;
            for (op.properties) |prop| {
                var key_val: Value = .{ .string = prop.key };
                if (prop.computed) |ck| {
                    // §13.2.5 ComputedPropertyName + §7.1.19 ToPropertyKey, evaluated at bind time.
                    const kc = try self.evalExpr(ck, env);
                    if (kc.isAbrupt()) return kc;
                    key_val = if (kc.normal == .symbol) kc.normal else .{ .string = try self.toString(kc.normal) };
                }
                if (op.rest != null and key_val == .string) try excluded.append(self.arena, key_val.string);
                const gc = try self.getPropertyV(value, key_val);
                if (gc.isAbrupt()) return gc;
                var v = gc.normal;
                if (v == .undefined) {
                    if (prop.default) |dn| {
                        const dc = try self.evalExpr(dn, env);
                        if (dc.isAbrupt()) return dc;
                        v = dc.normal;
                        // §13.3.3.7 KeyedBindingInitialization step 6.d: name an anonymous fn/class
                        // default initializer after a single-identifier binding target.
                        if (prop.target.* == .identifier)
                            try self.maybeSetAnonName(dn, v, prop.target.identifier);
                    }
                }
                const bc = try bindPattern(self, prop.target, v, env, mutable);
                if (bc.isAbrupt()) return bc;
            }
            if (op.rest) |rest_name| {
                // §14.3.3 BindingRestProperty — §7.3.25 CopyDataProperties of the own enumerable
                // (string + symbol) props not already destructured, in [[OwnPropertyKeys]] order,
                // into a fresh ordinary object (reading via [[Get]], so getters run).
                const rest_obj = try Object.create(self.arena, self.objectProto());
                if (try interp_expr.copyDataPropertiesExcluding(self, rest_obj, value, excluded.items)) |abrupt| return abrupt;
                try env.declare(rest_name, .{ .object = rest_obj }, mutable, true);
            }
            return .{ .normal = .undefined };
        },
    }
}

/// §13.15.5.2 DestructuringAssignmentEvaluation — the assignment analogue of `bindPattern`. The
/// `target` is a refined ArrayLiteral / ObjectLiteral (or, by recursion, a nested one). Each leaf
/// value is PUT into an EXISTING reference (identifier env assignment with const/TDZ checks via
/// `assignToTarget`; member `a.b` / index `a[k]`; or a further nested pattern). Defaults apply when
/// the matched value is `undefined`. Parallels `bindPattern` but assigns instead of declaring.
pub fn assignPattern(self: *Interpreter, target: *const ast.Node, value: Value, env: *Environment) EvalError!Completion {
    switch (target.*) {
        .array_literal => |elems| {
            // §13.15.5.3 IteratorDestructuringAssignmentEvaluation — GetIterator(value) ONCE, step
            // once per element (Arrays/Strings fast-pathed). A rest element `...t` drains the
            // remainder; otherwise, when the pattern is satisfied and the iterator is not done, close
            // it (§7.4.11). An abrupt completion mid-pattern closes a not-done iterator first.
            const opened = try destrOpen(self, value);
            var rec: ArrayDestr = switch (opened) {
                .abrupt => |c| return c,
                .driver => |d| d,
            };
            for (elems) |el| {
                if (el.* == .spread) {
                    // §13.15.5.3 AssignmentRestElement — drain the remainder, then assign it (the rest
                    // target — identifier / member / index / nested pattern). No close (iterator drained).
                    const rest = try destrRest(self, &rec);
                    const rest_arr = switch (rest) {
                        .abrupt => |c| return c,
                        .array => |a| a,
                    };
                    const rc = try assignTargetNode(self, el.spread, .{ .object = rest_arr }, env);
                    if (rc.isAbrupt()) return rc;
                    return .{ .normal = .undefined }; // rest is always last — done
                }
                // §13.15.5.3: every element (incl. an elision) advances the iterator exactly once.
                const sc = try destrStep(self, &rec);
                if (sc.isAbrupt()) return sc; // IteratorStep threw → already done, no close needed
                if (el.* == .elision) continue; // hole — value consumed, assigned nowhere
                const tc = assignElement(self, el, sc.normal, env) catch |e| {
                    try destrClose(self, rec);
                    return e;
                };
                if (tc.isAbrupt()) {
                    try destrClose(self, rec); // §13.15.5.3: a throwing target/default closes the iterator
                    return tc;
                }
            }
            // §13.15.5.3: pattern satisfied with no rest → close the iterator if not done. A
            // NORMAL completion close (§7.4.11): a throwing `return()` / non-object propagates.
            const cc = try destrCloseChecked(self, rec);
            if (cc.isAbrupt()) return cc;
            return .{ .normal = .undefined };
        },
        .object_literal => |props| {
            // §13.15.5.4: an ObjectAssignmentPattern requires a coercible value.
            if (value == .undefined or value == .null) {
                return self.throwError("TypeError", "Cannot destructure null or undefined");
            }
            // §13.15.5.4: the set of string keys bound by earlier properties is excluded from the
            // rest. Each property's key (incl. a ComputedPropertyName) is evaluated ONCE in source
            // order; record it here so a trailing `...rest` skips it (CopyDataProperties exclusion).
            var excluded: std.ArrayList([]const u8) = .empty;
            for (props) |p| {
                if (p.kind == .spread) {
                    // §13.15.5.4 AssignmentRestProperty — §7.3.25 CopyDataProperties of the remaining
                    // own enumerable (string + symbol) props not named by an earlier property, in
                    // [[OwnPropertyKeys]] order, into a fresh object.
                    const rest_obj = try Object.create(self.arena, self.objectProto());
                    if (try interp_expr.copyDataPropertiesExcluding(self, rest_obj, value, excluded.items)) |abrupt| return abrupt;
                    const rc = try assignTargetNode(self, p.value, .{ .object = rest_obj }, env);
                    if (rc.isAbrupt()) return rc;
                    continue;
                }
                // §13.15.5.5 AssignmentProperty — `key: target = default` / shorthand `{x}` /
                // shorthand-with-default `{x = default}`.
                const key = try interp_expr.propKey(self, p, env);
                if (key.isAbrupt()) return key.completion;
                // A string key (not a symbol) excludes the rest copy (a symbol never collides).
                if (key.symbol == null) try excluded.append(self.arena, key.key);
                const gc = try self.getProperty(value, key.key);
                if (gc.isAbrupt()) return gc;
                var v = gc.normal;
                // §13.2.5.1 shorthand CoverInitializedName `{x = d}`: the default lives in `p.default`
                // (the value is the bare identifier). A `key: target = d` form folds the default into
                // `p.value` (an `assign*` node) — `assignElement` strips and applies that one.
                if (v == .undefined) {
                    if (p.default) |dn| {
                        const dc = try self.evalExpr(dn, env);
                        if (dc.isAbrupt()) return dc;
                        v = dc.normal;
                        // §13.15.5.5 KeyedDestructuringAssignmentEvaluation: name an anonymous
                        // fn/class default on the shorthand `{x = <anon>}` identifier target.
                        if (p.value.* == .identifier)
                            try self.maybeSetAnonName(dn, v, p.value.identifier);
                    }
                }
                const tc = try assignElement(self, p.value, v, env);
                if (tc.isAbrupt()) return tc;
            }
            return .{ .normal = .undefined };
        },
        // A bare target reached as a pattern (shouldn't occur — callers route leaves through
        // `assignElement`/`assignTargetNode`) — assign directly.
        else => return assignTargetNode(self, target, value, env),
    }
}

/// One array-pattern element carrying its own `= default` tail (`[a = d]`, `[a.b = d]`, `[a[k] = d]`,
/// `[this.#x = d]` — the literal parser folded the `=` into an `assign`/`assign_*`/`private_assign`
/// node) or a plain target. Applies the default when `value` is `undefined`, then PUTs the value into
/// the reference. The `assign*` shapes carry the reference inline (name / object+name / object+key),
/// so we assign directly without reconstructing a target node.
pub fn assignElement(self: *Interpreter, el: *const ast.Node, value: Value, env: *Environment) EvalError!Completion {
    switch (el.*) {
        // §13.15.5.5: `target = Initializer` — apply the default when the source value is undefined.
        .assign => |a| {
            const v = try applyDefault(self, value, a.value, env);
            if (v.isAbrupt()) return v;
            // §13.15.5.2 step 5.d: when the default was used (source undefined), an anonymous
            // fn/class initializer on a single-identifier target takes that name.
            if (value == .undefined) try self.maybeSetAnonName(a.value, v.normal, a.name);
            return interp_stmt.assignToTarget(self, &.{ .identifier = a.name }, v.normal, env);
        },
        .assign_member => |m| {
            const oc = try self.evalExpr(m.object, env);
            if (oc.isAbrupt()) return oc;
            const v = try applyDefault(self, value, m.value, env);
            if (v.isAbrupt()) return v;
            return self.setProperty(oc.normal, m.name, v.normal);
        },
        .assign_index => |ix| {
            const oc = try self.evalExpr(ix.object, env);
            if (oc.isAbrupt()) return oc;
            const kc = try self.evalExpr(ix.key, env);
            if (kc.isAbrupt()) return kc;
            const v = try applyDefault(self, value, ix.value, env);
            if (v.isAbrupt()) return v;
            return self.setPropertyV(oc.normal, kc.normal, v.normal);
        },
        .private_assign => |pa| {
            const oc = try self.evalExpr(pa.object, env);
            if (oc.isAbrupt()) return oc;
            const v = try applyDefault(self, value, pa.value, env);
            if (v.isAbrupt()) return v;
            return self.setPrivate(oc.normal, pa.name, v.normal);
        },
        else => return assignTargetNode(self, el, value, env), // plain / nested target, no default
    }
}

/// §13.15.5.5: when the destructured source `value` is `undefined`, evaluate and use `default`;
/// otherwise keep `value`. Returns a Completion so a throwing default initializer propagates.
pub fn applyDefault(self: *Interpreter, value: Value, default: *const ast.Node, env: *Environment) EvalError!Completion {
    if (value != .undefined) return .{ .normal = value };
    return self.evalExpr(default, env);
}

/// Assign `value` to a destructuring TARGET node: a nested array/object pattern (recurse) or a
/// simple assignment reference (identifier / member / index — handled by `assignToTarget`).
pub fn assignTargetNode(self: *Interpreter, target: *const ast.Node, value: Value, env: *Environment) EvalError!Completion {
    switch (target.*) {
        .array_literal, .object_literal => return assignPattern(self, target, value, env),
        else => return interp_stmt.assignToTarget(self, target, value, env),
    }
}

/// §8.5.2 step: advance the array-destructuring iterator exactly once. Returns the produced value
/// (or `undefined` once the iterator is done — IteratorStep returned done, per §13.15.5.3 step 4),
/// or an abrupt completion if `next()` throws. After a done step the record is marked done so later
/// elements short-circuit to `undefined` without further `next()` calls (§8.5.2 4.a).
pub fn destrStep(self: *Interpreter, rec: *ArrayDestr) EvalError!Completion {
    switch (rec.*) {
        .fast => |*f| {
            if (f.idx >= f.items.len) return .{ .normal = .undefined };
            const v = f.items[f.idx];
            f.idx += 1;
            return .{ .normal = v };
        },
        .iter => |*it| {
            if (it.done) return .{ .normal = .undefined };
            try self.tick(); // §reliability: a bounded watchdog even though a fixed pattern steps finitely
            const step = try self.iteratorStep(it.iterator);
            switch (step) {
                .abrupt => |c| {
                    // §7.4.4: an abrupt IteratorStep sets [[Done]] = true (the iterator self-closed).
                    it.done = true;
                    return c;
                },
                .done => {
                    it.done = true;
                    return .{ .normal = .undefined };
                },
                .value => |v| return .{ .normal = v },
            }
        },
    }
}

/// §13.15.5.3 BindingRestElement / AssignmentRestElement — drain the REMAINDER of the iterator into a
/// fresh Array. This is the ONLY destructuring path that consumes to completion; the rest-drain loop
/// is step-bounded so an infinite iterable fails via the watchdog rather than hanging.
pub fn destrRest(self: *Interpreter, rec: *ArrayDestr) EvalError!Interpreter.ArrOrAbrupt {
    const arr = try Object.createArray(self.arena, self.arrayProto());
    switch (rec.*) {
        .fast => |*f| {
            while (f.idx < f.items.len) : (f.idx += 1) try arr.elements.append(self.arena, f.items[f.idx]);
        },
        .iter => |*it| {
            while (!it.done) {
                try self.tick(); // §reliability: a rest over an infinite iterable terminates via the watchdog
                const step = try self.iteratorStep(it.iterator);
                switch (step) {
                    .abrupt => |c| {
                        it.done = true;
                        return .{ .abrupt = c };
                    },
                    .done => it.done = true,
                    .value => |v| try arr.elements.append(self.arena, v),
                }
            }
        },
    }
    return .{ .array = arr };
}

/// §7.4.11 IteratorClose after a destructuring pattern WITHOUT a rest element: if the record is a
/// real iterator that is not yet done, call its `return()`. The plain-Array fast path has no iterator
/// object, so closing is a no-op. On an abrupt `completion` the original throw is preserved (a
/// throwing `return()` is swallowed; an engine error still propagates).
pub fn destrClose(self: *Interpreter, rec: ArrayDestr) EvalError!void {
    switch (rec) {
        .fast => {},
        .iter => |it| if (!it.done) try self.iteratorClose(it.iterator),
    }
}

/// §7.4.11 IteratorClose after a destructuring pattern that completed NORMALLY (no rest, iterator
/// not done): a throwing `return()` (or a non-object result) MUST propagate — unlike `destrClose`,
/// used after an abrupt completion, which swallows (§7.4.11 step 4). Returns `.normal` on a clean
/// close (incl. the fast Array path, which has no iterator object).
pub fn destrCloseChecked(self: *Interpreter, rec: ArrayDestr) EvalError!Completion {
    switch (rec) {
        .fast => return .{ .normal = .undefined },
        .iter => |it| return if (it.done) .{ .normal = .undefined } else self.iteratorCloseChecked(it.iterator),
    }
}

/// GetIterator(value) once for array destructuring, choosing the unobservable fast path for a plain
/// Array (default iterator) and the §7.4 protocol otherwise. A non-iterable → abrupt TypeError.
pub fn destrOpen(self: *Interpreter, value: Value) EvalError!Interpreter.DriverOrAbrupt {
    if (value == .object and value.object.kind == .array) {
        const arr = value.object;
        const len = arr.arrayLen();
        if (len == arr.elements.items.len) {
            return .{ .driver = .{ .fast = .{ .items = arr.elements.items } } }; // pure dense (hot path)
        }
        // Sparse: materialize length items (holes → `undefined`) once, then drive the fast path.
        var items: std.ArrayListUnmanaged(Value) = .empty;
        var i: usize = 0;
        while (i < len) : (i += 1) try items.append(self.arena, arr.arrayGet(i));
        return .{ .driver = .{ .fast = .{ .items = items.items } } };
    }
    if (value == .string) {
        // A String iterates code units; materialize once (finite) and drive the fast path over them.
        const s = value.string;
        var units: std.ArrayListUnmanaged(Value) = .empty;
        for (0..s.len) |i| try units.append(self.arena, .{ .string = s[i .. i + 1] });
        return .{ .driver = .{ .fast = .{ .items = units.items } } };
    }
    const git = try self.getIterator(value);
    return switch (git) {
        .abrupt => |c| .{ .abrupt = c },
        .iterator => |iterator| .{ .driver = .{ .iter = .{ .iterator = iterator } } },
    };
}
