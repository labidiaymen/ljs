//! HOST runtime (Node axis, spec 106 — NOT ECMA-262): the `vm` core module — `require('vm')`. A
//! minimal port of Node's `vm` surface sufficient to drive the `test-vm-*` corpus and to unblock the
//! many tests that merely `require('vm')` + `runInNewContext` a literal. NEVER on the Test262 engine
//! surface (host core modules are not requireable there), so 0 Test262 regressions by construction.
//!
//! Mechanics:
//!   • Each module function / `Script` method is a `.vm_method` native whose `native_name` selects the
//!     operation; the `Script` constructor + its prototype methods are distinguished by `native_name`
//!     too (the ctor is `"Script"`, methods are `"runInThisContext"` etc.).
//!   • `runInThisContext(code)` runs `code` in the CURRENT realm (like indirect eval — reuse
//!     `interp_eval.performEval` against the global env), returning the completion value.
//!   • `createContext(sandbox)` / `runInNewContext(code, sandbox)` create a FRESH realm (a new
//!     `Environment` + `builtins.setup`), seed the sandbox's own enumerable data props as globals,
//!     run `code` there, then copy any user-introduced global bindings back onto the sandbox object
//!     (Node's contextified-object behavior — approximated). A context object is marked with a hidden
//!     sentinel property `"%vmcontext%"` so `isContext` recognises it.
//!   • `compileFunction(code, params)` wraps the code as `(function(<params>){<code>})`, runs it in
//!     the current realm, and returns the function (the CommonJS-wrapper trick from host_require).
//!   • `new vm.Script(code)` stores `code` on a hidden own prop; `.runInThisContext()` /
//!     `.runInContext(ctx)` / `.runInNewContext([sandbox])` re-run the stored code.
//!
//! A SyntaxError in `code` throws a real catchable SyntaxError; a runtime throw propagates.
const std = @import("std");
const Value = @import("value.zig").Value;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Completion = @import("completion.zig").Completion;
const Environment = @import("environment.zig").Environment;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const interp_eval = @import("interp_eval.zig");
const builtins = @import("builtins.zig");
const Parser = @import("parser.zig").Parser;

// ════════════════════════════════════════════════════════════════════════════
//  build (require('vm'))
// ════════════════════════════════════════════════════════════════════════════

/// `require('vm')` → an object exposing the module functions + the `Script` class.
pub fn build(self: *Interpreter) EvalError!*Object {
    const arena = self.arena;
    const obj = try Object.create(arena, self.objectProto());

    for ([_][]const u8{
        "runInThisContext",
        "runInNewContext",
        "runInContext",
        "createContext",
        "isContext",
        "compileFunction",
    }) |m| {
        const fn_obj = try makeMethod(self, m);
        try obj.defineData(m, .{ .object = fn_obj }, true, false, true);
    }

    try obj.defineData("Script", .{ .object = try makeScriptCtor(self) }, true, false, true);
    return obj;
}

/// Make a `.vm_method` native function selecting `name` (via `native_name`). Proto-linked to
/// %Function.prototype%, no own `prototype` (a plain method).
fn makeMethod(self: *Interpreter, name: []const u8) EvalError!*Object {
    const fn_obj = try Object.createNative(self.arena, .vm_method, name);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("name", .{ .string = name }, false, false, true);
    return fn_obj;
}

/// The `vm.Script` constructor: a `.vm_method` native named `"Script"` (constructible — see
/// `interp_expr.constructNT`) with a `prototype` carrying `.vm_method` methods.
fn makeScriptCtor(self: *Interpreter) EvalError!*Object {
    const arena = self.arena;
    const proto = try Object.create(arena, self.objectProto());

    const ctor = try Object.createNative(arena, .vm_method, "Script");
    ctor.prototype = self.functionProto();
    try ctor.defineData("name", .{ .string = "Script" }, false, false, true);
    try ctor.defineData("prototype", .{ .object = proto }, false, false, false);
    try proto.defineData("constructor", .{ .object = ctor }, true, false, true);

    for ([_][]const u8{ "runInThisContext", "runInContext", "runInNewContext" }) |m| {
        const fn_obj = try makeMethod(self, m);
        try proto.defineData(m, .{ .object = fn_obj }, true, false, true);
    }
    return ctor;
}

// ════════════════════════════════════════════════════════════════════════════
//  dispatch
// ════════════════════════════════════════════════════════════════════════════

