const std = @import("std");
const ast = @import("tjs_ast.zig");

pub fn inferExprType(e: *const ast.Expr) ?[]const u8 {
    return switch (e.*) {
        .num => "i32",
        .str => "[]const u8",
        .neg => |inner| inferExprType(inner),
        .bin => "i32",
        .cmp => "bool",
        .var_ref, .obj, .field, .call => null,
    };
}

pub fn sameType(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Map a source type name to its Zig type. Accepts TS-ish aliases; unknown names pass through (a
/// struct type declared with `type`).
pub fn mapType(name: []const u8) ?[]const u8 {
    const eq = std.mem.eql;
    if (eq(u8, name, "int") or eq(u8, name, "i32")) return "i32";
    if (eq(u8, name, "i64")) return "i64";
    if (eq(u8, name, "number") or eq(u8, name, "float") or eq(u8, name, "f64")) return "f64";
    if (eq(u8, name, "bool") or eq(u8, name, "boolean")) return "bool";
    if (eq(u8, name, "string")) return "[]const u8";
    return null;
}
