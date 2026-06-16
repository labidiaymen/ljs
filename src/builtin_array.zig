//! §23.1.3 `Array.prototype` methods + `Array.isArray`. Native built-ins dispatched from the
//! interpreter's `callNative`; `this` is the receiver array. Lives in its own file so the
//! interpreter stays the evaluator and Cycles 2+ add sibling `builtin_string.zig` etc.
const std = @import("std");
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const Object = @import("object.zig").Object;
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const ops = @import("abstract_ops.zig");

pub fn call(it: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    const eql = std.mem.eql;
    if (eql(u8, name, "isArray")) {
        const v: Value = if (args.len > 0) args[0] else .undefined;
        return .{ .normal = .{ .boolean = v == .object and v.object.kind == .array } };
    }
    if (this_val != .object or this_val.object.kind != .array) {
        return it.throwError("TypeError", "Array.prototype method called on non-array");
    }
    const arr = this_val.object;
    if (eql(u8, name, "push")) {
        for (args) |a| try arr.elements.append(it.arena, a);
        return .{ .normal = .{ .number = @floatFromInt(arr.elements.items.len) } };
    }
    if (eql(u8, name, "pop")) {
        if (arr.elements.pop()) |v| return .{ .normal = v };
        return .{ .normal = .undefined };
    }
    if (eql(u8, name, "indexOf")) {
        const target: Value = if (args.len > 0) args[0] else .undefined;
        for (arr.elements.items, 0..) |el, i| {
            if (ops.strictEquals(el, target)) return .{ .normal = .{ .number = @floatFromInt(i) } };
        }
        return .{ .normal = .{ .number = -1 } };
    }
    if (eql(u8, name, "includes")) {
        const target: Value = if (args.len > 0) args[0] else .undefined;
        for (arr.elements.items) |el| {
            if (ops.strictEquals(el, target)) return .{ .normal = .{ .boolean = true } };
        }
        return .{ .normal = .{ .boolean = false } };
    }
    if (eql(u8, name, "join") or eql(u8, name, "toString")) {
        // §23.1.3.36 Array.prototype.toString delegates to join with the default `,` separator
        // (M-subset: join is the array's own join, not an arbitrary overridden one).
        const sep = if (eql(u8, name, "join") and args.len > 0 and args[0] != .undefined) try it.toString(args[0]) else ",";
        var buf: std.ArrayList(u8) = .empty;
        for (arr.elements.items, 0..) |el, i| {
            if (i > 0) try buf.appendSlice(it.arena, sep);
            if (el != .undefined and el != .null) try buf.appendSlice(it.arena, try it.toString(el));
        }
        return .{ .normal = .{ .string = buf.items } };
    }
    if (eql(u8, name, "slice")) {
        const len = arr.elements.items.len;
        const start = relIndex(if (args.len > 0) args[0] else .undefined, len, 0);
        const end = relIndex(if (args.len > 1) args[1] else .undefined, len, len);
        const out = try Object.createArray(it.arena, it.arrayProto());
        var i = start;
        while (i < end) : (i += 1) try out.elements.append(it.arena, arr.elements.items[i]);
        return .{ .normal = .{ .object = out } };
    }
    if (eql(u8, name, "forEach") or eql(u8, name, "map")) {
        if (args.len == 0 or args[0] != .object or args[0].object.kind != .function) {
            return it.throwError("TypeError", "callback is not a function");
        }
        const cb = args[0].object;
        const is_map = eql(u8, name, "map");
        const out: ?*Object = if (is_map) try Object.createArray(it.arena, it.arrayProto()) else null;
        for (arr.elements.items, 0..) |el, i| {
            const r = try it.callFunction(cb, &.{ el, .{ .number = @floatFromInt(i) }, this_val }, .undefined);
            if (r.isAbrupt()) return r;
            if (out) |o| try o.elements.append(it.arena, r.normal);
        }
        if (out) |o| return .{ .normal = .{ .object = o } };
        return .{ .normal = .undefined };
    }
    return .{ .normal = .undefined };
}

/// §23.1.3 relative index (negative counts from the end), clamped to [0, len].
fn relIndex(v: Value, len: usize, default: usize) usize {
    if (v == .undefined) return default;
    const n = ops.toNumber(v);
    if (std.math.isNan(n)) return 0;
    const flen: f64 = @floatFromInt(len);
    var idx = n;
    if (idx < 0) idx += flen;
    if (idx < 0) idx = 0;
    if (idx > flen) idx = flen;
    return @intFromFloat(idx);
}
