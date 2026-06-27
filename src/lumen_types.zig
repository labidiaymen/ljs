const std = @import("std");
const ast = @import("lumen_ast.zig");

pub const Type = union(enum) {
    i32,
    i64,
    f64,
    bool,
    string,
    void,
    error_obj,
    i32_array,
    i64_array,
    f64_array,
    bool_array,
    string_array,
    string_literal_union: []const u8,
    int_literal_union: []const u8,
    named: []const u8,
    named_array: []const u8,
    enum_type: EnumType,
    optional: *const Type, // T | null / T | undefined  ->  Zig ?T
    none, // the bare null/undefined literal, assignable to any optional
};

pub const EnumType = struct { name: []const u8, is_string: bool };

pub fn inferExprType(e: *const ast.Expr) ?Type {
    return switch (e.*) {
        .num => .i32,
        .float => .f64,
        .null_lit => .none,
        .bool => .bool,
        .str => .string,
        .neg => |inner| inferExprType(inner),
        .not => .bool,
        .bnot => |inner| inferExprType(inner),
        .bin => .i32,
        .bool_bin => .bool,
        .cmp => .bool,
        .ternary => |ternary| {
            const then_type = inferExprType(ternary.then_expr) orelse return null;
            const else_type = inferExprType(ternary.else_expr) orelse return null;
            return if (same(then_type, else_type)) then_type else null;
        },
        .template => .string,
        .array, .var_ref, .obj, .field, .index, .call, .static_call, .coalesce => null,
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
        .error_obj => b == .error_obj,
        .i32_array => b == .i32_array,
        .i64_array => b == .i64_array,
        .f64_array => b == .f64_array,
        .bool_array => b == .bool_array,
        .string_array => b == .string_array,
        .string_literal_union => |a_name| switch (b) {
            .string_literal_union => |b_name| std.mem.eql(u8, a_name, b_name),
            else => false,
        },
        .int_literal_union => |a_name| switch (b) {
            .int_literal_union => |b_name| std.mem.eql(u8, a_name, b_name),
            else => false,
        },
        .named => |a_name| switch (b) {
            .named => |b_name| std.mem.eql(u8, a_name, b_name),
            else => false,
        },
        .named_array => |a_name| switch (b) {
            .named_array => |b_name| std.mem.eql(u8, a_name, b_name),
            else => false,
        },
        .enum_type => |a_enum| switch (b) {
            .enum_type => |b_enum| std.mem.eql(u8, a_enum.name, b_enum.name),
            else => false,
        },
        .optional => |a_inner| switch (b) {
            .optional => |b_inner| same(a_inner.*, b_inner.*),
            else => false,
        },
        .none => b == .none,
    };
}

pub fn isOptional(t: Type) bool {
    return t == .optional;
}

/// The non-optional element type, or the type itself if not optional.
pub fn unwrapOptional(t: Type) Type {
    return switch (t) {
        .optional => |inner| inner.*,
        else => t,
    };
}

pub fn isNumeric(t: Type) bool {
    return switch (t) {
        .i32, .i64, .f64 => true,
        else => false,
    };
}

pub fn isInteger(t: Type) bool {
    return switch (t) {
        .i32, .i64 => true,
        else => false,
    };
}

pub fn isStringLike(t: Type) bool {
    return switch (t) {
        .string, .string_literal_union => true,
        else => false,
    };
}

pub fn isArray(t: Type) bool {
    return switch (t) {
        .i32_array, .i64_array, .f64_array, .bool_array, .string_array, .named_array => true,
        else => false,
    };
}

pub fn arrayElem(t: Type) ?Type {
    return switch (t) {
        .i32_array => .i32,
        .i64_array => .i64,
        .f64_array => .f64,
        .bool_array => .bool,
        .string_array => .string,
        .string_literal_union => .string,
        .named_array => |name| .{ .named = name },
        else => null,
    };
}

pub fn arrayOf(t: Type) ?Type {
    return switch (t) {
        .i32 => .i32_array,
        .i64 => .i64_array,
        .f64 => .f64_array,
        .bool => .bool_array,
        .string => .string_array,
        .named => |name| .{ .named_array = name },
        else => null,
    };
}

/// Parse a source type annotation. Unknown names are preserved as named types.
pub fn fromAnnotation(name: []const u8) Type {
    const eq = std.mem.eql;
    if (std.mem.endsWith(u8, name, "[]")) {
        const base = name[0 .. name.len - 2];
        const elem = fromAnnotation(base);
        return arrayOf(elem) orelse .{ .named = name };
    }
    if (eq(u8, name, "int") or eq(u8, name, "i32")) return .i32;
    if (eq(u8, name, "i64")) return .i64;
    if (eq(u8, name, "number") or eq(u8, name, "float") or eq(u8, name, "f64")) return .f64;
    if (eq(u8, name, "bool") or eq(u8, name, "boolean")) return .bool;
    if (eq(u8, name, "string")) return .string;
    if (eq(u8, name, "void")) return .void;
    return .{ .named = name };
}

pub fn zigName(arena: std.mem.Allocator, t: Type) ![]const u8 {
    return switch (t) {
        .i32 => "i32",
        .i64 => "i64",
        .f64 => "f64",
        .bool => "bool",
        .string => "[]const u8",
        .void => "void",
        .error_obj => "[]const u8",
        .i32_array => "[]const i32",
        .i64_array => "[]const i64",
        .f64_array => "[]const f64",
        .bool_array => "[]const bool",
        .string_array => "[]const []const u8",
        .string_literal_union => "[]const u8",
        .int_literal_union => "i32",
        .named => |name| name,
        .named_array => |name| try std.fmt.allocPrint(arena, "[]const {s}", .{name}),
        .enum_type => |e| if (e.is_string) "[]const u8" else "i32",
        .optional => |inner| try std.fmt.allocPrint(arena, "?{s}", .{try zigName(arena, inner.*)}),
        .none => "?u8", // defensive; a bare null is only valid in an optional context
    };
}
