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

const core_modules = [_][]const u8{ "path", "path/posix", "path/win32", "fs", "os", "events", "util", "util/types", "url", "assert", "assert/strict", "buffer", "querystring", "test", "timers", "timers/promises", "vm", "net" };

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
    const obj = try Object.create(arena, self.objectProto());
    if (std.mem.eql(u8, name, "fs")) {
        for ([_][]const u8{ "readFileSync", "existsSync", "writeFileSync", "statSync", "readdirSync", "mkdirSync" }) |m|
            try defineCoreMethod(self, obj, name, m);
    } else if (std.mem.eql(u8, name, "os")) {
        for ([_][]const u8{ "platform", "arch", "type", "release", "homedir", "tmpdir", "hostname", "cpus", "endianness", "totalmem", "freemem" }) |m|
            try defineCoreMethod(self, obj, name, m);
        try obj.defineData("EOL", .{ .string = if (is_windows) "\r\n" else "\n" }, true, true, true);
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

// ── shared helper ───────────────────────────────────────────────────────────────

/// ToString an argument via the engine (so a non-string arg coerces like Node's, e.g. a number).
fn argString(self: *Interpreter, v: Value) EvalError!Completion {
    return self.toStringValuePub(v);
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
