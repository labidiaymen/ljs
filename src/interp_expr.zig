//! Extracted from interpreter.zig (behavior-preserving split). Free functions taking
//! `self: *Interpreter`; thin wrappers remain on the struct for cross-module/native call sites.
const std = @import("std");
const ast = @import("ast.zig");
const Value = @import("value.zig").Value;
const Symbol = @import("value.zig").Symbol;
const Completion = @import("completion.zig").Completion;
const Environment = @import("environment.zig").Environment;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const ops = @import("abstract_ops.zig");
const bigint = @import("bigint.zig");
const Parser = @import("parser.zig").Parser;
const builtin_proxy = @import("builtin_proxy.zig");
const builtin_regexp = @import("builtin_regexp.zig");
const builtin_arraybuffer = @import("builtin_arraybuffer.zig");
const builtin_typedarray = @import("builtin_typedarray.zig");
const builtin_dataview = @import("builtin_dataview.zig");
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const interp_property = @import("interp_property.zig");
const interp_class = @import("interp_class.zig");
const interp_stmt = @import("interp_stmt.zig");
const interp_destr = @import("interp_destr.zig");
const interp_ops = @import("interp_ops.zig");
const interp_async = @import("interp_async.zig");
const interp_native = @import("interp_native.zig");
const interp_collection = @import("interp_collection.zig");

const toNumber = ops.toNumber;
const toBoolean = ops.toBoolean;
const typeOf = ops.typeOf;
const numToInt32 = ops.numberToInt32;

// Shared free helpers + named types (defined in interpreter.zig), aliased for natural call sites.
const shouldAssign = interpreter.shouldAssign;
const blockHasUsing = interpreter.blockHasUsing;
const ChainResult = Interpreter.ChainResult;
const KeyResult = Interpreter.KeyResult;

const envHasWith = interp_stmt.envHasWith;

pub fn evalExpr(self: *Interpreter, node: *const ast.Node, env: *Environment) EvalError!Completion {
    try self.tick();
    self.depth += 1;
    defer self.depth -= 1;
    if (self.depth > self.max_depth) return self.throwError("RangeError", "Maximum call stack size exceeded");
    switch (node.*) {
        .number => |n| return .{ .normal = .{ .number = n } },
        .bigint => |b| return .{ .normal = .{ .bigint = b } }, // §12.9.3.2 BigIntLiteral
        .string => |s| return .{ .normal = .{ .string = s } },
        .boolean => |b| return .{ .normal = .{ .boolean = b } },
        .null => return .{ .normal = .null },
        .regex_literal => |r| return builtin_regexp.makeRegExp(self, r.pattern, r.flags), // §13.2.7
        .identifier => |name| {
            // §9.4.2 ResolveBinding + §6.2.5.5 GetValue + §9.1.1.1.6 GetBindingValue.
            if (self.with_depth > 0) switch (interp_stmt.resolveIdRef(self, env, name)) {
                .with_object => |o| return self.getProperty(.{ .object = o }, name),
                .binding => |b| {
                    if (!b.initialized) return self.throwError("ReferenceError", name);
                    return .{ .normal = b.value };
                },
                // §9.1.1.4.6 GetBindingValue: a name absent from the declarative chain still resolves
                // against the global object record (a `this.x = …`-installed global), else ReferenceError.
                .unresolved => {
                    if (globalObjectHas(self, name)) return self.getProperty(.{ .object = globalObject(self).? }, name);
                    return self.throwError("ReferenceError", name);
                },
            };
            const raw = env.lookup(name) orelse {
                if (globalObjectHas(self, name)) return self.getProperty(.{ .object = globalObject(self).? }, name);
                return self.throwError("ReferenceError", name);
            };
            // §16.2.1.6 resolve an import alias through to the exporting module's live binding cell.
            const b = Environment.resolveAlias(raw) orelse return self.throwError("ReferenceError", name);
            if (!b.initialized) return self.throwError("ReferenceError", name); // TDZ (staged; see declaration note)
            return .{ .normal = b.value };
        },
        .assign => |a| {
            // §13.15.2 AssignmentExpression; mutation via §6.2.5.6 PutValue (identifier target).
            const c = try self.evalExpr(a.value, env);
            if (c.isAbrupt()) return c;
            // §13.15.2 / §8.4: `f = function(){}` (anonymous RHS, identifier LHS) → NamedEvaluation.
            try self.maybeSetAnonName(a.value, c.normal, a.name);
            if (self.with_depth > 0) switch (interp_stmt.resolveIdRef(self, env, a.name)) {
                .with_object => |o| return self.setProperty(.{ .object = o }, a.name, c.normal),
                .binding => |b| {
                    if (!b.initialized) return self.throwError("ReferenceError", a.name); // §13.x TDZ
                    if (!b.mutable) return self.throwError("TypeError", "Assignment to constant variable.");
                    b.value = c.normal;
                    return .{ .normal = c.normal };
                },
                .unresolved => return interp_stmt.assignUnresolved(self, a.name, c.normal),
            };
            const b = env.lookup(a.name) orelse return interp_stmt.assignUnresolved(self, a.name, c.normal);
            if (!b.initialized) return self.throwError("ReferenceError", a.name); // §13.x PutValue to a TDZ binding
            if (!b.mutable) return self.throwError("TypeError", "Assignment to constant variable.");
            b.value = c.normal;
            return .{ .normal = c.normal };
        },
        .unary => |u| return evalUnary(self, u.op, u.operand, env),
        .comma => |c| {
            // §13.16.1 Expression : Expression `,` AssignmentExpression — evaluate the left
            // operand for its side effects (discarding its value via GetValue), then evaluate and
            // yield the right operand.
            const lc = try self.evalExpr(c.left, env);
            if (lc.isAbrupt()) return lc;
            return self.evalExpr(c.right, env);
        },
        .binary => |b| return interp_ops.evalBinary(self, b.op, b.left, b.right, env),
        .object_literal => |props| return evalObjectLiteral(self, props, env),
        .array_literal => |elems| {
            // §13.2.4 ArrayLiteral — `...spread` elements flatten in place; an `elision` hole
            // contributes a TRUE hole (it advances the index without defining the slot, so the
            // resulting array is sparse there: `1 in [1,,3]` is false, holes are skipped by
            // forEach/reduce/indexOf, etc.). A trailing elision the parser appended to mark `[...x,]`
            // (a valid literal trailing comma after a spread) is dropped here so it adds no slot.
            var list = elems;
            if (list.len >= 2 and list[list.len - 1].* == .elision and list[list.len - 2].* == .spread) {
                list = list[0 .. list.len - 1];
            }
            const arr = try Object.createArray(self.arena, self.arrayProto());
            var idx: usize = 0;
            for (list) |n| {
                if (n.* == .elision) {
                    idx += 1; // hole — leave the slot undefined/absent
                    continue;
                }
                if (n.* == .spread) {
                    const sc = try self.evalExpr(n.spread, env);
                    if (sc.isAbrupt()) return sc;
                    var tmp: std.ArrayListUnmanaged(Value) = .empty;
                    const ic = try self.iterateToList(sc.normal, &tmp);
                    if (ic.isAbrupt()) return ic;
                    for (tmp.items) |v| {
                        try arr.arraySet(self.arena, idx, v);
                        idx += 1;
                    }
                    continue;
                }
                const c = try self.evalExpr(n, env);
                if (c.isAbrupt()) return c;
                try arr.arraySet(self.arena, idx, c.normal);
                idx += 1;
            }
            // A trailing elision (e.g. `[1,,]` ⇒ length 2 with a hole at index 1) sets the length
            // past the last defined slot; `arraySet` only bumps length up to the last write.
            if (idx > arr.arrayLen()) try arr.arraySetLen(idx);
            return .{ .normal = .{ .object = arr } };
        },
        .elision => return .{ .normal = .undefined }, // §13.2.4 array hole → `undefined` value
        .assign_pattern => |ap| {
            // §13.15.5 DestructuringAssignment — evaluate the RHS once, destructure it into the
            // refined literal pattern, and yield the RHS value.
            const rc = try self.evalExpr(ap.value, env);
            if (rc.isAbrupt()) return rc;
            const pc = try interp_destr.assignPattern(self, ap.target, rc.normal, env);
            if (pc.isAbrupt()) return pc;
            return .{ .normal = rc.normal };
        },
        .member => |m| {
            const oc = try self.evalExpr(m.object, env);
            if (oc.isAbrupt()) return oc;
            return self.getProperty(oc.normal, m.name);
        },
        .index => |ix| {
            const oc = try self.evalExpr(ix.object, env);
            if (oc.isAbrupt()) return oc;
            const kc = try self.evalExpr(ix.key, env);
            if (kc.isAbrupt()) return kc;
            return self.getPropertyV(oc.normal, kc.normal);
        },
        .assign_member => |am| {
            const oc = try self.evalExpr(am.object, env);
            if (oc.isAbrupt()) return oc;
            const vc = try self.evalExpr(am.value, env);
            if (vc.isAbrupt()) return vc;
            return self.setProperty(oc.normal, am.name, vc.normal);
        },
        .assign_index => |ai| {
            const oc = try self.evalExpr(ai.object, env);
            if (oc.isAbrupt()) return oc;
            const kc = try self.evalExpr(ai.key, env);
            if (kc.isAbrupt()) return kc;
            const vc = try self.evalExpr(ai.value, env);
            if (vc.isAbrupt()) return vc;
            return self.setPropertyV(oc.normal, kc.normal, vc.normal);
        },
        .function => |f| return self.evalFunctionExpr(f, env),
        .class_expr => |c| return evalClass(self, c, env),
        .yield_expr => |y| {
            // §14.4 YieldExpression — legal only on a generator body thread (`current_gen` set).
            // A `yield` reached outside a generator at runtime should not occur (the parser rejects
            // it), but guard defensively.
            if (self.current_gen == null) return self.throwError("SyntaxError", "yield outside a generator");
            var arg: Value = .undefined;
            if (y.argument) |an| {
                const ac = try self.evalExpr(an, env);
                if (ac.isAbrupt()) return ac;
                arg = ac.normal;
            }
            // §27.6.3.8 in an ASYNC generator, `yield` is AsyncGeneratorYield (await the operand,
            // then suspend producing {value,done:false}); `yield*` delegates over an async iterator.
            const cg = self.current_gen.?;
            if (cg.is_async_gen) {
                if (y.delegate) return interp_async.doAsyncYieldDelegate(self, arg);
                return interp_async.doAsyncYield(self, arg);
            }
            // §15.5.5 `yield* expr` delegates to the iterator of `expr`; plain `yield expr` performs
            // a single handoff.
            if (y.delegate) return interp_async.doYieldDelegate(self, arg);
            return interp_async.doYield(self, arg);
        },
        .await_expr => |operand| {
            // §27.7.5.3 AwaitExpression — evaluate the operand, then suspend the async body via the
            // ping-pong handoff: the awaited value is carried out, the caller registers fulfill/
            // reject reactions on PromiseResolve(value) that resume this body when it settles. Legal
            // only on an async body thread (`current_gen.is_async`); the parser rejects `await`
            // outside async, but guard defensively for a stray top-level await.
            const oc = try self.evalExpr(operand, env);
            if (oc.isAbrupt()) return oc;
            const cg = self.current_gen orelse return self.throwError("SyntaxError", "await outside an async function");
            if (!cg.is_async) return self.throwError("SyntaxError", "await outside an async function");
            return interp_async.doAwait(self, oc.normal);
        },
        .call => |c| return evalCall(self, c, env),
        .new_expr => |n| return evalNew(self, n, env),
        .import_call => |ic| return evalImportCall(self, ic, env),
        .logical => |l| {
            // §13.13 short-circuit: `||` returns left if truthy, `&&` returns left if falsy,
            // `??` returns left unless it is null/undefined (then the right operand).
            const lc = try self.evalExpr(l.left, env);
            if (lc.isAbrupt()) return lc;
            switch (l.op) {
                .or_ => if (toBoolean(lc.normal)) return lc,
                .and_ => if (!toBoolean(lc.normal)) return lc,
                .coalesce => if (lc.normal != .undefined and lc.normal != .null) return lc,
            }
            return self.evalExpr(l.right, env);
        },
        .logical_assign => |la| return evalLogicalAssign(self, la, env),
        .compound_assign => |ca| return evalCompoundAssign(self, ca, env),
        .optional => return evalOptionalChain(self, node, env),
        .conditional => |c| {
            // §13.14 cond ? then : otherwise
            const cc = try self.evalExpr(c.cond, env);
            if (cc.isAbrupt()) return cc;
            return self.evalExpr(if (toBoolean(cc.normal)) c.then else c.otherwise, env);
        },
        .update => |u| {
            // §13.4 ++/-- : read target → ToNumber → ±1 → write back; yield old (postfix) or new (prefix).
            const delta: f64 = if (u.op == .inc) 1 else -1;
            switch (u.target.*) {
                .identifier => |name| {
                    const b = env.lookup(name) orelse return self.throwError("ReferenceError", name);
                    // §16.2.1.6: an import binding is immutable — `++`/`--` on it is a TypeError.
                    if (b.alias != null) return self.throwError("TypeError", "Assignment to constant variable.");
                    if (!b.initialized) return self.throwError("ReferenceError", name); // §13.4 TDZ on the GetValue
                    const oldc = try self.toNumberV(b.value);
                    if (oldc.isAbrupt()) return oldc;
                    const old = oldc.normal.number;
                    b.value = .{ .number = old + delta };
                    return .{ .normal = .{ .number = if (u.prefix) old + delta else old } };
                },
                .member => |m| {
                    const oc = try self.evalExpr(m.object, env);
                    if (oc.isAbrupt()) return oc;
                    const cur = try self.getProperty(oc.normal, m.name);
                    if (cur.isAbrupt()) return cur;
                    const oldc = try self.toNumberV(cur.normal);
                    if (oldc.isAbrupt()) return oldc;
                    const old = oldc.normal.number;
                    const sc = try self.setProperty(oc.normal, m.name, .{ .number = old + delta });
                    if (sc.isAbrupt()) return sc;
                    return .{ .normal = .{ .number = if (u.prefix) old + delta else old } };
                },
                .index => |ix| {
                    const oc = try self.evalExpr(ix.object, env);
                    if (oc.isAbrupt()) return oc;
                    const kc = try self.evalExpr(ix.key, env);
                    if (kc.isAbrupt()) return kc;
                    // §6.2.5.5/.6 + §7.1.19: RequireObjectCoercible(base) precedes the SINGLE
                    // ToPropertyKey; the coerced primitive feeds both the read and the write-back.
                    if (oc.normal == .undefined or oc.normal == .null) return self.throwError("TypeError", "Cannot read properties of null or undefined");
                    const keyc = try self.coercePropertyKey(kc.normal);
                    if (keyc.isAbrupt()) return keyc;
                    const cur = try self.getPropertyV(oc.normal, keyc.normal);
                    if (cur.isAbrupt()) return cur;
                    const oldc = try self.toNumberV(cur.normal);
                    if (oldc.isAbrupt()) return oldc;
                    const old = oldc.normal.number;
                    const sc = try self.setPropertyV(oc.normal, keyc.normal, .{ .number = old + delta });
                    if (sc.isAbrupt()) return sc;
                    return .{ .normal = .{ .number = if (u.prefix) old + delta else old } };
                },
                .private_member => |pm| {
                    // §13.4 `obj.#x++` — brand-checked read, ToNumber, write back.
                    const oc = try self.evalExpr(pm.object, env);
                    if (oc.isAbrupt()) return oc;
                    const cur = try self.getPrivate(oc.normal, pm.name);
                    if (cur.isAbrupt()) return cur;
                    const oldc = try self.toNumberV(cur.normal);
                    if (oldc.isAbrupt()) return oldc;
                    const old = oldc.normal.number;
                    const sc = try self.setPrivate(oc.normal, pm.name, .{ .number = old + delta });
                    if (sc.isAbrupt()) return sc;
                    return .{ .normal = .{ .number = if (u.prefix) old + delta else old } };
                },
                .super_member => |sm| {
                    // §13.4 `super.x++` — read via the SuperProperty getter, ToNumber, write back.
                    const key = if (sm.key) |kn| blk: {
                        const kc = try self.evalExpr(kn, env);
                        if (kc.isAbrupt()) return kc;
                        break :blk try self.toString(kc.normal);
                    } else sm.name;
                    const cur = try getSuperProperty(self, key);
                    if (cur.isAbrupt()) return cur;
                    const oldc = try self.toNumberV(cur.normal);
                    if (oldc.isAbrupt()) return oldc;
                    const old = oldc.normal.number;
                    const sc = try setSuperProperty(self, key, .{ .number = old + delta });
                    if (sc.isAbrupt()) return sc;
                    return .{ .normal = .{ .number = if (u.prefix) old + delta else old } };
                },
                else => return self.throwError("SyntaxError", "Invalid update expression target"),
            }
        },
        .template => |t| {
            // §13.2.8 — concatenate quasis with ToString of each substitution.
            var buf: std.ArrayList(u8) = .empty;
            for (t.quasis, 0..) |q, idx| {
                try buf.appendSlice(self.arena, q);
                if (idx < t.exprs.len) {
                    const c = try self.evalExpr(t.exprs[idx], env);
                    if (c.isAbrupt()) return c;
                    const s = try interp_ops.toStringCoerceV(self, c.normal); // §13.2.8.5: ToPrimitive(string)+ToString; throws on a Symbol
                    switch (s) {
                        .abrupt => |a| return a,
                        .string => |str| try buf.appendSlice(self.arena, str),
                    }
                }
            }
            return .{ .normal = .{ .string = buf.items } };
        },
        .this => {
            // §13.3.7 / §9.3.3 GetThisBinding: reading `this` before `super(...)` in a derived
            // constructor (the TDZ) is a ReferenceError.
            if (self.this_init_cell) |c| if (!c.*) return self.throwError("ReferenceError", "Must call super constructor in derived class before accessing 'this'");
            return .{ .normal = self.this_val };
        },
        // §13.3.12.1 NewTarget — the active function's [[NewTarget]] (the constructor when invoked
        // via `new`/`super(...)`, else `undefined`). Arrows inherit it lexically (saved/restored
        // like `this_val`, never reset on an arrow [[Call]]).
        .new_target => return .{ .normal = self.new_target },
        .super_call => |args| return evalSuperCall(self, args, env),
        .super_member => |sm| {
            // §13.3.5 SuperProperty (read) — `super.x` / `super[k]`: look up on the home object's
            // [[Prototype]], with `this` = the current `this` as the receiver (for getters).
            const key = if (sm.key) |kn| blk: {
                const kc = try self.evalExpr(kn, env);
                if (kc.isAbrupt()) return kc;
                break :blk try self.toString(kc.normal);
            } else sm.name;
            return getSuperProperty(self, key);
        },
        .super_assign => |sa| {
            // §13.3.5/§6.2.5.6 `super.x = v` / `super[k] = v` — evaluate the (computed) key, then
            // the value, then PutValue through the SuperProperty reference (receiver = `this`).
            const key = if (sa.key) |kn| blk: {
                const kc = try self.evalExpr(kn, env);
                if (kc.isAbrupt()) return kc;
                break :blk try self.toString(kc.normal);
            } else sa.name;
            const vc = try self.evalExpr(sa.value, env);
            if (vc.isAbrupt()) return vc;
            return setSuperProperty(self, key, vc.normal);
        },
        .private_member => |pm| {
            // §13.3.2 `obj.#x` — read a private member from `obj`'s private slot.
            const oc = try self.evalExpr(pm.object, env);
            if (oc.isAbrupt()) return oc;
            return self.getPrivate(oc.normal, pm.name);
        },
        .private_assign => |pa| {
            // §13.3.2 `obj.#x = v` — write a private member.
            const oc = try self.evalExpr(pa.object, env);
            if (oc.isAbrupt()) return oc;
            const vc = try self.evalExpr(pa.value, env);
            if (vc.isAbrupt()) return vc;
            return self.setPrivate(oc.normal, pa.name, vc.normal);
        },
        .private_in => |pi| {
            // §13.10.1 `#x in obj` — the ergonomic brand check. False (no throw) for a non-object
            // or an object lacking the brand; true iff `obj` carries the private name.
            const oc = try self.evalExpr(pi.object, env);
            if (oc.isAbrupt()) return oc;
            const has = oc.normal == .object and oc.normal.object.hasPrivate(pi.name);
            return .{ .normal = .{ .boolean = has } };
        },
        .spread => return self.throwError("SyntaxError", "Unexpected token '...'"), // only valid in array/call/new lists
    }
}

