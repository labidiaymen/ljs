//! Extracted from interpreter.zig (behavior-preserving split). Free functions taking
//! `self: *Interpreter`; thin wrappers remain on the struct for cross-module/native call sites.
const std = @import("std");
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const Environment = @import("environment.zig").Environment;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const ops = @import("abstract_ops.zig");
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const interp_stmt = @import("interp_stmt.zig");
const interp_destr = @import("interp_destr.zig");
const interp_native = @import("interp_native.zig");

const toBoolean = ops.toBoolean;

// Shared free helpers + named types (defined in interpreter.zig), aliased for natural call sites.
const isCallable = interpreter.isCallable;
const handlerArg = interpreter.handlerArg;
const blockHasUsing = interpreter.blockHasUsing;
const Resumption = Interpreter.Resumption;
const IterStep = Interpreter.IterStep;
const CallStepResult = Interpreter.CallStepResult;
const CombinatorKind = Interpreter.CombinatorKind;

/// §15.5.4 / §27.5.2 generator-function [[Call]] — instead of running the body, create and return a
/// Generator object in `suspended_start`. The args / this / home are captured now; the body binds
/// and runs them on its own thread when first resumed (`.next`).
pub fn createGenerator(self: *Interpreter, func: *Object, args: []const Value, this_val: Value) EvalError!Completion {
    const gen = try self.arena.create(object_mod.Generator);
    // Copy the args into the arena (the caller's `args` slice may be transient).
    const args_copy = try self.arena.dupe(Value, args);
    gen.* = .{
        .func = func,
        .args = args_copy,
        .this_val = this_val,
        .home_object = if (func.call) |fd| fd.home_object else null,
        .private_env = if (func.call) |fd| fd.private_env else null,
    };
    // §15.5.2 EvaluateGeneratorBody step 1: FunctionDeclarationInstantiation runs EAGERLY here (on
    // the caller thread), so a param destructuring/default error throws at the call site, before
    // the generator object is created/returned and before any `.next`.
    var abrupt: ?Completion = null;
    gen.call_env = try instantiateGeneratorParams(self, gen, &abrupt);
    if (abrupt) |c| return c;
    if (self.gen_registry) |reg| try reg.append(self.arena, gen);
    // §27.5.1.1 OrdinaryCreateFromConstructor(func, "%GeneratorPrototype%"): the new generator's
    // [[Prototype]] is `Get(func, "prototype")` when that is an object, else the realm
    // %GeneratorPrototype% intrinsic (so `Object.getPrototypeOf(g()) === g.prototype`).
    const inst_proto: ?*Object = blk: {
        if (func.get("prototype")) |pv| if (pv == .object) break :blk pv.object;
        break :blk generatorProto(self);
    };
    const obj = try Object.create(self.arena, inst_proto);
    obj.generator = gen;
    return .{ .normal = .{ .object = obj } };
}

/// §27.5.1.2/.4/.5 %GeneratorPrototype%.next/return/throw — resume the generator with the given
/// completion kind and value, producing the next IteratorResult `{ value, done }` (or re-throwing
/// on a throw completion that escapes the body). Runs on the CALLER thread.
pub fn generatorResume(self: *Interpreter, this_val: Value, kind: object_mod.ResumeKind, value: Value) EvalError!Completion {
    if (this_val != .object or this_val.object.generator == null) {
        return self.throwError("TypeError", "Generator method called on a non-generator");
    }
    const gen = this_val.object.generator.?;

    // §27.5.3.3 step 2 / GeneratorValidate: a generator already executing cannot be re-entered.
    if (gen.state == .executing) return self.throwError("TypeError", "Generator is already running");

    // §27.5.1.2/.4/.5 on a COMPLETED generator: `.next` → {undefined, done:true}; `.return(v)` →
    // {v, done:true}; `.throw(e)` → re-throw e.
    if (gen.state == .completed) {
        return switch (kind) {
            .next => iterResult(self, .undefined, true),
            .ret => iterResult(self, value, true),
            .throw => .{ .throw = value },
        };
    }

    // §27.5.1.4/.5 on a SUSPENDED-START generator (the body never ran): `.return(v)`/`.throw(e)`
    // complete it immediately WITHOUT running the body. `.next` spawns the body thread.
    if (gen.state == .suspended_start) {
        if (kind == .ret) {
            gen.state = .completed;
            return iterResult(self, value, true);
        }
        if (kind == .throw) {
            gen.state = .completed;
            return .{ .throw = value };
        }
        // `.next` (start): spawn the body thread; it runs to the first suspension and posts.
        gen.state = .executing;
        gen.sent_value = value;
        gen.resume_kind = .next;
        const t = std.Thread.spawn(.{}, generatorBodyThread, .{ self, gen }) catch {
            gen.state = .completed;
            return self.throwError("RangeError", "Cannot spawn generator thread");
        };
        gen.thread = t;
        gen.to_caller.waitUncancelable(self.io); // wait for the first yield/return/throw
        return collectTransfer(self, gen);
    }

    // §27.5.3.3/.4 SUSPENDED-YIELD: hand the resume kind + value to the parked `yield`, run.
    gen.state = .executing;
    gen.sent_value = value;
    gen.resume_kind = kind;
    gen.resume_gen.post(self.io); // wake the parked yield
    gen.to_caller.waitUncancelable(self.io); // wait for the next yield/return/throw
    return collectTransfer(self, gen);
}

/// Read the gen→caller transfer slot after a handoff and turn it into the caller-side completion:
/// a `yield` → `{ value, done:false }`; a `return` → `{ value, done:true }` (+ join the finished
/// thread); a `throw` → re-throw in the caller (+ join). Marks `completed` on return/throw.
pub fn collectTransfer(self: *Interpreter, gen: *object_mod.Generator) EvalError!Completion {
    switch (gen.transfer_kind) {
        .yield => {
            gen.state = .suspended_yield;
            return iterResult(self, gen.transfer_value, false);
        },
        .ret => {
            gen.state = .completed;
            if (gen.thread) |t| {
                t.join();
                gen.thread = null;
            }
            return iterResult(self, gen.transfer_value, true);
        },
        .throw => {
            gen.state = .completed;
            if (gen.thread) |t| {
                t.join();
                gen.thread = null;
            }
            return .{ .throw = gen.transfer_value };
        },
    }
}

/// The body-thread entry point (§27.5.3.3 step 4 — run the FunctionBody). Builds a fresh per-
/// generator Interpreter that SHARES the arena + globals (safe: only one thread runs at a time)
/// with `current_gen` set so `yield` reaches the handoff, binds params/this, runs the body, and
/// posts the terminal completion (return/throw) to the caller. Never returns a Zig error to the
/// thread runtime — engine errors (OOM / step-limit) are surfaced as a thrown completion.
pub fn generatorBodyThread(parent: *Interpreter, gen: *object_mod.Generator) void {
    var body: Interpreter = .{
        .arena = parent.arena,
        .step_limit = parent.step_limit,
        .globals = parent.globals,
        .gen_registry = parent.gen_registry,
        .job_queue = parent.job_queue,
        .io = parent.io,
        .current_gen = gen,
        // §13.3.10 a generator/async-generator body may `yield import(...)` / `await import(...)`.
        .module_loader = parent.module_loader,
        .module_cache = parent.module_cache,
        .host_referrer_key = parent.host_referrer_key,
        .async_done = parent.async_done,
    };
    const comp = body.runGeneratorBody(gen) catch |e| blk: {
        // §27.5.3.3: an engine error (step-limit / OOM) on the body thread completes the generator
        // with a thrown completion (best-effort — surface it to the caller rather than crash).
        const kind: []const u8 = if (e == error.StepLimitExceeded) "RangeError" else "Error";
        const msg: []const u8 = if (e == error.StepLimitExceeded) "step limit exceeded" else "out of memory";
        const tc = body.throwError(kind, msg) catch break :blk Completion{ .throw = .undefined };
        break :blk tc;
    };
    // Translate the body completion into the terminal transfer (return / throw).
    switch (comp) {
        .normal => |v| {
            gen.transfer_value = v;
            gen.transfer_kind = .ret;
        },
        .ret => |v| {
            gen.transfer_value = v;
            gen.transfer_kind = .ret;
        },
        .throw => |v| {
            gen.transfer_value = v;
            gen.transfer_kind = .throw;
        },
        .brk, .cont => {
            // Not producible by a well-formed body (loops consume them); treat as a plain finish.
            gen.transfer_value = .undefined;
            gen.transfer_kind = .ret;
        },
    }
    gen.to_caller.post(body.io);
}

/// Bind the generator's params/this/home and run its body, honoring a `.return`/`.throw` injected
/// at the very start (`suspended_start` + abrupt resume is handled by the caller, so here the first
/// resume is always `.next`). Mirrors the ordinary [[Call]] body setup.
/// §9.2.6 FunctionDeclarationInstantiation for a generator/async-generator body — bind the params
/// (incl. destructuring patterns + default-value expressions) and the `arguments` object into a
/// fresh environment, returning it. Per §15.5.2 EvaluateGeneratorBody / §15.6.2
/// EvaluateAsyncGeneratorBody this runs EAGERLY when the generator object is created (on the caller
/// thread), so a destructuring/default error surfaces at the call site rather than at first `.next`.
/// An abrupt completion (a thrown default/pattern error) is returned via the `Completion` out-param.
pub fn instantiateGeneratorParams(self: *Interpreter, gen: *object_mod.Generator, abrupt: *?Completion) EvalError!*Environment {
    abrupt.* = null;
    const fd = gen.func.call.?;
    const args = gen.args;
    const call_env = try Environment.create(self.arena, fd.closure);
    call_env.is_var_scope = true; // §10.2.11: a generator/async FunctionBody is a VariableEnvironment
    // §10.2.11 step 19/22: the `arguments` exotic is created and bound BEFORE parameter
    // initialization, so a default-parameter initializer (`g(x = arguments[0])`) sees it. It is
    // suppressed only when a PARAMETER is literally named `arguments` (§10.2.11 step 17.a — that
    // binding shadows). Arrows inherit `arguments` lexically (handled at call sites, not here).
    if (!paramsBindName(fd, "arguments")) {
        const ao = try interp_native.makeArgumentsObject(self, args, gen.func, call_env, fd);
        try call_env.declare("arguments", .{ .object = ao }, true, true);
    }
    // §19.2.1.3 step 3.d: mark the formal-parameter-evaluation window so a direct eval that
    // `var`/function-declares `arguments` throws a SyntaxError (the parameter env's `arguments`
    // binding, created above, sits between the eval's lexEnv and the body var scope). A generator /
    // async-generator is never an arrow, so the parameter env always holds `arguments` here.
    // Saved/restored; cleared once parameter evaluation completes so a body `var arguments` is legal.
    const saved_in_param_init = self.in_param_init;
    self.in_param_init = true;
    defer self.in_param_init = saved_in_param_init;
    for (fd.params, 0..) |param, i| {
        var v: Value = if (i < args.len) args[i] else .undefined;
        var defaulted = false;
        if (v == .undefined) {
            if (param.default) |dn| {
                const dc = try self.evalExpr(dn, call_env);
                if (dc.isAbrupt()) {
                    abrupt.* = dc;
                    return call_env;
                }
                v = dc.normal;
                defaulted = true;
            }
        }
        if (param.pattern.* == .identifier) {
            // §15.1.3: name an anonymous fn/class default initializer on a SingleNameBinding.
            if (defaulted) try self.maybeSetAnonName(param.default.?, v, param.pattern.identifier);
            try call_env.declare(param.pattern.identifier, v, true, true);
        } else {
            const bc = try interp_destr.bindPattern(self, param.pattern, v, call_env, true);
            if (bc.isAbrupt()) {
                abrupt.* = bc;
                return call_env;
            }
        }
    }
    if (fd.rest) |rest_pat| {
        const rest_arr = try Object.createArray(self.arena, self.arrayProto());
        if (args.len > fd.params.len) {
            for (args[fd.params.len..]) |a| try rest_arr.elements.append(self.arena, a);
        }
        if (rest_pat.* == .identifier) {
            try call_env.declare(rest_pat.identifier, .{ .object = rest_arr }, true, true);
        } else {
            const bc = try interp_destr.bindPattern(self, rest_pat, .{ .object = rest_arr }, call_env, true);
            if (bc.isAbrupt()) {
                abrupt.* = bc;
                return call_env;
            }
        }
    }
    self.in_param_init = false; // parameter evaluation complete — body evals are no longer param-init
    return call_env;
}

