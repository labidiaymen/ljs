//! HOST runtime (Node axis, spec 102 — NOT ECMA-262): the CommonJS module system — `require`,
//! `module`/`exports`, and a minimal core-module registry (`path`, a sync `fs` subset, a minimal
//! `os`). Installed host-only by `host_setup` for the `ljs run` entry script; never on the Test262
//! engine surface.
//!
//! Mechanics (Node's minimal algorithm):
//!   • `makeRequire(dir)` builds a `.require_fn` native object carrying its module's directory as a
//!     hidden own `"%dir%"` property. `callNative` receives that `func`, so the per-module dir is read
//!     back off the receiver — one native id, per-instance state.
//!   • `resolve(dir, spec)` → a core-module name OR an absolute file path: core? relative (`./ ../ /`
//!     drive)? try `X`, `X.js`, `X.json`, `X/package.json` main, `X/index.js`; bare? walk up
//!     `<d>/node_modules/<spec>` to the filesystem root.
//!   • `loadModule(abspath)` reads the file. `.json` → `JSON.parse` the content. `.js` → wrap as
//!     `(function (exports, require, module, __filename, __dirname) { <source> })`, parse + run IN THE
//!     CURRENT REALM (the completion of that single expression-statement is the wrapper fn), then call
//!     it with the module's `exports`/child-`require`/`module`/filename/dir. The module's `exports`
//!     identity is cached BEFORE the body runs, so a circular require sees the partial exports.
const std = @import("std");
const builtin = @import("builtin");
const Value = @import("value.zig").Value;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Completion = @import("completion.zig").Completion;
const Parser = @import("parser.zig").Parser;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const module_mod = @import("module.zig");
const interp_module = @import("interp_module.zig");
const host_fs = @import("host_fs.zig");

const path = std.fs.path;

// ── platform-aware path separators (Node's `path.sep` follows the host OS) ────
const is_windows = builtin.os.tag == .windows;

// ════════════════════════════════════════════════════════════════════════════
//  require — per-module factory + dispatch
// ════════════════════════════════════════════════════════════════════════════

/// Build a per-module `require` function bound to `dir` (its module's directory). A `.require_fn`
/// native object with a hidden own `"%dir%"` property, plus `require.cache` (the interpreter's shared
/// file cache reified as a plain object — best-effort) and a `require.resolve` native.
pub fn makeRequire(self: *Interpreter, dir: []const u8) EvalError!*Object {
    const arena = self.arena;
    const function_proto = self.functionProto();
    const req = try Object.createNative(arena, .require_fn, "require");
    req.prototype = function_proto;
    _ = req.properties.orderedRemove("prototype"); // a require fn has no own `prototype`
    try req.defineData("name", .{ .string = "require" }, false, false, true);
    // Hidden own state: the directory relative to which this require resolves specifiers.
    try req.defineData("%dir%", .{ .string = dir }, false, false, true);

    // require.resolve(spec) — a `.require_fn` native flagged with "%resolve%" so dispatch returns the
    // resolved absolute path instead of the exports. Shares the same "%dir%".
    const resolve_fn = try Object.createNative(arena, .require_fn, "resolve");
    resolve_fn.prototype = function_proto;
    _ = resolve_fn.properties.orderedRemove("prototype");
    try resolve_fn.defineData("name", .{ .string = "resolve" }, false, false, true);
    try resolve_fn.defineData("%dir%", .{ .string = dir }, false, false, true);
    try resolve_fn.defineData("%resolve%", .{ .boolean = true }, false, false, true);
    try req.defineData("resolve", .{ .object = resolve_fn }, true, false, true);

    // require.cache — a minimal object (Node exposes the module-cache map here). Empty placeholder.
    const cache_obj = try Object.create(arena, self.objectProto());
    try req.defineData("cache", .{ .object = cache_obj }, true, false, true);
    return req;
}

/// Dispatch a `.require_fn` native (the `func` is the per-module require / its `.resolve`). Reads the
/// bound directory off `func`'s `"%dir%"`; resolves `args[0]` (the specifier) → core module or absolute
/// path; returns the cached exports (or loads the module). A `"%resolve%"`-flagged func returns the
/// resolved path string instead.
pub fn requireFn(self: *Interpreter, func: *Object, args: []const Value) EvalError!Completion {
    const dir = if (func.get("%dir%")) |v| (if (v == .string) v.string else "") else "";
    const is_resolve = func.get("%resolve%") != null;

    const spec_v: Value = if (args.len > 0) args[0] else .undefined;
    if (spec_v != .string) return self.throwError("TypeError", "The \"id\" argument must be of type string");
    const spec = spec_v.string;

    // Core module?
    if (isCoreModule(spec)) {
        const name = coreName(spec);
        if (is_resolve) return .{ .normal = .{ .string = name } };
        return loadCoreModule(self, name);
    }

    const abspath = (try resolvePath(self, dir, spec)) orelse return moduleNotFound(self, spec);
    if (is_resolve) return .{ .normal = .{ .string = abspath } };

    // Cached file module?
    if (self.require_cache.get(abspath)) |exports| return .{ .normal = exports };
    return loadModule(self, abspath);
}

/// Throw `Error` with `code: "MODULE_NOT_FOUND"` (Node's resolution failure).
fn moduleNotFound(self: *Interpreter, spec: []const u8) EvalError!Completion {
    const arena = self.arena;
    const msg = std.fmt.allocPrint(arena, "Cannot find module '{s}'", .{spec}) catch return error.OutOfMemory;
    const err = try Object.create(arena, self.errorProto("Error"));
    err.error_data = true;
    try err.set("name", .{ .string = "Error" });
    try err.set("message", .{ .string = msg });
    try err.defineData("code", .{ .string = "MODULE_NOT_FOUND" }, true, false, true);
    return .{ .throw = .{ .object = err } };
}

