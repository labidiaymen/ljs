//! §15.7 class definition & instance initialization — extracted from interpreter.zig as free
//! functions taking `self: *Interpreter` (Zig 0.16 removed `usingnamespace`). Covers ClassDefinition
//! evaluation (heritage, constructor, methods/accessors/fields, static elements, static blocks,
//! private elements), InitializeInstanceElements, running a parent constructor, and the derived-ctor
//! return semantics. Behavior-identical to the original methods; calls to OTHER interpreter methods
//! stay `self.foo(...)` (resolved via interpreter.zig wrappers / remaining methods).
const std = @import("std");
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const ast = @import("ast.zig");
const Completion = @import("completion.zig").Completion;
const Value = @import("value.zig").Value;
const Environment = @import("environment.zig").Environment;
const object_mod = @import("object.zig");
const Object = object_mod.Object;

const KeyResult = Interpreter.KeyResult;
const setFunctionLength = Interpreter.setFunctionLength;
const paramCount = Interpreter.paramCount;

pub fn wrapperResult(self: *Interpreter, prim: Value, this_val: Value) Completion {
    if (self.native_new_target != .undefined and this_val == .object) {
        this_val.object.primitive = prim;
        return .{ .normal = this_val };
    }
    return .{ .normal = prim };
}

/// §15.7.14: run a parent constructor `sup` on an existing `instance` (the `super(...)` /
/// default-derived path). If the parent is itself a BASE class, its instance fields initialize
/// before its body; a DERIVED parent runs its own body (which calls its own `super(...)`), so its
/// fields are handled by that nested call. The parent's `home_object` is installed by callFunction.
pub fn runParentCtor(self: *Interpreter, sup: *Object, args: []const Value, instance: *Object) EvalError!Completion {
    if (sup.call) |sfd| {
        if (!sfd.is_derived_ctor) {
            const fc = try initInstanceFields(self, sfd, instance);
            if (fc.isAbrupt()) return fc;
        }
    }
    // §13.3.12: `new.target` propagates DOWN a `super(...)` chain unchanged — the parent constructor
    // sees the SAME [[NewTarget]] as the derived class that invoked it (the original `new` target).
    // The active `new_target` is that value (set when this derived ctor body / construct began).
    // A `super(...)` is ALWAYS a [[Construct]], so signal that to `callFunction` (whose §15.7.14
    // class-ctor [[Call]] guard keys on a non-undefined hand-off) even in the edge where the active
    // new_target was lost — e.g. an arrow `() => super()` invoked from an iterator-return handler
    // after the derived ctor body already left (the parent ctor `sup` is itself the fallback marker).
    self.pending_new_target = if (self.new_target == .undefined) .{ .object = sup } else self.new_target;
    return self.callFunction(sup, args, .{ .object = instance });
}