/// §10.2.11: does the function's BoundNames of FormalParameters contain `name`? Used to suppress
/// the implicit `arguments` exotic when a parameter literally binds `arguments`. Covers the simple
/// `SingleNameBinding` and rest-identifier forms (a destructuring pattern binding the name is a
/// vanishingly rare edge not exercised by the conformance corpus).
pub fn paramsBindName(fd: object_mod.FunctionData, name: []const u8) bool {
    for (fd.params) |param| {
        if (param.pattern.* == .identifier and std.mem.eql(u8, param.pattern.identifier, name)) return true;
    }
    if (fd.rest) |rest_pat| {
        if (rest_pat.* == .identifier and std.mem.eql(u8, rest_pat.identifier, name)) return true;
    }
    return false;
}

pub fn runGeneratorBody(self: *Interpreter, gen: *object_mod.Generator) EvalError!Completion {
    // §16.2.1.6 ExecuteAsyncModule: a top-level-await module body has no function object — run the
    // module's top-level StatementList in its (already linked + hoisted) Module Environment Record,
    // strict, with `this` = undefined. `await` suspends via the shared async handoff; the terminal
    // completion settles the module's promise (see runModuleAsync).
    if (gen.module_run) |mr| {
        self.this_val = .undefined;
        self.home_object = null;
        self.strict = true;
        var last: Completion = .{ .normal = .undefined };
        for (mr.statements) |stmt| {
            last = try self.evalStmt(stmt, mr.env);
            switch (last) {
                .normal => {},
                else => return last,
            }
        }
        return last;
    }
    const func = gen.func;
    const fd = func.call.?;
    // §15.5.2/§15.6.2: a sync/async GENERATOR's params were already bound on the caller thread
    // (`gen.call_env` set in createGenerator/createAsyncGenerator). An ASYNC FUNCTION binds them
    // here on the body thread (a param error rejects the promise — see callAsyncFunction).
    var abrupt: ?Completion = null;
    const call_env = gen.call_env orelse try instantiateGeneratorParams(self, gen, &abrupt);
    if (abrupt) |c| return c;
    self.this_val = gen.this_val;
    self.home_object = gen.home_object;
    self.private_env = gen.private_env; // §9.2 restore [[PrivateEnvironment]] for `this.#x` in the body
    self.func_depth += 1; // §13.3.12: the body is a function context (a nested direct eval may use `new.target`)
    // §11.2.2: the generator/async body runs in its own strict context (this fresh body interpreter
    // started sloppy). A strict body's §6.2.5.6 PutValue to an unresolved name must throw.
    self.strict = fd.strict;
    // §10.2.11 (lexical step): hoist the body's top-level `let`/`const`/`class` names as TDZ bindings.
    try self.hoistLexicalNames(fd.body, call_env);
    // §10.2.11 (var step): instantiate VarDeclaredNames in the body VariableEnvironment.
    try self.hoistVarNames(fd.body, call_env);
    // §ER: a GeneratorBody / AsyncFunctionBody / AsyncGeneratorBody lexically containing a
    // `using`/`await using` disposes its resources on body exit (return OR throw). Gated on
    // `blockHasUsing` so an ordinary body pays nothing.
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
            .ret => |v| return .{ .normal = v },
            .throw => return c,
            .brk, .cont => {},
        }
    }
    return .{ .normal = .undefined };
}

/// §27.5.3.7 GeneratorYield core — the body-thread side of the handoff. Posts the yielded value to
/// the caller, parks on `resume_gen`, and reports back HOW the consumer resumed (`.next`/`.return`/
/// `.throw` + the carried value). Callers translate that into a body completion (plain `yield`) or
/// forward it to an inner iterator (`yield*`). Only ever runs on a body thread (`current_gen` set).
pub fn doYieldRaw(self: *Interpreter, value: Value) Resumption {
    const gen = self.current_gen.?;
    // Abandonment (realm teardown): once signaled, every further `yield` immediately unwinds the
    // body with a return completion (without parking), so a `yield` reached inside a `finally`
    // during the unwind cannot re-park and deadlock the joining thread.
    if (gen.abandon) return .{ .kind = .ret, .value = .undefined, .abandon = true };
    gen.transfer_value = value;
    gen.transfer_kind = .yield;
    gen.to_caller.post(self.io); // hand control to the caller
    gen.resume_gen.waitUncancelable(self.io); // park until the next .next/.return/.throw
    if (gen.abandon) return .{ .kind = .ret, .value = .undefined, .abandon = true }; // woken by cleanup
    return .{ .kind = gen.resume_kind, .value = gen.sent_value, .abandon = false };
}

/// §14.4.14 the `yield x` runtime — perform one handoff and translate the resumption into a body
/// completion: a normal `.next(v)` makes the yield expression evaluate to `v`; an injected
/// `.throw(e)` re-throws at the yield; an injected `.return(v)` returns (so the body's `finally`
/// blocks run during unwind).
pub fn doYield(self: *Interpreter, value: Value) EvalError!Completion {
    const r = doYieldRaw(self, value);
    // §27.5.3.3/.4 the resume kind decides what the yield expression "evaluates to".
    return switch (r.kind) {
        .next => .{ .normal = r.value }, // yield evaluates to the sent value
        .throw => .{ .throw = r.value }, // §27.5.3.4 inject a throw at the yield
        .ret => .{ .ret = r.value }, // §27.5.3.4 inject a return (runs finally blocks)
    };
}

/// §14.4.14 / §15.5.5 `yield* expr` delegation — drive the iterator of `expr`, forwarding each
/// `.next`/`.return`/`.throw` the OUTER consumer sends to the inner iterator and re-yielding the
/// inner's values to the outer consumer. When the inner iterator is done, the whole `yield*`
/// expression evaluates to that final `value`. Runs on the generator body thread.
///   • outer `.next(v)`  → inner `next(v)`; `{done:false}` re-yields, `{done:true}` finishes yield*.
///   • outer `.throw(e)` → inner `throw(e)` if present (§14.4.14 step 7); else IteratorClose + a
///     TypeError thrown into the body (the inner has no throw handler).
///   • outer `.return(v)`→ inner `return(v)` if present (§14.4.14 step 8); a `{done:true}` inner
///     result returns that value from the body; absent `return` → return `v` directly.
pub fn doYieldDelegate(self: *Interpreter, source: Value) EvalError!Completion {
    const git = try self.getIterator(source);
    const iterator: *Object = switch (git) {
        .abrupt => |c| return c,
        .iterator => |it| it,
    };
    // §14.4.14 step 5: the first inner call is `next(undefined)`; thereafter the value forwarded
    // is whatever the outer consumer sent. `received` carries the resume kind + value each round.
    var received: Resumption = .{ .kind = .next, .value = .undefined, .abandon = false };
    while (true) {
        switch (received.kind) {
            // §14.4.14 step 7.a.i: forward a normal resume to the inner iterator's `next`.
            .next => {
                const res = try iteratorCall(self, iterator, "next", received.value, true);
                switch (res) {
                    .abrupt => |c| return c,
                    .result => |r| {
                        if (r.done) return .{ .normal = r.value }; // §14.4.14 step 7.a.ii: yield* value
                        received = doYieldRaw(self, r.value); // re-yield; capture the next resumption
                        if (received.abandon) return .{ .ret = .undefined };
                    },
                }
            },
            // §14.4.14 step 7.b: an outer `.throw(e)` forwards to the inner iterator's `throw`.
            .throw => {
                const tm = try self.getProperty(.{ .object = iterator }, "throw");
                if (tm.isAbrupt()) return tm;
                if (tm.normal == .object and tm.normal.object.kind == .function) {
                    const rc = try self.callFunction(tm.normal.object, &.{received.value}, .{ .object = iterator });
                    if (rc.isAbrupt()) return rc;
                    const r = try iterResultFromValue(self, rc.normal);
                    switch (r) {
                        .abrupt => |c| return c,
                        .result => |ir| {
                            if (ir.done) return .{ .normal = ir.value }; // §14.4.14 step 7.b.iii
                            received = doYieldRaw(self, ir.value);
                            if (received.abandon) return .{ .ret = .undefined };
                        },
                    }
                } else {
                    // §14.4.14 step 7.b.iii: the inner iterator has no `throw` — close it and throw a
                    // TypeError into the body (so a `try`/`catch` around the `yield*` can observe it).
                    try self.iteratorClose(iterator);
                    return self.throwError("TypeError", "The iterator does not provide a throw method");
                }
            },
            // §14.4.14 step 8: an outer `.return(v)` forwards to the inner iterator's `return`.
            .ret => {
                const rm = try self.getProperty(.{ .object = iterator }, "return");
                if (rm.isAbrupt()) return rm;
                // §14.4.14 step 8.b: a missing `return` → return the value directly (unwind the body).
                if (rm.normal != .object or rm.normal.object.kind != .function) return .{ .ret = received.value };
                const rc = try self.callFunction(rm.normal.object, &.{received.value}, .{ .object = iterator });
                if (rc.isAbrupt()) return rc;
                const r = try iterResultFromValue(self, rc.normal);
                switch (r) {
                    .abrupt => |c| return c,
                    .result => |ir| {
                        // §14.4.14 step 8.d.iii: a done inner `return` result completes the body with
                        // that value; otherwise re-yield and keep delegating.
                        if (ir.done) return .{ .ret = ir.value };
                        received = doYieldRaw(self, ir.value);
                        if (received.abandon) return .{ .ret = .undefined };
                    },
                }
            },
        }
    }
}

/// Call `iterator[method](arg)` and decode the IteratorResult into `{ value, done }`. `pass_arg`
/// false calls with no argument (parameterless `next()`); true forwards `arg`. A non-object result
/// is a §7.4.4 TypeError. Used by `yield*` to drive the inner iterator's next/throw/return.
pub fn iteratorCall(self: *Interpreter, iterator: *Object, method: []const u8, arg: Value, pass_arg: bool) EvalError!CallStepResult {
    const mc = try self.getProperty(.{ .object = iterator }, method);
    if (mc.isAbrupt()) return .{ .abrupt = mc };
    if (mc.normal != .object or mc.normal.object.kind != .function) {
        return .{ .abrupt = try self.throwError("TypeError", "iterator method is not a function") };
    }
    const args: []const Value = if (pass_arg) &.{arg} else &.{};
    const rc = try self.callFunction(mc.normal.object, args, .{ .object = iterator });
    if (rc.isAbrupt()) return .{ .abrupt = rc };
    return iterResultFromValue(self, rc.normal);
}

/// Call `iterator[method](arg)` and return its RAW result value (no IteratorResult decode). Used by
/// `for await` (the result is a promise to be awaited before decoding) and by async `yield*`. A
/// missing/non-callable method → TypeError. `pass_arg` false calls with no argument.
pub fn iteratorCallRaw(self: *Interpreter, iterator: *Object, method: []const u8, arg: Value, pass_arg: bool) EvalError!Completion {
    const mc = try self.getProperty(.{ .object = iterator }, method);
    if (mc.isAbrupt()) return mc;
    if (mc.normal != .object or mc.normal.object.kind != .function) {
        return self.throwError("TypeError", "iterator method is not a function");
    }
    const args: []const Value = if (pass_arg) &.{arg} else &.{};
    return self.callFunction(mc.normal.object, args, .{ .object = iterator });
}

/// Decode an IteratorResult object into `{ value, done }` (§7.4.4 / §7.4.5). A non-object → TypeError.
pub fn iterResultFromValue(self: *Interpreter, result: Value) EvalError!CallStepResult {
    if (result != .object) {
        return .{ .abrupt = try self.throwError("TypeError", "Iterator result is not an object") };
    }
    const obj = result.object;
    const dc = try self.getProperty(.{ .object = obj }, "done");
    if (dc.isAbrupt()) return .{ .abrupt = dc };
    const vc = try self.getProperty(.{ .object = obj }, "value");
    if (vc.isAbrupt()) return .{ .abrupt = vc };
    return .{ .result = .{ .value = vc.normal, .done = toBoolean(dc.normal) } };
}

