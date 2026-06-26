const std = @import("std");
const ast = @import("lumen_ast.zig");

pub const Type = union(enum) {
    i32,
    i64,
    f64,
    bool,
    string,
    void,
    named: []const u8,
};

pub fn inferExprType(e: *const ast.Expr) ?Type {
    return switch (e.*) {
        .num => .i32,
        .bool => .bool,
        .str => .string,
        .neg => |inner| inferExprType(inner),
        .bin => .i32,
        .cmp => .bool,
        .var_ref, .obj, .field, .call => null,
    };
}

pub fn same(a: Type, b: Type) bool {
    return switch (a) {
        .i32 => b == .i32,
        .i64 => b == .i64,
        .f64 => b == .f64,
        .bool => b == .bool,
        .string => b == .string,
        .void => b == .void,
        .named => |a_name| switch (b) {
            .named => |b_name| std.mem.eql(u8, a_name, b_name),
            else => false,
        },
    };
}

pub fn isNumeric(t: Type) bool {
    return switch (t) {
        .i32, .i64, .f64 => true,
        else => false,
    };
}

/// Parse a source type annotation. Unknown names are preserved as named types.
pub fn fromAnnotation(name: []const u8) Type {
    const eq = std.mem.eql;
    if (eq(u8, name, "int") or eq(u8, name, "i32")) return .i32;
    if (eq(u8, name, "i64")) return .i64;
    if (eq(u8, name, "number") or eq(u8, name, "float") or eq(u8, name, "f64")) return .f64;
    if (eq(u8, name, "bool") or eq(u8, name, "boolean")) return .bool;
    if (eq(u8, name, "string")) return .string;
    if (eq(u8, name, "void")) return .void;
    return .{ .named = name };
}

pub fn zigName(t: Type) []const u8 {
    return switch (t) {
        .i32 => "i32",
        .i64 => "i64",
        .f64 => "f64",
        .bool => "bool",
        .string => "[]const u8",
        .void => "void",
        .named => |name| name,
    };
}
