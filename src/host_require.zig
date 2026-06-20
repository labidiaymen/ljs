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
    // Bare specifier: walk up <d>/node_modules/<spec> from `dir` to the root.
    var cur: []const u8 = dir;
    while (true) {
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
    const body_c = try self.callFunction(wrapper, &call_args, .undefined);
    if (body_c.isAbrupt()) return body_c;

    // The body may have reassigned `module.exports`; the authoritative exports is module.exports now.
    exports_v = module_obj.get("exports") orelse exports_v;
    self.require_cache.put(arena, abspath, exports_v) catch return error.OutOfMemory;
    try module_obj.defineData("loaded", .{ .boolean = true }, true, true, true);
    return .{ .normal = exports_v };
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

const core_modules = [_][]const u8{ "path", "fs", "os", "events", "util" };

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

/// Build a core module object: a plain object of `.core_module_fn` natives + a few data properties,
/// each native flagged with its module via a hidden own `"%mod%"` property.
fn buildCoreModule(self: *Interpreter, name: []const u8) EvalError!*Object {
    // The `events` module's exports IS the `EventEmitter` class itself (spec 103, host_events.zig).
    if (std.mem.eql(u8, name, "events")) return @import("host_events.zig").build(self);
    const arena = self.arena;
    if (std.mem.eql(u8, name, "util")) return @import("host_util.zig").build(self); // HOST util (spec 103)
    const obj = try Object.create(arena, self.objectProto());
    if (std.mem.eql(u8, name, "path")) {
        for ([_][]const u8{ "join", "resolve", "dirname", "basename", "extname", "normalize", "isAbsolute", "relative", "parse" }) |m|
            try defineCoreMethod(self, obj, name, m);
        try obj.defineData("sep", .{ .string = if (is_windows) "\\" else "/" }, true, true, true);
        try obj.defineData("delimiter", .{ .string = if (is_windows) ";" else ":" }, true, true, true);
    } else if (std.mem.eql(u8, name, "fs")) {
        for ([_][]const u8{ "readFileSync", "existsSync", "writeFileSync", "statSync", "readdirSync", "mkdirSync" }) |m|
            try defineCoreMethod(self, obj, name, m);
    } else if (std.mem.eql(u8, name, "os")) {
        for ([_][]const u8{ "platform", "arch", "type", "release", "homedir", "tmpdir", "hostname", "cpus", "endianness", "totalmem", "freemem" }) |m|
            try defineCoreMethod(self, obj, name, m);
        try obj.defineData("EOL", .{ .string = if (is_windows) "\r\n" else "\n" }, true, true, true);
    }
    return obj;
}

fn defineCoreMethod(self: *Interpreter, target: *Object, mod: []const u8, method: []const u8) EvalError!void {
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
    if (std.mem.eql(u8, mod, "path")) return pathMethod(self, method, args);
    if (std.mem.eql(u8, mod, "fs")) return fsMethod(self, method, args);
    if (std.mem.eql(u8, mod, "os")) return osMethod(self, method, args);
    if (std.mem.eql(u8, mod, "fs_stats")) {
        // A Stats predicate (isFile/isDirectory) — read the baked-in flag off the receiver object.
        const recv = if (this_val == .object) this_val.object else return .{ .normal = .{ .boolean = false } };
        const key = if (std.mem.eql(u8, method, "isFile")) "%isFile%" else "%isDirectory%";
        const flag = recv.get(key);
        return .{ .normal = .{ .boolean = flag != null and flag.? == .boolean and flag.?.boolean } };
    }
    return .{ .normal = .undefined };
}

// ── path methods ──────────────────────────────────────────────────────────────

/// ToString an argument via the engine (so a non-string path arg coerces like Node's, e.g. a number).
fn argString(self: *Interpreter, v: Value) EvalError!Completion {
    return self.toStringValuePub(v);
}

fn pathMethod(self: *Interpreter, method: []const u8, args: []const Value) EvalError!Completion {
    const arena = self.arena;
    const eq = std.mem.eql;

    if (eq(u8, method, "join")) {
        // Concatenate the string args with the platform sep, then normalize. `path.join()` → ".".
        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        for (args) |a| {
            const sc = try argString(self, a);
            if (sc.isAbrupt()) return sc;
            if (sc.normal.string.len > 0) parts.append(arena, sc.normal.string) catch return error.OutOfMemory;
        }
        if (parts.items.len == 0) return .{ .normal = .{ .string = "." } };
        const joined = joinRaw(arena, parts.items) catch return error.OutOfMemory;
        return .{ .normal = .{ .string = normalizeStr(arena, joined) catch return error.OutOfMemory } };
    }
    if (eq(u8, method, "resolve")) {
        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        for (args) |a| {
            const sc = try argString(self, a);
            if (sc.isAbrupt()) return sc;
            parts.append(arena, sc.normal.string) catch return error.OutOfMemory;
        }
        // path.resolve with no/empty args resolves against the cwd (like Node).
        if (parts.items.len == 0) {
            const cwd = if (self.host_cwd.len > 0) self.host_cwd else (std.process.currentPathAlloc(self.io, arena) catch ".");
            return .{ .normal = .{ .string = cwd } };
        }
        // Prepend the cwd so a fully-relative arg set resolves to an absolute path (Node semantics).
        var full: std.ArrayListUnmanaged([]const u8) = .empty;
        if (self.host_cwd.len > 0) full.append(arena, self.host_cwd) catch return error.OutOfMemory;
        full.appendSlice(arena, parts.items) catch return error.OutOfMemory;
        const r = path.resolve(arena, full.items) catch return error.OutOfMemory;
        return .{ .normal = .{ .string = r } };
    }
    if (eq(u8, method, "dirname")) {
        const sc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (sc.isAbrupt()) return sc;
        const d = path.dirname(sc.normal.string) orelse ".";
        return .{ .normal = .{ .string = if (d.len == 0) "." else d } };
    }
    if (eq(u8, method, "basename")) {
        const sc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (sc.isAbrupt()) return sc;
        var base = path.basename(sc.normal.string);
        // Optional ext suffix to strip (path.basename(p, ext)).
        if (args.len > 1 and args[1] != .undefined) {
            const ec = try argString(self, args[1]);
            if (ec.isAbrupt()) return ec;
            if (ec.normal.string.len > 0 and ec.normal.string.len < base.len and std.mem.endsWith(u8, base, ec.normal.string))
                base = base[0 .. base.len - ec.normal.string.len];
        }
        return .{ .normal = .{ .string = base } };
    }
    if (eq(u8, method, "extname")) {
        const sc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (sc.isAbrupt()) return sc;
        return .{ .normal = .{ .string = extnameStr(sc.normal.string) } };
    }
    if (eq(u8, method, "normalize")) {
        const sc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (sc.isAbrupt()) return sc;
        return .{ .normal = .{ .string = normalizeStr(arena, sc.normal.string) catch return error.OutOfMemory } };
    }
    if (eq(u8, method, "isAbsolute")) {
        const sc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (sc.isAbrupt()) return sc;
        return .{ .normal = .{ .boolean = path.isAbsolute(sc.normal.string) } };
    }
    if (eq(u8, method, "relative")) {
        const fc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (fc.isAbrupt()) return fc;
        const tc = try argString(self, if (args.len > 1) args[1] else .undefined);
        if (tc.isAbrupt()) return tc;
        const cwd = if (self.host_cwd.len > 0) self.host_cwd else ".";
        const r = path.relative(arena, cwd, null, fc.normal.string, tc.normal.string) catch return error.OutOfMemory;
        return .{ .normal = .{ .string = r } };
    }
    if (eq(u8, method, "parse")) {
        const sc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (sc.isAbrupt()) return sc;
        const p = sc.normal.string;
        const obj = try Object.create(arena, self.objectProto());
        const dir = path.dirname(p) orelse "";
        const base = path.basename(p);
        const ext = extnameStr(p);
        const root_len: usize = if (path.isAbsolute(p)) (if (is_windows) @min(p.len, 3) else 1) else 0;
        const name_part = if (ext.len > 0 and ext.len < base.len) base[0 .. base.len - ext.len] else base;
        try obj.defineData("root", .{ .string = p[0..root_len] }, true, true, true);
        try obj.defineData("dir", .{ .string = dir }, true, true, true);
        try obj.defineData("base", .{ .string = base }, true, true, true);
        try obj.defineData("ext", .{ .string = ext }, true, true, true);
        try obj.defineData("name", .{ .string = name_part }, true, true, true);
        return .{ .normal = .{ .object = obj } };
    }
    return .{ .normal = .undefined };
}

/// Concatenate path parts with the platform separator (no normalization).
fn joinRaw(arena: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    const sep: u8 = if (is_windows) '\\' else '/';
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (parts, 0..) |part, i| {
        if (i > 0) try out.append(arena, sep);
        try out.appendSlice(arena, part);
    }
    return out.items;
}

/// `path.extname` — the last `.`-extension of the basename (Node: a leading dot is not an extension,
/// and a trailing dot yields ".").
fn extnameStr(p: []const u8) []const u8 {
    const base = path.basename(p);
    var i: usize = base.len;
    var saw_non_dot = false;
    while (i > 0) {
        i -= 1;
        if (base[i] == '.') {
            if (i == 0) return ""; // ".foo" → no ext
            if (!saw_non_dot) continue; // trailing dots
            return base[i..];
        }
        saw_non_dot = true;
    }
    return "";
}

/// `path.normalize` — collapse `.`/`..` segments and duplicate separators, preserving the platform
/// separator and a leading absolute marker. Built on `path.resolve`-style semantics but pure-string
/// (does not consult the cwd).
fn normalizeStr(arena: std.mem.Allocator, p: []const u8) ![]const u8 {
    if (p.len == 0) return ".";
    const sep: u8 = if (is_windows) '\\' else '/';
    const is_abs = path.isAbsolute(p);
    const had_trailing = p.len > 0 and (p[p.len - 1] == '/' or p[p.len - 1] == '\\');

    var segs: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, p, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (segs.items.len > 0 and !std.mem.eql(u8, segs.items[segs.items.len - 1], "..")) {
                _ = segs.pop();
            } else if (!is_abs) {
                try segs.append(arena, "..");
            }
            continue;
        }
        try segs.append(arena, seg);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (is_abs and !is_windows) try out.append(arena, sep);
    for (segs.items, 0..) |seg, i| {
        if (i > 0) try out.append(arena, sep);
        try out.appendSlice(arena, seg);
    }
    if (out.items.len == 0) return if (is_abs) (if (is_windows) "\\" else "/") else ".";
    if (had_trailing) try out.append(arena, sep);
    return out.items;
}