/// Construct an IteratorResult `{ value, done }` object (§7.4.1 CreateIterResultObject), proto =
/// %Object.prototype%. Used to package generator `.next`/`.return` results.
pub fn iterResult(self: *Interpreter, value: Value, done: bool) EvalError!Completion {
    const obj = try Object.create(self.arena, self.objectProto());
    try obj.set("value", value);
    try obj.set("done", .{ .boolean = done });
    return .{ .normal = .{ .object = obj } };
}

/// Realm teardown: any generator left suspended (never fully consumed) has a body thread parked on
/// `resume_gen`. Signal each to abandon and resume it so the thread unwinds and we can join it —
/// otherwise the OS thread would linger past the realm. Best-effort (a body that ignores `abandon`
/// would still be joined once it next yields/completes). Runs on the MAIN interpreter at end-of-run.
pub fn cleanupGenerators(self: *Interpreter) void {
    const reg = self.gen_registry orelse return;
    for (reg.items) |gen| {
        if (gen.thread) |t| {
            if (gen.state == .suspended_yield or gen.state == .suspended_start) {
                // Signal abandonment and wake the parked body; it unwinds (its next yield returns a
                // return-completion that finishes the body) and posts to_caller, then we join.
                gen.abandon = true;
                gen.resume_kind = .ret;
                gen.sent_value = .undefined;
                gen.resume_gen.post(self.io);
                gen.to_caller.waitUncancelable(self.io);
            }
            t.join();
            gen.thread = null;
            gen.state = .completed;
        }
    }
}

/// %PromisePrototype% — the [[Prototype]] of every Promise object. Stashed under a sentinel global
/// name by `builtins.setup` (like %GeneratorPrototype%). Null only in a realm-less unit eval.
pub fn promiseProto(self: *Interpreter) ?*Object {
    const g = self.globals orelse return null;
    const b = g.lookup("%PromisePrototype%") orelse return null;
    return if (b.value == .object) b.value.object else null;
}

/// §27.2.3.1 CreatePromise / NewPromiseCapability — a fresh pending Promise object (proto =
/// %PromisePrototype%) with empty reaction lists.
pub fn newPromise(self: *Interpreter) EvalError!*Object {
    const obj = try Object.create(self.arena, promiseProto(self));
    const pd = try self.arena.create(object_mod.PromiseData);
    pd.* = .{};
    obj.promise = pd;
    return obj;
}

/// §9.5 HostEnqueuePromiseJob — append a Job to the realm's microtask FIFO (drained when the stack
/// is empty). A realm-less eval (no `job_queue`) silently drops it (no promises reach here).
pub fn enqueueJob(self: *Interpreter, job: object_mod.Job) EvalError!void {
    const q = self.job_queue orelse return;
    try q.append(self.arena, job);
}

/// §27.2.1.4 FulfillPromise — transition a pending promise to fulfilled with `value` and schedule
/// its fulfill reactions as Jobs (then clear both reaction lists).
pub fn fulfillPromise(self: *Interpreter, promise: *Object, value: Value) EvalError!void {
    const pd = promise.promise.?;
    if (pd.state != .pending) return;
    pd.result = value;
    pd.state = .fulfilled;
    for (pd.fulfill_reactions.items) |reaction| {
        try enqueueJob(self, .{ .reaction = .{ .reaction = reaction, .argument = value } });
    }
    pd.fulfill_reactions.clearRetainingCapacity();
    pd.reject_reactions.clearRetainingCapacity();
}

/// §27.2.1.7 RejectPromise — transition a pending promise to rejected with `reason` and schedule
/// its reject reactions as Jobs.
pub fn rejectPromise(self: *Interpreter, promise: *Object, reason: Value) EvalError!void {
    const pd = promise.promise.?;
    if (pd.state != .pending) return;
    pd.result = reason;
    pd.state = .rejected;
    for (pd.reject_reactions.items) |reaction| {
        try enqueueJob(self, .{ .reaction = .{ .reaction = reaction, .argument = reason } });
    }
    pd.fulfill_reactions.clearRetainingCapacity();
    pd.reject_reactions.clearRetainingCapacity();
}

/// §27.2.1.3.2 the resolve function's behavior — resolve `promise` with `resolution`. If
/// `resolution` is the promise itself → reject with a TypeError (chaining cycle). If it is a
/// thenable (an object with a callable `then`) → enqueue a PromiseResolveThenableJob to adopt its
/// eventual state. Otherwise fulfill with the value. `already_resolved` guards single settlement.
pub fn resolvePromise(self: *Interpreter, promise: *Object, resolution: Value) EvalError!void {
    const pd = promise.promise.?;
    if (pd.already_resolved) return;
    pd.already_resolved = true;
    // §27.2.1.3.2 step 6: resolving a promise with itself is a TypeError rejection.
    if (resolution == .object and resolution.object == promise) {
        const tc = try self.throwError("TypeError", "Chaining cycle detected for promise");
        return rejectPromiseRaw(self, promise, tc.throw);
    }
    if (resolution != .object) return fulfillPromiseRaw(self, promise, resolution);
    // §27.2.1.3.2 step 8–9: read `resolution.then`; a throw there rejects the promise.
    const then_c = try self.getProperty(resolution, "then");
    if (then_c.isAbrupt()) return rejectPromiseRaw(self, promise, then_c.throw);
    const then_v = then_c.normal;
    if (then_v != .object or !isCallable(then_v.object)) {
        // §27.2.1.3.2 step 10: not a thenable → fulfill with the resolution value.
        return fulfillPromiseRaw(self, promise, resolution);
    }
    // §27.2.1.3.2 step 12: a thenable → adopt its state via a job (calls then(resolve, reject)).
    try enqueueJob(self, .{ .thenable = .{ .promise = promise, .thenable = resolution, .then_fn = then_v.object } });
}

/// Internal fulfill that bypasses the [[AlreadyResolved]] guard (used by `resolvePromise` after it
/// has claimed resolution). Identical to FulfillPromise.
pub fn fulfillPromiseRaw(self: *Interpreter, promise: *Object, value: Value) EvalError!void {
    return fulfillPromise(self, promise, value);
}

/// Internal reject that ALSO marks already_resolved (the resolve-function path must block a later
/// resolve). Mirrors §27.2.1.3.1 setting [[AlreadyResolved]] before rejecting.
pub fn rejectPromiseRaw(self: *Interpreter, promise: *Object, reason: Value) EvalError!void {
    promise.promise.?.already_resolved = true;
    return rejectPromise(self, promise, reason);
}

/// Build a resolve or reject function object (§27.2.1.3) bound to `promise` via `promise_slot`.
pub fn makeResolvingFunction(self: *Interpreter, promise: *Object, id: object_mod.NativeId) EvalError!*Object {
    const f = try Object.createNative(self.arena, id, "");
    f.prototype = self.functionProto();
    f.promise_slot = promise;
    return f;
}

/// §27.2.4.7 PromiseResolve(x) — if `x` is already a promise, return it; otherwise wrap it in a
/// fresh resolved promise. Used by `Promise.resolve` and by `await` (§27.7.5.3 step 2). (M-subset:
/// no subclass/species — every promise is a %Promise%, so the "is it already a promise" test is the
/// `.promise != null` slot check.)
pub fn promiseResolveValue(self: *Interpreter, x: Value) EvalError!*Object {
    if (x == .object and x.object.promise != null) return x.object;
    const p = try self.newPromise();
    try resolvePromise(self, p, x);
    return p;
}

/// The `%Promise%` constructor object (`Promise`), or null in a realm-less eval.
pub fn promiseCtor(self: *Interpreter) ?*Object {
    const g = self.globals orelse return null;
    const b = g.lookup("Promise") orelse return null;
    return if (b.value == .object) b.value.object else null;
}

/// The result of building a PromiseCapability: the record, or an abrupt completion from a throwing
/// constructor / non-constructor argument. Named (not an inline union) so several helpers share it.
pub const CapResult = union(enum) { cap: *object_mod.PromiseCapability, abrupt: Completion };

/// `true` iff `o` is callable AND has a [[Construct]] (an ordinary function/class/bound ctor, a
/// native constructor, or a Proxy whose target is a constructor). Mirrors §7.2.4 IsConstructor —
/// arrow functions / built-in methods are callable but NOT constructors.
pub fn isConstructorObj(o: *Object) bool {
    if (o.proxy) |pd| return if (pd.revoked) false else isConstructorObj(pd.target);
    if (o.bound) |b| return isConstructorObj(b.target);
    if (o.call) |fd| return !fd.is_arrow; // ordinary fn / class / method body — arrows have no [[Construct]]
    return switch (o.native) {
        .promise_ctor, .error_ctor, .aggregate_error_ctor, .suppressed_error_ctor, .string_ctor, .object_ctor, .array_ctor, .function_ctor, .number_ctor, .boolean_ctor, .map_ctor, .set_ctor, .weakmap_ctor, .weakset_ctor, .iterator_ctor, .proxy_ctor, .regexp_ctor, .array_buffer_ctor, .typed_array_ctor, .data_view_ctor, .date_ctor => true,
        else => false,
    };
}

/// §27.2.1.5 NewPromiseCapability ( C ) — construct `new C(executor)` where `executor` captures the
/// resolve/reject `C` hands it into a fresh PromiseCapability record. `C` must be a constructor
/// (TypeError otherwise). After construction both `[[Resolve]]` and `[[Reject]]` must be callable
/// (§27.2.1.5 step 7/9 — a constructor that never calls the executor, or calls it with a
/// non-callable, throws). Returns the capability, or propagates an abrupt completion from `new C`.
pub fn newPromiseCapability(self: *Interpreter, c: Value) EvalError!CapResult {
    if (c != .object or !isConstructorObj(c.object)) {
        return .{ .abrupt = try self.throwError("TypeError", "Promise capability requires a constructor") };
    }
    const cap = try self.arena.create(object_mod.PromiseCapability);
    cap.* = .{};
    // §27.2.1.5.1 GetCapabilitiesExecutor — a fresh native closure carrying `cap`.
    const executor = try Object.createNative(self.arena, .promise_capability_executor, "");
    executor.prototype = self.functionProto();
    executor.capability = cap;
    const rc = try self.construct(c.object, &.{.{ .object = executor }});
    if (rc.isAbrupt()) return .{ .abrupt = rc };
    // §27.2.1.5 step 7/9: the resolve and reject captured by the executor must be callable.
    if (cap.resolve != .object or !isCallable(cap.resolve.object) or cap.reject != .object or !isCallable(cap.reject.object)) {
        return .{ .abrupt = try self.throwError("TypeError", "Promise resolve or reject is not callable") };
    }
    cap.promise = rc.normal;
    return .{ .cap = cap };
}

/// §27.2.1.5.1 the GetCapabilitiesExecutor body — record the resolve/reject it is called with into
/// the captured capability. A second call (resolve/reject already set) is a TypeError (§ step 4/6).
pub fn promiseCapabilityExecutor(self: *Interpreter, func: *Object, args: []const Value) EvalError!Completion {
    const cap = func.capability orelse return .{ .normal = .undefined };
    if (cap.resolve != .undefined or cap.reject != .undefined) {
        return self.throwError("TypeError", "Promise executor already invoked");
    }
    cap.resolve = if (args.len > 0) args[0] else .undefined;
    cap.reject = if (args.len > 1) args[1] else .undefined;
    return .{ .normal = .undefined };
}

/// §27.2.4.7.1-style fast path: build a capability over the genuine `%Promise%` (no user
/// constructor), reusing the engine's own resolving functions. Used when the species/constructor is
/// the built-in Promise so we keep the cheap direct-settlement path.
pub fn newBuiltinCapability(self: *Interpreter, promise: *Object) EvalError!*object_mod.PromiseCapability {
    const cap = try self.arena.create(object_mod.PromiseCapability);
    cap.* = .{
        .promise = .{ .object = promise },
        .resolve = .{ .object = try makeResolvingFunction(self, promise, .promise_resolve_fn) },
        .reject = .{ .object = try makeResolvingFunction(self, promise, .promise_reject_fn) },
    };
    return cap;
}

