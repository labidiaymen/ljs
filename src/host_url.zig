//! HOST runtime (Node axis, spec 103 — NOT ECMA-262): the WHATWG `URL` / `URLSearchParams` globals
//! and `TextEncoder` / `TextDecoder`. Installed host-only as GLOBALS (via `host_setup`) and — for
//! `URL`/`URLSearchParams` — as the `require('url')` core module. NEVER on the Test262 engine surface
//! (the conformance realm installs none of these), so 0 Test262 regressions by construction.
//!
//! Mechanics:
//!   • Each constructor/method is a `.url_method` native whose `native_name` selects the operation;
//!     a hidden own `"%kind%"` on the function distinguishes the family (URL ctor, URLSearchParams
//!     ctor, the two text-codec ctors, and the prototype-method families).
//!   • A constructor invoked via `new` receives the freshly-created instance as `this_val` (see
//!     `interp_expr.constructNT`, which lists `.url_method` as constructible). The constructor parses
//!     its input and stores the result as own data properties / a hidden slot on the instance.
//!   • URL stores each parsed component as an own data property (href/protocol/...). `searchParams`
//!     is a SNAPSHOT URLSearchParams built from the query; mutating it does NOT write back to
//!     `url.search` (a documented first-cut gap).
//!   • URLSearchParams keeps its pairs as a hidden own `"%pairs%"` JS Array of 2-element [key,value]
//!     arrays, so get/set/append/delete mutate that array and the iterators reuse the engine's array
//!     iterator (`interp_collection.makeArrayIterator`).
const std = @import("std");
const Value = @import("value.zig").Value;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;

// ════════════════════════════════════════════════════════════════════════════
//  install (globals) + buildUrlModule (require('url'))
// ════════════════════════════════════════════════════════════════════════════

/// Build + declare the four WHATWG globals (`URL`, `URLSearchParams`, `TextEncoder`, `TextDecoder`)
/// on `self.globals`, and mirror them onto the reified global object. Called from
/// `host_setup.installHostGlobals`.
pub fn install(self: *Interpreter) EvalError!void {
    const env = self.globals orelse return;
    const ctors = [_]struct { name: []const u8, ctor: *Object }{
        .{ .name = "URL", .ctor = try makeUrlCtor(self) },
        .{ .name = "URLSearchParams", .ctor = try makeUrlSearchParamsCtor(self) },
        .{ .name = "TextEncoder", .ctor = try makeTextEncoderCtor(self) },
        .{ .name = "TextDecoder", .ctor = try makeTextDecoderCtor(self) },
    };
    for (ctors) |p| {
        try env.declare(p.name, .{ .object = p.ctor }, true, true);
        if (env.lookup("%GlobalThis%")) |gb| if (gb.value == .object)
            try gb.value.object.defineData(p.name, .{ .object = p.ctor }, true, false, true);
    }
}

/// `require('url')` → an object exposing the WHATWG `URL`/`URLSearchParams` PLUS the legacy `url`
/// module surface (`parse`/`format`/`resolve`/`Url`/`domainToASCII`/`domainToUnicode`/
/// `pathToFileURL`/`fileURLToPath`/`urlToHttpOptions`). The WHATWG ctors here are FRESH ones (so the
/// module's `URL` is the requireable copy); they share the same `.url_method` dispatch.
pub fn buildUrlModule(self: *Interpreter) EvalError!*Object {
    const obj = try Object.create(self.arena, self.objectProto());
    const url_ctor = try makeUrlCtor(self);
    try obj.defineData("URL", .{ .object = url_ctor }, true, true, true);
    try obj.defineData("URLSearchParams", .{ .object = try makeUrlSearchParamsCtor(self) }, true, true, true);

    // Legacy `url` module free functions (each a `.url_method` flagged "url_legacy").
    const legacy = [_][]const u8{
        "parse",            "format",          "resolve",       "resolveObject",
        "domainToASCII",    "domainToUnicode", "pathToFileURL", "fileURLToPath",
        "urlToHttpOptions",
    };
    for (legacy) |m| {
        const fn_obj = try makeMethod(self, "url_legacy", m);
        try obj.defineData(m, .{ .object = fn_obj }, true, true, true);
    }
    // The legacy `url.Url` constructor (an empty-instance ctor — Node's `new url.Url()`).
    const url_legacy_ctor = try makeMethod(self, "url_legacy_ctor", "Url");
    try url_legacy_ctor.defineData("prototype", .{ .object = try Object.create(self.arena, self.objectProto()) }, false, false, false);
    try obj.defineData("Url", .{ .object = url_legacy_ctor }, true, true, true);
    return obj;
}

/// Install the WHATWG `URL` statics (`URL.canParse`/`URL.parse`/`URL.createObjectURL`/
/// `URL.revokeObjectURL`) as own properties of the `URL` constructor. Shared by the global ctor and
/// the `require('url')` copy.
fn installUrlStatics(self: *Interpreter, ctor: *Object) EvalError!void {
    const statics = [_][]const u8{ "canParse", "parse", "createObjectURL", "revokeObjectURL" };
    for (statics) |s| {
        const fn_obj = try makeMethod(self, "url_static", s);
        try ctor.defineData(s, .{ .object = fn_obj }, true, false, true);
    }
}

// ── constructor / prototype builders ─────────────────────────────────────────

/// Make a `.url_method` native function flagged with `kind` (read off `"%kind%"` in dispatch) and
/// selecting `name` (the operation, via `native_name`). Proto-linked to %Function.prototype%, no own
/// `prototype` (a method).
fn makeMethod(self: *Interpreter, kind: []const u8, name: []const u8) EvalError!*Object {
    const fn_obj = try Object.createNative(self.arena, .url_method, name);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("name", .{ .string = name }, false, false, true);
    try fn_obj.defineData("%kind%", .{ .string = kind }, false, false, true);
    return fn_obj;
}

/// Make a constructor function (`ctor_kind` selects the family) with a `prototype` object whose
/// `methods` are `.url_method` natives and `getters` are get-only accessor pairs (flagged
/// `proto_kind`).
fn makeCtor(self: *Interpreter, ctor_kind: []const u8, proto_kind: []const u8, ctor_name: []const u8, methods: []const []const u8, getters: []const []const u8) EvalError!*Object {
    const arena = self.arena;
    const proto = try Object.create(arena, self.objectProto());

    const ctor = try Object.createNative(arena, .url_method, ctor_name);
    ctor.prototype = self.functionProto();
    try ctor.defineData("name", .{ .string = ctor_name }, false, false, true);
    try ctor.defineData("%kind%", .{ .string = ctor_kind }, false, false, true);
    try ctor.defineData("prototype", .{ .object = proto }, false, false, false);
    try proto.defineData("constructor", .{ .object = ctor }, true, false, true);

    for (methods) |m| {
        const fn_obj = try makeMethod(self, proto_kind, m);
        try proto.defineData(m, .{ .object = fn_obj }, true, false, true);
    }
    for (getters) |g| {
        const getter = try makeMethod(self, proto_kind, g);
        try proto.defineAccessorEx(g, getter, null, false);
    }
    return ctor;
}

fn makeUrlCtor(self: *Interpreter) EvalError!*Object {
    const ctor = try makeCtor(self, "url_ctor", "url", "URL", &.{ "toString", "toJSON" }, &.{});
    try installUrlStatics(self, ctor);
    return ctor;
}