// ── fs methods (sync subset) ────────────────────────────────────────────────────

fn fsMethod(self: *Interpreter, method: []const u8, args: []const Value) EvalError!Completion {
    const arena = self.arena;
    const eq = std.mem.eql;

    if (eq(u8, method, "readFileSync")) {
        const pc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (pc.isAbrupt()) return pc;
        const content = std.Io.Dir.cwd().readFileAlloc(self.io, pc.normal.string, arena, .limited(64 << 20)) catch
            return fsError(self, "ENOENT", method, pc.normal.string);
        // An encoding (string arg / { encoding } option) → return a string; else a Buffer.
        var enc: ?[]const u8 = null;
        if (args.len > 1 and args[1] == .string) enc = args[1].string;
        if (args.len > 1 and args[1] == .object) {
            if (args[1].object.get("encoding")) |ev| if (ev == .string) {
                enc = ev.string;
            };
        }
        if (enc != null and !std.mem.eql(u8, enc.?, "buffer")) {
            return .{ .normal = .{ .string = content } };
        }
        // No encoding → a Buffer of the bytes.
        const buf = @import("host_buffer.zig").makeBufferFromBytes(self, content) catch return error.OutOfMemory;
        return .{ .normal = .{ .object = buf } };
    }
    if (eq(u8, method, "existsSync")) {
        const pc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (pc.isAbrupt()) return pc;
        const ok = blk: {
            std.Io.Dir.cwd().access(self.io, pc.normal.string, .{}) catch break :blk false;
            break :blk true;
        };
        return .{ .normal = .{ .boolean = ok } };
    }
    if (eq(u8, method, "writeFileSync")) {
        const pc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (pc.isAbrupt()) return pc;
        var bytes: []const u8 = "";
        const dc = try dataBytes(self, if (args.len > 1) args[1] else .undefined, &bytes);
        if (dc.isAbrupt()) return dc;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = pc.normal.string, .data = bytes }) catch
            return fsError(self, "EACCES", method, pc.normal.string);
        return .{ .normal = .undefined };
    }
    if (eq(u8, method, "statSync")) {
        const pc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (pc.isAbrupt()) return pc;
        const st = std.Io.Dir.cwd().statFile(self.io, pc.normal.string, .{}) catch
            return fsError(self, "ENOENT", method, pc.normal.string);
        return .{ .normal = .{ .object = try makeStats(self, st) } };
    }
    if (eq(u8, method, "readdirSync")) {
        const pc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (pc.isAbrupt()) return pc;
        return readdir(self, pc.normal.string, method);
    }
    if (eq(u8, method, "mkdirSync")) {
        const pc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (pc.isAbrupt()) return pc;
        // { recursive: true } → makePath; else a single makeDir.
        var recursive = false;
        if (args.len > 1 and args[1] == .object) {
            if (args[1].object.get("recursive")) |rv| recursive = (rv == .boolean and rv.boolean);
        }
        if (recursive) {
            std.Io.Dir.cwd().createDirPath(self.io, pc.normal.string) catch
                return fsError(self, "EACCES", method, pc.normal.string);
        } else {
            std.Io.Dir.cwd().createDir(self.io, pc.normal.string, .default_dir) catch
                return fsError(self, "EEXIST", method, pc.normal.string);
        }
        return .{ .normal = .undefined };
    }
    return .{ .normal = .undefined };
}