/// §27.2.4.3 SpeciesConstructor(O, %Promise%) then NewPromiseCapability(C). `then`/`catch`/`finally`
/// derive their result promise this way: read `O.constructor`, then `C[@@species]`; default to
/// `%Promise%`. When the species IS the genuine %Promise% (the common case), take the fast builtin
/// capability; otherwise construct via the user species. Returns the capability or an abrupt
/// completion (a poisoned `constructor`/`@@species` getter, or a throwing species constructor).
pub fn speciesCapability(self: *Interpreter, o: *Object) EvalError!CapResult {
    const default_ctor = promiseCtor(self);
    // §7.3.22 SpeciesConstructor: C = O.constructor; if undefined → default. Else S = C[@@species];
    // null/undefined S → default. A non-constructor S → TypeError.
    const cc = try self.getProperty(.{ .object = o }, "constructor");
    if (cc.isAbrupt()) return .{ .abrupt = cc };
    var species: Value = .undefined;
    if (cc.normal == .undefined) {
        species = if (default_ctor) |d| .{ .object = d } else .undefined;
    } else if (cc.normal == .object) {
        const sym = self.wellKnownSpecies() orelse return fastOrAbrupt(self, o, default_ctor);
        const sc = try self.getSymbolProperty(cc.normal, sym);
        if (sc.isAbrupt()) return .{ .abrupt = sc };
        species = if (sc.normal == .null) .undefined else sc.normal;
        if (species == .undefined) species = if (default_ctor) |d| .{ .object = d } else .undefined;
    } else {
        return .{ .abrupt = try self.throwError("TypeError", "constructor is not an object") };
    }
    // Fast path: the species is the genuine %Promise% → reuse the engine resolving functions.
    if (species == .object and default_ctor != null and species.object == default_ctor.?) {
        return .{ .cap = try newBuiltinCapability(self, try self.newPromise()) };
    }
    return newPromiseCapability(self, species);
}

fn fastOrAbrupt(self: *Interpreter, o: *Object, default_ctor: ?*Object) EvalError!CapResult {
    _ = o;
    _ = default_ctor;
    return .{ .cap = try newBuiltinCapability(self, try self.newPromise()) };
}

/// Resolve a PromiseCapability's promise with `value` by CALLING its [[Resolve]] function (works for
/// both the engine's own resolving function and a user subclass's). For the builtin fast path this
/// is equivalent to `resolvePromise`.
pub fn capabilityResolve(self: *Interpreter, cap: *object_mod.PromiseCapability, value: Value) EvalError!Completion {
    if (cap.resolve != .object) return .{ .normal = .undefined };
    return self.callFunction(cap.resolve.object, &.{value}, .undefined);
}

/// Reject a PromiseCapability's promise with `reason` by CALLING its [[Reject]] function.
pub fn capabilityReject(self: *Interpreter, cap: *object_mod.PromiseCapability, reason: Value) EvalError!Completion {
    if (cap.reject != .object) return .{ .normal = .undefined };
    return self.callFunction(cap.reject.object, &.{reason}, .undefined);
}

/// §27.2.5.4.1 PerformPromiseThen — attach a fulfill/reject reaction pair to `promise`, returning
/// the derived result promise (`capability`). If `promise` is already settled, the matching
/// reaction is enqueued as a Job immediately; otherwise it is appended to the pending list.
/// `on_fulfilled`/`on_rejected` are the user handlers (null ⇒ default pass-through). When
/// `result_promise` is provided it is used as the capability (so `await`/internal callers can pass
/// null for "no derived promise"); a normal `then` always creates one.
pub fn performPromiseThen(self: *Interpreter, promise: *Object, on_fulfilled: ?*Object, on_rejected: ?*Object, capability: ?*object_mod.PromiseCapability) EvalError!void {
    const pd = promise.promise.?;
    const fulfill_reaction: object_mod.PromiseReaction = .{ .kind = .fulfill, .handler = on_fulfilled, .capability = capability };
    const reject_reaction: object_mod.PromiseReaction = .{ .kind = .reject, .handler = on_rejected, .capability = capability };
    switch (pd.state) {
        .pending => {
            try pd.fulfill_reactions.append(self.arena, fulfill_reaction);
            try pd.reject_reactions.append(self.arena, reject_reaction);
        },
        .fulfilled => try enqueueJob(self, .{ .reaction = .{ .reaction = fulfill_reaction, .argument = pd.result } }),
        .rejected => try enqueueJob(self, .{ .reaction = .{ .reaction = reject_reaction, .argument = pd.result } }),
    }
}

/// §27.2.2.1 PromiseReactionJob — run one settled-promise reaction (the body of a queued Job). For
/// a user handler: call it with the settlement value; resolve the derived capability with the
/// result (or reject it if the handler throws). For a DEFAULT handler (null): fulfill→resolve the
/// capability with the value; reject→reject it with the reason (§27.2.4.7.1/.2). For an AWAIT
/// reaction (`await_gen` set): resume the awaiting async body thread (fulfill→`.next(value)`,
/// reject→`.throw(value)`) instead. Runs on the MAIN interpreter while draining the queue.
pub fn runReactionJob(self: *Interpreter, reaction: object_mod.PromiseReaction, argument: Value) EvalError!void {
    // §27.7.5.3 await: a reaction with no capability/handler resumes the parked async body thread.
    if (reaction.await_gen) |gen| {
        const kind: object_mod.ResumeKind = if (reaction.kind == .fulfill) .next else .throw;
        // §27.6.3.8: an async-GENERATOR body resumes through the request-queue servicer (settles
        // requests as it advances); a plain async function resumes through `resumeAsync`.
        if (gen.is_async_gen) return asyncGenResumeAfterAwait(self, gen, kind, argument);
        return resumeAsync(self, gen, kind, argument);
    }
    const cap = reaction.capability;
    if (reaction.handler) |h| {
        const hc = try self.callFunction(h, &.{argument}, .undefined);
        if (cap) |c| {
            switch (hc) {
                // §27.2.2.1 step 9/10: a normal handler result resolves the capability; a throw
                // rejects it — by CALLING its [[Resolve]]/[[Reject]] (subclass-aware).
                .normal => |v| _ = try capabilityResolve(self, c, v),
                .throw => |e| _ = try capabilityReject(self, c, e),
                else => {},
            }
        }
        return;
    }
    // Default handler (§27.2.4.7.1 identity / §27.2.4.7.2 thrower).
    if (cap) |c| switch (reaction.kind) {
        .fulfill => _ = try capabilityResolve(self, c, argument),
        .reject => _ = try capabilityReject(self, c, argument),
    };
}

/// §27.2.2.2 PromiseResolveThenableJob — `promise` was resolved with a thenable; call
/// `thenable.then(resolveFn, rejectFn)` so the thenable drives `promise`'s eventual settlement. A
/// throw from `then` rejects `promise`.
pub fn runThenableJob(self: *Interpreter, promise: *Object, thenable: Value, then_fn: *Object) EvalError!void {
    // §27.2.2.2 step 1: CreateResolvingFunctions(promise) — a FRESH [[AlreadyResolved]] record
    // (the original resolve already fired into THIS job and set the promise's flag). Clear the
    // promise's already_resolved so the thenable's resolve/reject can settle it; from here only
    // these new functions act on the promise, so this is the single fresh resolution gate.
    promise.promise.?.already_resolved = false;
    const resolve_fn = try makeResolvingFunction(self, promise, .promise_resolve_fn);
    const reject_fn = try makeResolvingFunction(self, promise, .promise_reject_fn);
    const rc = try self.callFunction(then_fn, &.{ .{ .object = resolve_fn }, .{ .object = reject_fn } }, thenable);
    if (rc == .throw) {
        // §27.2.2.2 step 4: a throw from `then` rejects the promise (if not already resolved).
        try resolvePromiseReject(self, promise, rc.throw);
    }
}

/// Reject `promise` honoring [[AlreadyResolved]] (used when a thenable's `then` throws): only the
/// FIRST settlement wins, so a `then` that both called resolve and then threw is a no-op here.
pub fn resolvePromiseReject(self: *Interpreter, promise: *Object, reason: Value) EvalError!void {
    const pd = promise.promise.?;
    if (pd.already_resolved) return;
    pd.already_resolved = true;
    return rejectPromise(self, promise, reason);
}

/// §9.5 drain the Job (microtask) queue to completion: while non-empty, dequeue (FIFO) and run the
/// front job; each job may enqueue more. Bounded by the interpreter step limit — a runaway microtask
/// loop (e.g. a promise that re-schedules itself forever) terminates via StepLimitExceeded rather
/// than hanging. Runs on the MAIN interpreter after the synchronous script completes. A job that
/// throws unhandled is swallowed (an unhandled rejection is not a host error — there is no host).
pub fn drainJobs(self: *Interpreter) EvalError!void {
    const q = self.job_queue orelse return;
    var head: usize = 0;
    while (head < q.items.len) {
        try self.tick(); // §9.5 bound the drain by the step watchdog (no hangs)
        const job = q.items[head];
        head += 1;
        switch (job) {
            .reaction => |r| {
                // A reaction job may itself throw (the handler / await resume); swallow it — there
                // is no host to report an unhandled rejection to, and the derived promise (if any)
                // already captured the outcome inside runReactionJob.
                runReactionJob(self, r.reaction, r.argument) catch |e| {
                    if (e == error.StepLimitExceeded) return e; // the watchdog must propagate
                };
            },
            .thenable => |t| {
                runThenableJob(self, t.promise, t.thenable, t.then_fn) catch |e| {
                    if (e == error.StepLimitExceeded) return e;
                };
            },
        }
        // Periodically compact the consumed prefix so a long-running drain doesn't grow unbounded.
        if (head >= 256 and head * 2 >= q.items.len) {
            std.mem.copyForwards(object_mod.Job, q.items[0 .. q.items.len - head], q.items[head..]);
            q.items.len -= head;
            head = 0;
        }
    }
    q.clearRetainingCapacity();
}

/// §27.7.5.1 AsyncFunctionStart — calling an async function returns a Promise immediately and runs
/// the body on a generator-style thread. The body suspends at each `await`; on normal return the
/// promise fulfills, on an uncaught throw it rejects. Reuses the `Generator` substrate with
/// `is_async = true` and runs to the FIRST suspension (await) or completion synchronously (so the
/// returned promise is already settled when the body has no awaits).
pub fn callAsyncFunction(self: *Interpreter, func: *Object, args: []const Value, this_val: Value) EvalError!Completion {
    const promise = try self.newPromise();
    const gen = try self.arena.create(object_mod.Generator);
    const args_copy = try self.arena.dupe(Value, args);
    gen.* = .{
        .func = func,
        .args = args_copy,
        .this_val = this_val,
        .home_object = if (func.call) |fd| fd.home_object else null,
        .private_env = if (func.call) |fd| fd.private_env else null,
        .is_async = true,
        .promise = promise,
    };
    if (self.gen_registry) |reg| try reg.append(self.arena, gen);
    // §27.7.5.2 AsyncBlockStart: spawn the body thread and run it to the first await / completion.
    gen.state = .executing;
    gen.resume_kind = .next;
    gen.sent_value = .undefined;
    const t = std.Thread.spawn(.{}, asyncBodyThread, .{ self, gen }) catch {
        gen.state = .completed;
        return self.throwError("RangeError", "Cannot spawn async function thread");
    };
    gen.thread = t;
    gen.to_caller.waitUncancelable(self.io); // wait for the first await suspension / completion
    try self.settleAsyncTransfer(gen);
    return .{ .normal = .{ .object = promise } };
}

/// Resume a suspended async body (from a settled-await reaction Job) with `kind`/`value`, run it to
/// the next await / completion, and process the resulting transfer. `.next` → the await evaluates to
/// `value`; `.throw` → the await throws `value` into the body.
pub fn resumeAsync(self: *Interpreter, gen: *object_mod.Generator, kind: object_mod.ResumeKind, value: Value) EvalError!void {
    if (gen.state == .completed) return; // a settled body never resumes (defensive)
    gen.state = .executing;
    gen.resume_kind = kind;
    gen.sent_value = value;
    gen.resume_gen.post(self.io); // wake the parked await
    gen.to_caller.waitUncancelable(self.io); // wait for the next await / completion
    try self.settleAsyncTransfer(gen);
}