fn makeUrlSearchParamsCtor(self: *Interpreter) EvalError!*Object {
    const ctor = try makeCtor(
        self,
        "usp_ctor",
        "usp",
        "URLSearchParams",
        &.{ "get", "getAll", "set", "append", "delete", "has", "forEach", "toString", "keys", "values", "entries", "sort" },
        &.{},
    );
    // §URLSearchParams.prototype[Symbol.iterator] === entries.
    if (self.wellKnownIterator()) |iter_sym| {
        const proto = ctor.get("prototype").?.object;
        const entries_fn = proto.get("entries").?;
        try proto.defineSymbolData(iter_sym, entries_fn, true, false, true);
    }
    return ctor;
}

fn makeTextEncoderCtor(self: *Interpreter) EvalError!*Object {
    return makeCtor(self, "te_ctor", "te", "TextEncoder", &.{ "encode", "encodeInto" }, &.{"encoding"});
}

fn makeTextDecoderCtor(self: *Interpreter) EvalError!*Object {
    return makeCtor(self, "td_ctor", "td", "TextDecoder", &.{"decode"}, &.{ "encoding", "fatal", "ignoreBOM" });
}

// ════════════════════════════════════════════════════════════════════════════
//  dispatch
// ════════════════════════════════════════════════════════════════════════════

/// Dispatch a `.url_method` native. `func` carries the family in `"%kind%"`; `this_val` is the
/// receiver (the new instance for a constructor, the URL/USP/codec instance for a method).
pub fn method(self: *Interpreter, func: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const kind = if (func.get("%kind%")) |v| (if (v == .string) v.string else "") else "";
    const name = func.native_name;
    const eq = std.mem.eql;
    if (eq(u8, kind, "url_ctor")) return urlConstruct(self, this_val, args);
    if (eq(u8, kind, "url_static")) return urlStatic(self, name, args);
    if (eq(u8, kind, "url_legacy")) return legacyMethod(self, name, this_val, args);
    if (eq(u8, kind, "url_legacy_ctor")) return .{ .normal = this_val }; // `new url.Url()` → empty instance
    if (eq(u8, kind, "usp_ctor")) return uspConstruct(self, this_val, args);
    if (eq(u8, kind, "te_ctor") or eq(u8, kind, "td_ctor")) return codecConstruct(self, this_val);
    if (eq(u8, kind, "url")) return urlMethod(self, name, this_val);
    if (eq(u8, kind, "usp")) return uspMethod(self, name, this_val, args);
    if (eq(u8, kind, "te")) return teMethod(self, name, args);
    if (eq(u8, kind, "td")) return tdMethod(self, name, args);
    return .{ .normal = .undefined };
}

// ════════════════════════════════════════════════════════════════════════════
//  URL
// ════════════════════════════════════════════════════════════════════════════

/// Parsed URL components (all arena-owned slices). A minimal but correct parser for the common shape
/// `scheme://[user[:pass]@]host[:port][/path][?query][#frag]` plus the `scheme:opaque` (no `//`) form.
const UrlParts = struct {
    protocol: []const u8 = "", // includes the trailing ':' (e.g. "https:")
    username: []const u8 = "",
    password: []const u8 = "",
    hostname: []const u8 = "",
    port: []const u8 = "",
    pathname: []const u8 = "",
    search: []const u8 = "", // includes the leading '?' when non-empty
    hash: []const u8 = "", // includes the leading '#' when non-empty
};

/// Is `s` an absolute URL (`scheme:` where scheme is ALPHA (ALPHA|DIGIT|+|-|.)*)? Returns the scheme
/// length (excluding ':') or null.
fn schemeLen(s: []const u8) ?usize {
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return null;
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == ':') return i;
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return null;
    }
    return null;
}

/// Default port for a scheme (so `origin`/`host` drop an explicit default port, per the WHATWG
/// serializer). Empty for an unknown scheme.
fn defaultPort(scheme: []const u8) []const u8 {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(scheme, "http") or eq(scheme, "ws")) return "80";
    if (eq(scheme, "https") or eq(scheme, "wss")) return "443";
    if (eq(scheme, "ftp")) return "21";
    return "";
}

fn isSpecialScheme(scheme: []const u8) bool {
    const eq = std.ascii.eqlIgnoreCase;
    return eq(scheme, "http") or eq(scheme, "https") or eq(scheme, "ws") or eq(scheme, "wss") or eq(scheme, "ftp") or eq(scheme, "file");
}

/// Parse an ABSOLUTE url string into `UrlParts`, or null if it has no valid scheme. `arena` owns the
/// lowercased scheme/hostname + the protocol string.
fn parseAbsolute(arena: std.mem.Allocator, input: []const u8) !?UrlParts {
    const sl = schemeLen(input) orelse return null;
    const scheme = try std.ascii.allocLowerString(arena, input[0..sl]);
    var parts: UrlParts = .{};
    parts.protocol = try std.fmt.allocPrint(arena, "{s}:", .{scheme});

    var rest = input[sl + 1 ..]; // after "scheme:"

    if (std.mem.startsWith(u8, rest, "//")) {
        rest = rest[2..];
        // authority ends at the first '/', '?', or '#'.
        var auth_end: usize = rest.len;
        for (rest, 0..) |c, i| {
            if (c == '/' or c == '?' or c == '#') {
                auth_end = i;
                break;
            }
        }
        var authority = rest[0..auth_end];
        rest = rest[auth_end..];

        // userinfo@ (last '@' in the authority).
        if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
            const userinfo = authority[0..at];
            authority = authority[at + 1 ..];
            if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| {
                parts.username = userinfo[0..colon];
                parts.password = userinfo[colon + 1 ..];
            } else {
                parts.username = userinfo;
            }
        }
        // host[:port] — a ':' inside [..] (IPv6) is not the port separator: take the LAST ':' that is
        // not inside brackets.
        var host_end: usize = authority.len;
        var in_bracket = false;
        var port_start: ?usize = null;
        for (authority, 0..) |c, i| {
            if (c == '[') in_bracket = true;
            if (c == ']') in_bracket = false;
            if (c == ':' and !in_bracket) port_start = i;
        }
        if (port_start) |ps| {
            host_end = ps;
            const port_raw = authority[ps + 1 ..];
            if (!std.mem.eql(u8, port_raw, defaultPort(scheme))) parts.port = port_raw;
        }
        parts.hostname = try std.ascii.allocLowerString(arena, authority[0..host_end]);
    }
    // else: no authority — an "opaque" path (scheme:rest), e.g. mailto:, urn:.

    // path?query#frag.
    var pq = rest;
    if (std.mem.indexOfScalar(u8, pq, '#')) |h| {
        parts.hash = if (pq.len - h > 1) pq[h..] else ""; // a bare "#" → empty hash
        pq = pq[0..h];
    }
    if (std.mem.indexOfScalar(u8, pq, '?')) |q| {
        parts.search = if (pq.len - q > 1) pq[q..] else ""; // a bare "?" → empty search
        pq = pq[0..q];
    }
    // A special scheme with an authority and empty path serializes path "/".
    if (pq.len == 0 and isSpecialScheme(scheme) and parts.hostname.len > 0) {
        parts.pathname = "/";
    } else {
        parts.pathname = pq;
    }
    return parts;
}