/// §15.7 PrivateGet — read PrivateName `key` from `base`'s own private slot. Accessing a private
/// name on a non-object, or on an object lacking the brand, is a TypeError (§15.7 — the brand
/// check). A private accessor invokes its getter with `this` = `base`; a getter-less accessor
/// (set-only) is a TypeError on read.
pub fn getPrivate(self: *Interpreter, base: Value, key: []const u8) EvalError!Completion {
    return interp_property.getPrivate(self, base, key);
}

/// §15.7 PrivateSet — write PrivateName `key` on `base`'s own private slot. The brand must exist
/// (TypeError otherwise). A private field is writable; a private method is read-only (TypeError on
/// assignment); a private accessor invokes its setter with `this` = `base` (set-less → TypeError).
pub fn setPrivate(self: *Interpreter, base: Value, key: []const u8, value: Value) EvalError!Completion {
    return interp_property.setPrivate(self, base, key, value);
}

/// §13.3.5 GetSuperBase + Get — resolve `super.<key>` against the active method's
/// [[HomeObject]].[[Prototype]], invoking accessors with `this` = the current `this` (the
/// receiver), NOT against `this`'s own properties. A missing home/proto yields `undefined`.
pub fn getSuperProperty(self: *Interpreter, key: []const u8) EvalError!Completion {
    return interp_property.getSuperProperty(self, key);
}

/// §13.3.5/§6.2.5.6 SuperProperty write — `super.x = v`. The reference's base is the home
/// object's [[Prototype]] but the receiver is the current `this` (§10.1.9.2): an accessor found
/// on the super chain has its SETTER invoked with `this` = the receiver; otherwise the value is
/// written on the RECEIVER (the instance), not the prototype. (A non-writable data property on
/// the super chain rejecting the write is an M-subset-deferred edge — see spec 060.)
pub fn setSuperProperty(self: *Interpreter, key: []const u8, value: Value) EvalError!Completion {
    return interp_property.setSuperProperty(self, key, value);
}

/// §13.3.7.1 SuperCall — invoke the superclass constructor with the current `this`. M-subset:
/// the instance already exists (created proto-linked to the derived `.prototype` by `evalNew`);
/// `super(...)` runs the parent constructor body on that same `this`, initializing parent fields
/// and running the parent constructor logic. The superclass constructor is read from the active
/// method's [[HomeObject]] chain (the derived constructor's home is the derived `.prototype`; its
/// `super_ctor` carries the linked parent). Returns the (unchanged) instance value.
pub fn evalSuperCall(self: *Interpreter, arg_nodes: []const *const ast.Node, env: *Environment) EvalError!Completion {
    // The active derived constructor is `home_object.constructor`; it carries the linked parent
    // (`super_ctor`) and this class's own instance fields, initialized AFTER the parent returns.
    const cur_fd = currentCtorData(self) orelse
        return self.throwError("SyntaxError", "'super' keyword unexpected here");
    // §13.3.7.1 step 1: `this` must be uninitialized — a second `super(...)` in the same derived
    // constructor (BindThisValue on an already-bound `this`) is a ReferenceError.
    if (self.this_init_cell) |c| if (c.*) return self.throwError("ReferenceError", "Super constructor may only be called once");
    var args: std.ArrayListUnmanaged(Value) = .empty;
    const alc = try evalSpreadList(self, arg_nodes, env, &args);
    if (alc.isAbrupt()) return alc;
    if (self.this_val != .object) return self.throwError("ReferenceError", "'super' called with no 'this'");
    const instance = self.this_val.object;
    // §15.7.14: run the parent constructor (its own fields-before-body for a base parent), then
    // this derived class's own instance fields — both on the existing `this`.
    if (cur_fd.super_ctor) |sup| {
        const pc = try runParentCtor(self, sup, args.items, instance);
        if (pc.isAbrupt()) return pc;
    }
    // §13.3.7.1: `this` is now bound (BindThisValue) — leave the TDZ before field initializers run
    // (a field initializer may reference `this`).
    if (self.this_init_cell) |c| c.* = true;
    const fc = try initInstanceFields(self, cur_fd, instance);
    if (fc.isAbrupt()) return fc;
    return .{ .normal = self.this_val };
}

/// The active method's enclosing constructor FunctionData: the active [[HomeObject]] is the
/// class's `.prototype`, whose `constructor` is that class's constructor (carrying `super_ctor`
/// and the instance `fields`). Used by `super(...)` to find the parent ctor + own fields.
pub fn currentCtorData(self: *Interpreter) ?@import("object.zig").FunctionData {
    const home = self.home_object orelse return null;
    const ctor_v = home.get("constructor") orelse return null;
    if (ctor_v != .object) return null;
    return ctor_v.object.call;
}

