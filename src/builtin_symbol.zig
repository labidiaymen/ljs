//! §20.4 Symbol — the constructor, `Symbol.prototype` methods (toString/valueOf/[@@toPrimitive]/
//! description) and the GlobalSymbolRegistry statics (`for`/`keyFor`). Dispatched from the
//! interpreter's `callNative`. Lives in its own file so the interpreter stays the evaluator.
const std = @import("std");
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const Value = @import("value.zig").Value;
const Symbol = @import("value.zig").Symbol;
const Completion = @import("completion.zig").Completion;
const builtins = @import("builtins.zig");

/// §20.4.1.1 Symbol ( [ description ] ) — mint a fresh unique Symbol whose [[Description]] is
/// ToString(description) (or undefined when omitted). Called only as a function (`new Symbol()` is
/// rejected in `construct`).
pub fn constructor(it: *Interpreter, args: []const Value) EvalError!Completion {
    const desc: ?[]const u8 = if (args.len > 0 and args[0] != .undefined)
        try it.toString(args[0]) // §20.4.1.1 step 2: ToString(description)
    else
        null;
    const sym = try builtins.newSymbol(it.arena, desc);
    return .{ .normal = .{ .symbol = sym } };
}

/// §20.4.3.3 Symbol.prototype.toString / §20.4.3.4 valueOf / §20.4.3.5 [Symbol.toPrimitive] — `this`
/// must be a Symbol (primitive or wrapper); `toString` returns its SymbolDescriptiveString, the others
/// return the Symbol itself. The `native_name` selects.
pub fn toStringMethod(it: *Interpreter, native_name: []const u8, this_val: Value) EvalError!Completion {
    // §20.4.3 ThisSymbolValue: `this` is a Symbol primitive OR a Symbol wrapper object (unwrap it).
    const sym: Value = switch (this_val) {
        .symbol => this_val,
        .object => |o| if (o.primitive) |p| (if (p == .symbol) p else return it.throwError("TypeError", "not a Symbol")) else return it.throwError("TypeError", "not a Symbol"),
        else => return it.throwError("TypeError", "Symbol.prototype method requires that 'this' be a Symbol"),
    };
    if (std.mem.eql(u8, native_name, "valueOf") or std.mem.eql(u8, native_name, "[Symbol.toPrimitive]")) {
        return .{ .normal = sym };
    }
    return .{ .normal = .{ .string = try it.toString(sym) } };
}

/// §20.4.3.2 get Symbol.prototype.description — the [[Description]] (a string, or undefined).
pub fn description(it: *Interpreter, this_val: Value) EvalError!Completion {
    const sym: *Symbol = switch (this_val) {
        .symbol => |s| s,
        .object => |o| if (o.primitive) |p| (if (p == .symbol) p.symbol else return it.throwError("TypeError", "not a Symbol")) else return it.throwError("TypeError", "not a Symbol"),
        else => return it.throwError("TypeError", "get description requires that 'this' be a Symbol"),
    };
    return .{ .normal = if (sym.description) |d| .{ .string = d } else .undefined };
}

/// §20.4.2.2 Symbol.for ( key ) / §20.4.2.6 Symbol.keyFor ( sym ).
pub fn static(it: *Interpreter, native_name: []const u8, args: []const Value) EvalError!Completion {
    const arg0: Value = if (args.len > 0) args[0] else .undefined;
    if (std.mem.eql(u8, native_name, "for")) {
        const sc = try it.toStringValuePub(arg0); // §20.4.2.2 step 1: stringKey = ToString(key)
        if (sc.isAbrupt()) return sc;
        const k = sc.normal.string;
        if (it.symbol_registry.get(k)) |existing| return .{ .normal = .{ .symbol = existing } };
        const sym = try builtins.newSymbol(it.arena, k);
        sym.registry_key = k;
        try it.symbol_registry.put(it.arena, k, sym);
        return .{ .normal = .{ .symbol = sym } };
    }
    // §20.4.2.6 Symbol.keyFor ( sym ) — sym MUST be a Symbol; returns its registry key or undefined.
    if (arg0 != .symbol) return it.throwError("TypeError", "Symbol.keyFor requires a Symbol argument");
    return .{ .normal = if (arg0.symbol.registry_key) |rk| .{ .string = rk } else .undefined };
}