// ════════════════════════════════════════════════════════════════════════════
//  resolution
// ════════════════════════════════════════════════════════════════════════════

fn isRelative(spec: []const u8) bool {
    return std.mem.startsWith(u8, spec, "./") or std.mem.startsWith(u8, spec, "../") or
        std.mem.eql(u8, spec, ".") or std.mem.eql(u8, spec, "..");
}

/// Resolve `spec` (relative or bare) against `dir` to an absolute, existing file path, or null.
fn resolvePath(self: *Interpreter, dir: []const u8, spec: []const u8) EvalError!?[]const u8 {
    const arena = self.arena;
    if (isRelative(spec) or path.isAbsolute(spec)) {
        const base = if (path.isAbsolute(spec)) spec else (path.resolve(arena, &.{ dir, spec }) catch return error.OutOfMemory);
        return try resolveAsFileOrDir(self, base);
    }
    // Bare specifier: walk up <d>/node_modules/<pkg> from `dir` to the root. At each level, prefer the
    // package's `"exports"` map (modern packages have no `main`); fall back to the classic
    // file/dir/main/index resolution.
    const split = try splitPackage(self, spec);
    var cur: []const u8 = dir;
    while (true) {
        const pkg_dir = path.resolve(arena, &.{ cur, "node_modules", split.name }) catch return error.OutOfMemory;
        const pkg_json = path.resolve(arena, &.{ pkg_dir, "package.json" }) catch return error.OutOfMemory;
        if (try readFileOpt(self, pkg_json)) |content| {
            if (try parsePackageJson(self, content)) |obj| {
                if (obj.get("exports")) |exports_v| {
                    if (try resolveExports(self, exports_v, split.subpath)) |rel| {
                        const target = path.resolve(arena, &.{ pkg_dir, rel }) catch return error.OutOfMemory;
                        if (try fileExists(self, target)) return target;
                        if (try resolveAsFileOrDir(self, target)) |p| return p;
                    }
                    // `exports` present but the subpath is not exported → do NOT fall through to
                    // legacy resolution (Node treats exports as the authoritative gate) for this pkg.
                }
            }
        }
        // No exports (or no package.json): classic resolution of the full spec under this node_modules.
        const candidate = path.resolve(arena, &.{ cur, "node_modules", spec }) catch return error.OutOfMemory;
        if (try resolveAsFileOrDir(self, candidate)) |p| return p;
        const parent = path.dirname(cur) orelse break;
        if (std.mem.eql(u8, parent, cur)) break; // reached the root
        cur = parent;
    }
    return null;
}

/// LOAD_AS_FILE then LOAD_AS_DIRECTORY for an absolute base path. Tries `X`, `X.js`, `X.json`, then
/// `X/package.json`'s `main`, then `X/index.js` / `X/index.json`.
fn resolveAsFileOrDir(self: *Interpreter, base: []const u8) EvalError!?[]const u8 {
    const arena = self.arena;
    // LOAD_AS_FILE: exact, then with extensions.
    if (try fileExists(self, base)) return base;
    for ([_][]const u8{ ".js", ".json" }) |ext| {
        const p = std.fmt.allocPrint(arena, "{s}{s}", .{ base, ext }) catch return error.OutOfMemory;
        if (try fileExists(self, p)) return p;
    }
    // LOAD_AS_DIRECTORY: package.json "main", then index.js / index.json.
    const pkg = path.resolve(arena, &.{ base, "package.json" }) catch return error.OutOfMemory;
    if (try readFileOpt(self, pkg)) |content| {
        if (try readPackageMain(self, content)) |main_rel| {
            const main_base = path.resolve(arena, &.{ base, main_rel }) catch return error.OutOfMemory;
            if (try resolveAsFileOrDir(self, main_base)) |p| return p;
        }
    }
    for ([_][]const u8{ "index.js", "index.json" }) |idx| {
        const p = path.resolve(arena, &.{ base, idx }) catch return error.OutOfMemory;
        if (try fileExists(self, p)) return p;
    }
    return null;
}

/// Extract the `"main"` field from a package.json's source. Parsed via the engine's JSON.parse (so
/// any valid package.json works); returns null when absent / not a string.
fn readPackageMain(self: *Interpreter, content: []const u8) EvalError!?[]const u8 {
    const parsed = try jsonParse(self, content);
    if (parsed.isAbrupt()) return null; // a malformed package.json → no main (fall through to index)
    if (parsed.normal != .object) return null;
    const main_v = parsed.normal.object.get("main") orelse return null;
    if (main_v != .string) return null;
    if (main_v.string.len == 0) return null;
    return main_v.string;
}

// ── package.json "exports" / "type" resolution (Node subpath + conditional exports) ──────────────

/// Parse a package.json's source into its top-level object Value (or null on malformed JSON).
fn parsePackageJson(self: *Interpreter, content: []const u8) EvalError!?*Object {
    const parsed = try jsonParse(self, content);
    if (parsed.isAbrupt() or parsed.normal != .object) return null;
    return parsed.normal.object;
}

/// `"type"` field of a package.json object ("module" / "commonjs" / null).
fn packageType(pkg: *Object) ?[]const u8 {
    if (pkg.get("type")) |v| if (v == .string) return v.string;
    return null;
}