/// Dispatch a `.vm_method` native. `func.native_name` selects the operation; `this_val` is the
/// receiver (the freshly-created instance for `new vm.Script`, or a Script instance for its methods).
pub fn method(self: *Interpreter, func: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const name = func.native_name;
    const eq = std.mem.eql;

    // The `Script` constructor: `new vm.Script(code[, opts])` — store the code on the instance.
    if (eq(u8, name, "Script")) {
        if (this_val != .object) return self.throwError("TypeError", "Class constructor Script cannot be invoked without 'new'");
        const code = try codeArg(self, if (args.len > 0) args[0] else .undefined);
        if (code.isAbrupt()) return code;
        // Validate the source up front (Node compiles in the constructor → a SyntaxError throws here).
        if (try parseError(self, code.normal.string)) |err| return err;
        try this_val.object.defineData("%code%", code.normal, false, false, true);
        return .{ .normal = this_val };
    }

    // Script.prototype methods read the stored code off the receiver.
    if (eq(u8, name, "runInThisContext") and isScript(this_val)) {
        const code = scriptCode(this_val) orelse return self.throwError("TypeError", "Script method called on a non-Script");
        return runInThisContext(self, code);
    }
    if (eq(u8, name, "runInContext") and isScript(this_val)) {
        const code = scriptCode(this_val) orelse return self.throwError("TypeError", "Script method called on a non-Script");
        const ctx = if (args.len > 0) args[0] else .undefined;
        return runInContext(self, code, ctx);
    }
    if (eq(u8, name, "runInNewContext") and isScript(this_val)) {
        const code = scriptCode(this_val) orelse return self.throwError("TypeError", "Script method called on a non-Script");
        const sandbox = if (args.len > 0) args[0] else .undefined;
        return runInNewContext(self, code, sandbox);
    }

    // Module-level functions.
    if (eq(u8, name, "runInThisContext")) {
        const code = try codeArg(self, if (args.len > 0) args[0] else .undefined);
        if (code.isAbrupt()) return code;
        return runInThisContext(self, code.normal.string);
    }
    if (eq(u8, name, "runInNewContext")) {
        const code = try codeArg(self, if (args.len > 0) args[0] else .undefined);
        if (code.isAbrupt()) return code;
        const sandbox = if (args.len > 1) args[1] else .undefined;
        return runInNewContext(self, code.normal.string, sandbox);
    }
    if (eq(u8, name, "runInContext")) {
        const code = try codeArg(self, if (args.len > 0) args[0] else .undefined);
        if (code.isAbrupt()) return code;
        const ctx = if (args.len > 1) args[1] else .undefined;
        return runInContext(self, code.normal.string, ctx);
    }
    if (eq(u8, name, "createContext")) {
        const sandbox = if (args.len > 0) args[0] else .undefined;
        return createContext(self, sandbox);
    }
    if (eq(u8, name, "isContext")) {
        const v = if (args.len > 0) args[0] else .undefined;
        const ok = v == .object and v.object.get("%vmcontext%") != null;
        return .{ .normal = .{ .boolean = ok } };
    }
    if (eq(u8, name, "compileFunction")) {
        return compileFunction(self, args);
    }
    return .{ .normal = .undefined };
}

// ── Script instance helpers ──────────────────────────────────────────────────

fn isScript(v: Value) bool {
    return v == .object and v.object.get("%code%") != null;
}

fn scriptCode(v: Value) ?[]const u8 {
    if (v != .object) return null;
    const c = v.object.get("%code%") orelse return null;
    return if (c == .string) c.string else null;
}

// ── argument coercion ────────────────────────────────────────────────────────

/// Coerce the `code` argument to a string (Node ToString-coerces a non-string source).
fn codeArg(self: *Interpreter, v: Value) EvalError!Completion {
    return self.toStringValuePub(v);
}

/// Parse `source` as a Script; return an abrupt SyntaxError completion if it fails to parse, else
/// null. Used to surface a compile-time SyntaxError eagerly (e.g. in the `Script` constructor).
fn parseError(self: *Interpreter, source: []const u8) EvalError!?Completion {
    _ = Parser.parseMode(self.arena, source, false) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return try self.throwError("SyntaxError", "vm: invalid source"),
    };
    return null;
}

// ════════════════════════════════════════════════════════════════════════════
//  runInThisContext — indirect eval in the current realm
// ════════════════════════════════════════════════════════════════════════════

