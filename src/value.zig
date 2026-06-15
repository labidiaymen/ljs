//! ECMAScript language values (ECMA-262 §6.1). M1 adds the Object reference; Symbol and
//! BigInt arrive in later milestones.
const std = @import("std");
const Object = @import("object.zig").Object;

pub const Value = union(enum) {
    undefined,
    null,
    boolean: bool,
    /// §6.1.6.1 Number — IEEE-754 double.
    number: f64,
    /// §6.1.4 String — UTF-8 bytes owned by the evaluation arena.
    string: []const u8,
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
            .object => try w.writeAll("[object Object]"), // §20.1.3.6 Object.prototype.toString (M1 stub)
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
