//! §16.2.1.6 ECMAScript module linking & evaluation — extracted from interpreter.zig as free
//! functions taking `self: *Interpreter` (Zig 0.16 removed `usingnamespace`). Covers Link + Evaluate
//! of a module graph, async (top-level-await) module evaluation, ResolveExport, import-binding
//! instantiation, and namespace-object construction. Behavior-identical to the original methods;
//! calls to OTHER interpreter methods stay `self.foo(...)` (resolved via interpreter.zig wrappers).
const std = @import("std");
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const Completion = @import("completion.zig").Completion;
const Value = @import("value.zig").Value;
const Environment = @import("environment.zig").Environment;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const module_mod = @import("module.zig");
const Parser = @import("parser.zig").Parser;

/// §16.2.1.6.3 ResolveExport result — the resolved binding's owning module + LOCAL name. For a
/// local export this is `(m, local)`; an indirect/star re-export hops to the defining module.
const ResolvedBinding = struct { module: *const module_mod.ModuleRecord, local: []const u8 };

/// One entry of the §16.2.1.6.3 resolveSet (a (module, exportName) pair already in flight) used to
/// break circular indirect/star re-export chains.
const ResolveVisit = struct { module: *const module_mod.ModuleRecord, name: []const u8 };

/// §16.2.1.6 Link + Evaluate a module graph rooted at `root` (whose `deps` were pre-resolved by
/// the loader). Returns the root body's Completion. A SyntaxError surfaced during linking (an
/// unresolvable / ambiguous import binding, §16.2.1.6.3 ResolveExport) is reported as an engine
/// `throw` of a SyntaxError so the runner classifies a `negative: { phase: resolution }` test.
pub fn runModule(self: *Interpreter, root: *module_mod.ModuleRecord, global: *Environment) EvalError!Completion {
    self.strict = true;
    // §9.4.1 module top-level `this` is undefined.
    self.this_val = .undefined;
    try linkModule(self, root, global);
    const lc = try instantiateModule(self, root);
    if (lc.isAbrupt()) return lc;
    // §16.2.1.6 if the root module has top-level await ([[HasTLA]]), evaluate it asynchronously:
    // its body runs on the async substrate and suspends at each `await`. The returned value is the
    // module's evaluation promise, pending until the realm Job-queue drain (driven by the caller)
    // resumes the body to its terminal completion (then fulfilled / rejected). The engine reads the
    // settled promise state after the drain to surface the module's final result.
    if (root.program.has_top_level_await) return runModuleAsync(self, root);
    return evaluateModule(self, root);
}

/// §16.2.1.6 ExecuteAsyncModule — evaluate a top-level-await root module asynchronously. First
/// evaluate its dependencies synchronously (the documented single-awaiting-root scope), then spawn
/// an async body thread (reusing the §27.7 Generator substrate) that runs the module's top-level
/// statements; `await` suspends via the shared handoff. Returns the (pending) module promise; the
/// body resumes during the caller's Job drain, ultimately fulfilling/rejecting that promise.
pub fn runModuleAsync(self: *Interpreter, root: *module_mod.ModuleRecord) EvalError!Completion {
    // Evaluate dependencies first (synchronously) so their bindings are live before the root runs.
    for (root.deps) |dep| {
        const c = try evaluateModule(self, dep);
        if (c.isAbrupt()) return c;
    }
    const env = root.env.?;
    const promise = try self.newPromise();
    const gen = try self.arena.create(object_mod.Generator);
    gen.* = .{
        // SAFETY: a module-body Generator (`module_run` set) has no function object — `func` is
        // never read on this path (`runGeneratorBody` returns at the `module_run` branch before
        // touching `gen.func`, and the async-module body thread never calls the function-body code).
        .func = undefined,
        .args = &.{},
        .this_val = .undefined,
        .home_object = null,
        .is_async = true,
        .promise = promise,
        .module_run = .{ .statements = root.program.statements, .env = env },
    };
    if (self.gen_registry) |reg| try reg.append(self.arena, gen);
    gen.state = .executing;
    gen.resume_kind = .next;
    gen.sent_value = .undefined;
    const t = std.Thread.spawn(.{}, asyncModuleBodyThread, .{ self, root, gen }) catch {
        gen.state = .completed;
        return self.throwError("RangeError", "Cannot spawn async module thread");
    };
    gen.thread = t;
    gen.to_caller.waitUncancelable(self.io); // run to first await / completion
    try self.settleAsyncTransfer(gen);
    root.status = .evaluated;
    return .{ .normal = .{ .object = promise } };
}