/// Coerce `writeFileSync`'s data arg to bytes into `out`: a Buffer/Uint8Array → its bytes; else
/// ToString. Returns a normal completion on success (writing through `out`), or an abrupt completion
/// (a throwing ToString) which the caller propagates.
fn dataBytes(self: *Interpreter, v: Value, out: *[]const u8) EvalError!Completion {
    if (v == .object) {
        if (v.object.typed_array) |ta| {
            if (ta.buffer.array_buffer) |ab| {
                const start = ta.byte_offset;
                const end = start + ta.array_length;
                if (end <= ab.bytes.len) {
                    out.* = ab.bytes[start..end];
                    return .{ .normal = .undefined };
                }
            }
        }
    }
    const sc = try argString(self, v);
    if (sc.isAbrupt()) return sc;
    out.* = sc.normal.string;
    return .{ .normal = .undefined };
}

/// A minimal `fs.Stats` object: `{ size, isFile(), isDirectory() }` (booleans baked in via hidden props
/// read by the predicate natives — but for simplicity we expose them as plain data + closure-free
/// natives that read a hidden `%kind%`).
fn makeStats(self: *Interpreter, st: std.Io.File.Stat) EvalError!*Object {
    const arena = self.arena;
    const obj = try Object.create(arena, self.objectProto());
    try obj.defineData("size", .{ .number = @floatFromInt(st.size) }, true, true, true);
    const is_file = st.kind == .file;
    const is_dir = st.kind == .directory;
    try obj.defineData("%isFile%", .{ .boolean = is_file }, false, false, true);
    try obj.defineData("%isDirectory%", .{ .boolean = is_dir }, false, false, true);
    try defineCoreMethod(self, obj, "fs_stats", "isFile");
    try defineCoreMethod(self, obj, "fs_stats", "isDirectory");
    return obj;
}