/// Split a bare specifier into its package name and the requested subpath (`"."` or `"./sub"`).
/// Scoped packages (`@scope/name`) keep both segments in the name.
const PkgSplit = struct { name: []const u8, subpath: []const u8 };
fn splitPackage(self: *Interpreter, spec: []const u8) EvalError!PkgSplit {
    var slash_count: usize = if (std.mem.startsWith(u8, spec, "@")) @as(usize, 2) else 1;
    var i: usize = 0;
    var name_end: usize = spec.len;
    while (i < spec.len) : (i += 1) {
        if (spec[i] == '/') {
            slash_count -= 1;
            if (slash_count == 0) {
                name_end = i;
                break;
            }
        }
    }
    const name = spec[0..name_end];
    if (name_end >= spec.len) return .{ .name = name, .subpath = "." };
    const rest = spec[name_end + 1 ..];
    const sub = std.fmt.allocPrint(self.arena, "./{s}", .{rest}) catch return error.OutOfMemory;
    return .{ .name = name, .subpath = sub };
}

/// The condition names we resolve for, in priority order (the CommonJS `require` world). `"import"` is
/// intentionally absent — an ESM target is reached via `"node"`/`"default"` and then detected by
/// extension / `"type"` (see `isEsmFile`).
const require_conditions = [_][]const u8{ "node", "require", "default" };

/// Resolve a package's `"exports"` map for `subpath` (`"."`/`"./x"`) → a package-relative target
/// (e.g. `"./dist/index.js"`), or null if unmapped. Handles string targets, conditional-object
/// targets (recursing the condition set), the subpath-map vs conditions-for-"." ambiguity, and a
/// single trailing `*` wildcard.
fn resolveExports(self: *Interpreter, exports_v: Value, subpath: []const u8) EvalError!?[]const u8 {
    // A bare string export is the `"."` target.
    if (exports_v == .string) return if (std.mem.eql(u8, subpath, ".")) exports_v.string else null;
    if (exports_v != .object) return null;
    const obj = exports_v.object;

    // Distinguish a SUBPATH map (keys start with ".") from a CONDITIONS object (keys are condition
    // names) by the first own key.
    var it = obj.properties.iterator();
    const first = it.next();
    const is_subpath_map = if (first) |e| std.mem.startsWith(u8, e.key_ptr.*, ".") else false;

    if (is_subpath_map) {
        // Exact subpath match first.
        if (obj.get(subpath)) |t| return resolveExportTarget(self, t);
        // Wildcard: a key like "./lib/*" mapping to "./lib/*.js".
        var it2 = obj.properties.iterator();
        while (it2.next()) |e| {
            const key = e.key_ptr.*;
            if (std.mem.indexOfScalar(u8, key, '*')) |star| {
                const prefix = key[0..star];
                const suffix = key[star + 1 ..];
                if (std.mem.startsWith(u8, subpath, prefix) and std.mem.endsWith(u8, subpath, suffix) and subpath.len >= prefix.len + suffix.len) {
                    const matched = subpath[prefix.len .. subpath.len - suffix.len];
                    if (e.value_ptr.payload == .data and e.value_ptr.payload.data == .string) {
                        const tmpl = e.value_ptr.payload.data.string;
                        if (std.mem.indexOfScalar(u8, tmpl, '*')) |tstar| {
                            return std.fmt.allocPrint(self.arena, "{s}{s}{s}", .{ tmpl[0..tstar], matched, tmpl[tstar + 1 ..] }) catch return error.OutOfMemory;
                        }
                    }
                }
            }
        }
        return null;
    }
    // Conditions object — only valid for the "." subpath.
    if (!std.mem.eql(u8, subpath, ".")) return null;
    return resolveExportTarget(self, exports_v);
}

/// Resolve an export TARGET (a string, or a conditions object) to a package-relative path.
fn resolveExportTarget(self: *Interpreter, target: Value) EvalError!?[]const u8 {
    if (target == .string) return target.string;
    if (target != .object) return null;
    for (require_conditions) |cond| {
        if (target.object.get(cond)) |sub| {
            if (try resolveExportTarget(self, sub)) |p| return p;
        }
    }
    return null;
}

/// Is the resolved file an ES module? `.mjs` → yes, `.cjs`/`.json` → no, `.js` → the nearest enclosing
/// `package.json`'s `"type" === "module"`.
fn isEsmFile(self: *Interpreter, abspath: []const u8, pkg_dir_type: ?[]const u8) EvalError!bool {
    if (std.mem.endsWith(u8, abspath, ".mjs")) return true;
    if (std.mem.endsWith(u8, abspath, ".cjs") or std.mem.endsWith(u8, abspath, ".json")) return false;
    if (std.mem.endsWith(u8, abspath, ".js")) {
        if (pkg_dir_type) |t| return std.mem.eql(u8, t, "module");
        // Walk up for the nearest package.json "type".
        if (try nearestPackageType(self, abspath)) |t| return std.mem.eql(u8, t, "module");
    }
    return false;
}

/// The `"type"` of the nearest `package.json` at or above `file`'s directory (null if none/commonjs).
fn nearestPackageType(self: *Interpreter, file: []const u8) EvalError!?[]const u8 {
    var dir = path.dirname(file) orelse return null;
    while (true) {
        const pkg = path.resolve(self.arena, &.{ dir, "package.json" }) catch return error.OutOfMemory;
        if (try readFileOpt(self, pkg)) |content| {
            if (try parsePackageJson(self, content)) |obj| return packageType(obj);
        }
        const parent = path.dirname(dir) orelse return null;
        if (std.mem.eql(u8, parent, dir)) return null;
        dir = parent;
    }
}

