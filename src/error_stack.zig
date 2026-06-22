//! V8/Node-compatible `Error.prototype.stack` formatting + the `Error.prepareStackTrace` CallSite API
//! (spec 119). Frames are snapshotted at Error construction (`Interpreter.captureStack` →
//! `Object.error_stack`); this module turns them into either the V8 string or CallSite objects.
//!
//! NOT ECMA-262 (the stack string is implementation-defined) — a host/V8 compatibility surface. Never
//! consulted on the Test262 conformance path (errors there don't read `.stack` content).
const std = @import("std");
const Value = @import("value.zig").Value;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const rt = @import("runtime_types.zig");
const parser = @import("parser.zig");

/// The `.stack` value for `err`: the result of `Error.prepareStackTrace(err, callSites)` when that
/// hook is a function, else the V8-format string. Computed lazily on each `stack` get (so a hook set
/// after construction still applies — matching V8).
pub fn build(self: *Interpreter, err: *Object) EvalError!Completion {
    const frames: []rt.StackFrame = err.error_stack orelse &.{};
    if (prepareHook(self)) |hook| {
        const arr = try buildCallSites(self, frames);
        return self.callFunction(hook, &.{ .{ .object = err }, .{ .object = arr } }, .undefined);
    }
    return .{ .normal = .{ .string = try formatString(self, err, frames) } };
}

/// `Error.prepareStackTrace` if it is currently a callable function, else null.
fn prepareHook(self: *Interpreter) ?*Object {
    const g = self.globals orelse return null;
    const eb = g.lookup("Error") orelse return null;
    if (eb.value != .object) return null;
    const h = eb.value.object.get("prepareStackTrace") orelse return null;
    if (h == .object and h.object.kind == .function) return h.object;
    return null;
}

// ── string formatting ────────────────────────────────────────────────────────

fn formatString(self: *Interpreter, err: *Object, frames: []rt.StackFrame) EvalError![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(self.arena, try header(self, err));
    for (frames, 0..) |fr, i| {
        try out.appendSlice(self.arena, "\n    at ");
        try appendFrame(self, &out, fr, i == frames.len - 1);
    }
    return out.items;
}

/// `<Name>: <message>` (or just `<Name>` when the message is empty) — the first `.stack` line.
fn header(self: *Interpreter, err: *Object) EvalError![]const u8 {
    const name = try strProp(self, err, "name", "Error");
    const msg = try strProp(self, err, "message", "");
    if (msg.len == 0) return name;
    return std.mem.concat(self.arena, u8, &.{ name, ": ", msg }) catch return error.OutOfMemory;
}

fn appendFrame(self: *Interpreter, out: *std.ArrayListUnmanaged(u8), fr: rt.StackFrame, is_last: bool) EvalError!void {
    const a = self.arena;
    const fname = frameName(fr);
    const src = frameSrc(fr);
    if (fr.kind == .native or src.len == 0) {
        // No source position available → `fname (native)` (or `<anonymous> (native)`).
        try out.appendSlice(a, if (fname.len != 0) fname else "<anonymous>");
        try out.appendSlice(a, " (native)");
        return;
    }
    const lc = parser.lineColOf(src, fr.cur_pos);
    const file = frameSrcName(fr);
    // V8 labels the outermost (module top-level) anonymous frame `Object.<anonymous>`; a non-top
    // anonymous function is `<anonymous>`. A named function uses its name.
    const label = if (fname.len != 0) fname else if (is_last) "Object.<anonymous>" else "<anonymous>";
    try out.appendSlice(a, label);
    try out.appendSlice(a, " (");
    try appendLoc(self, out, file, lc.line, lc.col);
    try out.append(a, ')');
}

fn appendLoc(self: *Interpreter, out: *std.ArrayListUnmanaged(u8), file: []const u8, line: usize, col: usize) EvalError!void {
    const s = std.fmt.allocPrint(self.arena, "{s}:{d}:{d}", .{ if (file.len != 0) file else "<anonymous>", line, col }) catch return error.OutOfMemory;
    try out.appendSlice(self.arena, s);
}

// ── frame field accessors ────────────────────────────────────────────────────

fn frameName(fr: rt.StackFrame) []const u8 {
    const f = fr.func orelse return "";
    if (fr.kind == .native) return f.native_name;
    if (f.get("name")) |nv| if (nv == .string) return nv.string;
    return "";
}

fn frameSrc(fr: rt.StackFrame) []const u8 {
    const f = fr.func orelse return "";
    const fd = f.call orelse return "";
    return fd.src;
}

fn frameSrcName(fr: rt.StackFrame) []const u8 {
    const f = fr.func orelse return "";
    const fd = f.call orelse return "";
    return fd.src_name;
}

/// Best-effort read of a string-valued own/inherited property (for `name`/`message`); `dflt` on miss
/// or non-string (avoids re-entrant ToString during stack formatting).
fn strProp(self: *Interpreter, obj: *Object, key: []const u8, dflt: []const u8) ![]const u8 {
    _ = self;
    const v = obj.get(key) orelse return dflt;
    return if (v == .string) v.string else dflt;
}

// ── CallSite objects (Error.prepareStackTrace) ───────────────────────────────

/// Build a JS Array of CallSite objects (innermost first) for the `prepareStackTrace` hook.
fn buildCallSites(self: *Interpreter, frames: []rt.StackFrame) EvalError!*Object {
    const arr = try Object.createArray(self.arena, self.arrayProto());
    for (frames, 0..) |fr, i| {
        const cs = try makeCallSite(self, fr);
        try arr.arraySet(self.arena, i, .{ .object = cs });
    }
    return arr;
}