/// Run `code` in the CURRENT realm (like indirect eval): parse + run against the global env. The
/// completion value is the last statement's value. A parse error throws a real SyntaxError; a runtime
/// throw propagates.
fn runInThisContext(self: *Interpreter, code: []const u8) EvalError!Completion {
    const genv = self.globals orelse return self.throwError("Error", "vm: no realm");
    // Indirect eval semantics: not direct, not inheriting the caller's strictness.
    const saved_this = self.this_val;
    const saved_home = self.home_object;
    defer {
        self.this_val = saved_this;
        self.home_object = saved_home;
    }
    self.this_val = if (genv.lookup("%GlobalThis%")) |b| b.value else .undefined;
    self.home_object = null;
    return interp_eval.performEval(self, code, genv, false, false);
}

// ════════════════════════════════════════════════════════════════════════════
//  fresh-realm contexts — createContext / runInNewContext / runInContext
// ════════════════════════════════════════════════════════════════════════════

/// Build a fresh realm Environment (a new global scope with its own intrinsics). Mirrors the realm
/// setup in `engine.zig` (`Environment.create` + `builtins.setup`).
fn freshRealm(self: *Interpreter) EvalError!*Environment {
    const genv = Environment.create(self.arena, null) catch return error.OutOfMemory;
    builtins.setup(self.arena, genv) catch return error.OutOfMemory;
    return genv;
}

/// Seed the sandbox object's own enumerable data properties as global bindings of `genv` (and onto
/// its reified global object), so `runInNewContext('x', { x: 1 })` sees `x`.
fn seedSandbox(self: *Interpreter, genv: *Environment, sandbox: Value) EvalError!void {
    _ = self;
    if (sandbox != .object) return;
    const src = sandbox.object;
    const gobj: ?*Object = if (genv.lookup("%GlobalThis%")) |b| (if (b.value == .object) b.value.object else null) else null;
    var it = src.properties.iterator();
    while (it.next()) |entry| {
        const pv = entry.value_ptr.*;
        if (!pv.enumerable) continue;
        if (pv.payload != .data) continue;
        const key = entry.key_ptr.*;
        if (std.mem.startsWith(u8, key, "%")) continue; // skip hidden engine slots
        // Declare (or update) the global binding.
        if (genv.lookupLocal(key)) |b| {
            b.value = pv.payload.data;
        } else {
            try genv.declare(key, pv.payload.data, true, true);
        }
        if (gobj) |g| try g.defineData(key, pv.payload.data, true, true, true);
    }
}

/// After running code in `genv`, copy any global bindings whose key is NOT a default intrinsic back
/// onto the sandbox object (Node's contextified-object writeback — approximated). We copy the reified
/// global object's own enumerable data props that aren't engine-internal intrinsics.
fn writebackSandbox(self: *Interpreter, genv: *Environment, sandbox: Value) EvalError!void {
    if (sandbox != .object) return;
    _ = self;
    const dst = sandbox.object;
    const gobj: ?*Object = if (genv.lookup("%GlobalThis%")) |b| (if (b.value == .object) b.value.object else null) else null;
    const g = gobj orelse return;
    var it = g.properties.iterator();
    while (it.next()) |entry| {
        const pv = entry.value_ptr.*;
        if (!pv.enumerable) continue;
        if (pv.payload != .data) continue;
        const key = entry.key_ptr.*;
        if (std.mem.startsWith(u8, key, "%")) continue;
        if (isIntrinsicGlobal(key)) continue; // don't clobber the sandbox with engine intrinsics
        try dst.defineData(key, pv.payload.data, true, true, true);
    }
}

/// Whether `name` is one of the realm's default global intrinsics (so writeback skips it — only
/// user-introduced globals flow back to the sandbox). A coarse allowlist of the common builtins.
fn isIntrinsicGlobal(name: []const u8) bool {
    const intrinsics = [_][]const u8{
        "globalThis",           "undefined",          "NaN",               "Infinity",
        "Object",               "Function",           "Array",             "String",
        "Boolean",              "Number",             "BigInt",            "Symbol",
        "Math",                 "JSON",               "Date",              "RegExp",
        "Error",                "TypeError",          "RangeError",        "ReferenceError",
        "SyntaxError",          "EvalError",          "URIError",          "AggregateError",
        "Promise",              "Proxy",              "Reflect",           "Map",
        "Set",                  "WeakMap",            "WeakSet",           "WeakRef",
        "FinalizationRegistry", "ArrayBuffer",        "SharedArrayBuffer", "DataView",
        "Int8Array",            "Uint8Array",         "Uint8ClampedArray", "Int16Array",
        "Uint16Array",          "Int32Array",         "Uint32Array",       "Float16Array",
        "Float32Array",         "Float64Array",       "BigInt64Array",     "BigUint64Array",
        "Atomics",              "parseInt",           "parseFloat",        "isNaN",
        "isFinite",             "eval",               "encodeURI",         "decodeURI",
        "encodeURIComponent",   "decodeURIComponent", "escape",            "unescape",
    };
    for (intrinsics) |i| if (std.mem.eql(u8, name, i)) return true;
    return false;
}