fn fileExists(self: *Interpreter, p: []const u8) EvalError!bool {
    const st = std.Io.Dir.cwd().statFile(self.io, p, .{}) catch return false;
    return st.kind == .file;
}

/// Read a file's bytes (arena-owned), or null if it does not exist / cannot be read.
fn readFileOpt(self: *Interpreter, p: []const u8) EvalError!?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(self.io, p, self.arena, .limited(16 << 20)) catch return null;
}

// ════════════════════════════════════════════════════════════════════════════
//  module loading + execution (in-realm wrapper exec)
// ════════════════════════════════════════════════════════════════════════════

/// Load + evaluate a module at `abspath` (an existing absolute file path). `.json` → JSON.parse the
/// content. `.js` (or other) → wrap + run-in-realm + call the wrapper. Caches `module.exports` BEFORE
/// running a `.js` body (circular-require safety), returns the final exports.
fn loadModule(self: *Interpreter, abspath: []const u8) EvalError!Completion {
    const arena = self.arena;
    const content = (try readFileOpt(self, abspath)) orelse return moduleNotFound(self, abspath);

    // .json → exports = JSON.parse(content).
    if (std.mem.endsWith(u8, abspath, ".json")) {
        const parsed = try jsonParse(self, content);
        if (parsed.isAbrupt()) return parsed;
        self.require_cache.put(arena, abspath, parsed.normal) catch return error.OutOfMemory;
        return parsed;
    }

    // ESM target (`.mjs`, or `.js` under `"type":"module"`) → load + evaluate as a module graph in the
    // CURRENT realm; `module.exports` is the §10.4.6 namespace object (named exports + `default`).
    if (try isEsmFile(self, abspath, null)) return loadEsm(self, abspath, content);

    const dir = path.dirname(abspath) orelse abspath;

    // module = { exports: {}, id, filename, loaded:false, paths:[] }.
    const exports_obj = try Object.create(arena, self.objectProto());
    var exports_v: Value = .{ .object = exports_obj };
    const module_obj = try Object.create(arena, self.objectProto());
    try module_obj.defineData("exports", exports_v, true, true, true);
    try module_obj.defineData("id", .{ .string = abspath }, true, true, true);
    try module_obj.defineData("filename", .{ .string = abspath }, true, true, true);
    try module_obj.defineData("loaded", .{ .boolean = false }, true, true, true);

    // Cache the exports object identity BEFORE running the body (circular require sees the partial
    // exports). Updated to module.exports after the body (the body may reassign module.exports).
    self.require_cache.put(arena, abspath, exports_v) catch return error.OutOfMemory;

    // Build + run the CommonJS wrapper IN THE CURRENT REALM. The single expression-statement's
    // completion value is the wrapper function object.
    const wrapped = std.fmt.allocPrint(
        arena,
        "(function (exports, require, module, __filename, __dirname) {{\n{s}\n}})",
        .{content},
    ) catch return error.OutOfMemory;
    const program = Parser.parseMode(arena, wrapped, false) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return self.throwError("SyntaxError", "module parse error"),
    };
    const wrapper_c = try self.run(program, self.globals.?);
    if (wrapper_c.isAbrupt()) return wrapper_c;
    if (wrapper_c.normal != .object) return self.throwError("Error", "module wrapper did not produce a function");
    const wrapper = wrapper_c.normal.object;

    const child_require = try makeRequire(self, dir);
    const call_args = [_]Value{
        exports_v,
        .{ .object = child_require },
        .{ .object = module_obj },
        .{ .string = abspath },
        .{ .string = dir },
    };
    // spec 119: stamp this module's source + filename while its body runs, so functions DEFINED here
    // map their stack frames to THIS file (not the entry script). Restored after (modules nest).
    const saved_src = self.script_source;
    const saved_name = self.script_name;
    self.script_source = wrapped;
    self.script_name = abspath;
    const body_c = try self.callFunction(wrapper, &call_args, .undefined);
    self.script_source = saved_src;
    self.script_name = saved_name;
    if (body_c.isAbrupt()) return body_c;

    // The body may have reassigned `module.exports`; the authoritative exports is module.exports now.
    exports_v = module_obj.get("exports") orelse exports_v;
    self.require_cache.put(arena, abspath, exports_v) catch return error.OutOfMemory;
    try module_obj.defineData("loaded", .{ .boolean = true }, true, true, true);
    return .{ .normal = exports_v };
}

// ── require(ESM): load + evaluate an ES module graph from CommonJS require ────────────────────────

/// Load an ESM file at `abspath` (already read into `source`): build its module-record graph, link +
/// evaluate it IN THE CURRENT REALM (shares globals/builtins with the running program), drain
/// microtasks, and return the module namespace as `module.exports`. Node's `require(esm)` shape — so
/// `require('pkg').named` and `require('pkg').default` both resolve.
/// HOST entry point: run an ESM file as the program ENTRY (`ljs run x.mjs`). Same machinery as
/// `require(ESM)` — build + link + evaluate the module graph in the host realm (relative imports
/// resolve against `abspath`'s dir; bare/core specifiers via the same loader) — but the namespace is
/// the program's result, not a `require` value. Call AFTER `installHostGlobals`.
pub fn runEsmEntry(self: *Interpreter, abspath: []const u8, source: []const u8) EvalError!Completion {
    self.host_referrer_key = abspath;
    return loadEsm(self, abspath, source);
}