/// `new URL(input[, base])`: parse, throw TypeError on an invalid absolute URL with no usable base,
/// and store the components as own data properties on the instance.
fn urlConstruct(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    const arena = self.arena;
    if (this_val != .object) return self.throwError("TypeError", "URL constructor requires `new`");
    const inst = this_val.object;

    const inc = try self.toStringValuePub(if (args.len > 0) args[0] else .undefined);
    if (inc.isAbrupt()) return inc;
    const input = inc.normal.string;

    var base_parts: ?UrlParts = null;
    if (args.len > 1 and args[1] != .undefined and args[1] != .null) {
        const bc = try self.toStringValuePub(args[1]);
        if (bc.isAbrupt()) return bc;
        base_parts = (parseAbsolute(arena, bc.normal.string) catch return error.OutOfMemory) orelse
            return self.throwError("TypeError", "Invalid base URL");
    }

    const parts = (parseAbsolute(arena, input) catch return error.OutOfMemory) orelse blk: {
        // Relative input: resolve against the base (first cut — merge path/query/hash onto the base).
        const bp = base_parts orelse return self.throwError("TypeError", "Invalid URL");
        var p = bp;
        const rc = resolveRelative(arena, bp, input) catch return error.OutOfMemory;
        p.pathname = rc.pathname;
        p.search = rc.search;
        p.hash = rc.hash;
        break :blk p;
    };

    try storeUrl(self, inst, parts);
    return .{ .normal = .{ .object = inst } };
}

const RelParts = struct { pathname: []const u8, search: []const u8, hash: []const u8 };

/// Resolve a relative reference `rel` against `base` — a minimal path merge (absolute path replaces;
/// otherwise merge against the base directory).
fn resolveRelative(arena: std.mem.Allocator, base: UrlParts, rel: []const u8) !RelParts {
    var r = rel;
    var out: RelParts = .{ .pathname = base.pathname, .search = "", .hash = "" };
    if (std.mem.indexOfScalar(u8, r, '#')) |h| {
        out.hash = if (r.len - h > 1) r[h..] else "";
        r = r[0..h];
    }
    if (std.mem.indexOfScalar(u8, r, '?')) |q| {
        out.search = if (r.len - q > 1) r[q..] else "";
        r = r[0..q];
    }
    if (r.len == 0) return out;
    if (r[0] == '/') {
        out.pathname = try arena.dupe(u8, r);
    } else {
        const slash = std.mem.lastIndexOfScalar(u8, base.pathname, '/');
        const dir = if (slash) |s| base.pathname[0 .. s + 1] else "/";
        out.pathname = try std.fmt.allocPrint(arena, "{s}{s}", .{ dir, r });
    }
    return out;
}

/// Serialize `parts` into `href` and store every component as an own data property on the URL
/// instance (plus the `searchParams` snapshot object).
fn storeUrl(self: *Interpreter, inst: *Object, parts: UrlParts) EvalError!void {
    const arena = self.arena;
    const scheme = if (parts.protocol.len > 0) parts.protocol[0 .. parts.protocol.len - 1] else "";

    const host = if (parts.port.len > 0)
        try std.fmt.allocPrint(arena, "{s}:{s}", .{ parts.hostname, parts.port })
    else
        parts.hostname;

    const origin = if (isSpecialScheme(scheme) and parts.hostname.len > 0)
        try std.fmt.allocPrint(arena, "{s}//{s}", .{ parts.protocol, host })
    else
        "null";

    var href: std.ArrayListUnmanaged(u8) = .empty;
    href.appendSlice(arena, parts.protocol) catch return error.OutOfMemory;
    const has_authority = parts.hostname.len > 0 or parts.username.len > 0;
    if (has_authority) {
        href.appendSlice(arena, "//") catch return error.OutOfMemory;
        if (parts.username.len > 0) {
            href.appendSlice(arena, parts.username) catch return error.OutOfMemory;
            if (parts.password.len > 0) {
                href.append(arena, ':') catch return error.OutOfMemory;
                href.appendSlice(arena, parts.password) catch return error.OutOfMemory;
            }
            href.append(arena, '@') catch return error.OutOfMemory;
        }
        href.appendSlice(arena, host) catch return error.OutOfMemory;
    }
    href.appendSlice(arena, parts.pathname) catch return error.OutOfMemory;
    href.appendSlice(arena, parts.search) catch return error.OutOfMemory;
    href.appendSlice(arena, parts.hash) catch return error.OutOfMemory;

    const D = struct {
        fn def(o: *Object, k: []const u8, v: []const u8) EvalError!void {
            try o.defineData(k, .{ .string = v }, true, true, true);
        }
    };
    try D.def(inst, "href", href.items);
    try D.def(inst, "protocol", parts.protocol);
    try D.def(inst, "username", parts.username);
    try D.def(inst, "password", parts.password);
    try D.def(inst, "host", host);
    try D.def(inst, "hostname", parts.hostname);
    try D.def(inst, "port", parts.port);
    try D.def(inst, "pathname", parts.pathname);
    try D.def(inst, "search", parts.search);
    try D.def(inst, "hash", parts.hash);
    try D.def(inst, "origin", origin);

    // searchParams — a snapshot URLSearchParams built from `search` (without the leading '?').
    const query = if (parts.search.len > 1) parts.search[1..] else "";
    const usp = try makeUsp(self);
    try parseQueryInto(self, usp, query);
    try inst.defineData("searchParams", .{ .object = usp }, true, true, true);
}

fn urlMethod(self: *Interpreter, name: []const u8, this_val: Value) EvalError!Completion {
    if (this_val != .object) return self.throwError("TypeError", "URL method called on non-object");
    // toString / toJSON → href.
    if (std.mem.eql(u8, name, "toString") or std.mem.eql(u8, name, "toJSON")) {
        return .{ .normal = this_val.object.get("href") orelse Value{ .string = "" } };
    }
    return .{ .normal = .undefined };
}

// ════════════════════════════════════════════════════════════════════════════
//  URL statics: canParse / parse / createObjectURL / revokeObjectURL
// ════════════════════════════════════════════════════════════════════════════

/// Build a Node-style error with a `code` own property (so `assert.throws({ code })` matches).
fn throwCode(self: *Interpreter, kind: []const u8, code: []const u8, msg: []const u8) EvalError!Completion {
    const arena = self.arena;
    const err = try Object.create(arena, self.errorProto(kind));
    err.error_data = true;
    try err.set("name", .{ .string = kind });
    try err.set("message", .{ .string = msg });
    try err.defineData("code", .{ .string = code }, true, false, true);
    return .{ .throw = .{ .object = err } };
}

/// Can `input` (resolved against an optional `base`) be parsed as an absolute URL? (first-cut: the
/// minimal absolute-scheme test; relative-with-valid-base also counts).
fn canParseInput(arena: std.mem.Allocator, input: []const u8, base: ?[]const u8) bool {
    if ((parseAbsolute(arena, input) catch return false) != null) return true;
    if (base) |b| return (parseAbsolute(arena, b) catch return false) != null;
    return false;
}