/// §15.7.14 InitializeInstanceElements — add this class's PrivateName brand (private fields /
/// methods / accessors) to `instance`, then define each instance FieldDefinition on `instance`, in
/// declaration order, evaluating its initializer with `this` = the instance, in a scope child of
/// the class's defining environment (so an initializer may reference the class name / outer
/// bindings). A field with no initializer is created with value `undefined`.
pub fn initInstanceFields(self: *Interpreter, fd: object_mod.FunctionData, instance: *Object) EvalError!Completion {
    // §15.7: install the private brand first — private methods/accessors are shared (recorded at
    // class definition), and private fields' initializers run with `this` = the instance below.
    const pc = try installPrivateElements(self, fd, instance);
    if (pc.isAbrupt()) return pc;
    if (fd.fields.len == 0) return .{ .normal = .undefined };
    const field_env = try Environment.create(self.arena, fd.closure);
    const saved_this = self.this_val;
    self.this_val = .{ .object = instance };
    defer self.this_val = saved_this;
    // §13.3.5: a field initializer's [[HomeObject]] is the class's `.prototype` (the ctor's home),
    // so `super.x` inside an initializer resolves against the superclass prototype.
    const saved_home = self.home_object;
    self.home_object = fd.home_object;
    defer self.home_object = saved_home;
    // §9.2: a field initializer resolves `this.#x` against the class's [[PrivateEnvironment]].
    const saved_penv = self.private_env;
    self.private_env = fd.private_env;
    defer self.private_env = saved_penv;
    // §15.7.10: a field initializer is evaluated as a function (§13.3.12 `new.target` is legal in it,
    // evaluating to undefined) — count it as a function context so a nested direct `eval` can parse
    // `new.target`. A BASE class runs fields outside the ctor body's callFunction frame, so bump here.
    self.func_depth += 1;
    defer self.func_depth -= 1;
    for (fd.fields) |field| {
        var v: Value = .undefined;
        if (field.init) |ie| {
            const ic = try self.evalExpr(ie, field_env);
            if (ic.isAbrupt()) return ic;
            v = ic.normal;
            // §15.7.10 / §8.4 NamedEvaluation: a field with an anonymous function/class initializer
            // gets the field name (string key, or "[desc]" for a symbol-keyed field).
            const fname = if (field.key_symbol) |sym| try self.symbolPropName(sym) else field.key;
            try self.maybeSetAnonName(ie, v, fname);
        }
        // §15.7.14 DefineField: a private field adds its brand to the instance's private slots AT
        // this point in declaration order (so a forward `this.#x` earlier in the list threw above);
        // a public field defines an ordinary own property.
        if (field.is_private) {
            // §7.3.28 PrivateFieldAdd step 2: adding a Private Name already present on the object is a
            // TypeError (a derived class re-running its initializer on an object already branded — e.g.
            // `class Base{constructor(o){return o}}` returning the same object to two `new C(o)` calls).
            if (instance.hasPrivate(field.key)) return self.throwError("TypeError", "Cannot initialize private field twice on the same object");
            try instance.setPrivate(field.key, v);
        } else if (field.key_symbol) |sym| {
            try instance.setSymbol(sym, v);
        } else {
            try instance.set(field.key, v);
        }
    }
    return .{ .normal = .undefined };
}

/// §15.7 install this class's instance PrivateName elements on `instance` (its brand): private
/// methods/accessors (shared function objects, copied/merged into the private slot) and private
/// fields (initializer run with `this` = the instance, in the class's defining scope). Done in
/// declaration order so a later field initializer may call an earlier private method.
pub fn installPrivateElements(self: *Interpreter, fd: object_mod.FunctionData, instance: *Object) EvalError!Completion {
    if (fd.private_elements.len == 0) return .{ .normal = .undefined };
    const env = try Environment.create(self.arena, fd.closure);
    const saved_this = self.this_val;
    const saved_home = self.home_object;
    self.this_val = .{ .object = instance };
    self.home_object = fd.home_object; // the class `.prototype` (so `super.x` resolves)
    // §9.2: a private field initializer resolves `this.#x` against the class's [[PrivateEnvironment]].
    const saved_penv = self.private_env;
    self.private_env = fd.private_env;
    defer self.this_val = saved_this;
    defer self.home_object = saved_home;
    defer self.private_env = saved_penv;
    // §7.3.29 PrivateMethodOrAccessorAdd step 3: adding a private method/accessor whose Private Name is
    // already on the object is a TypeError. This fires when a derived class re-runs its private-element
    // install on an object a previous construction already branded (a base ctor returning the same
    // object to two `new C(o)` calls). Check up front — a get+set pair shares one key and is added in a
    // single pass below (the per-element merge must NOT trip this), so test BEFORE adding any.
    for (fd.private_elements) |pe| {
        if (instance.hasPrivate(pe.key)) return self.throwError("TypeError", "Cannot initialize private method twice on the same object");
    }
    for (fd.private_elements) |pe| {
        switch (pe.kind) {
            .method => try instance.setPrivate(pe.key, .{ .object = pe.func.? }),
            .get => try instance.definePrivateAccessor(pe.key, pe.func.?, null),
            .set => try instance.definePrivateAccessor(pe.key, null, pe.func.?),
            .field => {
                var v: Value = .undefined;
                if (pe.init) |ie| {
                    const ic = try self.evalExpr(ie, env);
                    if (ic.isAbrupt()) return ic;
                    v = ic.normal;
                }
                try instance.setPrivate(pe.key, v);
            },
        }
    }
    return .{ .normal = .undefined };
}