fn loadEsm(self: *Interpreter, abspath: []const u8, source: []const u8) EvalError!Completion {
    const arena = self.arena;
    var graph: std.StringHashMapUnmanaged(*module_mod.ModuleRecord) = .empty;
    const loader = module_mod.ModuleLoader{ .ctx = self, .resolve = esmResolve };
    const root = loadModuleGraph(self, loader, &graph, abspath, source) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return self.throwError("SyntaxError", "ESM parse/resolve error"),
    };

    // runModule sets strict + module `this`; save/restore so the requiring CJS context is unchanged.
    const saved_strict = self.strict;
    const saved_this = self.this_val;
    const saved_referrer = self.host_referrer_key;
    defer {
        self.strict = saved_strict;
        self.this_val = saved_this;
        self.host_referrer_key = saved_referrer;
    }
    const c = try interp_module.runModule(self, root, self.globals.?);
    if (c.isAbrupt()) return c;
    try self.drainJobs(); // settle any Promise reactions the module scheduled (sync packages)

    const ns = try interp_module.moduleNamespace(self, root);
    const ns_v = Value{ .object = ns };
    self.require_cache.put(arena, abspath, ns_v) catch return error.OutOfMemory;
    return .{ .normal = ns_v };
}

/// `ModuleLoader.resolve` for the require(ESM) graph: a core-module specifier (`fs`, `node:crypto`, …)
/// is bridged to a synthetic ESM shim re-exporting the host core module; otherwise resolve the
/// (relative/bare) specifier against the referrer's directory like `require` and read its source.
fn esmResolve(ctx: *anyopaque, referrer_key: []const u8, specifier: []const u8) ?module_mod.ResolvedSource {
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    if (isCoreModule(specifier)) return synthCoreEsm(self, specifier) catch return null;
    const dir = path.dirname(referrer_key) orelse referrer_key;
    const abspath = (resolvePath(self, dir, specifier) catch return null) orelse return null;
    // ESM `import` of a CommonJS (or JSON) module → bridge it to a synthetic ESM shim (default =
    // module.exports, named = its own identifier keys), mirroring Node's CJS-named-export interop. A
    // real ESM file is parsed as a module directly.
    const is_esm = isEsmFile(self, abspath, null) catch false;
    if (!is_esm) return synthCjsEsm(self, abspath) catch return null;
    const src = (readFileOpt(self, abspath) catch return null) orelse return null;
    return .{ .key = abspath, .source = src };
}

/// Bridge an ESM `import … from 'node:fs'` (etc.) to the host CommonJS core module.
fn synthCoreEsm(self: *Interpreter, specifier: []const u8) EvalError!?module_mod.ResolvedSource {
    const arena = self.arena;
    const name = coreName(specifier);
    const exports_c = try loadCoreModule(self, name);
    const gkey = std.fmt.allocPrint(arena, "%coreesm:{s}%", .{name}) catch return error.OutOfMemory;
    const modkey = std.fmt.allocPrint(arena, "coreesm:{s}", .{name}) catch return error.OutOfMemory;
    return try esmShim(self, exports_c.normal, gkey, modkey);
}

/// Bridge an ESM `import … from './thing.js'` where `./thing.js` is CommonJS (or JSON): evaluate it via
/// `require`, then re-export `module.exports` as an ESM shim. So `import x from './cjs'` /
/// `import { y } from './cjs'` bind (default = module.exports; named = its own identifier keys).
fn synthCjsEsm(self: *Interpreter, abspath: []const u8) EvalError!?module_mod.ResolvedSource {
    const arena = self.arena;
    const exports_c = try loadModule(self, abspath);
    if (exports_c.isAbrupt()) return null; // a CJS module that throws on load can't be bridged
    // Path separators (`\`) are invalid in a JS string literal — normalize to `/` for the gkey only.
    const safe = arena.dupe(u8, abspath) catch return error.OutOfMemory;
    for (safe) |*c| if (c.* == '\\') {
        c.* = '/';
    };
    const gkey = std.fmt.allocPrint(arena, "%cjsesm:{s}%", .{safe}) catch return error.OutOfMemory;
    return try esmShim(self, exports_c.normal, gkey, abspath);
}

/// Stash `exports_v` on `globalThis[gkey]` and synthesize an ESM source (cache key `modkey`) that
/// `export default`s it plus re-exports each own identifier-named property (when it's an object).
fn esmShim(self: *Interpreter, exports_v: Value, gkey: []const u8, modkey: []const u8) EvalError!module_mod.ResolvedSource {
    const arena = self.arena;
    if (self.globals) |g| if (g.lookup("%GlobalThis%")) |gb| if (gb.value == .object) {
        try gb.value.object.defineData(gkey, exports_v, true, false, true);
    };
    var src: std.ArrayListUnmanaged(u8) = .empty;
    src.appendSlice(arena, "const __m = globalThis[\"") catch return error.OutOfMemory;
    src.appendSlice(arena, gkey) catch return error.OutOfMemory;
    src.appendSlice(arena, "\"];\nexport default __m;\n") catch return error.OutOfMemory;
    if (exports_v == .object) {
        var it = exports_v.object.properties.iterator();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            if (!isIdentifier(k) or std.mem.eql(u8, k, "default")) continue;
            src.appendSlice(arena, "export const ") catch return error.OutOfMemory;
            src.appendSlice(arena, k) catch return error.OutOfMemory;
            src.appendSlice(arena, " = __m.") catch return error.OutOfMemory;
            src.appendSlice(arena, k) catch return error.OutOfMemory;
            src.appendSlice(arena, ";\n") catch return error.OutOfMemory;
        }
    }
    return .{ .key = modkey, .source = src.items };
}