/// §13.15.2 LogicalAssignment `&&=` / `||=` / `??=`. Short-circuit, evaluating the target
/// reference EXACTLY ONCE: resolve the reference (binding, or base [+ key] for member/index),
/// read the current value, let the guard decide, and only then evaluate the RHS and write.
///   • `&&=` assigns only when the current value is truthy.
///   • `||=` assigns only when the current value is falsy.
///   • `??=` assigns only when the current value is null/undefined (§13.13 nullish, from Cycle 6).
/// Yields the final value of the target (the RHS when assigned, else the unchanged value).
pub fn evalLogicalAssign(self: *Interpreter, la: anytype, env: *Environment) EvalError!Completion {
    switch (la.target.*) {
        .identifier => |name| {
            const b = env.lookup(name) orelse return self.throwError("ReferenceError", name);
            if (!b.initialized) return self.throwError("ReferenceError", name); // TDZ
            if (!shouldAssign(la.op, b.value)) return .{ .normal = b.value };
            const rc = try self.evalExpr(la.value, env);
            if (rc.isAbrupt()) return rc;
            if (!b.mutable) return self.throwError("TypeError", "Assignment to constant variable.");
            b.value = rc.normal;
            return .{ .normal = rc.normal };
        },
        .member => |m| {
            const oc = try self.evalExpr(m.object, env); // base evaluated once
            if (oc.isAbrupt()) return oc;
            const cur = try self.getProperty(oc.normal, m.name);
            if (cur.isAbrupt()) return cur;
            if (!shouldAssign(la.op, cur.normal)) return cur;
            const rc = try self.evalExpr(la.value, env);
            if (rc.isAbrupt()) return rc;
            return self.setProperty(oc.normal, m.name, rc.normal);
        },
        .index => |ix| {
            const oc = try self.evalExpr(ix.object, env); // base evaluated once
            if (oc.isAbrupt()) return oc;
            const kc = try self.evalExpr(ix.key, env); // key evaluated once
            if (kc.isAbrupt()) return kc;
            const key = try self.toString(kc.normal);
            const cur = try self.getProperty(oc.normal, key);
            if (cur.isAbrupt()) return cur;
            if (!shouldAssign(la.op, cur.normal)) return cur;
            const rc = try self.evalExpr(la.value, env);
            if (rc.isAbrupt()) return rc;
            return self.setProperty(oc.normal, key, rc.normal);
        },
        .private_member => |pm| {
            // §13.15.2 `obj.#x ||= v` etc. — base evaluated once, brand-checked read, then the
            // guard decides whether to write the RHS to the private slot.
            const oc = try self.evalExpr(pm.object, env);
            if (oc.isAbrupt()) return oc;
            const cur = try self.getPrivate(oc.normal, pm.name);
            if (cur.isAbrupt()) return cur;
            if (!shouldAssign(la.op, cur.normal)) return cur;
            const rc = try self.evalExpr(la.value, env);
            if (rc.isAbrupt()) return rc;
            return self.setPrivate(oc.normal, pm.name, rc.normal);
        },
        .super_member => |sm| {
            // §13.15.2 `super.x ||= v` etc. — read via the SuperProperty getter (key once), guard,
            // then write via the SuperProperty setter (receiver = `this`).
            const key = if (sm.key) |kn| blk: {
                const kc = try self.evalExpr(kn, env);
                if (kc.isAbrupt()) return kc;
                break :blk try self.toString(kc.normal);
            } else sm.name;
            const cur = try getSuperProperty(self, key);
            if (cur.isAbrupt()) return cur;
            if (!shouldAssign(la.op, cur.normal)) return cur;
            const rc = try self.evalExpr(la.value, env);
            if (rc.isAbrupt()) return rc;
            return setSuperProperty(self, key, rc.normal);
        },
        else => return self.throwError("SyntaxError", "Invalid assignment target"),
    }
}

/// §13.15.2 compound AssignmentExpression `target op= value` (`+= -= *= …`). The reference is
/// evaluated ONCE (base + key coerced a single time), its current value read, combined with `value`
/// via the §13.15.3 operator, and written back. Keeping the node intact (rather than the
/// `target = target op value` desugar) is what makes a side-effecting base/key run exactly once.
pub fn evalCompoundAssign(self: *Interpreter, ca: anytype, env: *Environment) EvalError!Completion {
    switch (ca.target.*) {
        .identifier => |name| {
            // §13.15.2: read the current value, evaluate the RHS, combine, then PutValue. With a
            // `with` in scope the reference is re-resolved at write time (matching §9.1.1.2.5: a
            // getter that deletes its own binding makes the strict-mode PutValue a ReferenceError).
            if (self.with_depth > 0) {
                const cur: Value = switch (interp_stmt.resolveIdRef(self, env, name)) {
                    .with_object => |o| blk: {
                        const c = try self.getProperty(.{ .object = o }, name);
                        if (c.isAbrupt()) return c;
                        break :blk c.normal;
                    },
                    .binding => |b| blk: {
                        if (!b.initialized) return self.throwError("ReferenceError", name);
                        break :blk b.value;
                    },
                    .unresolved => return self.throwError("ReferenceError", name),
                };
                const rc = try self.evalExpr(ca.value, env);
                if (rc.isAbrupt()) return rc;
                const res = try interp_ops.applyNumericOrStringOp(self, ca.op, cur, rc.normal);
                if (res.isAbrupt()) return res;
                switch (interp_stmt.resolveIdRef(self, env, name)) { // §6.2.5.6 PutValue: re-resolve the reference
                    .with_object => |o| {
                        const sc = try self.setProperty(.{ .object = o }, name, res.normal);
                        if (sc.isAbrupt()) return sc;
                    },
                    .binding => |b| {
                        if (!b.mutable) return self.throwError("TypeError", "Assignment to constant variable.");
                        b.value = res.normal;
                    },
                    .unresolved => return interp_stmt.assignUnresolved(self, name, res.normal),
                }
                return res;
            }
            const b = env.lookup(name) orelse return self.throwError("ReferenceError", name);
            if (!b.initialized) return self.throwError("ReferenceError", name); // §13.x TDZ
            const rc = try self.evalExpr(ca.value, env);
            if (rc.isAbrupt()) return rc;
            const res = try interp_ops.applyNumericOrStringOp(self, ca.op, b.value, rc.normal);
            if (res.isAbrupt()) return res;
            if (!b.mutable) return self.throwError("TypeError", "Assignment to constant variable.");
            b.value = res.normal;
            return res;
        },
        .member => |m| {
            const oc = try self.evalExpr(m.object, env); // base evaluated once
            if (oc.isAbrupt()) return oc;
            const cur = try self.getProperty(oc.normal, m.name);
            if (cur.isAbrupt()) return cur;
            const rc = try self.evalExpr(ca.value, env);
            if (rc.isAbrupt()) return rc;
            const res = try interp_ops.applyNumericOrStringOp(self, ca.op, cur.normal, rc.normal);
            if (res.isAbrupt()) return res;
            const sc = try self.setProperty(oc.normal, m.name, res.normal);
            if (sc.isAbrupt()) return sc;
            return res;
        },
        .index => |ix| {
            const oc = try self.evalExpr(ix.object, env); // base evaluated once
            if (oc.isAbrupt()) return oc;
            const kc = try self.evalExpr(ix.key, env); // key expression evaluated once
            if (kc.isAbrupt()) return kc;
            // §6.2.5.5/.6: RequireObjectCoercible(base) precedes the SINGLE §7.1.19 ToPropertyKey.
            if (oc.normal == .undefined or oc.normal == .null) return self.throwError("TypeError", "Cannot read properties of null or undefined");
            const keyc = try self.coercePropertyKey(kc.normal);
            if (keyc.isAbrupt()) return keyc;
            const cur = try self.getPropertyV(oc.normal, keyc.normal);
            if (cur.isAbrupt()) return cur;
            const rc = try self.evalExpr(ca.value, env);
            if (rc.isAbrupt()) return rc;
            const res = try interp_ops.applyNumericOrStringOp(self, ca.op, cur.normal, rc.normal);
            if (res.isAbrupt()) return res;
            const sc = try self.setPropertyV(oc.normal, keyc.normal, res.normal);
            if (sc.isAbrupt()) return sc;
            return res;
        },
        .private_member => |pm| {
            const oc = try self.evalExpr(pm.object, env);
            if (oc.isAbrupt()) return oc;
            const cur = try self.getPrivate(oc.normal, pm.name);
            if (cur.isAbrupt()) return cur;
            const rc = try self.evalExpr(ca.value, env);
            if (rc.isAbrupt()) return rc;
            const res = try interp_ops.applyNumericOrStringOp(self, ca.op, cur.normal, rc.normal);
            if (res.isAbrupt()) return res;
            return self.setPrivate(oc.normal, pm.name, res.normal);
        },
        .super_member => |sm| {
            // §13.15.2 `super.x += v` — read via the SuperProperty getter (key evaluated once),
            // combine, write via the SuperProperty setter (receiver = `this`).
            const key = if (sm.key) |kn| blk: {
                const kc = try self.evalExpr(kn, env);
                if (kc.isAbrupt()) return kc;
                break :blk try self.toString(kc.normal);
            } else sm.name;
            const cur = try getSuperProperty(self, key);
            if (cur.isAbrupt()) return cur;
            const rc = try self.evalExpr(ca.value, env);
            if (rc.isAbrupt()) return rc;
            const res = try interp_ops.applyNumericOrStringOp(self, ca.op, cur.normal, rc.normal);
            if (res.isAbrupt()) return res;
            return setSuperProperty(self, key, res.normal);
        },
        else => return self.throwError("SyntaxError", "Invalid assignment target"),
    }
}

/// §13.3.5 new — construct an object proto-linked to the constructor's `.prototype`, run
/// the body with `this` = the new object; if the body returns an object, use it instead.
pub fn evalNew(self: *Interpreter, n: anytype, env: *Environment) EvalError!Completion {
    const cc = try self.evalExpr(n.callee, env);
    if (cc.isAbrupt()) return cc;
    if (cc.normal != .object or cc.normal.object.kind != .function) {
        return self.throwError("TypeError", "value is not a constructor");
    }
    // §10.4.1.2 [[Construct]] of a Bound Function Exotic Object: ignore [[BoundThis]], construct the
    // (possibly nested) target with [[BoundArguments]] ++ callArgs. Collect the prepended bound args
    // by unwrapping any chain of bound functions, then `new` the underlying target.
    if (cc.normal.object.bound != null) {
        var bound_prefix: []const Value = &.{};
        var inner: *Object = cc.normal.object;
        while (inner.bound) |b| {
            bound_prefix = try concatArgs(self, b.bound_args, bound_prefix);
            inner = b.target;
        }
        var call_args: std.ArrayListUnmanaged(Value) = .empty;
        const alc = try evalSpreadList(self, n.args, env, &call_args);
        if (alc.isAbrupt()) return alc;
        const merged = try concatArgs(self, bound_prefix, call_args.items);
        return self.construct(inner, merged);
    }
    var args: std.ArrayListUnmanaged(Value) = .empty;
    const alc = try evalSpreadList(self, n.args, env, &args);
    if (alc.isAbrupt()) return alc;
    return self.construct(cc.normal.object, args.items);
}

/// §10.2.2 [[Construct]] — instantiate `ctor` with already-evaluated `args`. Creates the new object
/// (proto = `ctor.prototype`), runs base/derived class field + `super` ordering, invokes the
/// constructor body with `this` = the new object, and returns an explicit object return if any.
/// Shared by `new C()` and a bound function's [[Construct]] (§10.4.1.2). The instance's [[Prototype]]
/// derives from `ctor` (i.e. newTarget === ctor); `Reflect.construct` uses `constructNT` for an
/// explicit newTarget.
pub fn construct(self: *Interpreter, ctor: *Object, args: []const Value) EvalError!Completion {
    return self.constructNT(ctor, args, ctor);
}