const callsite_methods = [_][]const u8{
    "getThis",         "getTypeName",   "getFunction",     "getFunctionName", "getMethodName",
    "getFileName",     "getLineNumber", "getColumnNumber", "getEvalOrigin",   "isToplevel",
    "isEval",          "isNative",      "isConstructor",   "isAsync",         "isPromiseAll",
    "getPromiseIndex", "toString",
};

fn makeCallSite(self: *Interpreter, fr: rt.StackFrame) EvalError!*Object {
    const a = self.arena;
    const cs = try Object.create(a, self.objectProto());
    // Stash the resolved frame facts as hidden own props the methods read back.
    const src = frameSrc(fr);
    const has_loc = fr.kind != .native and src.len != 0;
    var line: usize = 0;
    var col: usize = 0;
    if (has_loc) {
        const lc = parser.lineColOf(src, fr.cur_pos);
        line = lc.line;
        col = lc.col;
    }
    try cs.defineData("%file%", .{ .string = frameSrcName(fr) }, false, false, false);
    try cs.defineData("%line%", .{ .number = @floatFromInt(line) }, false, false, false);
    try cs.defineData("%col%", .{ .number = @floatFromInt(col) }, false, false, false);
    try cs.defineData("%fn%", .{ .string = frameName(fr) }, false, false, false);
    try cs.defineData("%native%", .{ .boolean = fr.kind == .native or !has_loc }, false, false, false);
    try cs.defineData("%ctor%", .{ .boolean = fr.kind == .ctor }, false, false, false);
    try cs.defineData("%this%", fr.this_val, false, false, false);
    if (fr.func) |f| try cs.defineData("%func%", .{ .object = f }, false, false, false);
    for (callsite_methods) |m| {
        const fn_obj = try Object.createNative(a, .callsite_method, m);
        fn_obj.prototype = self.functionProto();
        _ = fn_obj.properties.orderedRemove("prototype");
        try fn_obj.defineData("name", .{ .string = m }, false, false, true);
        try cs.defineData(m, .{ .object = fn_obj }, false, false, true);
    }
    return cs;
}

/// Dispatch a `.callsite_method` native (`this` is the CallSite object).
pub fn callsiteMethod(self: *Interpreter, name: []const u8, this_val: Value) EvalError!Completion {
    if (this_val != .object) return .{ .normal = .null };
    const cs = this_val.object;
    const eq = std.mem.eql;
    const get = struct {
        fn p(o: *Object, k: []const u8) Value {
            return o.get(k) orelse .undefined;
        }
    }.p;
    if (eq(u8, name, "getFileName")) {
        const f = get(cs, "%file%");
        return .{ .normal = if (f == .string and f.string.len != 0) f else .null };
    }
    if (eq(u8, name, "getLineNumber")) {
        const l = get(cs, "%line%");
        return .{ .normal = if (l == .number and l.number > 0) l else .null };
    }
    if (eq(u8, name, "getColumnNumber")) {
        const c = get(cs, "%col%");
        return .{ .normal = if (c == .number and c.number > 0) c else .null };
    }
    if (eq(u8, name, "getFunctionName") or eq(u8, name, "getMethodName")) {
        const fnm = get(cs, "%fn%");
        return .{ .normal = if (fnm == .string and fnm.string.len != 0) fnm else .null };
    }
    if (eq(u8, name, "getTypeName")) {
        const t = get(cs, "%this%");
        if (t == .object) {
            if (t.object.get("constructor")) |cv| if (cv == .object)
                if (cv.object.get("name")) |nv| if (nv == .string) return .{ .normal = nv };
        }
        return .{ .normal = .null };
    }
    if (eq(u8, name, "getThis")) return .{ .normal = get(cs, "%this%") };
    if (eq(u8, name, "getFunction")) return .{ .normal = get(cs, "%func%") };
    if (eq(u8, name, "isNative")) return .{ .normal = get(cs, "%native%") };
    if (eq(u8, name, "isConstructor")) return .{ .normal = get(cs, "%ctor%") };
    if (eq(u8, name, "isToplevel")) {
        const fnm = get(cs, "%fn%");
        return .{ .normal = .{ .boolean = !(fnm == .string and fnm.string.len != 0) } };
    }
    if (eq(u8, name, "isEval") or eq(u8, name, "isAsync") or eq(u8, name, "isPromiseAll")) {
        return .{ .normal = .{ .boolean = false } };
    }
    if (eq(u8, name, "getEvalOrigin") or eq(u8, name, "getPromiseIndex")) {
        return .{ .normal = .null };
    }
    if (eq(u8, name, "toString")) {
        const fnm = get(cs, "%fn%");
        const file = get(cs, "%file%");
        const line = get(cs, "%line%");
        const col = get(cs, "%col%");
        const file_s = if (file == .string and file.string.len != 0) file.string else "<anonymous>";
        const ln: usize = if (line == .number) @intFromFloat(line.number) else 0;
        const cn: usize = if (col == .number) @intFromFloat(col.number) else 0;
        const s = if (fnm == .string and fnm.string.len != 0)
            std.fmt.allocPrint(self.arena, "{s} ({s}:{d}:{d})", .{ fnm.string, file_s, ln, cn }) catch return error.OutOfMemory
        else
            std.fmt.allocPrint(self.arena, "{s}:{d}:{d}", .{ file_s, ln, cn }) catch return error.OutOfMemory;
        return .{ .normal = .{ .string = s } };
    }
    return .{ .normal = .undefined };
}