/// Dispatch a `URL.*` static. `name` is canParse/parse/createObjectURL/revokeObjectURL.
fn urlStatic(self: *Interpreter, name: []const u8, args: []const Value) EvalError!Completion {
    const arena = self.arena;
    const eq = std.mem.eql;

    if (eq(u8, name, "createObjectURL")) {
        // Minimal: a blob: URL with an opaque id (no real Blob store; identity not relied upon).
        if (args.len == 0) return throwCode(self, "TypeError", "ERR_MISSING_ARGS", "The \"obj\" argument must be specified");
        const tag: usize = if (args[0] == .object) @intFromPtr(args[0].object) else 0;
        const id = std.fmt.allocPrint(arena, "blob:nodedata:{x}", .{tag}) catch return error.OutOfMemory;
        return .{ .normal = .{ .string = id } };
    }
    if (eq(u8, name, "revokeObjectURL")) {
        // Node requires the `url` argument; a missing arg is ERR_MISSING_ARGS.
        if (args.len == 0) return throwCode(self, "TypeError", "ERR_MISSING_ARGS", "The \"url\" argument must be specified");
        return .{ .normal = .undefined };
    }

    // canParse / parse share input + base coercion.
    const inc = try self.toStringValuePub(if (args.len > 0) args[0] else .undefined);
    if (inc.isAbrupt()) return inc;
    const input = inc.normal.string;
    var base: ?[]const u8 = null;
    if (args.len > 1 and args[1] != .undefined and args[1] != .null) {
        const bc = try self.toStringValuePub(args[1]);
        if (bc.isAbrupt()) return bc;
        base = bc.normal.string;
    }

    if (eq(u8, name, "canParse")) {
        return .{ .normal = .{ .boolean = canParseInput(arena, input, base) } };
    }
    if (eq(u8, name, "parse")) {
        // URL.parse(input[,base]) → a URL instance, or null if it cannot be parsed (never throws).
        if (!canParseInput(arena, input, base)) return .{ .normal = .null };
        const proto = self.globalProto("URL") orelse self.objectProto();
        const inst = try Object.create(arena, proto);
        const c = try urlConstruct(self, .{ .object = inst }, args);
        if (c == .throw) return .{ .normal = .null };
        return c;
    }
    return .{ .normal = .undefined };
}

// ════════════════════════════════════════════════════════════════════════════
//  legacy `url` module: parse / format / resolve / domainTo* / *fileURL* / urlToHttpOptions
// ════════════════════════════════════════════════════════════════════════════

fn legacyMethod(self: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    _ = this_val;
    const eq = std.mem.eql;
    if (eq(u8, name, "urlToHttpOptions")) return urlToHttpOptions(self, args);
    if (eq(u8, name, "domainToASCII")) return domainToAsciiOrUnicode(self, args, true);
    if (eq(u8, name, "domainToUnicode")) return domainToAsciiOrUnicode(self, args, false);
    if (eq(u8, name, "pathToFileURL")) return pathToFileURL(self, args);
    if (eq(u8, name, "fileURLToPath")) return fileURLToPath(self, args);
    if (eq(u8, name, "format")) return legacyFormat(self, args);
    if (eq(u8, name, "parse")) return legacyParse(self, args);
    if (eq(u8, name, "resolve") or eq(u8, name, "resolveObject")) return legacyResolve(self, args);
    return .{ .normal = .undefined };
}

/// `urlToHttpOptions(urlObject)` — project a WHATWG URL instance to the http(s) `request` options
/// shape: `{ protocol, hostname, hash, search, pathname, path, href, port?, auth? }`. Reads the URL's
/// own data properties (a non-URL object yields `undefined`/`NaN` fields, per Node).
fn urlToHttpOptions(self: *Interpreter, args: []const Value) EvalError!Completion {
    const arena = self.arena;
    const url_v: Value = if (args.len > 0) args[0] else .undefined;
    const opts = try Object.create(arena, self.objectProto());
    if (url_v != .object) return .{ .normal = .{ .object = opts } };
    const uo = url_v.object;

    const get = struct {
        fn s(o: *Object, k: []const u8) ?[]const u8 {
            const v = o.get(k) orelse return null;
            return if (v == .string) v.string else null;
        }
    };

    // protocol/hash/search/pathname/href pass through (undefined when absent on the source).
    for ([_][]const u8{ "protocol", "hash", "search", "pathname", "href" }) |k| {
        if (get.s(uo, k)) |val| {
            try opts.defineData(k, .{ .string = val }, true, true, true);
        } else {
            try opts.defineData(k, .undefined, true, true, true);
        }
    }
    // hostname: Node's urlToHttpOptions strips the IPv6 brackets (`[::1]` → `::1`).
    if (get.s(uo, "hostname")) |hn| {
        const stripped = if (hn.len >= 2 and hn[0] == '[' and hn[hn.len - 1] == ']') hn[1 .. hn.len - 1] else hn;
        try opts.defineData("hostname", .{ .string = stripped }, true, true, true);
    } else {
        try opts.defineData("hostname", .undefined, true, true, true);
    }

    // port → number (NaN when absent/empty).
    const port_num: f64 = blk: {
        const ps = get.s(uo, "port") orelse break :blk std.math.nan(f64);
        if (ps.len == 0) break :blk std.math.nan(f64);
        const n = std.fmt.parseInt(u32, ps, 10) catch break :blk std.math.nan(f64);
        break :blk @floatFromInt(n);
    };
    try opts.defineData("port", .{ .number = port_num }, true, true, true);

    // auth → "user[:pass]" when a username is present (else undefined).
    const user = get.s(uo, "username") orelse "";
    if (user.len > 0) {
        const pass = get.s(uo, "password") orelse "";
        const auth = if (pass.len > 0)
            std.fmt.allocPrint(arena, "{s}:{s}", .{ user, pass }) catch return error.OutOfMemory
        else
            user;
        try opts.defineData("auth", .{ .string = auth }, true, true, true);
    } else {
        try opts.defineData("auth", .undefined, true, true, true);
    }

    // path = pathname + search (search "" when absent → "").
    const pathname = get.s(uo, "pathname") orelse "";
    const search = get.s(uo, "search") orelse "";
    const path = std.fmt.allocPrint(arena, "{s}{s}", .{ pathname, search }) catch return error.OutOfMemory;
    try opts.defineData("path", .{ .string = path }, true, true, true);

    return .{ .normal = .{ .object = opts } };
}

/// `domainToASCII` / `domainToUnicode` — without ICU we cannot do real IDNA/punycode. Return the
/// input domain UNCHANGED for an already-ASCII domain (so the ASCII round-trip used by tests works);
/// a non-ASCII domain has no available transform → "" (Node returns "" for an unparseable domain).
fn domainToAsciiOrUnicode(self: *Interpreter, args: []const Value, to_ascii: bool) EvalError!Completion {
    _ = to_ascii;
    const sc = try self.toStringValuePub(if (args.len > 0) args[0] else .{ .string = "" });
    if (sc.isAbrupt()) return sc;
    const s = sc.normal.string;
    var ascii_only = true;
    for (s) |c| if (c >= 0x80) {
        ascii_only = false;
        break;
    };
    return .{ .normal = .{ .string = if (ascii_only) s else "" } };
}