/// §10.2.2 [[Construct]] with an explicit [[NewTarget]] (§28.1.2 Reflect.construct). The instance's
/// [[Prototype]] is read from `new_target.prototype` (an object, else %Object.prototype% per §10.1.13
/// OrdinaryCreateFromConstructor), while the BODY still runs `ctor`. `new_target` must be a
/// constructor (the caller validates IsConstructor).
pub fn constructNT(self: *Interpreter, ctor: *Object, args: []const Value, new_target: *Object) EvalError!Completion {
    // §10.5.13 [[Construct]] of a Proxy exotic — route through the `construct` trap (or forward to
    // the target). The target must itself be a constructor (validated when the trap is absent by
    // the recursive constructNT; with a trap, the proxy is callable+constructable iff the target is).
    if (ctor.proxy) |pd| return builtin_proxy.proxyConstruct(self, pd, args, new_target);
    // §15.3: arrow functions have no [[Construct]] — `new (() => {})` is a TypeError.
    if (ctor.call) |fd| {
        if (fd.is_arrow) return self.throwError("TypeError", "value is not a constructor");
    }
    // §20.4.1: the `Symbol` constructor has no [[Construct]] — `new Symbol()` is a TypeError.
    if (ctor.native == .symbol_ctor) return self.throwError("TypeError", "Symbol is not a constructor");
    // §21.2.1: the `BigInt` constructor has no [[Construct]] — `new BigInt()` is a TypeError.
    if (ctor.native == .bigint_ctor) return self.throwError("TypeError", "BigInt is not a constructor");
    // §17 / §10.3: a built-in *method* or *static* (e.g. `String.prototype.concat`, `String.fromCharCode`,
    // `Math.max`) has NO [[Construct]] — only the genuine built-in *constructors* below do. A native
    // with no AST body (`call == null`) that is not one of those throws "not a constructor". Ordinary
    // functions / bound functions / classes have `native == .none` and a `call` body, so they pass.
    if (ctor.call == null and ctor.native != .none) {
        const constructible = switch (ctor.native) {
            .error_ctor, .aggregate_error_ctor, .suppressed_error_ctor, .string_ctor, .object_ctor, .array_ctor, .function_ctor, .number_ctor, .boolean_ctor, .promise_ctor, .map_ctor, .set_ctor, .weakmap_ctor, .weakset_ctor, .iterator_ctor, .proxy_ctor, .regexp_ctor, .array_buffer_ctor, .typed_array_ctor, .data_view_ctor => true,
            else => false,
        };
        if (!constructible) return self.throwError("TypeError", "value is not a constructor");
    }
    // §10.1.13 OrdinaryCreateFromConstructor: the instance proto is `new_target.prototype` if an
    // object, else the realm's %Object.prototype% intrinsic (matched here by leaving it null when
    // `new_target.prototype` is absent — Object.create(null) then inherits nothing, but a non-object
    // `.prototype` falls back to %Object.prototype%). For `new C()` new_target === ctor.
    var proto: ?*Object = self.objectProto();
    if (new_target.get("prototype")) |pv| {
        if (pv == .object) proto = pv.object;
    }
    const new_obj = try Object.create(self.arena, proto);

    // §24.1.1.1/§24.2.1.1/§24.3.1.1/§24.4.1.1: a keyed-collection constructor attaches its backing
    // store to the freshly-created instance (which already has new_target.prototype → subclassing
    // works), then AddEntriesFromIterable. The instance IS the result (no explicit-return override).
    switch (ctor.native) {
        .map_ctor, .set_ctor, .weakmap_ctor, .weakset_ctor => {
            const ic = try interp_collection.initCollectionInstance(self, ctor.native, new_obj, args);
            if (ic.isAbrupt()) return ic;
            return .{ .normal = .{ .object = new_obj } };
        },
        .proxy_ctor => return builtin_proxy.construct(self, new_obj, args), // §28.2.1.1
        .regexp_ctor => return builtin_regexp.construct(self, args), // §22.2.4.1 (new RegExp)
        .array_buffer_ctor => return builtin_arraybuffer.construct(self, .{ .object = new_obj }, args), // §25.1.3.1 (new ArrayBuffer)
        .typed_array_ctor => { // §23.2.5.1 (new <Type>Array) — element type from the ctor's native_name.
            const elem = blk: {
                for (builtin_typedarray.all_elems) |e| {
                    if (std.mem.eql(u8, e.constructorName(), ctor.native_name)) break :blk e;
                }
                return self.throwError("TypeError", "Unknown TypedArray constructor");
            };
            return builtin_typedarray.construct(self, new_obj, elem, args);
        },
        .data_view_ctor => return builtin_dataview.construct(self, .{ .object = new_obj }, args), // §25.3.2.1 (new DataView)
        else => {},
    }

    const is_derived = if (ctor.call) |fd| fd.is_derived_ctor else false;

    // §15.7.14 field ordering: a BASE class runs the instance FieldDefinitions on the new object
    // BEFORE the constructor body. A DERIVED class initializes its own fields AFTER `super(...)`
    // returns (done in evalSuperCall / the implicit-super path below), so they are skipped here.
    // Ordinary functions carry no fields, so this is a no-op for them.
    if (!is_derived) {
        if (ctor.call) |fd| {
            const fc = try initInstanceFields(self, fd, new_obj);
            if (fc.isAbrupt()) return fc;
        }
    }

    // §15.7.14: a DERIVED class with NO explicit constructor has a default constructor that runs
    // `super(...args)` then initializes its own fields. Synthesize that here (the body is empty).
    if (is_derived) {
        const fd = ctor.call.?;
        if (fd.is_default_ctor) {
            if (fd.super_ctor) |sup| {
                // §13.3.12: a synthesized default derived constructor forwards the original `new`
                // target down the implicit `super(...)`. Set the active `new_target` to this ctor so
                // `runParentCtor` propagates it (mirroring an explicit `super()` from a real body).
                const saved_nt = self.new_target;
                self.new_target = .{ .object = ctor };
                defer self.new_target = saved_nt;
                // Run the parent constructor (base or derived) on the new instance.
                const pc = try runParentCtor(self, sup, args, new_obj);
                if (pc.isAbrupt()) return pc;
            }
            // Then this class's own fields.
            const fc = try initInstanceFields(self, fd, new_obj);
            if (fc.isAbrupt()) return fc;
            return .{ .normal = .{ .object = new_obj } };
        }
    }

    // §13.3.12: a [[Construct]] sets the running body's [[NewTarget]] to the constructor. Handed off
    // to `callFunction` via the one-shot `pending_new_target` slot, which it consumes for this body.
    self.pending_new_target = .{ .object = ctor };
    const result = try self.callFunction(ctor, args, .{ .object = new_obj });
    if (result.isAbrupt()) return result;
    // §21.1.4.1/§22.1.4.1/§20.3.4.1: a primitive-wrapper ctor (and Array, M75) boxes its internal
    // slot directly on `new_obj` and returns it (`wrapperResult`), so the explicit-object-return
    // path below carries it back. A ctor whose body returns undefined falls through to `new_obj`.
    if (result.normal == .object) return .{ .normal = result.normal }; // explicit object return wins
    return .{ .normal = .{ .object = new_obj } };
}

/// §20.3/§21.1/§22.1 primitive-wrapper constructor result: invoked as a constructor
/// (`new`/`super`, so `native_new_target` is defined) with an object receiver, box `prim` on the
/// instance's primitive slot ([[BooleanData]]/[[NumberData]]/[[StringData]]) and return the
/// instance — so subclassing works and the wrapper's prototype methods recover the value. A plain
/// call (no new_target) returns the primitive.
pub fn wrapperResult(self: *Interpreter, prim: Value, this_val: Value) Completion {
    return interp_class.wrapperResult(self, prim, this_val);
}

/// §15.7.14: run a parent constructor `sup` on an existing `instance` (the `super(...)` /
/// default-derived path). If the parent is itself a BASE class, its instance fields initialize
/// before its body; a DERIVED parent runs its own body (which calls its own `super(...)`), so its
/// fields are handled by that nested call. The parent's `home_object` is installed by callFunction.
pub fn runParentCtor(self: *Interpreter, sup: *Object, args: []const Value, instance: *Object) EvalError!Completion {
    return interp_class.runParentCtor(self, sup, args, instance);
}

/// §15.7.14 InitializeInstanceElements — add this class's PrivateName brand (private fields /
/// methods / accessors) to `instance`, then define each instance FieldDefinition on `instance`, in
/// declaration order, evaluating its initializer with `this` = the instance, in a scope child of
/// the class's defining environment (so an initializer may reference the class name / outer
/// bindings). A field with no initializer is created with value `undefined`.
pub fn initInstanceFields(self: *Interpreter, fd: @import("object.zig").FunctionData, instance: *Object) EvalError!Completion {
    return interp_class.initInstanceFields(self, fd, instance);
}

/// §13.2.5 ObjectLiteral evaluation — a fresh ordinary object (proto-linked to Object.prototype
/// when available). Walks PropertyDefinitions in order: data `k:v` / shorthand / method, computed
/// keys, accessors (`get`/`set` → `defineAccessor`), and `...spread` (CopyDataProperties).
pub fn evalObjectLiteral(self: *Interpreter, props: []const ast.Property, env: *Environment) EvalError!Completion {
    const obj = try Object.create(self.arena, self.globalProto("Object"));
    for (props) |p| {
        switch (p.kind) {
            .spread => {
                // §13.2.5.4 CopyDataProperties — copy own enumerable props of the source. Null /
                // undefined sources are ignored (no throw); arrays spread their indices + length-
                // independent own props.
                const sc = try self.evalExpr(p.value, env);
                if (sc.isAbrupt()) return sc;
                if (try copyDataProperties(self, obj, sc.normal)) |abrupt| return abrupt;
            },
            .get, .set => {
                const key = try propKey(self, p, env);
                if (key.isAbrupt()) return key.completion;
                const fc = try self.evalExpr(p.value, env);
                if (fc.isAbrupt()) return fc;
                const f = fc.normal.object; // a `function` node always yields a function object
                // §13.2.5.6 / §13.3.5: an object-literal accessor is a MethodDefinition with a
                // [[HomeObject]] = the object literal, so `super.x` inside it resolves against
                // `obj.[[Prototype]]`. Set it here (class accessors get theirs via MakeMethod).
                if (f.call) |*afd| afd.home_object = obj;
                // §13.2.5.6: an accessor's name is "get x" / "set x" (the key with the kind prefix).
                const name_key = if (key.symbol) |sym| try self.symbolPropName(sym) else key.key;
                try self.setFunctionName(f, name_key, if (p.kind == .get) "get" else "set");
                const getter: ?*Object = if (p.kind == .get) f else null;
                const setter: ?*Object = if (p.kind == .set) f else null;
                if (key.symbol) |sym| {
                    // §13.2.5: a symbol-keyed accessor → the symbol store (merged get+set).
                    try obj.defineSymbolAccessor(sym, getter, setter);
                } else {
                    try obj.defineAccessor(key.key, getter, setter);
                }
            },
            .init => {
                const key = try propKey(self, p, env);
                if (key.isAbrupt()) return key.completion;
                const c = try self.evalExpr(p.value, env);
                if (c.isAbrupt()) return c;
                // §13.2.5 / §13.3.5: an object-literal METHOD (`{m(){}}`) is a MethodDefinition with a
                // [[HomeObject]] = the object literal, so `super.x` inside its body resolves against
                // `obj.[[Prototype]]`. An ordinary value (`{f: function(){}}`, `{x: 1}`) is NOT a
                // method and keeps no home — gate on the AST `function` node's `is_method` flag.
                if (p.value.* == .function and p.value.function.is_method and c.normal == .object) {
                    if (c.normal.object.call) |*mfd| mfd.home_object = obj;
                }
                // §B.3.1 `__proto__` Property Names in Object Initializers: a `{__proto__: v}`
                // colon property (literal, non-computed name) sets [[Prototype]] instead of
                // creating an own property — if `v` is an Object (set proto to it) or null (null
                // proto). Any other value (primitive) is IGNORED: no own `__proto__` property and
                // the prototype is unchanged.
                if (p.is_proto) {
                    switch (c.normal) {
                        .object => |o| obj.prototype = o,
                        .null => obj.prototype = null,
                        else => {}, // primitive → ignored
                    }
                    continue;
                }
                // §13.2.5 PropertyDefinitionEvaluation / §8.4 NamedEvaluation: an object-literal
                // method (`{m(){}}`, normalized to an anonymous `function` value) OR an anonymous
                // function/class property value (`{f: function(){}}`) gets the property key as its
                // name. Object-literal members stay ENUMERABLE (ordinary properties) — only the
                // function NAME is set, never the enumerability.
                if (key.symbol) |sym| {
                    try self.maybeSetAnonName(p.value, c.normal, try self.symbolPropName(sym));
                    try obj.setSymbol(sym, c.normal); // §13.2.5 symbol-keyed data property
                } else {
                    try self.maybeSetAnonName(p.value, c.normal, key.key);
                    try obj.set(key.key, c.normal);
                }
            },
        }
    }
    return .{ .normal = .{ .object = obj } };
}

/// Resolve a PropertyDefinition's key: a computed `[expr]` (evaluated → §7.1.19 ToPropertyKey: a
/// Symbol stays a Symbol, else ToString) or the static identifier/string/numeric key parsed earlier.
pub fn propKey(self: *Interpreter, p: ast.Property, env: *Environment) EvalError!KeyResult {
    if (p.computed_key) |ck| {
        const c = try self.evalExpr(ck, env);
        if (c.isAbrupt()) return .{ .completion = c };
        return self.toPropertyKey(c.normal);
    }
    return .{ .key = p.key };
}

/// §7.1.19 ToPropertyKey ( argument ) — a Symbol stays a Symbol; an object is ToPrimitive(string)'d
/// (which may itself yield a Symbol), then any non-symbol primitive is ToString'd. So a computed
/// `[fn]` key uses the function's `toString` (consistent with `String(fn)`), not a raw fallback.
pub fn toPropertyKey(self: *Interpreter, v: Value) EvalError!KeyResult {
    if (v == .symbol) return .{ .symbol = v.symbol }; // §7.1.19 step 2
    if (v == .object) {
        const pc = try self.toPrimitive(v, .string);
        if (pc.isAbrupt()) return .{ .completion = pc };
        if (pc.normal == .symbol) return .{ .symbol = pc.normal.symbol };
        return .{ .key = try self.toString(pc.normal) };
    }
    return .{ .key = try self.toString(v) };
}