/// Read a directory's entries into a JS array of name strings.
fn readdir(self: *Interpreter, dir_path: []const u8, method: []const u8) EvalError!Completion {
    const arena = self.arena;
    var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch
        return fsError(self, "ENOENT", method, dir_path);
    defer dir.close(self.io);
    const arr = try Object.createArray(arena, self.arrayProto());
    var it = dir.iterate();
    var i: usize = 0;
    while (it.next(self.io) catch null) |entry| {
        const name = arena.dupe(u8, entry.name) catch return error.OutOfMemory;
        try arr.arraySet(arena, i, .{ .string = name });
        i += 1;
    }
    return .{ .normal = .{ .object = arr } };
}

/// Build + throw a Node-style fs error with a `code` property.
fn fsError(self: *Interpreter, code: []const u8, syscall: []const u8, p: []const u8) EvalError!Completion {
    const arena = self.arena;
    const msg = std.fmt.allocPrint(arena, "{s}: {s} '{s}'", .{ code, syscall, p }) catch return error.OutOfMemory;
    const err = try Object.create(arena, self.errorProto("Error"));
    err.error_data = true;
    try err.set("name", .{ .string = "Error" });
    try err.set("message", .{ .string = msg });
    try err.defineData("code", .{ .string = code }, true, false, true);
    try err.defineData("syscall", .{ .string = syscall }, true, false, true);
    try err.defineData("path", .{ .string = p }, true, false, true);
    return .{ .throw = .{ .object = err } };
}