/// `vm.createContext(sandbox)` — mark `sandbox` as a contextified object (so `isContext` returns
/// true). Returns the sandbox (or a fresh object when called with no/undefined sandbox).
fn createContext(self: *Interpreter, sandbox: Value) EvalError!Completion {
    const arena = self.arena;
    const ctx_obj: *Object = if (sandbox == .object) sandbox.object else try Object.create(arena, self.objectProto());
    try ctx_obj.defineData("%vmcontext%", .{ .boolean = true }, false, false, true);
    return .{ .normal = .{ .object = ctx_obj } };
}

/// `vm.runInNewContext(code[, sandbox])` — fresh realm seeded from `sandbox`, run `code`, write back
/// new globals onto `sandbox`. Returns the completion value.
fn runInNewContext(self: *Interpreter, code: []const u8, sandbox: Value) EvalError!Completion {
    const genv = try freshRealm(self);
    try seedSandbox(self, genv, sandbox);
    const c = try runInRealm(self, code, genv);
    if (c.isAbrupt()) return c;
    try writebackSandbox(self, genv, sandbox);
    return c;
}

/// `vm.runInContext(code, contextifiedSandbox)` — run `code` in the realm associated with the
/// contextified `sandbox`. First-cut: each call builds a fresh realm seeded from the sandbox, runs,
/// and writes back (sufficient for the assertions in the corpus).
fn runInContext(self: *Interpreter, code: []const u8, ctx: Value) EvalError!Completion {
    if (ctx != .object or ctx.object.get("%vmcontext%") == null)
        return self.throwError("TypeError", "The \"contextifiedObject\" argument must be a vm.Context");
    return runInNewContext(self, code, ctx);
}

/// Parse + run `code` in `genv` (a fresh realm) — temporarily swap the active realm so `this` /
/// global lookups resolve against `genv`, then restore. The step/depth counters carry through
/// (runaway code still terminates). A parse error throws a real SyntaxError.
fn runInRealm(self: *Interpreter, code: []const u8, genv: *Environment) EvalError!Completion {
    const program = Parser.parseMode(self.arena, code, false) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return self.throwError("SyntaxError", "vm: invalid source"),
    };
    const saved_globals = self.globals;
    const saved_this = self.this_val;
    const saved_home = self.home_object;
    defer {
        self.globals = saved_globals;
        self.this_val = saved_this;
        self.home_object = saved_home;
    }
    self.globals = genv;
    self.this_val = if (genv.lookup("%GlobalThis%")) |b| b.value else .undefined;
    self.home_object = null;
    return self.run(program, genv);
}

// ════════════════════════════════════════════════════════════════════════════
//  compileFunction
// ════════════════════════════════════════════════════════════════════════════

/// `vm.compileFunction(code[, params[, options]])` — wrap `code` as a function body with `params`,
/// run the wrapper expression in the current realm, and return the resulting function object (the
/// CommonJS-wrapper trick). A parse error throws a real SyntaxError.
fn compileFunction(self: *Interpreter, args: []const Value) EvalError!Completion {
    const arena = self.arena;
    const code_c = try codeArg(self, if (args.len > 0) args[0] else .undefined);
    if (code_c.isAbrupt()) return code_c;
    const code = code_c.normal.string;

    // params: an optional array of parameter-name strings.
    var params: std.ArrayListUnmanaged(u8) = .empty;
    if (args.len > 1 and args[1] == .object) {
        const arr = args[1].object;
        const len = arr.arrayLen();
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const pv = arr.arrayGet(i);
            const sc = try self.toStringValuePub(pv);
            if (sc.isAbrupt()) return sc;
            if (i > 0) try params.appendSlice(arena, ",");
            try params.appendSlice(arena, sc.normal.string);
        }
    }

    const wrapped = std.fmt.allocPrint(arena, "(function ({s}) {{\n{s}\n}})", .{ params.items, code }) catch return error.OutOfMemory;
    const program = Parser.parseMode(arena, wrapped, false) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return self.throwError("SyntaxError", "vm: invalid source"),
    };
    const genv = self.globals orelse return self.throwError("Error", "vm: no realm");
    const c = try self.run(program, genv);
    if (c.isAbrupt()) return c;
    if (c.normal != .object) return self.throwError("Error", "vm.compileFunction: did not produce a function");
    return .{ .normal = c.normal };
}