/// §7.3.25 CopyDataProperties — copy `source`'s own enumerable properties (string AND symbol
/// keyed) into `target` in [[OwnPropertyKeys]] order (integer indices ascending, then strings in
/// insertion order, then symbols), reading each via [[Get]] so getters run. `excluded` holds
/// string keys to skip (the BindingRestProperty / AssignmentRestProperty exclusion set; symbol
/// keys are never excluded by a string rest). A throwing getter / abrupt [[OwnPropertyKeys]] (a
/// Proxy) propagates. The single primitive behind object spread `{...src}` and the two
/// destructuring rest forms (§14.3.3 BindingRestProperty / §13.15.5.4 AssignmentRestProperty).
/// Returns null on success, or the abrupt Completion (a throwing getter / Proxy trap) to propagate.
pub fn copyDataPropertiesExcluding(self: *Interpreter, target: *Object, source: Value, excluded: []const []const u8) EvalError!?Completion {
    return interp_property.copyDataPropertiesExcluding(self, target, source, excluded);
}

/// Object spread `{...source}` — §7.3.25 CopyDataProperties with no exclusions. Returns the abrupt
/// Completion (throwing getter / revoked Proxy) to propagate, else null.
pub fn copyDataProperties(self: *Interpreter, target: *Object, source: Value) EvalError!?Completion {
    return interp_property.copyDataProperties(self, target, source);
}

/// §13.3.9 Optional chain evaluation — a thin wrapper returning the chain's value (the receiver
/// is only needed internally for `?.( )` calls). A short-circuit yields `undefined`.
pub fn evalOptionalChain(self: *Interpreter, node: *const ast.Node, env: *Environment) EvalError!Completion {
    const r = try evalChain(self, node, env);
    if (r.isAbrupt()) return r.completion;
    return .{ .normal = r.value };
}

/// Walk one access link of an optional chain. `node` is either an `.optional` link (whose base
/// is the rest of the chain) or any other expression (the chain root). Returns the produced
/// value, the receiver for a following call, and whether the chain short-circuited.
pub fn evalChain(self: *Interpreter, node: *const ast.Node, env: *Environment) EvalError!ChainResult {
    if (node.* != .optional) {
        // Chain root: an ordinary (possibly member/call) expression.
        const c = try self.evalExpr(node, env);
        if (c.isAbrupt()) return .{ .completion = c };
        return .{ .value = c.normal };
    }
    const opt = node.optional;
    const base = try evalChain(self, opt.base, env);
    if (base.isAbrupt()) return base;
    if (base.short) return .{ .short = true }; // §13.3.9.1: propagate the short-circuit
    // §13.3.9.1: a `?.` link whose base is null/undefined short-circuits the WHOLE chain.
    if (opt.optional and (base.value == .undefined or base.value == .null)) {
        return .{ .short = true };
    }
    switch (opt.link) {
        .member => |name| {
            const gc = try self.getProperty(base.value, name);
            if (gc.isAbrupt()) return .{ .completion = gc };
            return .{ .value = gc.normal, .this_val = base.value };
        },
        .index => |key_node| {
            const kc = try self.evalExpr(key_node, env);
            if (kc.isAbrupt()) return .{ .completion = kc };
            const gc = try self.getPropertyV(base.value, kc.normal);
            if (gc.isAbrupt()) return .{ .completion = gc };
            return .{ .value = gc.normal, .this_val = base.value };
        },
        .call => |arg_nodes| {
            // §13.3.6: the callee is `base.value`; `this` is the receiver carried from the
            // previous member/index link (undefined for a bare `a?.()`).
            var args: std.ArrayListUnmanaged(Value) = .empty;
            const alc = try evalSpreadList(self, arg_nodes, env, &args);
            if (alc.isAbrupt()) return .{ .completion = alc };
            if (base.value != .object or base.value.object.kind != .function) {
                return .{ .completion = try self.throwError("TypeError", "value is not a function") };
            }
            if (base.value.object.call) |fd| {
                if (fd.is_class_ctor) return .{ .completion = try self.throwError("TypeError", "Class constructor cannot be invoked without 'new'") };
            }
            const rc = try self.callFunction(base.value.object, args.items, base.this_val);
            if (rc.isAbrupt()) return .{ .completion = rc };
            return .{ .value = rc.normal };
        },
    }
}

/// §15.7.14 ClassDefinitionEvaluation. Builds the constructor function object: its body is the
/// explicit `constructor` method (or a default body), its `.prototype` carries the instance
/// methods, and the constructor object itself carries the static methods/fields. Instance
/// FieldDefinitions are stashed on the constructor's `FunctionData.fields` and run per-instance by
/// `evalNew`/`super(...)`. The class name is bound in an inner scope for self-reference. With an
/// `extends` heritage (Cycle 2): the superclass is evaluated, the prototype chains are linked
/// (`proto.[[Prototype]]` = `Super.prototype`, `ctor.[[Prototype]]` = `Super` for static
/// inheritance; `extends null` → `proto.[[Prototype]]` = null), and every method gets a
/// [[HomeObject]] so `super.x` resolves; a derived constructor records its `super_ctor`.
pub fn evalClass(self: *Interpreter, c: *const ast.Class, env: *Environment) EvalError!Completion {
    return interp_class.evalClass(self, c, env);
}

/// §15.1.5 ExpectedArgumentCount — the `length` value: the count of leading FormalParameters
/// before the first one with a default initializer, a destructuring BindingPattern, or the rest
/// element. (A simple identifier param with no default counts; the first non-simple param or the
/// rest element stops the count.) `rest` is never counted (only stops the leading run).
pub fn paramCount(params: []const ast.Param) f64 {
    var n: f64 = 0;
    for (params) |p| {
        if (p.default != null or p.pattern.* != .identifier) break;
        n += 1;
    }
    return n;
}

/// §20.2.4.1 install the `length` own data property — `{ writable:false, enumerable:false,
/// configurable:true }`. Created at function-object creation (outside hot loops, so the two
/// inserts cost nothing in the bench).
pub fn setFunctionLength(obj: *Object, n: f64) std.mem.Allocator.Error!void {
    try obj.defineData("length", .{ .number = n }, false, false, true);
}

/// §10.2.4 MakeConstructor — install the `constructor` back-reference on an ordinary function's
/// own `.prototype`: `F.prototype.constructor === F`, descriptor `{ writable:true,
/// enumerable:false, configurable:true }`. So `function F(){}; F.prototype.constructor === F`
/// and (through the chain) `new F().constructor === F`. NON-enumerable is load-bearing (a stray
/// enumerable `constructor` would surface in for-in / Object.keys). Only ordinary (constructible)
/// functions are MakeConstructor targets: arrows have no `.prototype`; a Generator/AsyncGenerator
/// function's `.prototype` is the (non-constructor) %Generator%-instance prototype and carries no
/// `constructor` (§27.x.4); an async function has no own `.prototype`. Runs at function-object
/// creation (outside hot loops).
pub fn setConstructorBackref(obj: *Object) std.mem.Allocator.Error!void {
    const fd = obj.call orelse return;
    // Not a MakeConstructor target: arrows, generators/async-generators, async functions, and
    // §10.2.5 MethodDefinitions (which have no own `.prototype` to hang a `constructor` on).
    if (fd.is_arrow or fd.is_generator or fd.is_async or fd.is_method) return;
    const pv = obj.get("prototype") orelse return;
    if (pv != .object) return;
    try pv.object.defineData("constructor", .{ .object = obj }, true, false, true);
}

/// §10.2.4 / §27.5.1 — fix up a function object's own `prototype` property metadata after
/// `createFunction` installed it with default `set` semantics:
///   • An ordinary function's `.prototype` is `{ writable:true, enumerable:false, configurable:true }`.
///   • A generator/async-generator function's `.prototype` is `{ writable:true, enumerable:false,
///     configurable:FALSE }` (§27.3.3/§27.4) and its [[Prototype]] is %GeneratorPrototype% /
///     %AsyncGeneratorPrototype% (so `Object.getPrototypeOf(g.prototype) === %GeneratorPrototype%`,
///     and a generator instance — proto-linked to `g.prototype` — inherits `.next`/`.return`/`.throw`).
/// No-op for functions without an own `.prototype` (arrows, async non-generators, methods).
pub fn finalizeFunctionPrototype(self: *Interpreter, obj: *Object) std.mem.Allocator.Error!void {
    const fd = obj.call orelse return;
    const pv = obj.get("prototype") orelse return;
    if (pv != .object) return;
    if (fd.is_generator) {
        // The generator-instance prototype carries no `constructor` and is non-configurable.
        pv.object.prototype = if (fd.is_async) interp_async.asyncGeneratorProto(self) else interp_async.generatorProto(self);
        try obj.defineData("prototype", pv, true, false, false);
    } else {
        // §10.2.4: an ordinary constructor's `.prototype` is non-enumerable + configurable.
        try obj.defineData("prototype", pv, true, false, true);
    }
}

/// §20.2.4.2 / §10.2.9 SetFunctionName — install the `name` own data property `{ writable:false,
/// enumerable:false, configurable:true }`. `prefix` (when non-empty) is space-joined ahead of the
/// name ("get"/"set"/"bound"). Names are interned in the realm arena so they outlive the call.
pub fn setFunctionName(self: *Interpreter, obj: *Object, name: []const u8, prefix: []const u8) std.mem.Allocator.Error!void {
    const full = if (prefix.len == 0) name else try std.fmt.allocPrint(self.arena, "{s} {s}", .{ prefix, name });
    try obj.defineData("name", .{ .string = full }, false, false, true);
}

/// §10.2.9 SetFunctionName for a Symbol key — the name is `"[" + description + "]"`, or `""` when
/// the symbol has no description (`[[Description]]` is undefined). Interned in the realm arena.
pub fn symbolPropName(self: *Interpreter, sym: *Symbol) std.mem.Allocator.Error![]const u8 {
    const desc = sym.description orelse return "";
    return std.fmt.allocPrint(self.arena, "[{s}]", .{desc});
}

/// True iff a function object currently has no `name` own property, or an empty-string one — i.e.
/// it is "anonymous" and eligible for §8.4 NamedEvaluation to assign it a binding/property name.
pub fn isAnonymousFn(obj: *Object) bool {
    if (obj.properties.getPtr("name")) |pv| {
        return pv.payload == .data and pv.payload.data == .string and pv.payload.data.string.len == 0;
    }
    return true;
}

/// §8.4 NamedEvaluation — if `node` is an anonymous function/arrow/class expression and the
/// evaluated `value` is the resulting (still-anonymous) function object, set its `name` to the
/// binding/property name. Covers the common naming contexts: `var/let/const f = <anon>`,
/// `f = <anon>` (identifier assignment), object-literal `{f: <anon>}`, and default initializers.
/// A no-op for any non-anonymous-function value, so callers can apply it unconditionally.
pub fn maybeSetAnonName(self: *Interpreter, node: *const ast.Node, value: Value, name: []const u8) std.mem.Allocator.Error!void {
    switch (node.*) {
        .function, .class_expr => {},
        else => return, // only an anonymous function/class literal is a NamedEvaluation site
    }
    if (value != .object) return;
    const obj = value.object;
    if (obj.kind != .function) return;
    if (!isAnonymousFn(obj)) return; // a NAMED function/class expression keeps its own name
    try self.setFunctionName(obj, name, "");
}

pub fn evalFunctionExpr(self: *Interpreter, f: *const ast.Function, env: *Environment) EvalError!Completion {
    // §15.2.5 InstantiateOrdinaryFunctionExpression: a NAMED FunctionExpression `function g(){…}`
    // binds its own name `g` in an inner DeclarativeEnvironment that is the function's [[Environment]]
    // — so the body (and parameter defaults) can self-reference / recurse via `g`, while `g` is NOT
    // visible in the enclosing scope. The binding is immutable. Arrows have no name; a method's name
    // is not a self-binding either — both use the outer `env` directly.
    const has_self_name = f.name != null and !f.is_arrow and !f.is_method;
    const closure_env = if (has_self_name) try Environment.create(self.arena, env) else env;
    // §15.3: an arrow captures the enclosing `this` at creation time (lexical `this`); an
    // ordinary function gets `this` bound per-call instead.
    const obj = try Object.createFunction(self.arena, .{
        .params = f.params,
        .rest = f.rest,
        .body = f.body,
        .closure = closure_env,
        .is_arrow = f.is_arrow,
        .is_generator = f.is_generator,
        .is_async = f.is_async,
        .is_method = f.is_method,
        .captured_this = if (f.is_arrow) self.this_val else .undefined,
        .captured_this_init_cell = if (f.is_arrow) self.this_init_cell else null, // §13.3.7 lexical TDZ
        .captured_home_object = if (f.is_arrow) self.home_object else null, // §13.3.5 lexical [[HomeObject]]
        .strict = f.strict,
    });
    obj.prototype = self.functionProto(); // §20.2.3 so `f.call`/`.apply`/`.bind` resolve
    // §20.2.4.1/.2: install `length` (ExpectedArgumentCount) and `name` (the declared name, or
    // "" for an anonymous expression — a NamedEvaluation site may rename it via maybeSetAnonName).
    try setFunctionLength(obj, paramCount(f.params));
    try self.setFunctionName(obj, f.name orelse "", "");
    try setConstructorBackref(obj); // §10.2.4 MakeConstructor: F.prototype.constructor === F (no-op for arrows)
    try finalizeFunctionPrototype(self, obj); // §10.2.4/§27.5.1 prototype descriptor + proto link
    // §15.2.5 step 4: initialize the immutable self-name binding to the created function object.
    if (has_self_name) try closure_env.declare(f.name.?, .{ .object = obj }, false, true);
    return .{ .normal = .{ .object = obj } };
}

