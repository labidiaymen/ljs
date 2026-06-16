//! ECMAScript language values (ECMA-262 §6.1). M1 adds the Object reference; M8 adds Symbol;
//! BigInt arrives in a later milestone.
const std = @import("std");
const Object = @import("object.zig").Object;

/// §6.1.5 The Symbol Type — a unique, immutable primitive value. Each Symbol has a stable
/// identity (pointer equality is the spec's SameValue for Symbols) and an optional [[Description]]
/// string. Allocated in the realm arena; `===` / SameValue compare by pointer. Well-known symbols
/// (`Symbol.iterator`, …) are ordinary `Symbol` values held on the `Symbol` constructor object.
pub const Symbol = struct {
    /// A process-unique id, purely for cheap display/debugging; identity is by pointer (`*Symbol`).
    id: u64,
    description: ?[]const u8 = null,
};

pub const Value = union(enum) {
    undefined,
    null,
    boolean: bool,
    /// §6.1.6.1 Number — IEEE-754 double.
    number: f64,
    /// §6.1.4 String — UTF-8 bytes owned by the evaluation arena.
    string: []const u8,
    /// §6.1.5 Symbol — a unique primitive identity (reference into the realm arena).
    symbol: *Symbol,
    /// §6.1.7 Object — reference into the realm arena.
    object: *Object,

    /// Observable display form used by the CLI and tests. This is a pragmatic subset of
    /// Number::toString (§6.1.6.1.21) / ToString (§7.1.17) sufficient for M0; full
    /// number-formatting conformance is a later milestone.
    pub fn writeDisplay(self: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .undefined => try w.writeAll("undefined"),
            .null => try w.writeAll("null"),
            .boolean => |b| try w.writeAll(if (b) "true" else "false"),
            .number => |n| try writeNumber(w, n),
            .string => |s| try w.print("\"{s}\"", .{s}),
            .symbol => |s| { // §20.4.3.3 SymbolDescriptiveString: `Symbol(desc)`
                try w.writeAll("Symbol(");
                if (s.description) |d| try w.writeAll(d);
                try w.writeAll(")");
            },
            .object => |o| {
                if (o.kind == .array) {
                    try w.writeAll("[");
                    for (o.elements.items, 0..) |el, i| {
                        if (i > 0) try w.writeAll(", ");
                        try el.writeDisplay(w);
                    }
                    try w.writeAll("]");
                } else if (o.kind == .function) {
                    try w.writeAll("[Function (anonymous)]");
                } else if (o.get("name")) |nv| { // error-like: "Name: message"
                    if (nv == .string) {
                        try w.writeAll(nv.string);
                        if (o.get("message")) |mv| {
                            if (mv == .string and mv.string.len > 0) {
                                try w.writeAll(": ");
                                try w.writeAll(mv.string);
                            }
                        }
                    } else try w.writeAll("[object Object]");
                } else try w.writeAll("[object Object]");
            },
        }
    }
};

fn writeNumber(w: *std.Io.Writer, n: f64) std.Io.Writer.Error!void {
    if (std.math.isNan(n)) return w.writeAll("NaN");
    if (std.math.isPositiveInf(n)) return w.writeAll("Infinity");
    if (std.math.isNegativeInf(n)) return w.writeAll("-Infinity");
    // Integer-valued numbers print without a decimal point (matches JS for the common case).
    if (n == @floor(n) and @abs(n) < 1e21) {
        try w.print("{d}", .{@as(i64, @intFromFloat(n))});
    } else {
        try w.print("{d}", .{n});
    }
}
