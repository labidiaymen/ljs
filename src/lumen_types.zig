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
    // A discriminated union over named record variants, identified by the union's
    // declared name. Lowers to a flat Zig struct (union of all variant fields).
    union_type: []const u8,
    enum_type: EnumType,
    optional: *const Type, // T | null / T | undefined  ->  Zig ?T
    none, // the bare null/undefined literal, assignable to any optional
    func_type: *const FuncSig, // (A, B) => R  ->  Zig *const fn(A, B) R
    class_type: []const u8, // a class instance  ->  Zig *Name (heap pointer)
};

pub const EnumType = struct { name: []const u8, is_string: bool };

pub const FuncSig = struct { params: []const Type, ret: *const Type };

// Registry of function-value (closure) signatures encountered during emission.
// The compiler points this at a list before emitting and drains it afterward to
// emit one `LumenFn_*` fat-pointer struct definition per distinct signature.
pub const SigEntry = struct { name: []const u8, sig: FuncSig };
pub var g_sig_registry: ?*std.ArrayListUnmanaged(SigEntry) = null;
pub var g_sig_arena: ?std.mem.Allocator = null;

fn mangle(arena: std.mem.Allocator, t: Type) error{OutOfMemory}![]const u8 {
    return switch (t) {
        .i32 => "i32",
        .i64 => "i64",
        .f64 => "f64",
        .bool => "bool",
        .string => "str",
        .void => "void",
        .error_obj => "err",
        .none => "none",
        .i32_array => "ar_i32",
        .i64_array => "ar_i64",
        .f64_array => "ar_f64",
        .bool_array => "ar_bool",
        .string_array => "ar_str",
        .string_literal_union => |n| try std.fmt.allocPrint(arena, "slu_{s}", .{n}),
        .int_literal_union => |n| try std.fmt.allocPrint(arena, "ilu_{s}", .{n}),
        .named => |n| n,
        .named_array => |n| try std.fmt.allocPrint(arena, "ar_{s}", .{n}),
        .union_type => |n| try std.fmt.allocPrint(arena, "un_{s}", .{n}),
        .enum_type => |e| try std.fmt.allocPrint(arena, "enum_{s}", .{e.name}),
        .optional => |inner| try std.fmt.allocPrint(arena, "opt_{s}", .{try mangle(arena, inner.*)}),
        .class_type => |n| try std.fmt.allocPrint(arena, "cls_{s}", .{n}),
        .func_type => |sig| blk: {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            try buf.appendSlice(arena, "fn");
            for (sig.params) |p| {
                try buf.append(arena, '_');
                try buf.appendSlice(arena, try mangle(arena, p));
            }
            try buf.appendSlice(arena, "_R_");
            try buf.appendSlice(arena, try mangle(arena, sig.ret.*));
            break :blk buf.items;
        },
    };
}

/// The Zig struct name for a function-value signature, registering it for
/// emission. Sanitizes the mangle into a valid identifier.
pub fn funcStructName(arena: std.mem.Allocator, sig: FuncSig) error{OutOfMemory}![]const u8 {
    var name_buf: std.ArrayListUnmanaged(u8) = .empty;
    try name_buf.appendSlice(arena, "LumenFn_");
    for (sig.params, 0..) |p, i| {
        if (i > 0) try name_buf.append(arena, '_');
        try name_buf.appendSlice(arena, try mangle(arena, p));
    }
    if (sig.params.len == 0) try name_buf.appendSlice(arena, "void");
    try name_buf.appendSlice(arena, "__R__");
    try name_buf.appendSlice(arena, try mangle(arena, sig.ret.*));
    for (name_buf.items) |*ch| {
        const ok = (ch.* >= 'a' and ch.* <= 'z') or (ch.* >= 'A' and ch.* <= 'Z') or (ch.* >= '0' and ch.* <= '9') or ch.* == '_';
        if (!ok) ch.* = '_';
    }
    const name = name_buf.items;
    if (g_sig_registry) |reg| {
        const arena2 = g_sig_arena orelse arena;
        var present = false;
        for (reg.items) |e| {
            if (std.mem.eql(u8, e.name, name)) {
                present = true;
                break;
            }
        }
        if (!present) reg.append(arena2, .{ .name = name, .sig = sig }) catch {};
    }
    return name;
}

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
        .array, .var_ref, .obj, .field, .index, .call, .static_call, .coalesce, .arrow, .this_expr, .new_expr, .method_call, .super_call, .cast => null,
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
        .union_type => |a_name| switch (b) {
            .union_type => |b_name| std.mem.eql(u8, a_name, b_name),
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
        .class_type => |a_name| switch (b) {
            .class_type => |b_name| std.mem.eql(u8, a_name, b_name),
            else => false,
        },
        .func_type => |a_sig| switch (b) {
            .func_type => |b_sig| blk: {
                if (a_sig.params.len != b_sig.params.len) break :blk false;
                for (a_sig.params, b_sig.params) |ap, bp| {
                    if (!same(ap, bp)) break :blk false;
                }
                break :blk same(a_sig.ret.*, b_sig.ret.*);
            },
            else => false,
        },
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

/// Render a resolved type back to a canonical source annotation string. The
/// inverse of `fromAnnotation` for the V1 type surface; used when a generic type
/// argument inferred as a `Type` must be substituted back into a template's
/// annotations. Returns null for types with no annotation spelling.
pub fn toAnnotation(arena: std.mem.Allocator, t: Type) error{OutOfMemory}!?[]const u8 {
    return switch (t) {
        .i32 => "int",
        .i64 => "i64",
        .f64 => "number",
        .bool => "bool",
        .string => "string",
        .void => "void",
        .i32_array => "int[]",
        .i64_array => "i64[]",
        .f64_array => "number[]",
        .bool_array => "bool[]",
        .string_array => "string[]",
        .named => |n| n,
        .named_array => |n| try std.fmt.allocPrint(arena, "{s}[]", .{n}),
        .union_type => |n| n,
        .class_type => |n| n,
        .enum_type => |e| e.name,
        .string_literal_union => |n| n,
        .int_literal_union => |n| n,
        .optional => |inner| blk: {
            const inner_ann = (try toAnnotation(arena, inner.*)) orelse break :blk null;
            break :blk try std.fmt.allocPrint(arena, "{s}?", .{inner_ann});
        },
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
        .union_type => |name| name,
        .enum_type => |e| if (e.is_string) "[]const u8" else "i32",
        .optional => |inner| try std.fmt.allocPrint(arena, "?{s}", .{try zigName(arena, inner.*)}),
        .none => "?u8", // defensive; a bare null is only valid in an optional context
        .func_type => |sig| try funcStructName(arena, sig.*),
        .class_type => |name| try std.fmt.allocPrint(arena, "*{s}", .{name}),
    };
}