/// `pathToFileURL(path)` → a `file:` URL instance. Percent-encodes the path's special bytes and
/// normalizes backslashes; a minimal POSIX-leaning implementation.
fn pathToFileURL(self: *Interpreter, args: []const Value) EvalError!Completion {
    const arena = self.arena;
    const sc = try self.toStringValuePub(if (args.len > 0) args[0] else .{ .string = "" });
    if (sc.isAbrupt()) return sc;
    const path = sc.normal.string;

    var enc: std.ArrayListUnmanaged(u8) = .empty;
    const hex = "0123456789ABCDEF";
    for (path) |c| {
        // Encode the bytes Node escapes in a file URL path (%, control, space, ?, #) and leave the
        // path separators; a backslash is preserved as %5C on POSIX.
        if (c == '%' or c == '?' or c == '#' or c < 0x20 or c == ' ' or c == '\\') {
            enc.append(arena, '%') catch return error.OutOfMemory;
            enc.append(arena, hex[c >> 4]) catch return error.OutOfMemory;
            enc.append(arena, hex[c & 0x0f]) catch return error.OutOfMemory;
        } else {
            enc.append(arena, c) catch return error.OutOfMemory;
        }
    }
    const lead = if (enc.items.len > 0 and enc.items[0] == '/') "" else "/";
    const href = std.fmt.allocPrint(arena, "file://{s}{s}", .{ lead, enc.items }) catch return error.OutOfMemory;

    const proto = self.globalProto("URL") orelse self.objectProto();
    const inst = try Object.create(arena, proto);
    const parts = (parseAbsolute(arena, href) catch return error.OutOfMemory) orelse return throwCode(self, "TypeError", "ERR_INVALID_URL", "Invalid URL");
    try storeUrl(self, inst, parts);
    return .{ .normal = .{ .object = inst } };
}

/// `fileURLToPath(url)` — the inverse: a `file:` URL (string or URL instance) → a filesystem path.
/// Throws Node's typed errors for a non-string/URL arg, a non-`file:` scheme, etc.
fn fileURLToPath(self: *Interpreter, args: []const Value) EvalError!Completion {
    const arena = self.arena;
    const url_v: Value = if (args.len > 0) args[0] else .undefined;

    var href: []const u8 = "";
    if (url_v == .string) {
        href = url_v.string;
    } else if (url_v == .object and url_v.object.get("href") != null) {
        const h = url_v.object.get("href").?;
        if (h == .string) href = h.string;
    } else {
        return throwCode(self, "TypeError", "ERR_INVALID_ARG_TYPE", "The \"path\" argument must be of type string or an instance of URL.");
    }

    const parts = (parseAbsolute(arena, href) catch return error.OutOfMemory) orelse
        return throwCode(self, "TypeError", "ERR_INVALID_URL", "Invalid URL");
    if (!std.mem.eql(u8, parts.protocol, "file:"))
        return throwCode(self, "TypeError", "ERR_INVALID_URL_SCHEME", "The URL must be of scheme file");
    if (parts.hostname.len > 0)
        return throwCode(self, "TypeError", "ERR_INVALID_FILE_URL_HOST", "File URL host must be \"localhost\" or empty");

    // Percent-decode the pathname.
    const decoded = percentDecodePath(arena, parts.pathname) catch return error.OutOfMemory;
    return .{ .normal = .{ .string = decoded } };
}

/// Percent-decode a URL path (NO '+'→' ' mapping — that's form-encoding, not path-encoding).
fn percentDecodePath(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '%' and i + 2 < s.len) {
            const hi = hexVal(s[i + 1]);
            const lo = hexVal(s[i + 2]);
            if (hi != null and lo != null) {
                try out.append(arena, hi.? * 16 + lo.?);
                i += 2;
                continue;
            }
        }
        try out.append(arena, c);
    }
    return out.items;
}