// ── os methods (minimal) ────────────────────────────────────────────────────────

fn osMethod(self: *Interpreter, method: []const u8, args: []const Value) EvalError!Completion {
    _ = args;
    const arena = self.arena;
    const eq = std.mem.eql;
    if (eq(u8, method, "platform")) return .{ .normal = .{ .string = osPlatform() } };
    if (eq(u8, method, "arch")) return .{ .normal = .{ .string = osArch() } };
    if (eq(u8, method, "type")) return .{ .normal = .{ .string = osType() } };
    if (eq(u8, method, "release")) return .{ .normal = .{ .string = "0.0.0" } };
    if (eq(u8, method, "endianness")) return .{ .normal = .{ .string = if (builtin.cpu.arch.endian() == .little) "LE" else "BE" } };
    if (eq(u8, method, "hostname")) return .{ .normal = .{ .string = "localhost" } };
    if (eq(u8, method, "totalmem")) return .{ .normal = .{ .number = 0 } };
    if (eq(u8, method, "freemem")) return .{ .normal = .{ .number = 0 } };
    if (eq(u8, method, "cpus")) return .{ .normal = .{ .object = try Object.createArray(arena, self.arrayProto()) } };
    if (eq(u8, method, "homedir")) {
        const home = osEnv(self, if (is_windows) "USERPROFILE" else "HOME") orelse (if (is_windows) "C:\\" else "/");
        return .{ .normal = .{ .string = home } };
    }
    if (eq(u8, method, "tmpdir")) {
        const tmp = osEnv(self, if (is_windows) "TEMP" else "TMPDIR") orelse (if (is_windows) "C:\\Windows\\Temp" else "/tmp");
        return .{ .normal = .{ .string = tmp } };
    }
    return .{ .normal = .undefined };
}

/// Read an env var off the installed `process.env` (so os.homedir/tmpdir reflect the run's environment).
fn osEnv(self: *Interpreter, key: []const u8) ?[]const u8 {
    const g = self.globals orelse return null;
    const proc = g.lookup("process") orelse return null;
    if (proc.value != .object) return null;
    const env_v = proc.value.object.get("env") orelse return null;
    if (env_v != .object) return null;
    const v = env_v.object.get(key) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}

fn osPlatform() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "win32",
        .linux => "linux",
        .macos => "darwin",
        .freebsd => "freebsd",
        .openbsd => "openbsd",
        else => @tagName(builtin.os.tag),
    };
}
fn osArch() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "x64",
        .x86 => "ia32",
        .aarch64 => "arm64",
        .arm => "arm",
        else => @tagName(builtin.cpu.arch),
    };
}
fn osType() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "Windows_NT",
        .linux => "Linux",
        .macos => "Darwin",
        else => @tagName(builtin.os.tag),
    };
}