/// Is `s` a valid JS identifier (ASCII-subset: starts with letter/_/$, then alnum/_/$)?
fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    const c0 = s[0];
    if (!(std.ascii.isAlphabetic(c0) or c0 == '_' or c0 == '$')) return false;
    for (s[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '$')) return false;
    return true;
}

/// Parse + recursively load an ES module graph rooted at `root_key`/`root_source` (mirrors the engine's
/// loadGraph), caching each record by resolved key so a diamond/cycle is shared + terminates.
fn loadModuleGraph(
    self: *Interpreter,
    loader: module_mod.ModuleLoader,
    cache: *std.StringHashMapUnmanaged(*module_mod.ModuleRecord),
    root_key: []const u8,
    root_source: []const u8,
) error{ OutOfMemory, SyntaxError }!*module_mod.ModuleRecord {
    const arena = self.arena;
    if (cache.get(root_key)) |m| return m;
    const program = Parser.parseModule(arena, root_source) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SyntaxError,
    };
    const rec = arena.create(module_mod.ModuleRecord) catch return error.OutOfMemory;
    rec.* = .{ .key = root_key, .program = program };
    cache.put(arena, root_key, rec) catch return error.OutOfMemory;
    var deps: std.ArrayListUnmanaged(*module_mod.ModuleRecord) = .empty;
    for (program.requested_modules) |spec| {
        const resolved = loader.resolve(loader.ctx, root_key, spec) orelse return error.SyntaxError;
        const dep = try loadModuleGraph(self, loader, cache, resolved.key, resolved.source);
        deps.append(arena, dep) catch return error.OutOfMemory;
    }
    rec.deps = deps.items;
    return rec;
}

/// Run the engine's `JSON.parse(text)` on `content`. Returns the parsed Value completion (or an abrupt
/// completion if JSON.parse throws / JSON is unavailable).
fn jsonParse(self: *Interpreter, content: []const u8) EvalError!Completion {
    const g = self.globals orelse return self.throwError("Error", "no realm");
    const json_b = g.lookup("JSON") orelse return self.throwError("Error", "JSON is not available");
    if (json_b.value != .object) return self.throwError("Error", "JSON is not available");
    const parse_v = json_b.value.object.get("parse") orelse return self.throwError("Error", "JSON.parse is not available");
    if (parse_v != .object) return self.throwError("Error", "JSON.parse is not callable");
    return self.callFunction(parse_v.object, &.{.{ .string = content }}, json_b.value);
}

// ════════════════════════════════════════════════════════════════════════════
//  entry-script require (injected as a global for `ljs run`)
// ════════════════════════════════════════════════════════════════════════════

/// HOST: inject `require`/`module`/`exports`/`__filename`/`__dirname` as globals for the top-level
/// entry script, bound to the entry file's directory. Called by `host_setup.installHostGlobals` when a
/// script path is known (`ljs run <file>`). Keeps the entry script-scoped (a minor deviation from
/// Node's full module-wrap — sufficient, and required modules ARE wrapped).
pub fn installEntryRequire(self: *Interpreter, script_path: []const u8, script_dir: []const u8) EvalError!void {
    const arena = self.arena;
    const env = self.globals orelse return;

    const req = try makeRequire(self, script_dir);
    try env.declare("require", .{ .object = req }, true, true);

    const exports_obj = try Object.create(arena, self.objectProto());
    const module_obj = try Object.create(arena, self.objectProto());
    try module_obj.defineData("exports", .{ .object = exports_obj }, true, true, true);
    try module_obj.defineData("id", .{ .string = "." }, true, true, true);
    try module_obj.defineData("filename", .{ .string = script_path }, true, true, true);
    try module_obj.defineData("loaded", .{ .boolean = false }, true, true, true);

    try env.declare("module", .{ .object = module_obj }, true, true);
    try env.declare("exports", .{ .object = exports_obj }, true, true);
    try env.declare("__filename", .{ .string = script_path }, true, true);
    try env.declare("__dirname", .{ .string = script_dir }, true, true);

    // Mirror onto the reified global object too (so `globalThis.require` etc. work).
    if (env.lookup("%GlobalThis%")) |gb| if (gb.value == .object) {
        try gb.value.object.defineData("require", .{ .object = req }, true, false, true);
        try gb.value.object.defineData("module", .{ .object = module_obj }, true, false, true);
        try gb.value.object.defineData("exports", .{ .object = exports_obj }, true, false, true);
    };
}

// ════════════════════════════════════════════════════════════════════════════
//  core module registry: path / fs / os
// ════════════════════════════════════════════════════════════════════════════

const core_modules = [_][]const u8{ "path", "path/posix", "path/win32", "fs", "os", "events", "util", "util/types", "url", "assert", "assert/strict", "buffer", "querystring", "test", "timers", "timers/promises", "vm", "net", "crypto", "stream", "string_decoder", "http", "tty", "zlib" };

/// Strip a `node:` prefix (Node accepts `node:path` etc.).
fn coreName(spec: []const u8) []const u8 {
    if (std.mem.startsWith(u8, spec, "node:")) return spec["node:".len..];
    return spec;
}

fn isCoreModule(spec: []const u8) bool {
    const name = coreName(spec);
    for (core_modules) |m| if (std.mem.eql(u8, name, m)) return true;
    return false;
}