/// §15.7.14 ClassElementName for a method/accessor/field — the literal key, or (for a computed
/// `[expr]` key) the ToPropertyKey of the evaluated key expression.
pub fn classElementKey(self: *Interpreter, el: ast.ClassElement, env: *Environment) EvalError!KeyResult {
    if (el.computed_key) |ck| {
        const c = try self.evalExpr(ck, env);
        if (c.isAbrupt()) return .{ .completion = c };
        return self.toPropertyKey(c.normal); // §7.1.19 ToPropertyKey (Symbol stays; object → ToPrimitive)
    }
    return .{ .key = el.key };
}

/// §15.7.14 step 4 / §10.2.4: a STATIC class element keyed `"prototype"` (literal or a computed key
/// evaluating to the string `"prototype"`) is a TypeError — DefinePropertyOrThrow on the
/// constructor's non-configurable, non-writable `prototype` own property fails. A symbol key is
/// always distinct from the string `"prototype"`, and instance elements install on `.prototype`
/// (where `prototype` is a fine key), so neither is affected. Returns the abrupt completion to
/// propagate when this rule fires, else null.
pub fn staticPrototypeKeyError(self: *Interpreter, is_static: bool, key: KeyResult) EvalError!?Completion {
    if (is_static and key.symbol == null and std.mem.eql(u8, key.key, "prototype")) {
        return try self.throwError("TypeError", "Classes may not have a static property named 'prototype'");
    }
    return null;
}

/// §10.2.1.3 EvaluateBody / §10.2.2 [[Construct]] step 13 (constructor return). For a DERIVED
/// constructor: an Object return is returned as-is (step 13.a); a `return;`/fall-off `undefined`
/// yields GetThisBinding — a ReferenceError if `super(...)` was never called (step 13.e, `this`
/// uninitialized); and a NON-undefined NON-object return (e.g. `return null` / `return 5`) is a
/// TypeError (step 13.c). A BASE constructor ignores a non-object return (its `this` always wins),
/// and non-derived functions return their value untouched.
pub fn finishCtorReturn(self: *Interpreter, fd: object_mod.FunctionData, value: Value) EvalError!Completion {
    if (fd.is_derived_ctor and value != .object) {
        if (value == .undefined) {
            if (self.this_init_cell) |c| if (!c.*)
                return self.throwError("ReferenceError", "Must call super constructor in derived class before accessing 'this' or returning from derived constructor");
        } else {
            // §10.2.2 step 13.c: a derived ctor returning a primitive (null/number/string/etc.) throws.
            return self.throwError("TypeError", "Derived constructors may only return object or undefined");
        }
    }
    return .{ .normal = value };
}

