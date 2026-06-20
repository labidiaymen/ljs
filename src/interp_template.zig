//! §13.2.8 Template literals — TaggedTemplate evaluation (§13.2.8.6) and GetTemplateObject
//! (§13.2.8.3, the realm template cache). Extracted from interp_expr.zig (behavior-preserving split,
//! Zig 0.16 has no `usingnamespace`) to keep that core under the file-size budget. Free functions
//! taking `self: *Interpreter`; the `evalExpr` dispatch in interp_expr forwards here.
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
const interp_expr = @import("interp_expr.zig");

/// §13.2.8.6 TaggedTemplate `tag\`a${x}b\`` — call `tag` with the template object as the first
/// argument and the ToString of each substitution as the rest, evaluated left-to-right. The `tag`
/// callee is resolved as a Reference (so `obj.m\`…\`` calls `m` with `this = obj`); the `quasi`
/// node's identity keys the realm template cache (§13.2.8.3 GetTemplateObject), so the SAME frozen
/// template object is reused at a given source site across evaluations.
pub fn evalTaggedTemplate(self: *Interpreter, tag: *const ast.Node, quasi: *const ast.Node, env: *Environment) EvalError!Completion {
    // Resolve the tag callee + its `this` (mirrors the callee Reference handling in `evalCall`).
    var this_for_call: Value = .undefined;
    var callee: Value = .undefined;
    switch (tag.*) {
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
            const key = if (sm.key) |kn| blk: {
                const kc = try self.evalExpr(kn, env);
                if (kc.isAbrupt()) return kc;
                break :blk try self.toString(kc.normal);
            } else sm.name;
            const got = try interp_expr.getSuperProperty(self, key);
            if (got.isAbrupt()) return got;
            this_for_call = self.this_val;
            callee = got.normal;
        },
        .private_member => |pm| {
            const oc = try self.evalExpr(pm.object, env);
            if (oc.isAbrupt()) return oc;
            this_for_call = oc.normal;
            const got = try self.getPrivate(oc.normal, pm.name);
            if (got.isAbrupt()) return got;
            callee = got.normal;
        },
        else => {
            const cc = try self.evalExpr(tag, env);
            if (cc.isAbrupt()) return cc;
            callee = cc.normal;
        },
    }

    // §13.2.8.3 GetTemplateObject — the frozen template object (cached by `quasi` identity).
    const t = quasi.template;
    const site = try getTemplateObject(self, quasi, t);

    // §13.2.8.6 ArgumentListEvaluation: arg[0] = the template object, then the VALUES of the
    // substitution expressions (GetValue, NOT ToString — the tag receives the raw values), in
    // left-to-right source order. (ToString is applied only by untagged template concatenation.)
    var args: std.ArrayListUnmanaged(Value) = .empty;
    try args.append(self.arena, .{ .object = site });
    for (t.exprs) |e| {
        const c = try self.evalExpr(e, env);
        if (c.isAbrupt()) return c;
        try args.append(self.arena, c.normal);
    }

    if (callee != .object or callee.object.kind != .function) {
        return self.throwError("TypeError", "Tagged template tag is not a function");
    }
    if (callee.object.call) |fd| {
        if (fd.is_class_ctor) return self.throwError("TypeError", "Class constructor cannot be invoked without 'new'");
    }
    return self.callFunction(callee.object, args.items, this_for_call);
}

/// §13.2.8.3 GetTemplateObject ( templateLiteral ) — return the realm's cached frozen template object
/// for this site, creating it (and the parallel frozen `raw` array) on first use. The cooked array
/// holds the TV of each segment (`undefined` where the segment had an illegal escape); `raw` holds the
/// TRV. Both arrays — and the template object's `raw` property + every index + `length` — are
/// integrity-level "frozen" (§13.2.8.3 steps 9–11): non-writable, non-configurable indices and a
/// non-enumerable, non-writable, non-configurable `raw`.
fn getTemplateObject(self: *Interpreter, key: *const ast.Node, t: anytype) EvalError!*Object {
    if (self.template_map.get(key)) |obj| return obj;

    const cooked = try Object.createArray(self.arena, self.arrayProto());
    const raw = try Object.createArray(self.arena, self.arrayProto());
    for (t.quasis, t.raw, 0..) |q_opt, r, idx| {
        try cooked.arraySet(self.arena, idx, if (q_opt) |q| .{ .string = q } else .undefined);
        try raw.arraySet(self.arena, idx, .{ .string = r });
    }
    // §13.2.8.3 step 9: SetIntegrityLevel(rawObj, frozen) — present indices + `length` non-writable.
    raw.freezeObject();
    // §13.2.8.3 step 10: DefineOwnProperty(template, "raw", { value: rawObj, writable:false,
    // enumerable:false, configurable:false }).
    try cooked.defineData("raw", .{ .object = raw }, false, false, false);
    // §13.2.8.3 step 11: SetIntegrityLevel(template, frozen) — freezes the indices/`length` AND turns
    // the just-defined `raw` data property non-configurable/non-writable (already so; idempotent).
    cooked.freezeObject();

    try self.template_map.put(self.arena, key, cooked);
    return cooked;
}