/// Return the (cached, built-once) exports object for a core module `name`.
fn loadCoreModule(self: *Interpreter, name: []const u8) EvalError!Completion {
    if (self.core_module_cache.get(name)) |exports| return .{ .normal = exports };
    const obj = try buildCoreModule(self, name);
    self.core_module_cache.put(self.arena, name, .{ .object = obj }) catch return error.OutOfMemory;
    return .{ .normal = .{ .object = obj } };
}

/// Public wrapper around `loadCoreModule` so other host modules can require a core module's exports
/// (e.g. `node:test`'s `t.assert` aliasing the `assert` module).
pub fn loadCoreModulePub(self: *Interpreter, name: []const u8) EvalError!Completion {
    return loadCoreModule(self, name);
}

/// Build a core module object: a plain object of `.core_module_fn` natives + a few data properties,
/// each native flagged with its module via a hidden own `"%mod%"` property.
fn buildCoreModule(self: *Interpreter, name: []const u8) EvalError!*Object {
    // The `events` module's exports IS the `EventEmitter` class itself (spec 103, host_events.zig).
    if (std.mem.eql(u8, name, "events")) return @import("host_events.zig").build(self);
    // HOST assert (spec 104): `require('assert')` (callable + methods) / `require('assert/strict')`.
    if (std.mem.eql(u8, name, "assert")) return @import("host_assert.zig").build(self);
    if (std.mem.eql(u8, name, "assert/strict")) return @import("host_assert.zig").buildStrict(self);
    // HOST node:test (spec 106 Unit A): require('node:test') / require('test') → the test runner.
    if (std.mem.eql(u8, name, "test")) return @import("host_nodetest.zig").build(self);
    const arena = self.arena;
    if (std.mem.eql(u8, name, "util")) return @import("host_util.zig").build(self); // HOST util (spec 103)
    // HOST path (spec 105): require('path') → an in-engine port of Node's lib/path.js carrying
    // `.posix`/`.win32` full namespaces. `path/posix` / `path/win32` select a sub-namespace.
    if (std.mem.eql(u8, name, "path")) return @import("host_path.zig").build(self);
    if (std.mem.eql(u8, name, "path/posix") or std.mem.eql(u8, name, "path/win32")) {
        // Reuse the cached `path` module so `require('path/posix') === require('path').posix`.
        const root_c = try loadCoreModule(self, "path");
        const root = root_c.normal.object;
        const sub = if (std.mem.eql(u8, name, "path/posix")) "posix" else "win32";
        const v = root.get(sub) orelse return error.OutOfMemory;
        if (v != .object) return error.OutOfMemory;
        return v.object;
    }
    // HOST (spec 105): `require('util/types')` IS `require('util').types` (identity must match).
    if (std.mem.eql(u8, name, "util/types")) {
        const util_c = try loadCoreModule(self, "util");
        if (util_c.normal == .object) {
            if (util_c.normal.object.get("types")) |tv| if (tv == .object) return tv.object;
        }
        return Object.create(self.arena, self.objectProto());
    }
    // HOST (spec 105): `require('querystring')` → parse/decode/stringify/encode/escape/unescape.
    if (std.mem.eql(u8, name, "querystring")) return @import("host_querystring.zig").build(self);
    // HOST (spec 106): `require('timers')` → the timer globals as a module, plus a `.promises`
    // sub-namespace; `require('timers/promises')` IS that same `.promises` object (identity holds).
    if (std.mem.eql(u8, name, "timers")) return @import("host_timers_mod.zig").buildTimers(self);
    if (std.mem.eql(u8, name, "timers/promises")) {
        const timers_c = try loadCoreModule(self, "timers");
        if (timers_c.normal == .object) {
            if (timers_c.normal.object.get("promises")) |pv| if (pv == .object) return pv.object;
        }
        return Object.create(self.arena, self.objectProto());
    }
    // HOST (spec 106): `require('vm')` → runInThisContext/runInNewContext/createContext/Script/...
    if (std.mem.eql(u8, name, "vm")) return @import("host_vm.zig").build(self);
    // HOST (spec 107): `require('net')` / `require('node:net')` → TCP Socket/Server backed by libxev.
    if (std.mem.eql(u8, name, "net")) return @import("host_net.zig").build(self);
    // HOST (spec 108): `require('crypto')` → minimal randomness surface (randomBytes/UUID/getRandomValues).
    if (std.mem.eql(u8, name, "crypto")) return @import("host_crypto.zig").build(self);
    if (std.mem.eql(u8, name, "stream")) return @import("host_stream.zig").build(self);
    if (std.mem.eql(u8, name, "string_decoder")) return @import("host_string_decoder.zig").build(self);
    if (std.mem.eql(u8, name, "http")) return @import("host_http.zig").build(self);
    if (std.mem.eql(u8, name, "zlib")) return @import("host_zlib.zig").build(self);
    const obj = try Object.create(arena, self.objectProto());
    if (std.mem.eql(u8, name, "fs")) {
        for ([_][]const u8{ "readFileSync", "existsSync", "writeFileSync", "statSync", "readdirSync", "mkdirSync", "appendFileSync", "unlinkSync", "rmSync", "rmdirSync", "renameSync", "copyFileSync", "accessSync", "lstatSync", "realpathSync", "readlinkSync", "truncateSync" }) |m|
            try defineCoreMethod(self, obj, name, m);
    } else if (std.mem.eql(u8, name, "os")) {
        for ([_][]const u8{ "platform", "arch", "type", "release", "homedir", "tmpdir", "hostname", "cpus", "endianness", "totalmem", "freemem" }) |m|
            try defineCoreMethod(self, obj, name, m);
        try obj.defineData("EOL", .{ .string = if (is_windows) "\r\n" else "\n" }, true, true, true);
    } else if (std.mem.eql(u8, name, "tty")) {
        // HOST: minimal `tty` — `isatty(fd)` (always false here; packages like debug/colorette/
        // supports-color use it to decide on ANSI colors) + `ReadStream`/`WriteStream` placeholder
        // constructors (referenced for `instanceof` checks).
        try defineCoreMethod(self, obj, name, "isatty");
        for ([_][]const u8{ "ReadStream", "WriteStream" }) |c| {
            const ctor = try Object.createNative(self.arena, .core_module_fn, c);
            ctor.prototype = self.functionProto();
            try ctor.defineData("name", .{ .string = c }, false, false, true);
            try ctor.defineData("%mod%", .{ .string = name }, false, false, true);
            try ctor.defineData("prototype", .{ .object = try Object.create(self.arena, self.objectProto()) }, false, false, false);
            try obj.defineData(c, .{ .object = ctor }, true, false, true);
        }
    } else if (std.mem.eql(u8, name, "url")) {
        // HOST (spec 103): require('url') → { URL, URLSearchParams }.
        return @import("host_url.zig").buildUrlModule(self);
    } else if (std.mem.eql(u8, name, "buffer")) {
        // HOST (spec 105): require('buffer') → { Buffer, kMaxLength, constants, SlowBuffer, ... }.
        return buildBufferModule(self, obj);
    }
    return obj;
}