/// The async module-body thread (mirrors `asyncBodyThread`): a fresh body interpreter sharing the
/// realm, with `current_gen` set so top-level `await` reaches the handoff. Runs the module's
/// statements; on a normal terminal completion refreshes the module's namespace snapshot (post-eval
/// export values), then posts the terminal transfer (ret/throw) so the caller settles the module
/// promise. The settled promise state is the module's evaluation result the engine reads.
fn asyncModuleBodyThread(parent: *Interpreter, root: *module_mod.ModuleRecord, gen: *object_mod.Generator) void {
    var body: Interpreter = .{
        .arena = parent.arena,
        .step_limit = parent.step_limit,
        .globals = parent.globals,
        .gen_registry = parent.gen_registry,
        .job_queue = parent.job_queue,
        .io = parent.io,
        .current_gen = gen,
        // Top-level-await module code may call the Test262 `$DONE` sink directly (the `[async]`
        // module contract); the body thread needs the shared sink so that call is recorded.
        .async_done = parent.async_done,
        // §13.3.10 a top-level-await module body may contain a dynamic `import()`.
        .module_loader = parent.module_loader,
        .module_cache = parent.module_cache,
        .host_referrer_key = parent.host_referrer_key,
    };
    const comp = body.runGeneratorBody(gen) catch |e| blk: {
        const kind: []const u8 = if (e == error.StepLimitExceeded) "RangeError" else "Error";
        const msg: []const u8 = if (e == error.StepLimitExceeded) "step limit exceeded" else "out of memory";
        const tc = body.throwError(kind, msg) catch break :blk Completion{ .throw = .undefined };
        break :blk tc;
    };
    switch (comp) {
        .normal, .ret => {
            // Refresh the namespace snapshot with the final export values (a populate engine error
            // becomes a throw transfer so it surfaces rather than being silently dropped).
            if (root.namespace) |ns| {
                if (populateNamespace(&body, root, ns)) |_| {
                    gen.transfer_value = .undefined;
                    gen.transfer_kind = .ret;
                } else |_| {
                    const tc = body.throwError("Error", "module namespace finalization failed") catch Completion{ .throw = .undefined };
                    gen.transfer_value = tc.throw;
                    gen.transfer_kind = .throw;
                }
            } else {
                gen.transfer_value = .undefined;
                gen.transfer_kind = .ret;
            }
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

/// §16.2.1.6.2 InnerModuleLinking — create each module's environment and hoist its top-level
/// declarations (depth-first over dependencies, once per module). Import bindings are created in a
/// SECOND pass (`instantiateModule`) once every module's environment exists.
pub fn linkModule(self: *Interpreter, m: *module_mod.ModuleRecord, global: *Environment) EvalError!void {
    if (m.status != .unlinked) return;
    m.status = .linking;
    for (m.deps) |dep| try linkModule(self, dep, global);
    const env = Environment.create(self.arena, global) catch return error.OutOfMemory;
    env.is_var_scope = true; // a Module Environment Record is a var scope (hoist target).
    m.env = env;
    // §16.2.1.6.4 InitializeEnvironment (declaration step): hoist top-level lexical + var +
    // function/class names as TDZ bindings (functions are instantiated when the body runs).
    try self.hoistLexicalNames(m.program.statements, env);
    try self.hoistVarNames(m.program.statements, env);
    m.status = .linked;
}

/// §16.2.1.6.4 InitializeEnvironment (import step) — CreateImportBinding for each ImportEntry,
/// resolving the imported name in the (already-linked) source module. A namespace import binds the
/// source module's namespace object. Recurses over dependencies once (idempotent via status).
pub fn instantiateModule(self: *Interpreter, m: *module_mod.ModuleRecord) EvalError!Completion {
    if (m.status == .evaluating or m.status == .evaluated or m.status == .unlinked) return .{ .normal = .undefined };
    if (m.status == .linking) return .{ .normal = .undefined };
    // Use `evaluating` transiently as an "imports-bound" guard to avoid re-entry on cycles.
    m.status = .evaluating;
    for (m.deps) |dep| {
        const c = try instantiateModule(self, dep);
        if (c.isAbrupt()) {
            m.status = .linked;
            return c;
        }
    }
    const env = m.env.?;
    for (m.program.import_entries) |ie| {
        const src = m.depFor(ie.module_request) orelse {
            m.status = .linked;
            return self.throwError("SyntaxError", "unresolved module specifier");
        };
        if (std.mem.eql(u8, ie.import_name, "*")) {
            const ns = try moduleNamespace(self, src);
            env.declare(ie.local_name, .{ .object = ns }, false, true) catch return error.OutOfMemory;
        } else {
            // §16.2.1.6.3 ResolveExport: find the (module, local) the imported name denotes.
            const rb = resolveExportBinding(self, src, ie.import_name) orelse {
                m.status = .linked;
                return self.throwError("SyntaxError", "the requested module does not provide an export");
            };
            const senv = rb.module.env orelse {
                m.status = .linked;
                return self.throwError("SyntaxError", "unresolved import");
            };
            env.declareImport(ie.local_name, senv, rb.local) catch return error.OutOfMemory;
        }
    }
    m.status = .linked;
    return .{ .normal = .undefined };
}

/// §16.2.1.6.3 ResolveExport — find the module + LOCAL binding name that an exported `name`
/// resolves to, following indirect (`export {a} from "m"`) and star (`export * from "m"`)
/// re-exports. A `resolveSet` breaks circular requests (a cyclic indirect re-export resolves to
/// null, not an infinite loop). Returns null if the name is not resolvable (or is ambiguous).
fn resolveExport(m: *const module_mod.ModuleRecord, name: []const u8, visited: *std.ArrayListUnmanaged(ResolveVisit), a: std.mem.Allocator) ?ResolvedBinding {
    // §16.2.1.6.3 step 1: if (module, name) is already in the resolveSet, this is a circular
    // request → return null (the caller treats it as "not provided here").
    for (visited.items) |v| {
        if (v.module == m and std.mem.eql(u8, v.name, name)) return null;
    }
    visited.append(a, .{ .module = m, .name = name }) catch return null;
    // Direct local / indirect named exports.
    for (m.program.export_entries) |e| {
        const en = e.export_name orelse continue;
        if (!std.mem.eql(u8, en, name)) continue;
        if (e.module_request) |req| {
            const dep = m.depFor(req) orelse return null;
            const inner = e.import_name orelse return null;
            return resolveExport(dep, inner, visited, a);
        }
        return .{ .module = m, .local = e.local_name orelse en };
    }
    // §16.2.1.6.3 star re-exports: search each `export * from "m"` for the name. The first
    // resolution wins (ambiguity across stars is not distinguished in this minimal resolver).
    for (m.program.export_entries) |e| {
        if (e.export_name != null) continue;
        const star = e.import_name orelse continue;
        if (!std.mem.eql(u8, star, "*")) continue;
        const req = e.module_request orelse continue;
        const dep = m.depFor(req) orelse continue;
        if (resolveExport(dep, name, visited, a)) |r| return r;
    }
    return null;
}

/// Resolve an exported `name` to the (module, local) binding it denotes — a thin wrapper over
/// `resolveExport` that owns the resolveSet. Used by import binding instantiation and namespaces.
fn resolveExportBinding(self: *Interpreter, m: *const module_mod.ModuleRecord, name: []const u8) ?ResolvedBinding {
    var visited: std.ArrayListUnmanaged(ResolveVisit) = .empty;
    return resolveExport(m, name, &visited, self.arena);
}

/// §16.2.1.6 InnerModuleEvaluation — evaluate dependencies first (once), then this module's body
/// in its environment with `this` = undefined, strict. Idempotent (a module evaluates once).
pub fn evaluateModule(self: *Interpreter, m: *module_mod.ModuleRecord) EvalError!Completion {
    if (m.status == .evaluated or m.status == .evaluating) return .{ .normal = .undefined };
    m.status = .evaluating;
    for (m.deps) |dep| {
        const c = try evaluateModule(self, dep);
        if (c.isAbrupt()) {
            m.status = .evaluated;
            return c;
        }
    }
    const env = m.env.?;
    const saved_this = self.this_val;
    const saved_strict = self.strict;
    const saved_ref = self.host_referrer_key;
    self.this_val = .undefined;
    self.strict = true;
    self.host_referrer_key = m.key; // a nested dynamic import() resolves relative to THIS module
    defer self.this_val = saved_this;
    defer self.strict = saved_strict;
    defer self.host_referrer_key = saved_ref;
    var last: Completion = .{ .normal = .undefined };
    for (m.program.statements) |stmt| {
        last = try self.evalStmt(stmt, env);
        if (last.isAbrupt()) {
            m.status = .evaluated;
            return last;
        }
    }
    m.status = .evaluated;
    // After evaluation, refresh any namespace object already built for this module so its
    // snapshot reflects the final export values.
    if (m.namespace != null) try populateNamespace(self, m, m.namespace.?);
    return last;
}

/// §10.4.6 build (and cache) the module namespace exotic object for `m`. Properties are the
/// module's exported names, reading the current binding values (snapshot refreshed post-eval).
pub fn moduleNamespace(self: *Interpreter, m: *module_mod.ModuleRecord) EvalError!*Object {
    if (m.namespace) |ns| return ns;
    const ns = Object.create(self.arena, null) catch return error.OutOfMemory;
    m.namespace = ns;
    try populateNamespace(self, m, ns);
    return ns;
}

/// Fill a namespace object with the module's exported names → current values. Local exports read
/// the module env; `export * as ns` / re-exports resolve through the source module.
pub fn populateNamespace(self: *Interpreter, m: *module_mod.ModuleRecord, ns: *Object) EvalError!void {
    for (m.program.export_entries) |e| {
        const name = e.export_name orelse continue;
        if (std.mem.eql(u8, name, "default") == false and e.import_name != null and std.mem.eql(u8, e.import_name.?, "*")) {
            // `export * as sub from "m"` — value is the sub-module's namespace object.
            const req = e.module_request orelse continue;
            const dep = m.depFor(req) orelse continue;
            const sub = try moduleNamespace(self, dep);
            ns.defineData(name, .{ .object = sub }, true, true, false) catch return error.OutOfMemory;
            continue;
        }
        const rb = resolveExportBinding(self, m, name) orelse continue;
        const val = lookupModuleExport(rb.module, rb.local);
        ns.defineData(name, val, true, true, false) catch return error.OutOfMemory;
    }
}

/// Read the current value of a module's local binding (following an import alias), or undefined.
fn lookupModuleExport(m: *const module_mod.ModuleRecord, local: []const u8) Value {
    const env = m.env orelse return .undefined;
    const raw = env.lookupLocal(local) orelse return .undefined;
    const b = Environment.resolveAlias(raw) orelse return .undefined;
    if (!b.initialized) return .undefined;
    return b.value;
}

// ── §13.3.10 / §16.2.1.6 dynamic import() module graph loading ───────────────

/// §16.2.1.6 ContinueDynamicImport — parse + recursively resolve a module graph for a dynamic
/// `import()`, caching every module by resolved key in the interpreter's shared `module_cache` (so a
/// re-import of the same specifier — or a cycle / diamond — reuses the record and evaluates once).
/// Returns the root record, or null when any module fails to parse or a specifier fails to resolve
/// (the caller rejects the import() promise with a SyntaxError). Requires `module_loader` +
/// `module_cache` to be set; returns null if not (a loader-less realm cannot load).
pub fn loadDynamicGraph(self: *Interpreter, key: []const u8, source: []const u8) EvalError!?*module_mod.ModuleRecord {
    const cache = self.module_cache orelse return null;
    if (cache.get(key)) |m| return m;
    const program = Parser.parseModule(self.arena, source) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null, // parse error in the imported module → reject with SyntaxError
    };
    const rec = self.arena.create(module_mod.ModuleRecord) catch return error.OutOfMemory;
    rec.* = .{ .key = key, .program = program };
    cache.put(self.arena, key, rec) catch return error.OutOfMemory; // cache BEFORE recursing (cycles)
    const loader = self.module_loader orelse return null;
    var deps: std.ArrayListUnmanaged(*module_mod.ModuleRecord) = .empty;
    for (program.requested_modules) |spec| {
        const resolved = loader.resolve(loader.ctx, key, spec) orelse return null;
        const dep = (try loadDynamicGraph(self, resolved.key, resolved.source)) orelse return null;
        deps.append(self.arena, dep) catch return error.OutOfMemory;
    }
    rec.deps = deps.items;
    return rec;
}

/// §13.3.10 ImportCall completion: load + Link + Evaluate the module graph at (`key`,`source`) and
/// return its namespace object as a `.normal` completion, or an abrupt `.throw` (a SyntaxError for a
/// parse/resolve failure, an unresolvable-import SyntaxError from linking, or the module body's own
/// thrown error). The caller (`evalImportCall`) maps a `.normal` to FulfillPromise(namespace) and a
/// `.throw` to RejectPromise(reason). The module graph evaluates synchronously (the harness loader is
/// synchronous; the import() promise's reactions still run as Jobs during the drain).
pub fn dynamicImport(self: *Interpreter, key: []const u8, source: []const u8) EvalError!Completion {
    const root = (try loadDynamicGraph(self, key, source)) orelse
        return self.throwError("SyntaxError", "could not load the dynamically imported module");
    const global = self.globals orelse return self.throwError("TypeError", "no realm for dynamic import");
    try linkModule(self, root, global);
    const ic = try instantiateModule(self, root);
    if (ic.isAbrupt()) return ic;
    const ec = try evaluateModule(self, root); // saves/restores this_val/strict/host_referrer_key
    if (ec.isAbrupt()) return ec;
    const ns = try moduleNamespace(self, root);
    return .{ .normal = .{ .object = ns } };
}