pub fn evalClass(self: *Interpreter, c: *const ast.Class, env: *Environment) EvalError!Completion {
    // §15.7.14: a class is created in a new declarative scope that holds the (immutable) class
    // binding for self-reference. Methods/field initializers close over this scope.
    const class_env = try Environment.create(self.arena, env);
    // §15.7.14 step 4: CreateImmutableBinding(className) as UNINITIALIZED (TDZ) BEFORE evaluating
    // the heritage, so a self-reference in `extends` (`class x extends x {}`) is a ReferenceError.
    // Re-declared as the initialized class object after the constructor is built (below).
    if (c.name) |name| try class_env.declare(name, .undefined, false, false);

    // §15.7.14 ClassHeritage: evaluate `extends LHS`. `super_ctor` is the parent constructor
    // (null for `extends null` and for a non-derived class); `is_derived` is set by the presence
    // of the heritage clause (so `extends null` is still a derived class with no parent ctor).
    var super_ctor: ?*Object = null;
    var super_proto: ?*Object = null; // the prototype to link the instance `.prototype` to
    var super_proto_is_null = false; // `extends null` explicitly links to null
    const is_derived = c.superclass != null;
    if (c.superclass) |se| {
        const sc = try self.evalExpr(se, class_env);
        if (sc.isAbrupt()) return sc;
        switch (sc.normal) {
            .null => super_proto_is_null = true, // §15.7.14: `extends null`
            .object => |so| {
                // §15.7.14: the superclass must be a constructor with an object/null `.prototype`.
                if (so.kind != .function) return self.throwError("TypeError", "Class extends value is not a constructor or null");
                super_ctor = so;
                // §15.7.14: protoParent = Get(superclass, "prototype"); it must be an Object or
                // null — a present primitive (number/string/undefined/…) is a TypeError. An object
                // links the derived prototype; null links to null (no parent prototype).
                if (so.get("prototype")) |pv| switch (pv) {
                    .object => |po| super_proto = po,
                    .null => {},
                    else => return self.throwError("TypeError", "Class extends value does not have a valid prototype property"),
                };
            },
            else => return self.throwError("TypeError", "Class extends value is not a constructor or null"),
        }
    }

    // Locate the explicit constructor (if any). Instance field records are collected during the
    // definition-order installation pass below (their keys — including computed `[expr]` keys —
    // are evaluated at class-definition time, §15.7.14 ClassElementEvaluation) and attached to the
    // constructor's FunctionData afterward.
    var ctor_fn: ?*const ast.Function = null;
    for (c.elements) |el| {
        if (el.kind == .constructor) ctor_fn = el.value.func;
    }
    var fields: std.ArrayListUnmanaged(object_mod.FieldInit) = .empty;

    // §8.2.x / §15.7.14 ClassDefinitionEvaluation: mint a FRESH Private Name per declared private
    // element of THIS class evaluation, and push a PrivateEnvironment frame (parent = the enclosing
    // one). Two evaluations of the same class source get distinct Private Names (so a `#x` minted by
    // one is never found on an instance branded by the other → the §13.15 brand-check TypeError); a
    // nested class's `#x` shadows an outer one (innermost-out resolution). The frame is installed as
    // the running [[PrivateEnvironment]] for the whole body (methods/initializers capture/resolve it)
    // and restored on exit. A `key`-map is built so each element's install uses its unique slot key.
    var pname_map: std.StringHashMapUnmanaged(*object_mod.PrivateName) = .empty;
    var pnames: std.ArrayListUnmanaged(*object_mod.PrivateName) = .empty;
    for (c.elements) |el| {
        if (!el.is_private) continue;
        if (pname_map.contains(el.key)) continue; // a get/set pair shares ONE Private Name
        const pn = try self.arena.create(object_mod.PrivateName);
        const key = try std.fmt.allocPrint(self.arena, "{s}\x00{d}", .{ el.key, self.private_name_counter });
        self.private_name_counter += 1;
        pn.* = .{ .spelling = el.key, .key = key };
        try pname_map.put(self.arena, el.key, pn);
        try pnames.append(self.arena, pn);
    }
    const saved_penv = self.private_env;
    defer self.private_env = saved_penv;
    if (pnames.items.len > 0) {
        const pe = try self.arena.create(object_mod.PrivateEnv);
        pe.* = .{ .parent = saved_penv, .names = pnames.items };
        self.private_env = pe;
    }
    // Resolve a private element's source spelling (`#x`) to its unique slot key for this class.
    const privKey = struct {
        fn f(map: *std.StringHashMapUnmanaged(*object_mod.PrivateName), spelling: []const u8) []const u8 {
            return if (map.get(spelling)) |pn| pn.key else spelling;
        }
    }.f;

    // §15.7.14: build the constructor function object. Default constructor: a base class gets an
    // empty body; a derived class's default constructor forwards its args to `super(...)` (handled
    // by `is_derived_ctor` + an implicit super-call in evalNew when there's no explicit ctor body).
    const ctor = try Object.createFunction(self.arena, .{
        .params = if (ctor_fn) |f| f.params else &.{},
        .rest = if (ctor_fn) |f| f.rest else null,
        .body = if (ctor_fn) |f| f.body else &.{},
        .closure = class_env,
        .is_class_ctor = true,
        .is_derived_ctor = is_derived,
        .is_default_ctor = ctor_fn == null, // no explicit `constructor` → synthesized default
        .super_ctor = super_ctor,
        .strict = true, // §15.7: a class body (and thus its constructor) is always strict
        .src = self.script_source,
        .src_name = self.script_name,
    });
    ctor.prototype = self.functionProto(); // §20.2.3 default; a derived class overrides to Super below
    // The constructor's `.prototype` object holds the instance methods.
    const proto: *Object = blk: {
        const pv = ctor.get("prototype") orelse break :blk try Object.create(self.arena, null);
        break :blk if (pv == .object) pv.object else try Object.create(self.arena, null);
    };
    // §15.7.14: a class constructor's [[HomeObject]] is its `.prototype` (so `super.x` in the
    // constructor resolves against `Super.prototype`); the ctor reads its own `super_ctor` for
    // `super(...)` via `proto.constructor`.
    if (ctor.call) |*fd| fd.home_object = proto;
    // §9.2: the constructor (explicit or synthesized default) runs with this class's
    // [[PrivateEnvironment]], so `this.#x` inside the constructor body resolves to this class's
    // Private Names. `self.private_env` is the frame pushed above (or the outer one if no privates).
    if (ctor.call) |*fd| fd.private_env = self.private_env;
    // §15.7.14 step 13 / §10.2.4 MakeConstructor: a class constructor's `prototype` own property is
    // { [[Writable]]: false, [[Enumerable]]: false, [[Configurable]]: false } (an ordinary function
    // gets a writable one; `createFunction` defaulted to writable). Lock it here so a later
    // `static prototype`/`static get ['prototype']` element hits DefinePropertyOrThrow on a
    // non-configurable property and throws (§14.5 prototype-property; static-prototype tests).
    try ctor.defineData("prototype", .{ .object = proto }, false, false, false);
    // §15.7.14: the `constructor` own property of `.prototype` is non-enumerable (writable +
    // configurable). `set` would make it enumerable, so define it explicitly.
    try proto.defineData("constructor", .{ .object = ctor }, true, false, true);
    // §20.2.4.1/.2: the constructor's `length` = ExpectedArgumentCount of its params; its `name`
    // is the class name (or "" for an anonymous class expression — a NamedEvaluation site may
    // rename it). §15.7.14 step 17/18 SetFunctionName/SetFunctionLength on the constructor.
    try setFunctionLength(ctor, paramCount(ctor.call.?.params));
    try self.setFunctionName(ctor, c.name orelse "", "");

    // §15.7.14 link the prototype chains for inheritance.
    if (is_derived) {
        // `proto.[[Prototype]]` = `Super.prototype` (or null for `extends null` / a parent whose
        // `.prototype` is not an object).
        proto.prototype = if (super_proto_is_null) null else super_proto;
        // `ctor.[[Prototype]]` = `Super` (static inheritance). For `extends null` there is no
        // parent constructor, so static inheritance falls back to the default function proto chain.
        ctor.prototype = super_ctor;
    } else {
        // §15.7.14 step 6.a: a base class (no `extends`) has `protoParent` = %Object.prototype%, so
        // `C.prototype.[[Prototype]]` is `Object.prototype` (the freshly-created proto object that
        // `createFunction` made has a null [[Prototype]] — relink it here).
        proto.prototype = self.objectProto();
    }

    // §15.7.14 ClassElementEvaluation: walk the ClassBody in definition order, installing methods,
    // accessors, and static fields, and collecting instance-field records. Instance members →
    // `.prototype`, static members → the constructor object. A computed `[expr]` PropertyName is
    // evaluated HERE (definition order, ToPropertyKey → ToString in the M-subset), so its
    // side-effects interleave with the other elements. Each method/accessor's [[HomeObject]] is its
    // install target (so `super.x` inside it looks up `home_object.[[Prototype]]`).
    var private_elements: std.ArrayListUnmanaged(object_mod.PrivateElement) = .empty;
    for (c.elements) |el| {
        switch (el.kind) {
            .constructor => {}, // already the [[Call]] body
            .static_block => {
                // §15.7.11: a ClassStaticBlock runs once at class definition with `this` = the
                // constructor, in a scope child of the class scope. Its [[HomeObject]] is the
                // constructor (so `super.x` resolves against `Super`).
                const block_env = try Environment.create(self.arena, class_env);
                block_env.is_var_scope = true; // §15.7.11: a ClassStaticBlock is its own VariableEnvironment
                try self.hoistVarNames(el.value.block, block_env);
                const saved_this = self.this_val;
                const saved_home = self.home_object;
                self.this_val = .{ .object = ctor };
                self.home_object = ctor;
                self.func_depth += 1; // §13.3.12: `new.target` is legal inside a static block (→ a nested direct eval may use it)
                const bc = self.runBlockBody(el.value.block, block_env);
                self.func_depth -= 1;
                self.this_val = saved_this;
                self.home_object = saved_home;
                const r = try bc;
                if (r.isAbrupt()) return r;
            },
            .method => {
                const target = if (el.is_static) ctor else proto;
                const fc = try self.evalFunctionExpr(el.value.func, class_env);
                if (fc.isAbrupt()) return fc;
                const f = fc.normal.object;
                // §9.2.5: a method's [[HomeObject]] is the object it is defined on.
                if (f.call) |*mfd| mfd.home_object = target;
                if (el.is_private) {
                    // §15.7: a private method. Static → install on the ctor's private slot now;
                    // instance → record for per-instance install (the brand is added on each `new`).
                    if (f.call) |*mfd| mfd.is_private_method = true;
                    // §15.7.14: a private method's name is `#m` (its key includes the `#`).
                    try self.setFunctionName(f, el.key, "");
                    const pkey = privKey(&pname_map, el.key);
                    if (el.is_static) {
                        try ctor.setPrivate(pkey, fc.normal);
                    } else {
                        try private_elements.append(self.arena, .{ .key = pkey, .spelling = el.key, .kind = .method, .func = f });
                    }
                } else {
                    const key = try classElementKey(self, el, class_env);
                    if (key.isAbrupt()) return key.completion;
                    if (try staticPrototypeKeyError(self, el.is_static, key)) |e| return e;
                    // §15.7.14: a class method's `name` is its property key (symbol → "[desc]").
                    try self.setFunctionName(f, if (key.symbol) |sym| try self.symbolPropName(sym) else key.key, "");
                    // §15.7.x: class methods are NON-enumerable (writable + configurable). Define
                    // explicitly (vs `set`, which would make it enumerable like an object method).
                    if (key.symbol) |sym| {
                        try target.defineSymbolData(sym, fc.normal, true, false, true);
                    } else {
                        try target.defineData(key.key, fc.normal, true, false, true);
                    }
                }
            },
            .get, .set => {
                // §15.7 accessor (§13.2.5.6 model): merge a get/set pair for the same key into one
                // accessor property on `.prototype` (instance) or the constructor (static).
                const target = if (el.is_static) ctor else proto;
                const fc = try self.evalFunctionExpr(el.value.func, class_env);
                if (fc.isAbrupt()) return fc;
                const f = fc.normal.object;
                // §9.2.5: the accessor carries [[HomeObject]] too (so `super.x` works inside it).
                if (f.call) |*mfd| mfd.home_object = target;
                if (el.is_private) {
                    // §15.7: a private accessor. Static → merge into the ctor's private slot now;
                    // instance → record (merged per-instance at construction).
                    // §15.7.14: a private accessor's name is "get #x" / "set #x".
                    try self.setFunctionName(f, el.key, if (el.kind == .get) "get" else "set");
                    const pkey = privKey(&pname_map, el.key);
                    if (el.is_static) {
                        if (el.kind == .get) {
                            try ctor.definePrivateAccessor(pkey, f, null);
                        } else {
                            try ctor.definePrivateAccessor(pkey, null, f);
                        }
                    } else {
                        try private_elements.append(self.arena, .{
                            .key = pkey,
                            .spelling = el.key,
                            .kind = if (el.kind == .get) .get else .set,
                            .func = f,
                        });
                    }
                } else {
                    const key = try classElementKey(self, el, class_env);
                    if (key.isAbrupt()) return key.completion;
                    if (try staticPrototypeKeyError(self, el.is_static, key)) |e| return e;
                    // §15.7.14: a class accessor's name is "get x" / "set x" (symbol → "[desc]").
                    try self.setFunctionName(f, if (key.symbol) |sym| try self.symbolPropName(sym) else key.key, if (el.kind == .get) "get" else "set");
                    const getter: ?*Object = if (el.kind == .get) f else null;
                    const setter: ?*Object = if (el.kind == .set) f else null;
                    // §15.7.x: class accessors are NON-enumerable (configurable). Define explicitly.
                    if (key.symbol) |sym| {
                        try target.defineSymbolAccessorEx(sym, getter, setter, false);
                    } else {
                        try target.defineAccessorEx(key.key, getter, setter, false);
                    }
                }
            },
            .field => {
                if (el.is_private) {
                    if (el.is_static) {
                        // §15.7.14: a static private field initializes at class definition with
                        // `this` = the constructor, into the ctor's private slot.
                        var v: Value = .undefined;
                        if (el.value.field_init) |ie| {
                            const saved_this = self.this_val;
                            self.this_val = .{ .object = ctor };
                            self.func_depth += 1; // §15.7.10: a field initializer is a function context (`new.target` legal)
                            const ic = try self.evalExpr(ie, class_env);
                            self.func_depth -= 1;
                            self.this_val = saved_this;
                            if (ic.isAbrupt()) return ic;
                            v = ic.normal;
                        }
                        try ctor.setPrivate(privKey(&pname_map, el.key), v);
                    } else {
                        // §15.7.14: an instance private field joins the SINGLE ordered [[Fields]] list
                        // (interleaved with public fields, declaration order) — its brand is added when
                        // its initializer runs (DefineField), so an earlier forward `this.#x` throws.
                        try fields.append(self.arena, .{ .key = privKey(&pname_map, el.key), .init = el.value.field_init, .is_private = true });
                    }
                    continue;
                }
                const key = try classElementKey(self, el, class_env);
                if (key.isAbrupt()) return key.completion;
                if (try staticPrototypeKeyError(self, el.is_static, key)) |e| return e;
                // §15.7.10: a field's name (string key, or "[desc]" for a symbol key) is the
                // NamedEvaluation name for an anonymous function/class initializer.
                const field_name = if (key.symbol) |sym| try self.symbolPropName(sym) else key.key;
                if (el.is_static) {
                    // §15.7.14: a static field initializer runs at class definition with `this` =
                    // the constructor object.
                    var v: Value = .undefined;
                    if (el.value.field_init) |ie| {
                        const saved_this = self.this_val;
                        self.this_val = .{ .object = ctor };
                        self.func_depth += 1; // §15.7.10: a field initializer is a function context (`new.target` legal)
                        const ic = try self.evalExpr(ie, class_env);
                        self.func_depth -= 1;
                        self.this_val = saved_this;
                        if (ic.isAbrupt()) return ic;
                        v = ic.normal;
                        try self.maybeSetAnonName(ie, v, field_name); // §8.4 NamedEvaluation
                    }
                    if (key.symbol) |sym| try ctor.setSymbol(sym, v) else try ctor.set(key.key, v);
                } else {
                    // §15.7.14: the instance FieldDefinition's name is evaluated now (definition
                    // order); the initializer is run per-instance by initInstanceFields.
                    try fields.append(self.arena, .{ .key = key.key, .init = el.value.field_init, .key_symbol = key.symbol });
                }
            },
        }
    }
    // §15.7.14: stash the resolved instance-field + private-element records on the constructor.
    if (ctor.call) |*fd| {
        fd.fields = fields.items;
        fd.private_elements = private_elements.items;
    }

    // §15.7.14: bind the class name immutably in the inner scope for self-reference.
    if (c.name) |name| try class_env.declare(name, .{ .object = ctor }, false, true);

    return .{ .normal = .{ .object = ctor } };
}