/// After an async body handoff: an `await` transfer (kind `.yield`) registers fulfill/reject
/// reactions on the awaited promise that will resume the body; a terminal `.ret`/`.throw` resolves
/// /rejects the function's promise and joins the thread (§27.7.5.2).
pub fn settleAsyncTransfer(self: *Interpreter, gen: *object_mod.Generator) EvalError!void {
    switch (gen.transfer_kind) {
        .yield => {
            // §27.7.5.3 Await: `transfer_value` is the AWAITED value. Wrap it via PromiseResolve and
            // register internal reactions that resume THIS body on settlement.
            gen.state = .suspended_yield;
            const awaited = try promiseResolveValue(self, gen.transfer_value);
            const on_f: object_mod.PromiseReaction = .{ .kind = .fulfill, .handler = null, .capability = null, .await_gen = gen };
            const on_r: object_mod.PromiseReaction = .{ .kind = .reject, .handler = null, .capability = null, .await_gen = gen };
            const pd = awaited.promise.?;
            switch (pd.state) {
                .pending => {
                    try pd.fulfill_reactions.append(self.arena, on_f);
                    try pd.reject_reactions.append(self.arena, on_r);
                },
                .fulfilled => try enqueueJob(self, .{ .reaction = .{ .reaction = on_f, .argument = pd.result } }),
                .rejected => try enqueueJob(self, .{ .reaction = .{ .reaction = on_r, .argument = pd.result } }),
            }
        },
        .ret => {
            gen.state = .completed;
            if (gen.thread) |t| {
                t.join();
                gen.thread = null;
            }
            try resolvePromise(self, gen.promise.?, gen.transfer_value);
        },
        .throw => {
            gen.state = .completed;
            if (gen.thread) |t| {
                t.join();
                gen.thread = null;
            }
            // §27.7.5.2: an uncaught throw rejects the function's promise.
            const promise = gen.promise.?;
            const pd = promise.promise.?;
            if (!pd.already_resolved) {
                pd.already_resolved = true;
                try rejectPromise(self, promise, gen.transfer_value);
            }
        },
    }
}

/// The async-body thread entry (mirrors `generatorBodyThread`): a fresh per-body interpreter sharing
/// the arena + globals + job queue, with `current_gen` set so `await` reaches the handoff. Runs the
/// body and posts the terminal completion. Engine errors become a thrown completion.
pub fn asyncBodyThread(parent: *Interpreter, gen: *object_mod.Generator) void {
    var body: Interpreter = .{
        .arena = parent.arena,
        .step_limit = parent.step_limit,
        .globals = parent.globals,
        .gen_registry = parent.gen_registry,
        .job_queue = parent.job_queue,
        .io = parent.io,
        .current_gen = gen,
        // §13.3.10 a `await import(...)` inside the async body resolves via the parent's loader.
        .module_loader = parent.module_loader,
        .module_cache = parent.module_cache,
        .host_referrer_key = parent.host_referrer_key,
        .async_done = parent.async_done,
    };
    const comp = body.runGeneratorBody(gen) catch |e| blk: {
        const kind: []const u8 = if (e == error.StepLimitExceeded) "RangeError" else "Error";
        const msg: []const u8 = if (e == error.StepLimitExceeded) "step limit exceeded" else "out of memory";
        const tc = body.throwError(kind, msg) catch break :blk Completion{ .throw = .undefined };
        break :blk tc;
    };
    switch (comp) {
        .normal => |v| {
            gen.transfer_value = v;
            gen.transfer_kind = .ret;
        },
        .ret => |v| {
            gen.transfer_value = v;
            gen.transfer_kind = .ret;
        },
        .throw => |v| {
            gen.transfer_value = v;
            gen.transfer_kind = .throw;
        },
        .brk, .cont => {
            gen.transfer_value = .undefined;
            gen.transfer_kind = .ret;
        },
    }
    gen.to_caller.post(body.io);
}

pub fn doAwait(self: *Interpreter, value: Value) EvalError!Completion {
    // §27.6.3.8: in an async generator the servicer must distinguish an await from a yield (both are
    // `.yield`-kind handoffs); mark this transfer as an await so it registers resumption reactions.
    self.current_gen.?.transfer_await = true;
    const r = doYieldRaw(self, value);
    if (r.abandon) return .{ .ret = .undefined }; // realm teardown woke us to unwind
    return switch (r.kind) {
        .next => .{ .normal = r.value }, // §27.7.5.3: await evaluates to the fulfillment value
        .throw => .{ .throw = r.value }, // a rejected await throws the reason into the body
        .ret => .{ .ret = r.value }, // teardown injection (unwind, run finally blocks)
    };
}

/// §27.6.3.8 AsyncGeneratorYield — on the async-gen body thread: first AWAIT the operand (so a
/// thenable yield value is adopted), then hand it out as a YIELD (`transfer_await = false`) and park
/// until the next request resumes us. A `.next(v)` makes the yield evaluate to `v`; an injected
/// `.throw`/`.return` re-throws / returns at the yield point (running finally blocks).
pub fn doAsyncYield(self: *Interpreter, value: Value) EvalError!Completion {
    return doAsyncYieldRaw(self, value, true);
}

/// §27.6.3.8 AsyncGeneratorYield, parameterized by whether the operand is awaited first.
/// `await_first = true` is the plain `yield value` path (§27.6.3.8 step 5 awaits the operand).
/// `await_first = false` is the `yield*` re-yield (§14.4.14 step 7.a/b/c uses a plain GeneratorYield
/// of the ALREADY-decoded inner result — the inner `next` result was awaited once, and its `value`
/// must NOT be awaited again; otherwise a manually-implemented async iterator that yields a Promise
/// would have it unwrapped, violating `yield-star-promise-not-unwrapped`).
pub fn doAsyncYieldRaw(self: *Interpreter, value: Value, await_first: bool) EvalError!Completion {
    const yielded = if (await_first) blk: {
        // §27.6.3.8 step 5: Await the operand first.
        const ac = try doAwait(self, value);
        if (ac.isAbrupt()) return ac; // a rejected await of the yield operand throws into the body
        break :blk ac.normal;
    } else value;
    // Now suspend producing the yielded value (a non-await handoff → the servicer settles the request).
    self.current_gen.?.transfer_await = false;
    const r = doYieldRaw(self, yielded);
    if (r.abandon) return .{ .ret = .undefined };
    return switch (r.kind) {
        .next => .{ .normal = r.value }, // the value sent to the next .next(v)
        .throw => .{ .throw = r.value }, // §27.6.3.8: an injected .throw re-throws at the yield
        // §27.6.3.8 step 8.b: a `.return(v)` resumption of a PLAIN async yield Awaits `v` (so a
        // thenable resumption value is adopted — `yield-return-then-getter-ticks`). The `yield*`
        // re-yield path (`await_first = false`) does NOT await here: the resumption is forwarded to
        // the inner iterator's `return` by the delegate loop (§14.4.14 step 7.c), which awaits the
        // inner result instead.
        .ret => if (await_first) blk: {
            const av = try doAwait(self, r.value);
            if (av.isAbrupt()) break :blk av; // a rejected await throws into the body
            break :blk Completion{ .ret = av.normal };
        } else Completion{ .ret = r.value },
    };
}

/// §27.6.3.8 `yield* expr` in an ASYNC generator — delegate over the ASYNC iterator of `expr`
/// (GetIterator async; a sync iterable is wrapped). Each round: await the inner `next/throw/return`
/// (its result is a promise), decode `{value, done}`; a done result finishes the `yield*` with that
/// value; otherwise re-yield the value to the outer consumer (an AsyncGeneratorYield) and forward the
/// next resumption to the inner iterator. Runs on the async-gen body thread.
pub fn doAsyncYieldDelegate(self: *Interpreter, source: Value) EvalError!Completion {
    const ait = try self.getAsyncIterator(source);
    const iterator: *Object = switch (ait) {
        .abrupt => |c| return c,
        .iterator => |it| it,
    };
    var received: Resumption = .{ .kind = .next, .value = .undefined, .abandon = false };
    while (true) {
        const method: []const u8 = switch (received.kind) {
            .next => "next",
            .throw => "throw",
            .ret => "return",
        };
        // §27.6.3.8: a `.throw`/`.return` to a missing inner method is special-cased.
        if (received.kind != .next) {
            const mc = try self.getProperty(.{ .object = iterator }, method);
            if (mc.isAbrupt()) return mc;
            if (mc.normal != .object or mc.normal.object.kind != .function) {
                // §27.6.3.8 step 7.c.iii: inner `return` is undefined → for an async generator,
                // Await(received.[[Value]]) first, then Return Completion(received).
                if (received.kind == .ret) {
                    const av = try doAwait(self, received.value);
                    if (av.isAbrupt()) return av;
                    return .{ .ret = av.normal };
                }
                try interp_stmt.asyncIteratorClose(self, iterator);
                return self.throwError("TypeError", "The async iterator does not provide a throw method");
            }
        }
        const raw = try iteratorCallRaw(self, iterator, method, received.value, true);
        if (raw.isAbrupt()) return raw;
        // Await the (promise) result, then decode.
        const aw = try doAwait(self, raw.normal);
        if (aw.isAbrupt()) return aw;
        const decoded = try iterResultFromValue(self, aw.normal);
        const step: IterStep = switch (decoded) {
            .abrupt => |c| return c,
            .result => |r| r,
        };
        if (step.done) {
            // §27.6.3.8: a done `.return` result returns from the body; otherwise the yield* value.
            if (received.kind == .ret) return .{ .ret = step.value };
            return .{ .normal = step.value };
        }
        // §14.4.14 step 7.a.v / 7.b.iii / 7.c.ix: re-yield the inner result's value via a plain
        // GeneratorYield (NO second await — the inner result was already awaited at line above), so a
        // Promise produced by a manual async iterator passes through unwrapped.
        const yc = try doAsyncYieldRaw(self, step.value, false);
        switch (yc) {
            .normal => |v| received = .{ .kind = .next, .value = v, .abandon = false },
            .throw => |e| received = .{ .kind = .throw, .value = e, .abandon = false },
            // §27.6.3.8 step 7.c: a `.return` resumption at the re-yield is FORWARDED to the inner
            // iterator's `return` (next loop turn), NOT an immediate unwind — the inner `return` may
            // yield a not-done result that re-yields and continues the delegation. The body unwinds
            // only when the inner `return` reports done (step 7.c.viii) or has no `return` method.
            // EXCEPTION: realm teardown also surfaces as a `.ret` (via `doAsyncYield`'s abandon path);
            // never loop back to call the inner iterator in that case — unwind immediately.
            .ret => |v| {
                if (self.current_gen) |g| if (g.abandon) return .{ .ret = .undefined };
                received = .{ .kind = .ret, .value = v, .abandon = false };
            },
            .brk, .cont => return .{ .ret = .undefined },
        }
    }
}

/// §27.6.2 calling an `async function*` — create an AsyncGenerator object in `suspended_start`
/// (lazy: the body thread spawns on the first request). Mirrors `createGenerator` but tags the
/// underlying Generator `is_async`+`is_async_gen` and links it to the AsyncGenerator state.
pub fn createAsyncGenerator(self: *Interpreter, func: *Object, args: []const Value, this_val: Value) EvalError!Completion {
    const gen = try self.arena.create(object_mod.Generator);
    const args_copy = try self.arena.dupe(Value, args);
    gen.* = .{
        .func = func,
        .args = args_copy,
        .this_val = this_val,
        .home_object = if (func.call) |fd| fd.home_object else null,
        .private_env = if (func.call) |fd| fd.private_env else null,
        .is_async = true,
        .is_async_gen = true,
    };
    // §15.6.2 EvaluateAsyncGeneratorBody: FunctionDeclarationInstantiation runs EAGERLY here (on the
    // caller thread). A param destructuring/default error throws synchronously at the call site —
    // the async-generator object is never created (matches V8: `ag(bad)` throws, not a rejected next).
    var abrupt: ?Completion = null;
    gen.call_env = try instantiateGeneratorParams(self, gen, &abrupt);
    if (abrupt) |c| return c;
    const ag = try self.arena.create(object_mod.AsyncGenerator);
    ag.* = .{ .gen = gen };
    gen.async_gen = ag;
    if (self.gen_registry) |reg| try reg.append(self.arena, gen);
    // §27.6.1.1 OrdinaryCreateFromConstructor(func, "%AsyncGeneratorPrototype%"): the new
    // async-generator's [[Prototype]] is `Get(func, "prototype")` when that is an object, else the
    // realm %AsyncGeneratorPrototype% intrinsic.
    const inst_proto: ?*Object = blk: {
        if (func.get("prototype")) |pv| if (pv == .object) break :blk pv.object;
        break :blk asyncGeneratorProto(self);
    };
    const obj = try Object.create(self.arena, inst_proto);
    obj.async_generator = ag;
    return .{ .normal = .{ .object = obj } };
}