/// Evaluate an argument / element list into `out`, flattening `...expr` spread elements
/// (§13.2.4 / §13.3 — arrays spread their elements, strings their characters). Returns an
/// abrupt completion to propagate, else `.{ .normal = .undefined }`.
pub fn evalSpreadList(self: *Interpreter, nodes: []const *const ast.Node, env: *Environment, out: *std.ArrayListUnmanaged(Value)) EvalError!Completion {
    for (nodes) |n| {
        if (n.* == .spread) {
            // §13.2.4.1 SpreadElement — iterate the source via the full §7.4 protocol (Arrays/Strings
            // fast-pathed inside `iterateToList`), appending each yielded value. Any object with a
            // `[Symbol.iterator]` spreads; a non-iterable → TypeError.
            const sc = try self.evalExpr(n.spread, env);
            if (sc.isAbrupt()) return sc;
            const ic = try self.iterateToList(sc.normal, out);
            if (ic.isAbrupt()) return ic;
        } else {
            const c = try self.evalExpr(n, env);
            if (c.isAbrupt()) return c;
            try out.append(self.arena, c.normal);
        }
    }
    return .{ .normal = .undefined };
}

/// §13.3.6 Call. Resolves the callee (with `this` for method calls), evaluates arguments,
/// then invokes [[Call]].
pub fn evalCall(self: *Interpreter, c: anytype, env: *Environment) EvalError!Completion {
    var this_for_call: Value = .undefined;
    var callee: Value = .undefined;
    // §19.2.1.1 / §13.3.6: a DIRECT eval is a CallExpression whose callee is *exactly* the
    // IdentifierReference `eval` resolving to the %eval% intrinsic. Detect it here (before the
    // generic dispatch) so the eval body runs in the CALLER's running execution context.
    var is_direct_eval = false;
    switch (c.callee.*) {
        .member => |m| {
            const oc = try self.evalExpr(m.object, env);
            if (oc.isAbrupt()) return oc;
            this_for_call = oc.normal;
            const got = try self.getProperty(oc.normal, m.name);
            if (got.isAbrupt()) return got;
            callee = got.normal;
        },
        .index => |ix| {
            const oc = try self.evalExpr(ix.object, env);
            if (oc.isAbrupt()) return oc;
            this_for_call = oc.normal;
            const kc = try self.evalExpr(ix.key, env);
            if (kc.isAbrupt()) return kc;
            const got = try self.getPropertyV(oc.normal, kc.normal);
            if (got.isAbrupt()) return got;
            callee = got.normal;
        },
        .super_member => |sm| {
            // §13.3.5: `super.m(args)` — resolve `m` on the home object's [[Prototype]], but call
            // it with `this` = the CURRENT `this` (not the super base). (`super(...)` is the
            // separate SuperCall node, handled in evalExpr.)
            const key = if (sm.key) |kn| blk: {
                const kc = try self.evalExpr(kn, env);
                if (kc.isAbrupt()) return kc;
                break :blk try self.toString(kc.normal);
            } else sm.name;
            const got = try getSuperProperty(self, key);
            if (got.isAbrupt()) return got;
            this_for_call = self.this_val;
            callee = got.normal;
        },
        .private_member => |pm| {
            // §13.3.2 `obj.#m(args)` — resolve the private member (brand-checked), call with
            // `this` = `obj`.
            const oc = try self.evalExpr(pm.object, env);
            if (oc.isAbrupt()) return oc;
            this_for_call = oc.normal;
            const got = try self.getPrivate(oc.normal, pm.name);
            if (got.isAbrupt()) return got;
            callee = got.normal;
        },
        else => {
            const cc = try self.evalExpr(c.callee, env);
            if (cc.isAbrupt()) return cc;
            callee = cc.normal;
            // §19.2.1.1: the callee is the bare IdentifierReference `eval`, and it resolved to the
            // %eval% intrinsic (NOT a shadowing user binding named `eval`). This is a DIRECT eval.
            if (c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, "eval")) {
                if (cc.normal == .object and cc.normal.object.native == .eval_fn) is_direct_eval = true;
            }
        },
    }

    var args: std.ArrayListUnmanaged(Value) = .empty;
    const alc = try evalSpreadList(self, c.args, env, &args);
    if (alc.isAbrupt()) return alc;

    // §19.2.1.1 DIRECT eval: run in the CALLER's running execution context. A non-string argument
    // is returned unchanged (§19.2.1 step 2). Otherwise the eval body runs in a fresh CHILD of the
    // caller's current `env` — reads/writes of surrounding bindings work, and `let`/`const`/`class`
    // (and, in this slice, `var`) declared by the eval are eval-local. `this_val`/`home_object` are
    // inherited (left at the interpreter's current values). Counters carry through.
    if (is_direct_eval) {
        const arg: Value = if (args.items.len > 0) args.items[0] else .undefined;
        if (arg != .string) return .{ .normal = arg };
        const eval_env = try Environment.create(self.arena, env);
        // §19.2.1.1: a DIRECT eval inherits the caller's strictness. (Whether the eval scope is a
        // VariableEnvironment depends on the eval body's OWN strictness — set in `performEval`.)
        return performEval(self, arg.string, eval_env, self.strict);
    }

    if (callee != .object or callee.object.kind != .function) {
        return self.throwError("TypeError", "value is not a function");
    }
    // §15.7.14: a class constructor may only be invoked via `new` ([[Construct]]); a plain call
    // `C()` is a TypeError.
    if (callee.object.call) |fd| {
        if (fd.is_class_ctor) return self.throwError("TypeError", "Class constructor cannot be invoked without 'new'");
    }
    return self.callFunction(callee.object, args.items, this_for_call);
}

/// §10.2.1 [[Call]] — native built-in, else an ordinary AST-closure function.
/// The global object as a Value (the realm's `%GlobalThis%`), or null in a realm-less context.
/// Used for §10.2.1.2 sloppy `this` substitution and §9.4.2 global `this`.
pub fn globalThisValue(self: *Interpreter) ?Value {
    if (self.globals) |g| if (g.lookup("%GlobalThis%")) |b| return b.value;
    return null;
}

/// The reified global object (the realm's `%GlobalThis%`) as an `*Object`, or null.
pub fn globalObject(self: *Interpreter) ?*Object {
    if (self.globals) |g| if (g.lookup("%GlobalThis%")) |b| if (b.value == .object) return b.value.object;
    return null;
}

/// §9.1.1.4.1 GlobalEnvironmentRecord.HasBinding object-record half: does the global *object*
/// (own or inherited) expose `name`? ljs keeps the global namespace in TWO views — a declarative
/// Environment (where `var`/`let`/function declarations live) and the reified global object (where
/// `this.x = …` / `Object.defineProperty(globalThis, …)` land). A bare identifier that misses the
/// declarative chain must still resolve against the object record (§9.1.1.4.6/.11). The `%…%`
/// realm sentinels live only in the declarative env, never as global-object properties, so they
/// can't leak here.
pub fn globalObjectHas(self: *Interpreter, name: []const u8) bool {
    const go = globalObject(self) orelse return false;
    return go.get(name) != null; // §10.1.7 [[HasProperty]] over the proto chain
}

/// §10.4.4.6 the realm's unique %ThrowTypeError% intrinsic, or null in a realm-less context.
pub fn throwTypeErrorIntrinsic(self: *Interpreter) ?*Object {
    if (self.globals) |g| if (g.lookup("%ThrowTypeError%")) |b| if (b.value == .object) return b.value.object;
    return null;
}

