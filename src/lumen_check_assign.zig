//! Assignability and cast checking: "can a value of type X be used where Y is
//! expected" (`ensureAssignable`, called at every declaration/assignment/call
//! argument/return) and "is `expr as T` a sound type assertion"
//! (`castAllowed`, used by the `as` cast operator).
//!
//! Pulled out as a self-contained "type compatibility" concern, distinct from
//! computing an expression's type in the first place (`exprType`, in
//! `lumen_check_expr.zig`), which calls into this.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const diag_mod = @import("lumen_diag.zig");
const check_mod = @import("lumen_check.zig");

const Checker = check_mod.Checker;
const CompileError = diag_mod.CompileError;

pub fn ensureAssignable(self: *Checker, program: *ast.Program, expected: types.Type, value: *ast.Expr, line: u32, col: u32) CompileError!void {
    switch (expected) {
        .string_literal_union => |type_name| {
            const decl = self.type_decls.get(type_name) orelse return self.fail(line, col, "unknown type name");
            const literals = decl.string_literals orelse return self.fail(line, col, "E_TYPE_MISMATCH");
            if (value.* == .str) {
                for (literals) |literal| {
                    if (std.mem.eql(u8, literal, value.str)) return;
                }
                return self.fail(line, col, "E_TYPE_MISMATCH");
            }
            const actual_type = self.exprType(program, value, line, col) orelse return self.fail(line, col, "E_TYPE_MISMATCH");
            if (!types.same(expected, actual_type)) return self.fail(line, col, "E_TYPE_MISMATCH");
        },
        .int_literal_union => |type_name| {
            const decl = self.type_decls.get(type_name) orelse return self.fail(line, col, "unknown type name");
            const literals = decl.int_literals orelse return self.fail(line, col, "E_TYPE_MISMATCH");
            if (value.* == .num) {
                for (literals) |literal| {
                    if (literal == value.num) return;
                }
                return self.fail(line, col, "E_TYPE_MISMATCH");
            }
            const actual_type = self.exprType(program, value, line, col) orelse return self.fail(line, col, "E_TYPE_MISMATCH");
            if (!types.same(expected, actual_type)) return self.fail(line, col, "E_TYPE_MISMATCH");
        },
        .named => |type_name| {
            if (value.* != .obj) {
                const actual_type = self.exprType(program, value, line, col) orelse return self.fail(line, col, "E_TYPE_MISMATCH");
                if (!types.same(expected, actual_type)) return self.fail(line, col, "E_TYPE_MISMATCH");
                return;
            }
            const decl = self.type_decls.get(type_name) orelse return self.fail(line, col, "unknown type name");
            if (decl.string_literals != null) return self.fail(line, col, "E_TYPE_MISMATCH");
            const provided = value.obj;
            // A single `...src` spread may supply any fields not written
            // explicitly. The spread source must be a record assignable to the
            // target type.
            var spread_src: ?*ast.Expr = null;
            for (provided) |pf| {
                if (pf.is_spread) {
                    if (spread_src != null) return self.fail(line, col, "E_TYPE_MISMATCH");
                    try self.ensureAssignable(program, expected, pf.value, line, col);
                    spread_src = pf.value;
                    continue;
                }
                // Reject explicit fields not declared on the target type.
                var known = false;
                for (decl.fields) |df| {
                    if (std.mem.eql(u8, df.name, pf.name)) known = true;
                }
                if (!known) return self.fail(line, col, "E_TYPE_MISMATCH");
            }
            // Build the literal in declared order, filling omitted optional
            // fields with the absent value so emission has every field.
            const ordered = self.arena.alloc(ast.FieldInit, decl.fields.len) catch return error.OutOfMemory;
            for (decl.fields, 0..) |expected_field, i| {
                const expected_field_type = expected_field.checked_type orelse return self.fail(line, col, "unknown field type");
                if (check_mod.findField(provided, expected_field.name)) |value_field| {
                    try self.ensureAssignable(program, expected_field_type, value_field.value, line, col);
                    ordered[i] = value_field;
                } else if (spread_src) |src| {
                    // Inherit the field from the spread source: `src.field`.
                    const fref = self.arena.create(ast.Expr) catch return error.OutOfMemory;
                    fref.* = .{ .field = .{ .obj = src, .name = expected_field.name } };
                    ordered[i] = .{ .name = expected_field.name, .value = fref };
                } else if (expected_field_type == .optional) {
                    const absent = self.arena.create(ast.Expr) catch return error.OutOfMemory;
                    absent.* = .null_lit;
                    ordered[i] = .{ .name = expected_field.name, .value = absent };
                } else {
                    return self.fail(line, col, "E_TYPE_MISMATCH");
                }
            }
            value.* = .{ .obj = ordered };
        },
        .union_type => |union_name| {
            const uinfo = self.unions.get(union_name) orelse return self.fail(line, col, "unknown type name");
            // A union value flows through (same union, narrowed variant, or a
            // value already typed as one of the variants).
            if (value.* != .obj) {
                const actual_type = self.exprType(program, value, line, col) orelse return self.fail(line, col, "E_TYPE_MISMATCH");
                if (types.same(expected, actual_type)) return;
                if (actual_type == .named) {
                    for (uinfo.variants) |v| {
                        if (std.mem.eql(u8, v.name, actual_type.named)) return;
                    }
                }
                return self.fail(line, col, "E_TYPE_MISMATCH");
            }
            // An object literal must match exactly one variant. Match on the
            // discriminant field's literal value, then validate as that record.
            const disc_field = check_mod.findField(value.obj, uinfo.discriminant) orelse return self.fail(line, col, "E_TYPE_MISMATCH");
            if (disc_field.value.* != .str) return self.fail(line, col, "E_TYPE_MISMATCH");
            const tag = disc_field.value.str;
            for (uinfo.variants) |v| {
                if (std.mem.eql(u8, v.disc_value, tag)) {
                    return self.ensureAssignable(program, .{ .named = v.name }, value, line, col);
                }
            }
            return self.fail(line, col, "E_TYPE_MISMATCH");
        },
        .optional => |inner| {
            if (value.* == .null_lit) return; // absent is always assignable
            if (self.exprType(program, value, line, col)) |actual| {
                if (types.same(expected, actual)) return; // optional <- same optional
                if (actual == .none) return;
            }
            // otherwise the value must be assignable to the non-optional type
            return self.ensureAssignable(program, inner.*, value, line, col);
        },
        .i32_array, .i64_array, .f64_array, .bool_array, .string_array, .named_array => {
            if (value.* != .array) {
                const actual_type = self.exprType(program, value, line, col) orelse return self.fail(line, col, "E_TYPE_MISMATCH");
                if (!types.same(expected, actual_type)) return self.fail(line, col, "E_TYPE_MISMATCH");
                return;
            }
            const elem_type = types.arrayElem(expected) orelse return self.fail(line, col, "E_TYPE_MISMATCH");
            var has_spread = false;
            for (value.array.items) |item| {
                if (item.* == .spread) {
                    // `...src` must itself be an array of the same element type.
                    has_spread = true;
                    try self.ensureAssignable(program, expected, item.spread, line, col);
                } else {
                    try self.ensureAssignable(program, elem_type, item, line, col);
                }
            }
            if (has_spread) value.array.elem_type = elem_type;
        },
        .tuple_type => |elems| {
            // A tuple is written as an array literal of matching length whose
            // elements satisfy each position's declared type. Rewrite the
            // `.array` node into a `.tuple_lit` carrying the tuple type so the
            // emitter produces a positional struct rather than a slice.
            const items = switch (value.*) {
                .array => |a| a.items,
                .tuple_lit => |t| t.items,
                else => {
                    const actual_type = self.exprType(program, value, line, col) orelse return self.fail(line, col, "E_TYPE_MISMATCH");
                    if (!types.same(expected, actual_type)) return self.fail(line, col, "E_TYPE_MISMATCH");
                    return;
                },
            };
            if (items.len != elems.len) return self.fail(line, col, "E_TYPE_MISMATCH");
            for (items, elems) |item, et| {
                try self.ensureAssignable(program, et, item, line, col);
            }
            value.* = .{ .tuple_lit = .{ .items = items, .tuple_type = expected } };
        },
        else => {
            const actual_type = self.exprType(program, value, line, col) orelse return self.fail(line, col, "E_TYPE_MISMATCH");
            if (!types.same(expected, actual_type)) return self.fail(line, col, "E_TYPE_MISMATCH");
        },
    }
}

/// Whether `expr as T` is in the safe, representation-preserving subset: the
/// assertion is erased to the operand, so source and target must share the
/// same emitted layout. This covers identity, alias <-> underlying type, and
/// literal-union widening (`"a" | "b"` -> string, `1 | 2` -> int).
pub fn castAllowed(self: *Checker, source: types.Type, target: types.Type) bool {
    if (types.same(source, target)) return true;
    // A string-literal-union value may be asserted to/from string.
    if (source == .string_literal_union and target == .string) return true;
    if (source == .string and target == .string_literal_union) return true;
    if (source == .int_literal_union and target == .i32) return true;
    if (source == .i32 and target == .int_literal_union) return true;
    // Otherwise require an identical emitted layout so erasure stays sound.
    const sn = types.zigName(self.arena, source) catch return false;
    const tn = types.zigName(self.arena, target) catch return false;
    return std.mem.eql(u8, sn, tn);
}