/// %AsyncGeneratorPrototype% — stashed under the sentinel global name by `builtins.setup`.
pub fn asyncGeneratorProto(self: *Interpreter) ?*Object {
    const g = self.globals orelse return null;
    const b = g.lookup("%AsyncGeneratorPrototype%") orelse return null;
    return if (b.value == .object) b.value.object else null;
}

/// %AsyncFromSyncIteratorPrototype% — the proto of an AsyncFromSyncIterator wrapper object.
pub fn asyncFromSyncProto(self: *Interpreter) ?*Object {
    const g = self.globals orelse return null;
    const b = g.lookup("%AsyncFromSyncIteratorPrototype%") orelse return null;
    return if (b.value == .object) b.value.object else null;
}

/// §27.6.1.2/.3/.4 %AsyncGeneratorPrototype%.next/return/throw — enqueue an AsyncGeneratorRequest
/// (returning a fresh promise) and drive the queue. Each ALWAYS returns a promise (a sync error —
/// e.g. called on a non-async-generator — rejects that promise rather than throwing, §27.6.1.2).
pub fn asyncGeneratorResume(self: *Interpreter, this_val: Value, kind: object_mod.ResumeKind, value: Value) EvalError!Completion {
    const promise = try self.newPromise();
    const resolve_fn = try makeResolvingFunction(self, promise, .promise_resolve_fn);
    const reject_fn = try makeResolvingFunction(self, promise, .promise_reject_fn);
    // §27.6.1.2 step 3: a brand-check failure rejects the returned promise (does NOT throw).
    if (this_val != .object or this_val.object.async_generator == null) {
        const tc = try self.throwError("TypeError", "not an async generator");
        try rejectPromiseRaw(self, promise, tc.throw);
        return .{ .normal = .{ .object = promise } };
    }
    const ag = this_val.object.async_generator.?;
    // §27.6.3.1 AsyncGeneratorEnqueue: append the request to the queue.
    try ag.queue.append(self.arena, .{ .kind = kind, .value = value, .promise = promise, .resolve = resolve_fn, .reject = reject_fn });
    // §27.6.3.4 AsyncGeneratorDrainQueue: if not already running and not awaiting-return, service it.
    if (ag.state != .executing and ag.state != .awaiting_return) {
        try asyncGenDrainQueue(self, ag);
    }
    return .{ .normal = .{ .object = promise } };
}

/// §27.6.3.4 AsyncGeneratorDrainQueue / §27.6.3.5 AsyncGeneratorResume — service the FRONT request:
/// resume the body to its next yield/await/completion (or, on a completed generator, settle the
/// request directly), then react to the transfer. Services requests until the body suspends on an
/// `await` (a reaction Job will re-enter via `asyncGenResumeAfterAwait`) or the queue drains. Runs on
/// the servicing interpreter (main or a Job).
pub fn asyncGenDrainQueue(self: *Interpreter, ag: *object_mod.AsyncGenerator) EvalError!void {
    while (ag.head < ag.queue.items.len) {
        const req = ag.queue.items[ag.head];
        // §27.6.3.5 on a COMPLETED async generator: settle the request without running the body.
        if (ag.state == .completed) {
            switch (req.kind) {
                .next => try asyncGenSettleResult(self, req, .undefined, true),
                .ret => try asyncGenSettleResult(self, req, req.value, true),
                .throw => _ = try self.callFunction(req.reject, &.{req.value}, .undefined),
            }
            ag.head += 1;
            continue;
        }
        const gen = ag.gen;
        if (ag.state == .suspended_start) {
            // §27.6.3.5: spawn the body thread; it runs to the first await/yield/completion.
            // A `.return`/`.throw` on a suspended-start async generator completes it directly.
            if (req.kind == .ret) {
                ag.state = .completed;
                try asyncGenSettleResult(self, req, req.value, true);
                ag.head += 1;
                continue;
            }
            if (req.kind == .throw) {
                ag.state = .completed;
                _ = try self.callFunction(req.reject, &.{req.value}, .undefined);
                ag.head += 1;
                continue;
            }
            ag.state = .executing;
            gen.resume_kind = .next;
            gen.sent_value = req.value;
            gen.transfer_await = false;
            const t = std.Thread.spawn(.{}, asyncBodyThread, .{ self, gen }) catch {
                ag.state = .completed;
                const tc = try self.throwError("RangeError", "Cannot spawn async generator thread");
                _ = try self.callFunction(req.reject, &.{tc.throw}, .undefined);
                ag.head += 1;
                continue;
            };
            gen.thread = t;
            gen.to_caller.waitUncancelable(self.io);
        } else {
            // §27.6.3.5 SUSPENDED-YIELD: resume the parked yield with the request's completion.
            ag.state = .executing;
            gen.resume_kind = req.kind;
            gen.sent_value = req.value;
            gen.transfer_await = false;
            gen.resume_gen.post(self.io);
            gen.to_caller.waitUncancelable(self.io);
        }
        // React to where the body suspended / completed.
        const more = try asyncGenHandleTransfer(self, ag);
        if (!more) return; // suspended on an await — a reaction Job will resume the drain
    }
}

/// After a body handoff: classify the transfer. An AWAIT suspension registers reactions that resume
/// the body (returns false — stop draining; the Job continues it). A YIELD settles the front request
/// with {value,done:false} and advances the queue (returns true — keep draining the next request). A
/// terminal return/throw settles the front request done:true / rejection (returns true).
pub fn asyncGenHandleTransfer(self: *Interpreter, ag: *object_mod.AsyncGenerator) EvalError!bool {
    const gen = ag.gen;
    switch (gen.transfer_kind) {
        .yield => {
            if (gen.transfer_await) {
                // §27.6.3.8 step 8 (await): the body is parked on an await — register reactions on
                // PromiseResolve(value) that resume THIS body (via `asyncGenResumeAfterAwait`). Keep
                // `ag.state = .executing` so a NEW request arriving in this window only ENQUEUES (the
                // resume-guard in `asyncGeneratorResume` skips draining while executing) and does NOT
                // post `resume_gen` — the body is waiting for the await reaction, not a request. The
                // sole resume path is the reaction Job. (`gen.state` is left for `cleanupGenerators`.)
                ag.state = .executing;
                gen.state = .suspended_yield; // mark the body thread parked (for realm teardown).
                const awaited = try promiseResolveValue(self, gen.transfer_value);
                const on_f: object_mod.PromiseReaction = .{ .kind = .fulfill, .handler = null, .capability = null, .await_gen = gen };
                const on_r: object_mod.PromiseReaction = .{ .kind = .reject, .handler = null, .capability = null, .await_gen = gen };
                const pd = awaited.promise.?;
                switch (pd.state) {
                    .pending => {
                        try pd.fulfill_reactions.append(self.arena, on_f);
                        try pd.reject_reactions.append(self.arena, on_r);
                    },
                    .fulfilled => try enqueueJob(self, .{ .reaction = .{ .reaction = on_f, .argument = pd.result } }),
                    .rejected => try enqueueJob(self, .{ .reaction = .{ .reaction = on_r, .argument = pd.result } }),
                }
                return false;
            }
            // §27.6.3.8 a real YIELD: settle the front request with {value, done:false}, advance.
            ag.state = .suspended_yield;
            gen.state = .suspended_yield; // the body thread is parked at the yield (for teardown).
            const req = ag.queue.items[ag.head];
            try asyncGenSettleResult(self, req, gen.transfer_value, false);
            ag.head += 1;
            return true;
        },
        .ret => {
            // §27.6.3.5: body returned — settle the front request {value, done:true}, complete.
            ag.state = .completed;
            if (gen.thread) |t| {
                t.join();
                gen.thread = null;
            }
            const req = ag.queue.items[ag.head];
            try asyncGenSettleResult(self, req, gen.transfer_value, true);
            ag.head += 1;
            return true;
        },
        .throw => {
            // §27.6.3.5: an uncaught throw — reject the front request, complete the generator.
            ag.state = .completed;
            if (gen.thread) |t| {
                t.join();
                gen.thread = null;
            }
            const req = ag.queue.items[ag.head];
            _ = try self.callFunction(req.reject, &.{gen.transfer_value}, .undefined);
            ag.head += 1;
            return true;
        },
    }
}

/// Resume an async-generator body parked on an `await` (called from a settled-await reaction Job),
/// run it to the next suspension/completion, react, and keep draining the queue. `.next` → the await
/// evaluates to `value`; `.throw` → the await throws `value`.
pub fn asyncGenResumeAfterAwait(self: *Interpreter, gen: *object_mod.Generator, kind: object_mod.ResumeKind, value: Value) EvalError!void {
    const ag = gen.async_gen.?;
    if (ag.state == .completed) return; // defensive
    ag.state = .executing;
    gen.resume_kind = kind;
    gen.sent_value = value;
    gen.transfer_await = false;
    gen.resume_gen.post(self.io);
    gen.to_caller.waitUncancelable(self.io);
    const more = try asyncGenHandleTransfer(self, ag);
    if (more) try asyncGenDrainQueue(self, ag);
}

/// Settle a request's promise with a CreateIterResultObject {value, done} (§7.4.1) via its resolve
/// function (so a thenable value is properly adopted, §27.6.3.9 step 9 uses the resolve abstraction).
pub fn asyncGenSettleResult(self: *Interpreter, req: object_mod.AsyncGenRequest, value: Value, done: bool) EvalError!void {
    const result = try iterResultObject(self, value, done);
    _ = try self.callFunction(req.resolve, &.{.{ .object = result }}, .undefined);
}

/// Build a plain IteratorResult `{ value, done }` object (proto %Object.prototype%). Like
/// `iterResult` but returns the bare Object (callers wrap into a Completion / pass to resolve).
pub fn iterResultObject(self: *Interpreter, value: Value, done: bool) EvalError!*Object {
    const obj = try Object.create(self.arena, self.objectProto());
    try obj.set("value", value);
    try obj.set("done", .{ .boolean = done });
    return obj;
}

/// §27.1.4.2.1/.2/.3 %AsyncFromSyncIteratorPrototype%.next/return/throw — drive the wrapped SYNC
/// iterator's matching method and return a PROMISE of the IteratorResult whose `value` has been
/// awaited (§27.1.4.4 AsyncFromSyncIteratorContinuation). A sync throw rejects the returned promise.
/// `return`/`throw` on a sync iterator lacking that method resolve/reject per §27.1.4.2.2/.3 step 5.
pub fn asyncFromSyncMethod(self: *Interpreter, name: []const u8, this_val: Value, arg: Value, has_arg: bool) EvalError!Completion {
    const promise = try self.newPromise();
    if (this_val != .object or this_val.object.async_from_sync == null) {
        const tc = try self.throwError("TypeError", "not an AsyncFromSyncIterator");
        try rejectPromiseRaw(self, promise, tc.throw);
        return .{ .normal = .{ .object = promise } };
    }
    const sync_iter = this_val.object.async_from_sync.?;
    const is_next = std.mem.eql(u8, name, "next");
    const is_return = std.mem.eql(u8, name, "return");
    // §27.1.4.2.2/.3 step 3: look up `return`/`throw` on the sync iterator; absent → special-case.
    if (!is_next) {
        const mc = try self.getProperty(.{ .object = sync_iter }, name);
        if (mc.isAbrupt()) {
            try rejectPromiseRaw(self, promise, mc.throw);
            return .{ .normal = .{ .object = promise } };
        }
        if (mc.normal != .object or mc.normal.object.kind != .function) {
            // §27.1.4.2.2 step 5: absent `return` → resolve with { value: arg, done: true }.
            // §27.1.4.2.3 step 5: absent `throw` → reject with `arg` (re-throw the exception).
            if (is_return) {
                const ir = try iterResultObject(self, if (has_arg) arg else .undefined, true);
                try resolvePromise(self, promise, .{ .object = ir });
            } else {
                try rejectPromiseRaw(self, promise, arg);
            }
            return .{ .normal = .{ .object = promise } };
        }
    }
    // Call the sync iterator's method, decode the IteratorResult.
    const raw = try iteratorCallRaw(self, sync_iter, name, arg, has_arg);
    if (raw.isAbrupt()) {
        try rejectPromiseRaw(self, promise, raw.throw);
        return .{ .normal = .{ .object = promise } };
    }
    const decoded = try iterResultFromValue(self, raw.normal);
    const step: IterStep = switch (decoded) {
        .abrupt => |c| {
            try rejectPromiseRaw(self, promise, c.throw);
            return .{ .normal = .{ .object = promise } };
        },
        .result => |r| r,
    };
    // §27.1.4.4 AsyncFromSyncIteratorContinuation: valueWrapper = PromiseResolve(value); the result
    // promise resolves, when valueWrapper settles, to CreateIterResultObject(awaitedValue, done).
    const value_wrapper = try promiseResolveValue(self, step.value);
    const wrap = try Object.createNative(self.arena, .async_from_sync_wrap, "");
    wrap.prototype = self.functionProto();
    wrap.afs_done = step.done;
    // PerformPromiseThen(valueWrapper, wrap) with the result promise as the capability.
    try performPromiseThen(self, value_wrapper, wrap, null, try newBuiltinCapability(self, promise));
    return .{ .normal = .{ .object = promise } };
}