/// Legacy `url.format(urlObject)` — accept a WHATWG URL instance (→ its href) or a legacy-shaped
/// object (`{ protocol, host/hostname, pathname, search, hash, ... }`). A string passthrough too.
fn legacyFormat(self: *Interpreter, args: []const Value) EvalError!Completion {
    const arena = self.arena;
    const v: Value = if (args.len > 0) args[0] else .undefined;
    if (v == .string) return .{ .normal = v };
    if (v != .object) {
        const sc = try self.toStringValuePub(v);
        return sc;
    }
    const o = v.object;
    // A WHATWG URL instance → its href.
    if (o.get("href")) |h| if (h == .string) return .{ .normal = h };

    const get = struct {
        fn s(io: *Object, k: []const u8) []const u8 {
            const x = io.get(k) orelse return "";
            return if (x == .string) x.string else "";
        }
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const protocol = get.s(o, "protocol");
    if (protocol.len > 0) {
        out.appendSlice(arena, protocol) catch return error.OutOfMemory;
        if (!std.mem.endsWith(u8, protocol, ":")) out.append(arena, ':') catch return error.OutOfMemory;
    }
    const host = if (get.s(o, "host").len > 0) get.s(o, "host") else get.s(o, "hostname");
    if (host.len > 0) {
        out.appendSlice(arena, "//") catch return error.OutOfMemory;
        out.appendSlice(arena, host) catch return error.OutOfMemory;
    }
    out.appendSlice(arena, get.s(o, "pathname")) catch return error.OutOfMemory;
    out.appendSlice(arena, get.s(o, "search")) catch return error.OutOfMemory;
    out.appendSlice(arena, get.s(o, "hash")) catch return error.OutOfMemory;
    return .{ .normal = .{ .string = out.items } };
}

/// Legacy `url.parse(urlString)` — a minimal parse returning an object with the legacy field names
/// (`protocol/host/hostname/port/pathname/search/hash/path/href`). Throws ERR_INVALID_ARG_TYPE for a
/// non-string input (matching Node's first check).
fn legacyParse(self: *Interpreter, args: []const Value) EvalError!Completion {
    const arena = self.arena;
    const v: Value = if (args.len > 0) args[0] else .undefined;
    if (v != .string) {
        return throwCode(self, "TypeError", "ERR_INVALID_ARG_TYPE", "The \"url\" argument must be of type string.");
    }
    const input = v.string;
    const obj = try Object.create(arena, self.objectProto());

    const parts = (parseAbsolute(arena, input) catch return error.OutOfMemory) orelse {
        // No scheme → a path-only legacy URL.
        var pq = input;
        var hash: []const u8 = "";
        var search: []const u8 = "";
        if (std.mem.indexOfScalar(u8, pq, '#')) |h| {
            hash = pq[h..];
            pq = pq[0..h];
        }
        if (std.mem.indexOfScalar(u8, pq, '?')) |q| {
            search = pq[q..];
            pq = pq[0..q];
        }
        const path = std.fmt.allocPrint(arena, "{s}{s}", .{ pq, search }) catch return error.OutOfMemory;
        try obj.defineData("protocol", .null, true, true, true);
        try obj.defineData("host", .null, true, true, true);
        try obj.defineData("hostname", .null, true, true, true);
        try obj.defineData("port", .null, true, true, true);
        try obj.defineData("pathname", .{ .string = pq }, true, true, true);
        try obj.defineData("search", if (search.len > 0) Value{ .string = search } else .null, true, true, true);
        try obj.defineData("hash", if (hash.len > 0) Value{ .string = hash } else .null, true, true, true);
        try obj.defineData("path", .{ .string = path }, true, true, true);
        try obj.defineData("href", .{ .string = input }, true, true, true);
        return .{ .normal = .{ .object = obj } };
    };

    const host = if (parts.port.len > 0)
        std.fmt.allocPrint(arena, "{s}:{s}", .{ parts.hostname, parts.port }) catch return error.OutOfMemory
    else
        parts.hostname;
    const path = std.fmt.allocPrint(arena, "{s}{s}", .{ parts.pathname, parts.search }) catch return error.OutOfMemory;
    try obj.defineData("protocol", .{ .string = parts.protocol }, true, true, true);
    try obj.defineData("host", if (host.len > 0) Value{ .string = host } else .null, true, true, true);
    try obj.defineData("hostname", if (parts.hostname.len > 0) Value{ .string = parts.hostname } else .null, true, true, true);
    try obj.defineData("port", if (parts.port.len > 0) Value{ .string = parts.port } else .null, true, true, true);
    try obj.defineData("pathname", .{ .string = parts.pathname }, true, true, true);
    try obj.defineData("search", if (parts.search.len > 0) Value{ .string = parts.search } else .null, true, true, true);
    try obj.defineData("hash", if (parts.hash.len > 0) Value{ .string = parts.hash } else .null, true, true, true);
    try obj.defineData("path", .{ .string = path }, true, true, true);
    try obj.defineData("href", .{ .string = input }, true, true, true);
    return .{ .normal = .{ .object = obj } };
}

/// Legacy `url.resolve(from, to)` — resolve `to` against `from` via the WHATWG `new URL(to, from)`
/// path when `from` is absolute; else a simple path merge. First-cut: covers the common cases.
fn legacyResolve(self: *Interpreter, args: []const Value) EvalError!Completion {
    const arena = self.arena;
    const fc = try self.toStringValuePub(if (args.len > 0) args[0] else .{ .string = "" });
    if (fc.isAbrupt()) return fc;
    const tc = try self.toStringValuePub(if (args.len > 1) args[1] else .{ .string = "" });
    if (tc.isAbrupt()) return tc;
    const from = fc.normal.string;
    const to = tc.normal.string;

    // `to` absolute → it wins.
    if ((parseAbsolute(arena, to) catch null) != null) return .{ .normal = .{ .string = to } };

    // `from` absolute → resolve relative against it and re-serialize.
    if ((parseAbsolute(arena, from) catch null)) |base| {
        const rc = resolveRelative(arena, base, to) catch return error.OutOfMemory;
        var merged = base;
        merged.pathname = rc.pathname;
        merged.search = rc.search;
        merged.hash = rc.hash;
        const proto = self.globalProto("URL") orelse self.objectProto();
        const inst = try Object.create(arena, proto);
        try storeUrl(self, inst, merged);
        const href = inst.get("href") orelse Value{ .string = to };
        return .{ .normal = href };
    }

    // Both relative → a path merge.
    const rc = resolveRelative(arena, .{ .pathname = from }, to) catch return error.OutOfMemory;
    const out = std.fmt.allocPrint(arena, "{s}{s}{s}", .{ rc.pathname, rc.search, rc.hash }) catch return error.OutOfMemory;
    return .{ .normal = .{ .string = out } };
}

// ════════════════════════════════════════════════════════════════════════════
//  URLSearchParams
// ════════════════════════════════════════════════════════════════════════════

/// Create a fresh URLSearchParams instance (proto = the global %URLSearchParams.prototype%) with an
/// empty `%pairs%` backing array.
fn makeUsp(self: *Interpreter) EvalError!*Object {
    const proto = self.globalProto("URLSearchParams") orelse self.objectProto();
    const obj = try Object.create(self.arena, proto);
    const pairs = try Object.createArray(self.arena, self.arrayProto());
    try obj.defineData("%pairs%", .{ .object = pairs }, false, false, true);
    return obj;
}

/// The backing `%pairs%` array of a URLSearchParams instance (a JS Array of [key,value] arrays).
fn uspPairs(inst: *Object) ?*Object {
    const v = inst.get("%pairs%") orelse return null;
    return if (v == .object) v.object else null;
}

fn pairsLen(self: *Interpreter, pairs: *Object) EvalError!usize {
    const lc = try self.getProperty(.{ .object = pairs }, "length");
    if (lc.isAbrupt() or lc.normal != .number) return 0;
    return @intFromFloat(@max(lc.normal.number, 0));
}

fn pairAt(self: *Interpreter, pairs: *Object, i: usize) EvalError!?*Object {
    const ec = try self.getPropertyV(.{ .object = pairs }, .{ .number = @floatFromInt(i) });
    if (ec.isAbrupt()) return null;
    return if (ec.normal == .object) ec.normal.object else null;
}

fn pairKey(self: *Interpreter, pair: *Object) EvalError![]const u8 {
    const kc = try self.getPropertyV(.{ .object = pair }, .{ .number = 0 });
    if (kc.isAbrupt() or kc.normal != .string) return "";
    return kc.normal.string;
}
fn pairVal(self: *Interpreter, pair: *Object) EvalError![]const u8 {
    const vc = try self.getPropertyV(.{ .object = pair }, .{ .number = 1 });
    if (vc.isAbrupt() or vc.normal != .string) return "";
    return vc.normal.string;
}

/// Build a fresh [key,value] 2-element array.
fn makePair(self: *Interpreter, key: []const u8, val: []const u8) EvalError!*Object {
    const pair = try Object.createArray(self.arena, self.arrayProto());
    try pair.arraySet(self.arena, 0, .{ .string = key });
    try pair.arraySet(self.arena, 1, .{ .string = val });
    return pair;
}

/// Append a [key,value] pair to the backing array.
fn appendPair(self: *Interpreter, pairs: *Object, key: []const u8, val: []const u8) EvalError!void {
    const n = try pairsLen(self, pairs);
    try pairs.arraySet(self.arena, n, .{ .object = try makePair(self, key, val) });
}

/// Percent-decode `s` and map '+' → ' ' (the application/x-www-form-urlencoded sense). Arena-owned.
fn percentDecode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '+') {
            try out.append(arena, ' ');
        } else if (c == '%' and i + 2 < s.len) {
            const hi = hexVal(s[i + 1]);
            const lo = hexVal(s[i + 2]);
            if (hi != null and lo != null) {
                try out.append(arena, hi.? * 16 + lo.?);
                i += 2;
            } else {
                try out.append(arena, c);
            }
        } else {
            try out.append(arena, c);
        }
    }
    return out.items;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Percent-encode `s` for serialization (application/x-www-form-urlencoded): space → '+', and
/// non-unreserved bytes → %XX. Arena-owned.
fn percentEncode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        if (c == ' ') {
            try out.append(arena, '+');
        } else if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '*') {
            try out.append(arena, c);
        } else {
            try out.append(arena, '%');
            try out.append(arena, hex[c >> 4]);
            try out.append(arena, hex[c & 0x0f]);
        }
    }
    return out.items;
}

/// Parse a query string `q` (no leading '?') into `usp`'s backing pairs, percent-decoding each
/// key/value.
fn parseQueryInto(self: *Interpreter, usp: *Object, q: []const u8) EvalError!void {
    const arena = self.arena;
    const pairs = uspPairs(usp) orelse return;
    var it = std.mem.splitScalar(u8, q, '&');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        var key: []const u8 = seg;
        var val: []const u8 = "";
        if (std.mem.indexOfScalar(u8, seg, '=')) |e| {
            key = seg[0..e];
            val = seg[e + 1 ..];
        }
        const dk = percentDecode(arena, key) catch return error.OutOfMemory;
        const dv = percentDecode(arena, val) catch return error.OutOfMemory;
        try appendPair(self, pairs, dk, dv);
    }
}