pub fn callFunction(self: *Interpreter, func: *Object, args: []const Value, this_val: Value) EvalError!Completion {
    // §13.3.12: consume the one-shot [[NewTarget]] hand-off from a preceding `construct` (else
    // `undefined`) and clear the slot immediately — so it cannot leak past this [[Call]] into a
    // sibling/native/bound/generator dispatch. Installed below for the non-arrow ordinary body path.
    const pending_new_target = self.pending_new_target;
    self.pending_new_target = .undefined;
    // §10.5.12 [[Call]] of a Proxy exotic — route through the `apply` trap (or forward to the
    // target). A proxy is marked `kind == .function` when its target is callable, so it reaches
    // here; the `o.proxy` check precedes every ordinary-call path.
    if (func.proxy) |pd| return builtin_proxy.apply(self, pd, args, this_val);
    // §15.7.14: a class constructor's [[Call]] always throws — only [[Construct]] (a preceding
    // `construct` that handed off [[NewTarget]] via `pending_new_target`) runs its body. An
    // undefined hand-off ⇒ this is a plain [[Call]] (direct OR via call/apply/bind), so reject it
    // here at the single [[Call]] chokepoint. A bound wrapper has `func.call == null`, so the
    // check no-ops on it and fires on the unwrapped target's recursive call.
    if (pending_new_target == .undefined) {
        if (func.call) |cfd| if (cfd.is_class_ctor)
            return self.throwError("TypeError", "Class constructor cannot be invoked without 'new'");
    }
    // §10.4.1.1 [[Call]] of a Bound Function Exotic Object: run the target with `this` =
    // [[BoundThis]] and args = [[BoundArguments]] ++ callArgs. Cheap early branch (the common
    // case is `.bound == null`, a single optional test off the hot path).
    if (func.bound) |b| {
        const merged = try concatArgs(self, b.bound_args, args);
        return self.callFunction(b.target, merged, b.bound_this);
    }
    if (func.native != .none) {
        // Expose THIS call's [[NewTarget]] to the native — a built-in constructor reached via a
        // `super(...)` chain (defined → construct) must initialize the instance, while a plain call
        // (undefined) throws "requires 'new'". Reset by every dispatch so it never leaks.
        self.native_new_target = pending_new_target;
        return interp_native.callNative(self, func, args, this_val);
    }
    // §15.5.4 / §27.5: calling a generator function does NOT run the body — it returns a fresh
    // Generator object in `suspended_start` (the body runs on its own thread later, on `.next`).
    // Checked before the depth bump so it pays no recursion budget; ordinary functions skip it.
    if (func.call) |fd0| {
        // §10.2.1.2 OrdinaryCallBindThis: generator / async functions snapshot `this` here (off the
        // ordinary-body path below), so apply the non-strict global-`this` substitution before they
        // capture it — otherwise a sloppy `function* g(){}` / `async function f(){}` called with
        // undefined `this` would see undefined instead of the global object. Arrows: captured_this.
        const gen_this = if (!fd0.is_arrow and !fd0.strict and (this_val == .undefined or this_val == .null))
            (globalThisValue(self) orelse this_val)
        else
            this_val;
        // §27.6.2 an async generator (`async function*`) [[Call]] returns an AsyncGenerator object
        // (lazy — the body runs on its own thread when first driven). Checked before the plain
        // generator / async branches (it is both is_async AND is_generator).
        if (fd0.is_generator and fd0.is_async) return interp_async.createAsyncGenerator(self, func, args, gen_this);
        if (fd0.is_generator) return interp_async.createGenerator(self, func, args, gen_this);
        // §27.7.5.1 an async function's [[Call]] returns a Promise immediately and runs the body on
        // a generator-style thread, suspending at each `await`.
        if (fd0.is_async) return interp_async.callAsyncFunction(self, func, args, gen_this);
    }
    // Each call stacks several heavy native frames — count call depth too so the guard
    // fires before the native stack overflows (these frames are bigger than expr frames).
    self.depth += 1;
    defer self.depth -= 1;
    if (self.depth > self.max_depth) return self.throwError("RangeError", "Maximum call stack size exceeded");
    const fd = func.call orelse return self.throwError("TypeError", "value is not a function");
    const call_env = try Environment.create(self.arena, fd.closure);
    call_env.is_var_scope = true; // §10.2.11: a FunctionBody is a VariableEnvironment (var hoist target)
    // §9.1.2.2 a function CLOSED OVER a `with` resolves its free names through the captured object
    // Environment Record(s) even when the `with` statement is no longer dynamically on the stack
    // (the with-scope is lexical, in `fd.closure`). `with_depth` is the dynamic gate for the
    // with-aware resolution path, so bump it for the body's duration when the closure chain crosses
    // a `with` (cheap `envHasWith` walk, only on call setup). The overwhelming non-`with` case is a
    // no-op (depth unchanged → fast declarative resolution).
    const saved_with_depth = self.with_depth;
    if (self.with_depth == 0 and envHasWith(fd.closure)) self.with_depth = 1;
    defer self.with_depth = saved_with_depth;
    // §10.2.11 FunctionDeclarationInstantiation: the `this` / [[HomeObject]] / [[NewTarget]] bindings
    // are established BEFORE parameter initialization, so a default-parameter initializer (`m(x =
    // super.k)`, `f(p = this.q)`, `C(t = new.target)`) sees the correct method context. Installed
    // here (ahead of the param loop), saved/restored on return.
    // §15.3: an arrow has no own `this` binding — it uses the `this` captured at creation,
    // ignoring however it was called. Ordinary functions take the call-site `this`.
    const saved_this = self.this_val;
    self.this_val = if (fd.is_arrow) fd.captured_this else blk: {
        // §10.2.1.2 OrdinaryCallBindThis (this-mode = global): a NON-STRICT ordinary function called
        // with a `this` of undefined/null uses the global object instead. Strict functions keep the
        // value as-is; arrows use their captured `this`. (Primitive-`this` boxing in sloppy mode is a
        // separate refinement, not handled here.)
        if (!fd.strict and (this_val == .undefined or this_val == .null)) break :blk (globalThisValue(self) orelse this_val);
        break :blk this_val;
    };
    defer self.this_val = saved_this;
    // §13.3.7 [[ThisBindingStatus]]: select the active `this`-binding init cell. An ARROW restores
    // the cell it captured at creation (its lexical constructor's TDZ state); a DERIVED constructor
    // allocates a fresh cell starting `false` (TDZ until `super()`); every other function has an
    // always-initialized `this` (null cell). Saved/restored so nesting (and an arrow invoked from an
    // unrelated method mid-construction) resolves `this`/`super()` against the correct binding.
    const saved_init_cell = self.this_init_cell;
    if (fd.is_arrow) {
        self.this_init_cell = fd.captured_this_init_cell;
    } else if (fd.is_derived_ctor) {
        const cell = try self.arena.create(bool);
        cell.* = false;
        self.this_init_cell = cell;
    } else {
        self.this_init_cell = null;
    }
    defer self.this_init_cell = saved_init_cell;
    // §9.2.5/§13.3.5: a method invocation installs its [[HomeObject]] for `super` resolution.
    // An arrow has no own home object — it lexically keeps the enclosing one (like `this`), so
    // it is left untouched; an ordinary function's home_object is null, masking outer `super`.
    const saved_home = self.home_object;
    // §13.3.5: an arrow uses the [[HomeObject]] it captured LEXICALLY (so `super` resolves against
    // its defining method/constructor regardless of how the arrow is invoked); an ordinary function
    // installs its own (null for a non-method, masking outer `super`).
    self.home_object = if (fd.is_arrow) fd.captured_home_object else fd.home_object;
    defer self.home_object = saved_home;
    // §13.3.12: install [[NewTarget]] for this body. An ordinary [[Call]] gets `undefined`; a
    // [[Construct]] (`construct` set `pending_new_target` to the constructor right before this call)
    // gets that constructor. An arrow has no own [[NewTarget]] — it keeps the enclosing one lexically
    // (like `this`), so it is left untouched. The pending slot was consumed at the top of this
    // [[Call]] so nested ordinary calls within the body see `undefined`.
    const saved_new_target = self.new_target;
    if (!fd.is_arrow) self.new_target = pending_new_target;
    defer self.new_target = saved_new_target;
    for (fd.params, 0..) |param, i| {
        var v: Value = if (i < args.len) args[i] else .undefined; // missing args → undefined
        var defaulted = false;
        if (v == .undefined) {
            if (param.default) |dn| { // §15.1 default value applied when the arg is undefined
                const dc = try self.evalExpr(dn, call_env);
                if (dc.isAbrupt()) return dc;
                v = dc.normal;
                defaulted = true;
            }
        }
        // Fast path: a plain identifier parameter binds directly (no pattern matching).
        if (param.pattern.* == .identifier) {
            // §15.1.3 step on a SingleNameBinding: name an anonymous fn/class default initializer.
            if (defaulted) try self.maybeSetAnonName(param.default.?, v, param.pattern.identifier);
            try call_env.declare(param.pattern.identifier, v, true, true);
        } else {
            const bc = try interp_destr.bindPattern(self, param.pattern, v, call_env, true);
            if (bc.isAbrupt()) return bc;
        }
    }
    if (fd.rest) |rest_pat| {
        // §15.1 rest parameter — bind leftover args (beyond the fixed params) as an Array,
        // then destructure that Array into the rest pattern (commonly a single identifier).
        const rest_arr = try Object.createArray(self.arena, self.arrayProto());
        if (args.len > fd.params.len) {
            for (args[fd.params.len..]) |a| try rest_arr.elements.append(self.arena, a);
        }
        if (rest_pat.* == .identifier) {
            try call_env.declare(rest_pat.identifier, .{ .object = rest_arr }, true, true);
        } else {
            const bc = try interp_destr.bindPattern(self, rest_pat, .{ .object = rest_arr }, call_env, true);
            if (bc.isAbrupt()) return bc;
        }
    }
    // §10.4.4 / §15.1: an ordinary (non-arrow) function gets an `arguments` exotic binding holding
    // the call-site args (indexed data properties + a non-enumerable `length`). M-subset: an
    // ordinary object (NOT an Array exotic, so `Array.isArray(arguments)` is false) supporting
    // `arguments.length` / `arguments[i]` — what propertyHelper.js's `verifyProperty` reads. Skipped
    // when a parameter (or the rest binding) already binds the name `arguments` (it shadows). Arrows
    // inherit the enclosing `arguments` lexically, so they get none of their own.
    if (!fd.is_arrow and call_env.lookupLocal("arguments") == null) {
        const ao = try interp_native.makeArgumentsObject(self, args, func, call_env, fd);
        try call_env.declare("arguments", .{ .object = ao }, true, true);
    }
    // §14.13: labels do not cross a function boundary — the body starts with no pending label
    // (e.g. a call inside a labelled statement must not leak that label into the callee's loops).
    const saved_labels = self.pending_labels;
    self.pending_labels = .empty;
    defer self.pending_labels = saved_labels;
    // §11.2.2: the body runs in its own strict context (`fd.strict`, computed at parse time —
    // inherited strict, an own `"use strict"`, a class member, or a class constructor). Restored on
    // return so the caller's strictness is unaffected. A sloppy callee called from strict code (and
    // vice-versa) is gated correctly for §6.2.5.6 PutValue to an unresolved name.
    const saved_strict = self.strict;
    self.strict = fd.strict;
    defer self.strict = saved_strict;

    // §10.2.11 FunctionDeclarationInstantiation (lexical step): hoist the body's top-level
    // `let`/`const`/`class` names as TDZ bindings before it runs (so a forward reference throws).
    try self.hoistLexicalNames(fd.body, call_env);
    // §10.2.11 (var step): instantiate VarDeclaredNames in the FunctionBody VariableEnvironment,
    // descending through nested blocks/loops/try (no-clobber over params already bound above).
    try self.hoistVarNames(fd.body, call_env);
    // §ER: a FunctionBody lexically containing a `using`/`await using` disposes its resources on
    // exit (normal return OR throw). Gated on `blockHasUsing` so an ordinary body pays nothing.
    if (blockHasUsing(fd.body)) {
        const marker = self.disposables.items.len;
        var body_c: Completion = .{ .normal = .undefined };
        for (fd.body) |stmt| {
            const c = try self.evalStmt(stmt, call_env);
            switch (c) {
                .normal => {},
                .ret, .throw => {
                    body_c = c;
                    break;
                },
                .brk, .cont => {},
            }
        }
        const disposed = try self.disposeFrom(marker, body_c);
        return switch (disposed) {
            .ret => |v| .{ .normal = v },
            .throw => disposed,
            else => .{ .normal = .undefined },
        };
    }
    for (fd.body) |stmt| {
        const c = try self.evalStmt(stmt, call_env);
        switch (c) {
            .normal => {},
            .ret => |v| return finishCtorReturn(self, fd, v),
            .throw => return c,
            .brk, .cont => {}, // not produced inside a function body (loops/labels consume them)
        }
    }
    return finishCtorReturn(self, fd, .undefined); // implicit return
}

/// §10.2.1.3 EvaluateBody / §10.2.2 [[Construct]] step 13 (constructor return). For a DERIVED
/// constructor: an Object return is returned as-is (step 13.a); a `return;`/fall-off `undefined`
/// yields GetThisBinding — a ReferenceError if `super(...)` was never called (step 13.e, `this`
/// uninitialized); and a NON-undefined NON-object return (e.g. `return null` / `return 5`) is a
/// TypeError (step 13.c). A BASE constructor ignores a non-object return (its `this` always wins),
/// and non-derived functions return their value untouched.
pub fn finishCtorReturn(self: *Interpreter, fd: object_mod.FunctionData, value: Value) EvalError!Completion {
    return interp_class.finishCtorReturn(self, fd, value);
}