/// §27.2.3.1 the Promise constructor — `new Promise(executor)`: create a pending promise, build its
/// resolve/reject functions, call `executor(resolve, reject)`, and reject the promise if the
/// executor throws (§27.2.3.1 step 9–10). `executor` must be callable (§27.2.3.1 step 2 TypeError).
pub fn promiseConstructor(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    // §27.2.3.1 step 1: `Promise(...)` called without `new` (NewTarget undefined) → TypeError.
    if (self.native_new_target == .undefined) {
        return self.throwError("TypeError", "Constructor Promise requires 'new'");
    }
    const executor: Value = if (args.len > 0) args[0] else .undefined;
    if (executor != .object or !isCallable(executor.object)) {
        return self.throwError("TypeError", "Promise resolver is not a function");
    }
    // §27.2.3.1 step 3–4 OrdinaryCreateFromConstructor: when invoked via `new`/`super`, the instance
    // (`this_val`) was already created with NewTarget.prototype — attach PromiseData to IT so a
    // subclass's prototype is preserved. (A realm-less call with no instance falls back to a fresh one.)
    const promise = if (this_val == .object and this_val.object.promise == null) blk: {
        const pd = try self.arena.create(object_mod.PromiseData);
        pd.* = .{};
        this_val.object.promise = pd;
        break :blk this_val.object;
    } else try self.newPromise();
    const resolve_fn = try makeResolvingFunction(self, promise, .promise_resolve_fn);
    const reject_fn = try makeResolvingFunction(self, promise, .promise_reject_fn);
    const rc = try self.callFunction(executor.object, &.{ .{ .object = resolve_fn }, .{ .object = reject_fn } }, .undefined);
    if (rc == .throw) {
        // §27.2.3.1 step 10: an executor that throws rejects the promise (unless already resolved).
        const pd = promise.promise.?;
        if (!pd.already_resolved) {
            pd.already_resolved = true;
            try rejectPromise(self, promise, rc.throw);
        }
    }
    return .{ .normal = .{ .object = promise } };
}

/// §27.2.4.5 Promise.resolve(x) / §27.2.4.4 Promise.reject(r) — the `this`-static factories. resolve
/// returns `x` unchanged if it is already a promise, else a promise resolved with `x`; reject always
/// makes a fresh rejected promise.
pub fn promiseStaticResolve(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    // §27.2.4.7 PromiseResolve(C, x): `this` (C) must be an Object (TypeError otherwise).
    if (this_val != .object) return self.throwError("TypeError", "Promise.resolve called on a non-object");
    const x: Value = if (args.len > 0) args[0] else .undefined;
    // §27.2.4.7 step 2: if x is already a promise whose `.constructor` IS C, return x unchanged.
    if (x == .object and x.object.promise != null) {
        const xc = try self.getProperty(x, "constructor");
        if (xc.isAbrupt()) return xc;
        if (xc.normal == .object and xc.normal.object == this_val.object) return .{ .normal = x };
    }
    // §27.2.4.7 step 3: NewPromiseCapability(C); call its resolve with x; return its promise. The
    // identity short-circuit (step 2) already fired above, so a same-realm %Promise% input that
    // wasn't returned (its `.constructor` was reassigned) is wrapped in a FRESH promise here. Fast
    // path: C is the genuine %Promise% → reuse the engine's own resolving functions.
    const cap = if (this_val.object == promiseCtor(self))
        try newBuiltinCapability(self, try self.newPromise())
    else switch (try newPromiseCapability(self, this_val)) {
        .cap => |c| c,
        .abrupt => |a| return a,
    };
    const rc = try capabilityResolve(self, cap, x);
    if (rc.isAbrupt()) return rc;
    return .{ .normal = cap.promise };
}

pub fn promiseStaticReject(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    // §27.2.4.4: `this` (C) must be a constructor; NewPromiseCapability(C); call its reject with r.
    if (this_val != .object) return self.throwError("TypeError", "Promise.reject called on a non-object");
    const r: Value = if (args.len > 0) args[0] else .undefined;
    if (this_val.object == promiseCtor(self)) {
        const p = try self.newPromise();
        try rejectPromiseRaw(self, p, r);
        return .{ .normal = .{ .object = p } };
    }
    const sc = try newPromiseCapability(self, this_val);
    const cap = switch (sc) {
        .cap => |c| c,
        .abrupt => |a| return a,
    };
    const rc = try capabilityReject(self, cap, r);
    if (rc.isAbrupt()) return rc;
    return .{ .normal = cap.promise };
}

/// §27.2.4.3 Promise.withResolvers() — `{ promise, resolve, reject }` from NewPromiseCapability(this).
pub fn promiseWithResolvers(self: *Interpreter, this_val: Value) EvalError!Completion {
    if (this_val != .object) return self.throwError("TypeError", "Promise.withResolvers called on a non-object");
    const sc = try newPromiseCapability(self, this_val);
    const cap = switch (sc) {
        .cap => |c| c,
        .abrupt => |a| return a,
    };
    const obj = try Object.create(self.arena, self.objectProto());
    try obj.set("promise", cap.promise);
    try obj.set("resolve", cap.resolve);
    try obj.set("reject", cap.reject);
    return .{ .normal = .{ .object = obj } };
}

/// §27.2.4.1/.2/.3/.6 the shared driver. A non-iterable argument rejects the result promise (the
/// spec returns `IfAbruptRejectPromise` — a rejected promise, not a sync throw).
pub fn promiseCombinator(self: *Interpreter, this_val: Value, args: []const Value, comptime kind: CombinatorKind) EvalError!Completion {
    // §27.2.4.1 step 1–3: C = this (must be an Object/constructor); capability = NewPromiseCapability(C).
    if (this_val != .object) return self.throwError("TypeError", "Promise combinator called on a non-object");
    const fast = this_val.object == promiseCtor(self);
    const cap = blk: {
        if (fast) break :blk try newBuiltinCapability(self, try self.newPromise());
        const nc = try newPromiseCapability(self, this_val);
        switch (nc) {
            .cap => |c| break :blk c,
            .abrupt => |a| return a, // §27.2.4.1 step 2: a throwing capability ctor throws synchronously
        }
    };
    // §27.2.4.1.1 GetPromiseResolve(C): C.resolve must be callable (else IfAbruptRejectPromise).
    const promise_resolve: ?*Object = blk: {
        if (fast) break :blk null; // fast path: use promiseResolveValue directly
        const rc = try self.getProperty(this_val, "resolve");
        if (rc.isAbrupt()) {
            const rej = try capabilityReject(self, cap, rc.throw);
            if (rej.isAbrupt()) return rej;
            return .{ .normal = cap.promise };
        }
        if (rc.normal != .object or !isCallable(rc.normal.object)) {
            const rej = try capabilityReject(self, cap, (try self.throwError("TypeError", "Promise.resolve is not callable")).throw);
            if (rej.isAbrupt()) return rej;
            return .{ .normal = cap.promise };
        }
        break :blk rc.normal.object;
    };

    const arg: Value = if (args.len > 0) args[0] else .undefined;
    // §7.4 GetIterator + drain the iterable to a value list; a non-iterable (or a throwing
    // iterator) rejects the result promise rather than throwing synchronously.
    var items: std.ArrayListUnmanaged(Value) = .empty;
    const ic = try self.iterateToList(arg, &items);
    if (ic.isAbrupt()) {
        const rej = try capabilityReject(self, cap, ic.throw);
        if (rej.isAbrupt()) return rej;
        return .{ .normal = cap.promise };
    }

    // Resolve one input element to a promise via C.resolve (or the fast %Promise% path).
    const resolveElem = struct {
        fn call(s: *Interpreter, pr: ?*Object, c: Value, item: Value) EvalError!Completion {
            if (pr) |f| return s.callFunction(f, &.{item}, c);
            return .{ .normal = .{ .object = try promiseResolveValue(s, item) } };
        }
    }.call;

    if (kind == .race) {
        // §27.2.4.6.1 PerformPromiseRace — forward each element's settlement to the result promise.
        for (items.items) |item| {
            const epc = try resolveElem(self, promise_resolve, this_val, item);
            if (epc.isAbrupt()) {
                const rej = try capabilityReject(self, cap, epc.throw);
                if (rej.isAbrupt()) return rej;
                return .{ .normal = cap.promise };
            }
            if (epc.normal != .object) continue;
            const tc = try invokeThen(self, epc.normal.object, cap, null, null);
            if (tc.isAbrupt()) {
                const rej = try capabilityReject(self, cap, tc.throw);
                if (rej.isAbrupt()) return rej;
                return .{ .normal = cap.promise };
            }
        }
        return .{ .normal = cap.promise };
    }

    const state = try self.arena.create(object_mod.CombinatorState);
    state.* = .{ .capability = cap };
    for (items.items, 0..) |item, index| {
        // §27.2.4.1.1 step d.iii: a placeholder slot per element (filled by its resolve closure).
        try state.values.append(self.arena, .undefined);
        state.remaining += 1;
        const epc = try resolveElem(self, promise_resolve, this_val, item);
        if (epc.isAbrupt()) {
            const rej = try capabilityReject(self, cap, epc.throw);
            if (rej.isAbrupt()) return rej;
            return .{ .normal = cap.promise };
        }
        if (epc.normal != .object) continue;
        const on_f = try makeCombinatorElement(self, state, index, switch (kind) {
            .all => "all",
            .all_settled => "settled_fulfill",
            .any => "any_fulfill",
            .race => unreachable,
        });
        const on_r: ?*Object = switch (kind) {
            // §27.2.4.1: `all` reject → reject the result capability directly.
            .all => try makeCombinatorElement(self, state, index, "all_reject"),
            // §27.2.4.2/.3: `allSettled` reject and `any` reject record into the shared state.
            .all_settled => try makeCombinatorElement(self, state, index, "settled_reject"),
            .any => try makeCombinatorElement(self, state, index, "any_reject"),
            .race => unreachable,
        };
        const tc = try invokeThen(self, epc.normal.object, null, on_f, on_r);
        if (tc.isAbrupt()) {
            const rej = try capabilityReject(self, cap, tc.throw);
            if (rej.isAbrupt()) return rej;
            return .{ .normal = cap.promise };
        }
    }
    // §27.2.4.1.1 step e: the implicit final decrement — if every element already settled (or there
    // were none), settle the result now.
    try combinatorSettleIfDone(self, state, kind);
    return .{ .normal = cap.promise };
}

/// Invoke `ep.then(onFulfilled, onRejected)` — calling the element promise's OWN `then` (so a
/// thenable element drives the combinator). If `cap` is given (race fast path), its resolve/reject
/// are the handlers. Returns the `then` call completion (abrupt propagates as an IfAbruptRejectPromise
/// at the call site). `ep` may be any thenable; for the fast %Promise% path it is a native promise.
fn invokeThen(self: *Interpreter, ep: *Object, cap: ?*object_mod.PromiseCapability, on_f: ?*Object, on_r: ?*Object) EvalError!Completion {
    // Fast path: a genuine native promise → attach reactions directly (no observable `then` read).
    if (ep.promise != null and ep.prototype == promiseProto(self)) {
        if (cap) |c| {
            try performPromiseThen(self, ep, c.resolve.object, c.reject.object, null);
        } else {
            try performPromiseThen(self, ep, on_f, on_r, null);
        }
        return .{ .normal = .undefined };
    }
    // General path: Invoke `ep.then(onF, onR)`.
    const then_c = try self.getProperty(.{ .object = ep }, "then");
    if (then_c.isAbrupt()) return then_c;
    if (then_c.normal != .object or !isCallable(then_c.normal.object)) {
        return self.throwError("TypeError", "then is not a function");
    }
    const f: Value = if (cap) |c| c.resolve else if (on_f) |o| .{ .object = o } else .undefined;
    const r: Value = if (cap) |c| c.reject else if (on_r) |o| .{ .object = o } else .undefined;
    return self.callFunction(then_c.normal.object, &.{ f, r }, .{ .object = ep });
}