/// `new URLSearchParams(init?)`: from a string `"a=1&b=2"`, an iterable of [k,v] pairs, or a plain
/// record of key→value entries.
fn uspConstruct(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object) return self.throwError("TypeError", "URLSearchParams constructor requires `new`");
    const inst = this_val.object;
    const pairs = try Object.createArray(self.arena, self.arrayProto());
    try inst.defineData("%pairs%", .{ .object = pairs }, false, false, true);

    const init: Value = if (args.len > 0) args[0] else .undefined;
    switch (init) {
        .undefined, .null => {},
        .string => |s| {
            const q = if (std.mem.startsWith(u8, s, "?")) s[1..] else s;
            try parseQueryInto(self, inst, q);
        },
        .object => |o| {
            if (try self.isArrayFromIterable(.{ .object = o })) {
                const ir = try self.getIterator(.{ .object = o });
                const iter = switch (ir) {
                    .abrupt => |c| return c,
                    .iterator => |x| x,
                };
                while (true) {
                    const step = try self.iteratorStep(iter);
                    const entry = switch (step) {
                        .abrupt => |c| return c,
                        .done => break,
                        .value => |v| v,
                    };
                    const kc = try self.getPropertyV(entry, .{ .number = 0 });
                    if (kc.isAbrupt()) return kc;
                    const vc = try self.getPropertyV(entry, .{ .number = 1 });
                    if (vc.isAbrupt()) return vc;
                    const ks = try self.toStringValuePub(kc.normal);
                    if (ks.isAbrupt()) return ks;
                    const vs = try self.toStringValuePub(vc.normal);
                    if (vs.isAbrupt()) return vs;
                    try appendPair(self, pairs, ks.normal.string, vs.normal.string);
                }
            } else {
                // Plain record: own enumerable string keys → ToString(values).
                var pit = o.properties.iterator();
                while (pit.next()) |e| {
                    if (!e.value_ptr.enumerable) continue;
                    const vc = try self.getProperty(.{ .object = o }, e.key_ptr.*);
                    if (vc.isAbrupt()) return vc;
                    const vs = try self.toStringValuePub(vc.normal);
                    if (vs.isAbrupt()) return vs;
                    try appendPair(self, pairs, e.key_ptr.*, vs.normal.string);
                }
            }
        },
        else => {},
    }
    return .{ .normal = .{ .object = inst } };
}

fn uspMethod(self: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    const eq = std.mem.eql;
    if (this_val != .object) return self.throwError("TypeError", "URLSearchParams method called on non-object");
    const inst = this_val.object;
    const pairs = uspPairs(inst) orelse return self.throwError("TypeError", "not a URLSearchParams");
    const n = try pairsLen(self, pairs);

    if (eq(u8, name, "get")) {
        const key = try argStr(self, args, 0);
        if (key.isAbrupt()) return key;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const p = (try pairAt(self, pairs, i)) orelse continue;
            if (std.mem.eql(u8, try pairKey(self, p), key.normal.string))
                return .{ .normal = .{ .string = try pairVal(self, p) } };
        }
        return .{ .normal = .null };
    }
    if (eq(u8, name, "getAll")) {
        const key = try argStr(self, args, 0);
        if (key.isAbrupt()) return key;
        const arr = try Object.createArray(self.arena, self.arrayProto());
        var i: usize = 0;
        var j: usize = 0;
        while (i < n) : (i += 1) {
            const p = (try pairAt(self, pairs, i)) orelse continue;
            if (std.mem.eql(u8, try pairKey(self, p), key.normal.string)) {
                try arr.arraySet(self.arena, j, .{ .string = try pairVal(self, p) });
                j += 1;
            }
        }
        return .{ .normal = .{ .object = arr } };
    }
    if (eq(u8, name, "has")) {
        const key = try argStr(self, args, 0);
        if (key.isAbrupt()) return key;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const p = (try pairAt(self, pairs, i)) orelse continue;
            if (std.mem.eql(u8, try pairKey(self, p), key.normal.string)) return .{ .normal = .{ .boolean = true } };
        }
        return .{ .normal = .{ .boolean = false } };
    }
    if (eq(u8, name, "append")) {
        const key = try argStr(self, args, 0);
        if (key.isAbrupt()) return key;
        const val = try argStr(self, args, 1);
        if (val.isAbrupt()) return val;
        try appendPair(self, pairs, key.normal.string, val.normal.string);
        return .{ .normal = .undefined };
    }
    if (eq(u8, name, "set")) {
        const key = try argStr(self, args, 0);
        if (key.isAbrupt()) return key;
        const val = try argStr(self, args, 1);
        if (val.isAbrupt()) return val;
        try uspSet(self, inst, key.normal.string, val.normal.string);
        return .{ .normal = .undefined };
    }
    if (eq(u8, name, "delete")) {
        const key = try argStr(self, args, 0);
        if (key.isAbrupt()) return key;
        try uspRebuildWithout(self, inst, key.normal.string);
        return .{ .normal = .undefined };
    }
    if (eq(u8, name, "forEach")) return uspForEach(self, inst, this_val, args);
    if (eq(u8, name, "toString")) return uspToString(self, inst);
    if (eq(u8, name, "keys")) return uspIterator(self, inst, .key);
    if (eq(u8, name, "values")) return uspIterator(self, inst, .value);
    if (eq(u8, name, "entries")) return uspIterator(self, inst, .entry);
    if (eq(u8, name, "sort")) {
        try uspSort(self, inst);
        return .{ .normal = .undefined };
    }
    return .{ .normal = .undefined };
}

fn argStr(self: *Interpreter, args: []const Value, i: usize) EvalError!Completion {
    return self.toStringValuePub(if (args.len > i) args[i] else .undefined);
}

/// §set: if the name exists, set the FIRST occurrence's value and remove the rest; else append.
fn uspSet(self: *Interpreter, inst: *Object, key: []const u8, val: []const u8) EvalError!void {
    const pairs = uspPairs(inst).?;
    const n = try pairsLen(self, pairs);
    var found = false;
    const rebuilt = try Object.createArray(self.arena, self.arrayProto());
    var j: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = (try pairAt(self, pairs, i)) orelse continue;
        if (std.mem.eql(u8, try pairKey(self, p), key)) {
            if (!found) {
                try rebuilt.arraySet(self.arena, j, .{ .object = try makePair(self, key, val) });
                j += 1;
                found = true;
            }
            // drop subsequent occurrences
        } else {
            try rebuilt.arraySet(self.arena, j, .{ .object = p });
            j += 1;
        }
    }
    if (!found) try rebuilt.arraySet(self.arena, j, .{ .object = try makePair(self, key, val) });
    try inst.defineData("%pairs%", .{ .object = rebuilt }, false, false, true);
}

fn uspRebuildWithout(self: *Interpreter, inst: *Object, key: []const u8) EvalError!void {
    const pairs = uspPairs(inst).?;
    const n = try pairsLen(self, pairs);
    const rebuilt = try Object.createArray(self.arena, self.arrayProto());
    var j: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = (try pairAt(self, pairs, i)) orelse continue;
        if (!std.mem.eql(u8, try pairKey(self, p), key)) {
            try rebuilt.arraySet(self.arena, j, .{ .object = p });
            j += 1;
        }
    }
    try inst.defineData("%pairs%", .{ .object = rebuilt }, false, false, true);
}

fn uspSort(self: *Interpreter, inst: *Object) EvalError!void {
    const pairs = uspPairs(inst).?;
    const n = try pairsLen(self, pairs);
    var list: std.ArrayListUnmanaged(*Object) = .empty;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (try pairAt(self, pairs, i)) |p| list.append(self.arena, p) catch return error.OutOfMemory;
    }
    const Ctx = struct {
        interp: *Interpreter,
        fn lessThan(ctx: @This(), a: *Object, b: *Object) bool {
            const ka = pairKey(ctx.interp, a) catch "";
            const kb = pairKey(ctx.interp, b) catch "";
            return std.mem.order(u8, ka, kb) == .lt;
        }
    };
    std.mem.sort(*Object, list.items, Ctx{ .interp = self }, Ctx.lessThan);
    const rebuilt = try Object.createArray(self.arena, self.arrayProto());
    for (list.items, 0..) |p, k| try rebuilt.arraySet(self.arena, k, .{ .object = p });
    try inst.defineData("%pairs%", .{ .object = rebuilt }, false, false, true);
}