/// Concatenate two argument slices into a freshly-allocated slice (`a ++ b`). Used by the bound
/// function [[Call]]/[[Construct]] (§10.4.1) to prepend [[BoundArguments]] before the call args.
pub fn concatArgs(self: *Interpreter, a: []const Value, b: []const Value) EvalError![]const Value {
    if (a.len == 0) return b;
    if (b.len == 0) return a;
    const out = try self.arena.alloc(Value, a.len + b.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
}

/// §13.3.10 ImportCall Runtime Semantics: Evaluation. Evaluate the specifier (and, if present,
/// the import-options second argument) for their GetValue side effects, then ToString the
/// specifier and return a Promise. With no module loader, a successful ToString yields a Promise
/// REJECTED with a TypeError ("module loading is not supported"); an abrupt ToString (a Symbol
/// specifier, or a throwing `toString`/`valueOf`) rejects the Promise with that error
/// (IfAbruptRejectPromise, step 7). The result is always a genuine Promise object, so `.then`/
/// `.catch` and synchronous `assert.throws` on the call site behave per spec.
pub fn evalImportCall(self: *Interpreter, ic: anytype, env: *Environment) EvalError!Completion {
    // Step 3–4: evaluate the AssignmentExpression specifier and GetValue.
    const sc = try self.evalExpr(ic.specifier, env);
    if (sc.isAbrupt()) return sc;
    // The optional second argument (import options) — evaluate left-to-right for side effects.
    if (ic.options) |opt| {
        const oc = try self.evalExpr(opt, env);
        if (oc.isAbrupt()) return oc;
    }
    // Step 5: NewPromiseCapability(%Promise%).
    const promise = try self.newPromise();
    // Step 6–7: specifierString = ToString(specifier); IfAbruptRejectPromise.
    switch (try interp_ops.toStringCoerceV(self, sc.normal)) {
        .abrupt => |a| try interp_async.rejectPromise(self, promise, a.throw),
        .string => {
            // Step 8: HostLoadImportedModule — no loader in scope, so reject with a TypeError.
            const tc = try self.throwError("TypeError", "module loading is not supported");
            try interp_async.rejectPromise(self, promise, tc.throw);
        },
    }
    // Step 9: return the Promise.
    return .{ .normal = .{ .object = promise } };
}

pub fn evalUnary(self: *Interpreter, op: ast.UnaryOp, operand: *const ast.Node, env: *Environment) EvalError!Completion {
    if (op == .typeof_) {
        // §13.5.3: typeof of an *unresolved* identifier is "undefined" — it must NOT throw
        // (this is how assert.js probes `typeof JSON !== "undefined"`). A name is unresolved only
        // when it misses the declarative chain, any enclosing `with` object, AND the global object
        // record; otherwise fall through to evaluate it (and report its real type).
        if (operand.* == .identifier and env.lookup(operand.identifier) == null) {
            const nm = operand.identifier;
            const in_with = self.with_depth > 0 and interp_stmt.resolveIdRef(self, env, nm) != .unresolved;
            if (!in_with and !globalObjectHas(self, nm)) return .{ .normal = .{ .string = "undefined" } };
        }
        const c = try self.evalExpr(operand, env);
        if (c.isAbrupt()) return c;
        return .{ .normal = .{ .string = typeOf(c.normal) } };
    }
    // §13.5.1.2 `delete` — operates on a Reference, not a value, so resolve the target rather
    // than calling GetValue. A property reference (`a.b` / `a[k]`) deletes the own property and
    // returns true (M-subset: every own property is configurable). A non-Reference operand
    // (`delete 5`, `delete f()`, a parenthesized non-reference) evaluates its operand for side
    // effects and returns true. An unqualified identifier returns true in sloppy mode (we don't
    // yet enforce the §13.5.1.1 strict-mode SyntaxError — see gap note).
    if (op == .delete_) return evalDelete(self, operand, env);
    const c = try self.evalExpr(operand, env);
    if (c.isAbrupt()) return c;
    const v = c.normal;
    // §13.5.7 `!` and §13.5.2 `void` need no numeric coercion (so no ToPrimitive side effect).
    switch (op) {
        .not => return .{ .normal = .{ .boolean = !toBoolean(v) } }, // §13.5.7
        .void_ => return .{ .normal = .undefined }, // §13.5.2: evaluate operand (done), yield undefined
        .typeof_, .delete_ => unreachable,
        else => {},
    }
    // §13.5.4/.5/.6: unary `+`/`-`/`~` ToPrimitive (number hint), then operate. A BigInt primitive
    // takes the BigInt path: `-`/`~` produce a BigInt; unary `+` on a BigInt is a TypeError (§13.5.4.1).
    const pc = try self.toPrimitive(v, .number);
    if (pc.isAbrupt()) return pc;
    const prim = pc.normal;
    if (prim == .bigint) {
        const b = prim.bigint;
        switch (op) {
            .plus => return self.throwError("TypeError", "Cannot convert a BigInt value to a number"), // §13.5.4.1
            .minus => return .{ .normal = .{ .bigint = bigint.neg(self.arena, b) catch |e| return self.bigintError(e) } }, // §13.5.5
            .bit_not => return .{ .normal = .{ .bigint = bigint.bitNot(self.arena, b) catch |e| return self.bigintError(e) } }, // §13.5.6
            else => unreachable,
        }
    }
    if (prim == .symbol) return self.throwError("TypeError", "Cannot convert a Symbol value to a number");
    const n = toNumber(prim);
    return switch (op) {
        .plus => .{ .normal = .{ .number = n } }, // §13.5.4
        .minus => .{ .normal = .{ .number = -n } }, // §13.5.5
        .bit_not => .{ .normal = .{ .number = @floatFromInt(~numToInt32(n)) } }, // §13.5.6
        else => unreachable,
    };
}

/// §13.5.1.2 Runtime Semantics of the `delete` UnaryExpression. `delete a.b` / `delete a[k]`
/// resolves the base object, removes the own property `key`, and returns `true`. For an array
/// integer index we leave a hole by setting the element to `undefined` (M-subset; a true sparse
/// array model is deferred). A non-Reference operand evaluates for side effects and returns true.
/// §13.5.1.2 step 6: in strict mode a `delete` of a property reference whose [[Delete]] returned
/// false (a non-configurable own property) is a TypeError; sloppy mode yields the `false`.
pub fn finishStrictDelete(self: *Interpreter, dc: Completion) EvalError!Completion {
    if (dc.isAbrupt()) return dc;
    if (self.strict and dc.normal == .boolean and !dc.normal.boolean) return self.throwError("TypeError", "Cannot delete property of an object in strict mode");
    return dc;
}

pub fn evalDelete(self: *Interpreter, operand: *const ast.Node, env: *Environment) EvalError!Completion {
    switch (operand.*) {
        .member => |m| {
            const oc = try self.evalExpr(m.object, env);
            if (oc.isAbrupt()) return oc;
            const dc = try self.deleteProperty(oc.normal, m.name);
            return finishStrictDelete(self, dc);
        },
        .index => |ix| {
            const oc = try self.evalExpr(ix.object, env);
            if (oc.isAbrupt()) return oc;
            const kc = try self.evalExpr(ix.key, env);
            if (kc.isAbrupt()) return kc;
            // §13.5.1.2 / §10.1.10: ToPropertyKey first — a Symbol key deletes from the symbol-keyed
            // own store (`toString` would stringify it and silently no-op, leaving the prop in place).
            const pk = try self.toPropertyKey(kc.normal);
            if (pk.isAbrupt()) return pk.completion;
            if (pk.symbol) |sym| {
                if (oc.normal == .object) {
                    if (oc.normal.object.proxy) |pd| return finishStrictDelete(self, try builtin_proxy.deleteProperty(self, pd, .{ .symbol = sym }));
                    return finishStrictDelete(self, .{ .normal = .{ .boolean = oc.normal.object.deleteSymbol(sym) } });
                }
                if (oc.normal == .undefined or oc.normal == .null) return self.throwError("TypeError", "Cannot convert undefined or null to object");
                return .{ .normal = .{ .boolean = true } };
            }
            return finishStrictDelete(self, try self.deleteProperty(oc.normal, pk.key));
        },
        // §13.5.1.2 step 3 / §9.1.1.4.18 DeleteBinding: `delete` of an unqualified
        // IdentifierReference. A binding created by a sloppy assignment to an unresolved name
        // (§9.1.1.4.16) is a CONFIGURABLE global property — `delete` removes it (from both the
        // reified global object and the global Environment, keeping the two views consistent), so a
        // later read throws ReferenceError. Lexical/var/function bindings are non-deletable: those
        // (no configurable global-object property) keep the M-subset deviation of returning true
        // without removing. Strict `delete x` is a §13.5.1.1 SyntaxError (parse-rejected upstream).
        .identifier => |name| {
            if (self.globals) |g| {
                if (g.lookup("%GlobalThis%")) |gb| if (gb.value == .object) {
                    const o = gb.value.object;
                    if (o.properties.get(name)) |pv| {
                        if (!pv.configurable) return .{ .normal = .{ .boolean = false } };
                        _ = o.properties.orderedRemove(name);
                        _ = g.vars.remove(name); // remove the mirrored global Environment binding
                    }
                };
            }
            return .{ .normal = .{ .boolean = true } };
        },
        // §13.5.1.2 step 2: the operand is not a Reference — evaluate it for side effects and
        // return true (`delete 5`, `delete f()`, `delete (x + 1)`).
        else => {
            const c = try self.evalExpr(operand, env);
            if (c.isAbrupt()) return c;
            return .{ .normal = .{ .boolean = true } };
        },
    }
}

/// §20.5: throw a real Error object carrying `name`/`message`, proto-linked to the realm's
/// matching Error constructor (so `e instanceof TypeError` and name-based classification work).
/// §19.2.1.1 PerformEval — parse `source` as a Script and run it in `target_env` on THIS
/// interpreter (so the live step/depth counters carry through; runaway eval code still terminates
/// and recursion through eval stays bounded). A parse error → a real `SyntaxError` (§19.2.1 step
/// 7). The script's completion VALUE is the result (the engine's `run` already returns the last
/// statement's value). `target_env` is a fresh child of the caller's env for DIRECT eval (reads/
/// writes of surrounding bindings work; `let`/`const`/`class` are eval-local) or the GLOBAL env for
/// INDIRECT eval. `this_val`/`home_object` are left at the interpreter's current values (inherited
/// for direct; the caller resets them for indirect). Non-string `source` is handled by the caller.
/// §20.2.1.1 / §20.2.1.1.1 CreateDynamicFunction — `Function(p1, …, pN, body)`: the last argument is
/// the function body, the rest are parameter texts (joined with `,`). Builds the source
/// `(function anonymous(<params>\n) {\n<body>\n})` and evaluates it in the GLOBAL scope (the dynamic
/// function closes over global bindings, not the caller's), returning the resulting function. A
/// malformed parameter/body → a catchable SyntaxError (via performEval). The `\n` after the params
/// and around the body match the spec text (prevent `//`-comment / `)` injection from hiding the
/// closing delimiters). The function's name is `anonymous`; its strictness comes from its own body.
pub fn functionConstructor(self: *Interpreter, args: []const Value) EvalError!Completion {
    const genv = self.globals orelse return self.throwError("EvalError", "Function: no realm");
    var params: std.ArrayListUnmanaged(u8) = .empty;
    var body: []const u8 = "";
    if (args.len > 0) {
        for (args[0 .. args.len - 1], 0..) |p, i| {
            const sc = try self.toStringValuePub(p);
            if (sc.isAbrupt()) return sc;
            if (i > 0) try params.appendSlice(self.arena, ",");
            try params.appendSlice(self.arena, sc.normal.string);
        }
        const bc = try self.toStringValuePub(args[args.len - 1]);
        if (bc.isAbrupt()) return bc;
        body = bc.normal.string;
    }
    const source = try std.fmt.allocPrint(self.arena, "(function anonymous({s}\n) {{\n{s}\n}})", .{ params.items, body });
    // Evaluate in the global context with the global `this` (the dynamic function is created there).
    const saved_this = self.this_val;
    const saved_home = self.home_object;
    defer {
        self.this_val = saved_this;
        self.home_object = saved_home;
    }
    self.this_val = if (genv.lookup("%GlobalThis%")) |b| b.value else .undefined;
    self.home_object = null;
    return performEval(self, source, genv, false);
}

pub fn performEval(self: *Interpreter, source: []const u8, target_env: *Environment, inherit_strict: bool) EvalError!Completion {
    // §19.2.1.1: the eval code is strict iff it carries its own `"use strict"` prologue OR (DIRECT
    // eval only) the calling context is strict (`inherit_strict`). Parsing with the inherited flag
    // folds both into `program.strict`, which `run` installs as the eval body's runtime strictness.
    const program = Parser.parseMode(self.arena, source, inherit_strict) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // §19.2.1 step 7: a parse failure throws a SyntaxError (a real, catchable error object).
        else => return self.throwError("SyntaxError", "eval: invalid source"),
    };
    // §19.2.1.3: a STRICT eval gets its OWN VariableEnvironment (its `var`s are eval-local); a
    // SLOPPY direct eval's `var`s hoist to the caller's var scope (its fresh eval env is left a
    // non-var-scope so `varScope()` climbs past it). An indirect eval / Function-body eval already
    // targets the global var scope, which this preserves (`or`-ing keeps an existing var scope).
    target_env.is_var_scope = target_env.is_var_scope or program.strict;
    // Reuse `run` (ReturnIfAbrupt over the statement list); the completion value is the last
    // statement's value. Counters are the interpreter's own — not reset, so limits still apply.
    return self.run(program, target_env);
}

/// §20.2.3.1/.2/.3 — `Function.prototype.call`/`apply`/`bind`. `this_val` is the target function
/// (the receiver of the method call, e.g. `f` in `f.call(...)`); step 1 of each requires it to be
/// callable (TypeError otherwise). `name` selects the method.
pub fn functionPrototypeMethod(self: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    // §20.2.3.{1,2,3} step 1: the receiver must be callable.
    if (this_val != .object or this_val.object.kind != .function) {
        return self.throwError("TypeError", "Function.prototype method called on non-callable");
    }
    const target = this_val.object;

    if (std.mem.eql(u8, name, "call")) {
        // §20.2.3.3 Function.prototype.call ( thisArg, ...args )
        const this_arg = if (args.len > 0) args[0] else .undefined;
        const rest = if (args.len > 1) args[1..] else &.{};
        return self.callFunction(target, rest, this_arg);
    }

    if (std.mem.eql(u8, name, "apply")) {
        // §20.2.3.1 Function.prototype.apply ( thisArg, argArray )
        const this_arg = if (args.len > 0) args[0] else .undefined;
        const arg_array = if (args.len > 1) args[1] else .undefined;
        const call_args = try self.createListFromArrayLike(arg_array);
        switch (call_args) {
            .abrupt => |c| return c,
            .list => |list| return self.callFunction(target, list, this_arg),
        }
    }

    if (std.mem.eql(u8, name, "bind")) {
        // §20.2.3.2 Function.prototype.bind ( thisArg, ...args ) → §10.4.1.3 BoundFunctionCreate.
        const this_arg = if (args.len > 0) args[0] else .undefined;
        const bound_args_src = if (args.len > 1) args[1..] else &.{};
        // Copy the bound args into the realm arena (the caller's `args` slice is transient).
        const bound_args = try self.arena.dupe(Value, bound_args_src);
        const bf = try Object.createBound(self.arena, self.functionProto(), .{
            .target = target,
            .bound_this = this_arg,
            .bound_args = bound_args,
        });
        // §20.2.3.2 step 4–8: a bound function's `length` is max(0, target.length - boundArgs)
        // (target.length coerced to an integer; a non-number/absent → 0); its `name` is
        // "bound " + target.name (target.name coerced to string; a non-string → "").
        var target_len: f64 = 0;
        if (target.get("length")) |lv| if (lv == .number and lv.number > 0 and std.math.isFinite(lv.number)) {
            target_len = @trunc(lv.number);
        };
        const bound_len = @max(0, target_len - @as(f64, @floatFromInt(bound_args.len)));
        try setFunctionLength(bf, bound_len);
        const target_name = if (target.get("name")) |nv| (if (nv == .string) nv.string else "") else "";
        try self.setFunctionName(bf, target_name, "bound");
        return .{ .normal = .{ .object = bf } };
    }

    return self.throwError("TypeError", "unknown Function.prototype method");
}