/// Build one combinator per-element resolve/reject closure (id `promise_combinator_element`),
/// carrying the shared `state` and this element's `index`. `variant` selects the behavior.
pub fn makeCombinatorElement(self: *Interpreter, state: *object_mod.CombinatorState, index: usize, variant: []const u8) EvalError!*Object {
    const f = try Object.createNative(self.arena, .promise_combinator_element, variant);
    f.prototype = self.functionProto();
    f.combinator = state;
    f.combinator_index = index;
    return f;
}

/// The body of a `promise_combinator_element` closure (§27.2.4.1.2 / .2.2 / .3.2). Records this
/// element's settlement into the shared state, then settles the result if it was the last one.
/// `[[AlreadyCalled]]` makes each closure fire at most once.
pub fn promiseCombinatorElement(self: *Interpreter, func: *Object, args: []const Value) EvalError!Completion {
    const state = func.combinator orelse return .{ .normal = .undefined };
    if (func.already_called) return .{ .normal = .undefined }; // §27.2.4.1.2 step 2–4 [[AlreadyCalled]]
    func.already_called = true;
    const arg: Value = if (args.len > 0) args[0] else .undefined;
    const index = func.combinator_index;
    // NOTE: `combinatorSettleIfDone` is the SOLE place that decrements [[Remaining]] (per call) — the
    // element body only records its slot, then asks to settle. This avoids a double decrement.
    if (std.mem.eql(u8, func.native_name, "all")) {
        // §27.2.4.1.2: record the fulfillment value; reject is the result promise's reject closure.
        state.values.items[index] = arg;
        try combinatorSettleIfDone(self, state, .all);
    } else if (std.mem.eql(u8, func.native_name, "all_reject")) {
        // §27.2.4.1: `all` reject → reject the result capability directly (first rejection wins).
        _ = try capabilityReject(self, state.capability, arg);
    } else if (std.mem.eql(u8, func.native_name, "any_reject")) {
        // §27.2.4.3.2: record the rejection reason; if ALL reject, fail with an AggregateError.
        state.values.items[index] = arg;
        try combinatorSettleIfDone(self, state, .any);
    } else if (std.mem.eql(u8, func.native_name, "any_fulfill")) {
        // §27.2.4.3.1 step 8.j: the FIRST fulfillment resolves `any`'s result (later ones are no-ops).
        _ = try capabilityResolve(self, state.capability, arg);
    } else {
        // §27.2.4.2.2/.3 allSettled — build the `{status, value|reason}` record either way.
        const rec = try Object.create(self.arena, self.objectProto());
        if (std.mem.eql(u8, func.native_name, "settled_fulfill")) {
            try rec.set("status", .{ .string = "fulfilled" });
            try rec.set("value", arg);
        } else {
            try rec.set("status", .{ .string = "rejected" });
            try rec.set("reason", arg);
        }
        state.values.items[index] = .{ .object = rec };
        try combinatorSettleIfDone(self, state, .all_settled);
    }
    return .{ .normal = .undefined };
}

/// §27.2.4.1.1 settle the combinator's result once [[Remaining]] reaches 0. `all`/`allSettled`
/// fulfill with the values array; `any` rejects with an AggregateError of the collected reasons.
pub fn combinatorSettleIfDone(self: *Interpreter, state: *object_mod.CombinatorState, comptime kind: CombinatorKind) EvalError!void {
    state.remaining -= 1;
    if (state.remaining != 0) return;
    switch (kind) {
        .all, .all_settled => {
            const arr = try Object.createArray(self.arena, self.arrayProto());
            try arr.elements.appendSlice(self.arena, state.values.items);
            _ = try capabilityResolve(self, state.capability, .{ .object = arr });
        },
        .any => {
            // §27.2.4.3.1 step 8.d.iii / .3.2: every input rejected → reject with an AggregateError
            // whose `errors` is the array of reasons.
            const errs = try Object.createArray(self.arena, self.arrayProto());
            try errs.elements.appendSlice(self.arena, state.values.items);
            const agg = try makeAggregateError(self, .{ .object = errs }, "All promises were rejected");
            _ = try capabilityReject(self, state.capability, agg);
        },
        .race => unreachable,
    }
}

/// §20.5.7.1 build an AggregateError object with `errors` (an array) and `message`, proto-linked to
/// %AggregateError.prototype%. Used by `Promise.any` when every input rejects.
pub fn makeAggregateError(self: *Interpreter, errors: Value, message: []const u8) EvalError!Value {
    const proto = self.globalProto("AggregateError") orelse self.errorProto("Error");
    const err = try Object.create(self.arena, proto);
    try err.set("name", .{ .string = "AggregateError" });
    try err.set("message", .{ .string = message });
    try err.defineData("errors", errors, true, false, true); // §20.5.7.4 own data property
    return .{ .object = err };
}

/// §27.2.5.4 Promise.prototype.then(onFulfilled, onRejected) — `this` must be a promise; attach the
/// (callable-or-ignored) handlers and return the derived result promise.
pub fn promiseThen(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object or this_val.object.promise == null) {
        return self.throwError("TypeError", "Promise.prototype.then called on a non-Promise");
    }
    const on_f = handlerArg(args, 0);
    const on_r = handlerArg(args, 1);
    // §27.2.5.4 step 3: C = SpeciesConstructor(this, %Promise%); resultCapability = NewPromiseCapability(C).
    const sc = try speciesCapability(self, this_val.object);
    const cap = switch (sc) {
        .cap => |c| c,
        .abrupt => |a| return a,
    };
    try performPromiseThen(self, this_val.object, on_f, on_r, cap);
    return .{ .normal = cap.promise };
}

/// §27.2.5.1 Promise.prototype.catch(onRejected) — `this.then(undefined, onRejected)`.
pub fn promiseCatch(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    // §27.2.5.1: catch delegates to `this.then(undefined, onRejected)` — Invoke(this, "then", ...).
    const on_r: Value = if (args.len > 0) args[0] else .undefined;
    const then_c = try self.getProperty(this_val, "then");
    if (then_c.isAbrupt()) return then_c;
    if (then_c.normal != .object or !isCallable(then_c.normal.object)) {
        return self.throwError("TypeError", "then is not a function");
    }
    return self.callFunction(then_c.normal.object, &.{ .undefined, on_r }, this_val);
}

/// §27.2.5.3 Promise.prototype.finally(onFinally) — `this.then(thunk, thrower)` where the thunks run
/// `onFinally()` and then pass through the original value / re-throw the reason. If `onFinally` is
/// not callable, both handlers are it (so `then` treats them as the default pass-through).
pub fn promiseFinally(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    // §27.2.5.3 step 2: `this` must be an Object (not necessarily a native promise — finally calls
    // `this.then`, so a thenable subclass instance works).
    if (this_val != .object) {
        return self.throwError("TypeError", "Promise.prototype.finally called on a non-object");
    }
    // §27.2.5.3 step 4: C = SpeciesConstructor(this, %Promise%) — used to build the thunks' result.
    const on_finally: Value = if (args.len > 0) args[0] else .undefined;
    // Read `then` once (§27.2.5.3 dispatches through `this.then`).
    const then_c = try self.getProperty(this_val, "then");
    if (then_c.isAbrupt()) return then_c;
    if (then_c.normal != .object or !isCallable(then_c.normal.object)) {
        return self.throwError("TypeError", "then is not a function");
    }
    if (on_finally != .object or !isCallable(on_finally.object)) {
        // §27.2.5.3 step 6/8: a non-callable onFinally → both reactions are onFinally itself (so
        // `then` treats them as the default pass-through).
        return self.callFunction(then_c.normal.object, &.{ on_finally, on_finally }, this_val);
    }
    // §27.2.5.3.1/.2 the thunks: each captures onFinally; the value-thunk re-fulfills with the
    // original value after onFinally(), the thrower-thunk re-throws the reason.
    const value_thunk = try Object.createNative(self.arena, .promise_finally_thunk, "value");
    value_thunk.prototype = self.functionProto();
    value_thunk.finally_value = on_finally.object;
    const thrower_thunk = try Object.createNative(self.arena, .promise_finally_thunk, "thrower");
    thrower_thunk.prototype = self.functionProto();
    thrower_thunk.finally_value = on_finally.object;
    return self.callFunction(then_c.normal.object, &.{ .{ .object = value_thunk }, .{ .object = thrower_thunk } }, this_val);
}

/// The finally value/thrower thunk body (§27.2.5.3.1/.2): call the captured onFinally(); on the
/// "value" thunk return the original argument (after awaiting onFinally is M-subset-simplified to a
/// synchronous call — onFinally's own promise is not awaited here); on "thrower" re-throw `arg`.
pub fn promiseFinallyThunk(self: *Interpreter, func: *Object, args: []const Value) EvalError!Completion {
    const arg: Value = if (args.len > 0) args[0] else .undefined;
    const on_finally = func.finally_value orelse return .{ .normal = arg };
    const fc = try self.callFunction(on_finally, &.{}, .undefined);
    if (fc == .throw) return fc; // onFinally threw → propagate (rejects the derived promise)
    if (std.mem.eql(u8, func.native_name, "thrower")) return .{ .throw = arg };
    return .{ .normal = arg };
}

/// The resolve/reject function bodies (§27.2.1.3.2 / §27.2.1.3.1) — settle the captured
/// `promise_slot` with the argument. resolve → ResolvePromise (thenable-aware); reject → RejectPromise.
pub fn promiseResolvingFn(self: *Interpreter, func: *Object, args: []const Value) EvalError!Completion {
    const promise = func.promise_slot orelse return .{ .normal = .undefined };
    const arg: Value = if (args.len > 0) args[0] else .undefined;
    if (func.native == .promise_resolve_fn) {
        try resolvePromise(self, promise, arg);
    } else {
        try resolvePromiseReject(self, promise, arg);
    }
    return .{ .normal = .undefined };
}

/// Runner-injected `$DONE(err)` (Test262 asyncHelpers.js / doneprintHandle.js contract): record the
/// async test's completion. No/undefined/falsy arg → async PASS; a truthy arg → async FAIL (with the
/// argument stringified for diagnostics). Only the FIRST call counts (a re-`$DONE` is ignored, per
/// the harness). Writes the shared `async_done` sink the runner reads after draining the Job queue.
pub fn testDone(self: *Interpreter, args: []const Value) EvalError!Completion {
    const sink = self.async_done orelse return .{ .normal = .undefined };
    if (sink.called) return .{ .normal = .undefined }; // idempotent: first $DONE wins
    sink.called = true;
    const arg: Value = if (args.len > 0) args[0] else .undefined;
    if (arg != .undefined and toBoolean(arg)) {
        sink.failed = true;
        sink.message = self.toString(arg) catch "async test failed";
        if (arg == .object) {
            const nm = arg.object.get("name");
            const ms = arg.object.get("message");
            if (nm != null and nm.? == .string and ms != null and ms.? == .string) {
                sink.message = std.fmt.allocPrint(self.arena, "{s}: {s}", .{ nm.?.string, ms.?.string }) catch sink.message;
            }
        }
    }
    return .{ .normal = .undefined };
}

/// §27.5 %GeneratorPrototype% — the [[Prototype]] of every Generator object (carries
/// `next`/`return`/`throw` + `[Symbol.iterator]`). Stashed under the sentinel global name by
/// `builtins.setup`. Null only in a realm-less unit-test eval (those don't create generators).
pub fn generatorProto(self: *Interpreter) ?*Object {
    const g = self.globals orelse return null;
    const b = g.lookup("%GeneratorPrototype%") orelse return null;
    return if (b.value == .object) b.value.object else null;
}