fn uspToString(self: *Interpreter, inst: *Object) EvalError!Completion {
    const arena = self.arena;
    const pairs = uspPairs(inst).?;
    const n = try pairsLen(self, pairs);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    var first = true;
    while (i < n) : (i += 1) {
        const p = (try pairAt(self, pairs, i)) orelse continue;
        const k = percentEncode(arena, try pairKey(self, p)) catch return error.OutOfMemory;
        const v = percentEncode(arena, try pairVal(self, p)) catch return error.OutOfMemory;
        if (!first) out.append(arena, '&') catch return error.OutOfMemory;
        first = false;
        out.appendSlice(arena, k) catch return error.OutOfMemory;
        out.append(arena, '=') catch return error.OutOfMemory;
        out.appendSlice(arena, v) catch return error.OutOfMemory;
    }
    return .{ .normal = .{ .string = out.items } };
}

/// `forEach(callback[, thisArg])` — call `callback(value, key, this)` for each pair in order.
fn uspForEach(self: *Interpreter, inst: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const cb: Value = if (args.len > 0) args[0] else .undefined;
    if (cb != .object or !interpreter.isCallable(cb.object))
        return self.throwError("TypeError", "Callback must be a function");
    const this_arg: Value = if (args.len > 1) args[1] else .undefined;
    const pairs = uspPairs(inst).?;
    const n = try pairsLen(self, pairs);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = (try pairAt(self, pairs, i)) orelse continue;
        const k = try pairKey(self, p);
        const v = try pairVal(self, p);
        const c = try self.callFunction(cb.object, &.{ .{ .string = v }, .{ .string = k }, this_val }, this_arg);
        if (c.isAbrupt()) return c;
    }
    return .{ .normal = .undefined };
}

/// Build a fresh JS array of keys / values / entry-arrays and return its Array Iterator (reusing the
/// engine's array iterator machinery).
fn uspIterator(self: *Interpreter, inst: *Object, kind: object_mod.IterKind) EvalError!Completion {
    const pairs = uspPairs(inst).?;
    const n = try pairsLen(self, pairs);
    const arr = try Object.createArray(self.arena, self.arrayProto());
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = (try pairAt(self, pairs, i)) orelse continue;
        const k = try pairKey(self, p);
        const v = try pairVal(self, p);
        const item: Value = switch (kind) {
            .key => .{ .string = k },
            .value => .{ .string = v },
            .entry => .{ .object = try makePair(self, k, v) },
        };
        try arr.arraySet(self.arena, i, item);
    }
    // keys/values/entries iterate the array's VALUES (each item placed above).
    return @import("interp_collection.zig").makeArrayIterator(self, .{ .object = arr }, .value);
}

// ════════════════════════════════════════════════════════════════════════════
//  TextEncoder / TextDecoder
// ════════════════════════════════════════════════════════════════════════════

/// `new TextEncoder()` / `new TextDecoder([label])` — stateless first-cut UTF-8 codecs; the instance
/// carries no slots (encoding/flags are constant accessors on the prototype).
fn codecConstruct(self: *Interpreter, this_val: Value) EvalError!Completion {
    _ = self;
    if (this_val != .object) return .{ .normal = .undefined };
    return .{ .normal = this_val };
}

/// Build a real byte-backed Uint8Array (NOT a Buffer) over a fresh ArrayBuffer holding `src`.
fn makeUint8Array(self: *Interpreter, src: []const u8) EvalError!*Object {
    const ab = Object.createArrayBuffer(self.arena, self.globalProto("ArrayBuffer"), src.len, null) catch return error.OutOfMemory;
    const proto = self.globalProto("Uint8Array");
    const ta = Object.createTypedArray(self.arena, proto, ab, 0, src.len, .u8) catch return error.OutOfMemory;
    if (ab.array_buffer) |abd| if (src.len > 0) @memcpy(abd.bytes[0..src.len], src);
    return ta;
}

fn teMethod(self: *Interpreter, name: []const u8, args: []const Value) EvalError!Completion {
    const eq = std.mem.eql;
    if (eq(u8, name, "encoding")) return .{ .normal = .{ .string = "utf-8" } };
    if (eq(u8, name, "encode")) {
        const sc = try self.toStringValuePub(if (args.len > 0) args[0] else .{ .string = "" });
        if (sc.isAbrupt()) return sc;
        return .{ .normal = .{ .object = try makeUint8Array(self, sc.normal.string) } };
    }
    if (eq(u8, name, "encodeInto")) {
        const sc = try self.toStringValuePub(if (args.len > 0) args[0] else .{ .string = "" });
        if (sc.isAbrupt()) return sc;
        const src = sc.normal.string;
        const dest: Value = if (args.len > 1) args[1] else .undefined;
        var written: usize = 0;
        if (dest == .object) if (dest.object.typed_array) |tad| if (tad.buffer.array_buffer) |abd| {
            const start = tad.byte_offset;
            const cap = if (abd.bytes.len > start) @min(tad.array_length, abd.bytes.len - start) else 0;
            const n = @min(src.len, cap);
            if (n > 0) @memcpy(abd.bytes[start .. start + n], src[0..n]);
            written = n;
        };
        const res = try Object.create(self.arena, self.objectProto());
        try res.defineData("read", .{ .number = @floatFromInt(written) }, true, true, true);
        try res.defineData("written", .{ .number = @floatFromInt(written) }, true, true, true);
        return .{ .normal = .{ .object = res } };
    }
    return .{ .normal = .undefined };
}

fn tdMethod(self: *Interpreter, name: []const u8, args: []const Value) EvalError!Completion {
    const eq = std.mem.eql;
    if (eq(u8, name, "encoding")) return .{ .normal = .{ .string = "utf-8" } };
    if (eq(u8, name, "fatal")) return .{ .normal = .{ .boolean = false } };
    if (eq(u8, name, "ignoreBOM")) return .{ .normal = .{ .boolean = false } };
    if (eq(u8, name, "decode")) {
        const v: Value = if (args.len > 0) args[0] else .undefined;
        if (v == .undefined) return .{ .normal = .{ .string = "" } };
        const bytes = bytesOfView(v) orelse return self.throwError("TypeError", "decode argument must be a typed array or ArrayBuffer");
        const s = self.arena.dupe(u8, bytes) catch return error.OutOfMemory;
        return .{ .normal = .{ .string = s } };
    }
    return .{ .normal = .undefined };
}

/// The bytes viewed by a typed array / DataView / ArrayBuffer value, or null.
fn bytesOfView(v: Value) ?[]const u8 {
    if (v != .object) return null;
    const o = v.object;
    if (o.typed_array) |ta| {
        const ab = ta.buffer.array_buffer orelse return null;
        const start = ta.byte_offset;
        const end = start + ta.array_length;
        if (end > ab.bytes.len) return null;
        return ab.bytes[start..end];
    }
    if (o.data_view) |dv| {
        const ab = dv.buffer.array_buffer orelse return null;
        const start = dv.byte_offset;
        const end = start + dv.byte_length;
        if (end > ab.bytes.len) return null;
        return ab.bytes[start..end];
    }
    if (o.array_buffer) |ab| return ab.bytes;
    return null;
}