/// Build the `buffer` core module's exports. `Buffer` is the global ctor (installed by host_buffer);
/// `SlowBuffer` aliases it. Exposes `kMaxLength` and `constants.{MAX_LENGTH,MAX_STRING_LENGTH}`.
fn buildBufferModule(self: *Interpreter, obj: *Object) EvalError!*Object {
    const arena = self.arena;
    // Look up the global `Buffer` constructor (installed as a global by host_buffer).
    const buffer_ctor: Value = blk: {
        const g = self.globals orelse break :blk .undefined;
        if (g.lookup("Buffer")) |b| break :blk b.value;
        break :blk .undefined;
    };
    const host_buffer = @import("host_buffer.zig");
    if (buffer_ctor == .object) {
        try obj.defineData("Buffer", buffer_ctor, true, false, true);
    }
    // SlowBuffer(size) — historically a non-pooled Buffer; a distinct native requiring a number size.
    const slow = try host_buffer.makeNative(self, "SlowBuffer");
    try obj.defineData("SlowBuffer", .{ .object = slow }, true, false, true);
    // isAscii / isUtf8 (module-level helpers over a Buffer/TypedArray/ArrayBuffer view).
    for ([_][]const u8{ "isAscii", "isUtf8" }) |m| {
        const fn_obj = try host_buffer.makeNative(self, m);
        try obj.defineData(m, .{ .object = fn_obj }, true, false, true);
    }
    try obj.defineData("kMaxLength", .{ .number = @floatFromInt(host_buffer.kMaxLength) }, true, false, true);
    try obj.defineData("kStringMaxLength", .{ .number = 536870888 }, true, false, true);
    try obj.defineData("INSPECT_MAX_BYTES", .{ .number = 50 }, true, true, true);

    const constants = try Object.create(arena, self.objectProto());
    try constants.defineData("MAX_LENGTH", .{ .number = @floatFromInt(host_buffer.kMaxLength) }, false, false, true);
    try constants.defineData("MAX_STRING_LENGTH", .{ .number = 536870888 }, false, false, true);
    try obj.defineData("constants", .{ .object = constants }, true, false, true);

    // Buffer.isEncoding-backed standalone helper not exposed; the tests use Buffer.* directly.
    return obj;
}

pub fn defineCoreMethod(self: *Interpreter, target: *Object, mod: []const u8, method: []const u8) EvalError!void {
    const arena = self.arena;
    const fn_obj = try Object.createNative(arena, .core_module_fn, method);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("name", .{ .string = method }, false, false, true);
    try fn_obj.defineData("%mod%", .{ .string = mod }, false, false, true);
    try target.defineData(method, .{ .object = fn_obj }, true, true, true);
}

/// Dispatch a `.core_module_fn` native: the owning module is read off `"%mod%"`, the method off
/// `native_name`.
pub fn coreModuleFn(self: *Interpreter, func: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const mod = if (func.get("%mod%")) |v| (if (v == .string) v.string else "") else "";
    const method = func.native_name;
    if (std.mem.eql(u8, mod, "fs")) return host_fs.fsMethod(self, method, args);
    if (std.mem.eql(u8, mod, "os")) return host_fs.osMethod(self, method, args);
    if (std.mem.eql(u8, mod, "tty")) {
        // `isatty(fd)` → false (no TTY detection); the stream placeholder ctors are no-ops.
        if (std.mem.eql(u8, method, "isatty")) return .{ .normal = .{ .boolean = false } };
        return .{ .normal = .undefined };
    }
    if (std.mem.eql(u8, mod, "fs_stats")) {
        // A Stats predicate (isFile/isDirectory) — read the baked-in flag off the receiver object.
        const recv = if (this_val == .object) this_val.object else return .{ .normal = .{ .boolean = false } };
        const key = if (std.mem.eql(u8, method, "isFile")) "%isFile%" else "%isDirectory%";
        const flag = recv.get(key);
        return .{ .normal = .{ .boolean = flag != null and flag.? == .boolean and flag.?.boolean } };
    }
    return .{ .normal = .undefined };
}
