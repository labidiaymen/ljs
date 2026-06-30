//! Type-checking for stdlib/builtin calls: `Math.*`, `String.*`, `Array.*`,
//! `fs.*`, `Promise.*` static namespace calls, plus instance methods on
//! arrays/Maps/Sets/strings (`.push`, `.get`, `.indexOf`, ...).
//!
//! Each function here validates a call's argument count and types, sets any
//! `program.needs_*`/`program.uses_io` flags the codegen prologue needs, fills
//! the resolved type onto the AST node (e.g. `call.checked_type`), and returns
//! the call's result `Type` (or `null` plus a diagnostic on error). This is
//! pulled out of `lumen_check.zig` because it grows independently of the rest
//! of the checker -- adding a new `fs.*Sync` function (see `fsCallType`) never
//! needs to touch scoping, narrowing, generics, or class resolution.
//!
//! These are `Checker` methods physically defined in a different file: they
//! take `self: *Checker` as an explicit first parameter and are aliased back
//! onto the `Checker` type in `lumen_check.zig` (`pub const arrayMethod =
//! lumen_check_stdlib.arrayMethod;`), so `self.arrayMethod(...)` call sites
//! elsewhere in the checker are unchanged. This relies on Zig allowing a
//! circular `@import` between this file and `lumen_check.zig` (this file needs
//! the `Checker` type; `lumen_check.zig` needs these functions) -- supported
//! because it is a circular *reference*, not a circular *type definition*.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const check_mod = @import("lumen_check.zig");

const Checker = check_mod.Checker;

pub fn arrayMethod(self: *Checker, program: *ast.Program, mc: anytype, obj_type: types.Type, line: u32, col: u32) ?types.Type {
    const elem = types.arrayElem(obj_type) orelse {
        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
        return null;
    };
    mc.array_elem_type = elem;
    const name = mc.name;
    const eq = std.mem.eql;

    // Methods taking a single `(T) => bool` predicate.
    if (eq(u8, name, "filter") or eq(u8, name, "find") or eq(u8, name, "some") or eq(u8, name, "every")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const want = self.makeFuncType(&.{elem}, .bool) orelse return null;
        self.ensureAssignable(program, want, mc.args[0], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        if (eq(u8, name, "some") or eq(u8, name, "every")) {
            mc.array_result_type = .bool;
            return .bool;
        }
        if (eq(u8, name, "filter")) {
            mc.array_result_type = obj_type;
            return obj_type;
        }
        // find -> T | null
        const inner = self.arena.create(types.Type) catch return null;
        inner.* = elem;
        const res = types.Type{ .optional = inner };
        mc.array_result_type = res;
        return res;
    }

    // map((T) => U): U[]  — result element type is the callback return type.
    if (eq(u8, name, "map")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const cb_type = self.exprType(program, mc.args[0], line, col) orelse return null;
        if (cb_type != .func_type or cb_type.func_type.params.len != 1 or !types.same(cb_type.func_type.params[0], elem)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        const u = cb_type.func_type.ret.*;
        const res = types.arrayOf(u) orelse {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        mc.array_result_type = res;
        return res;
    }

    // forEach((T) => void): void
    if (eq(u8, name, "forEach")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const want = self.makeFuncType(&.{elem}, .void) orelse return null;
        self.ensureAssignable(program, want, mc.args[0], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        mc.array_result_type = .void;
        return .void;
    }

    // reduce((U, T) => U, init: U): U  — init fixes the accumulator type.
    if (eq(u8, name, "reduce")) {
        if (mc.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const acc = self.exprType(program, mc.args[1], line, col) orelse return null;
        const want = self.makeFuncType(&.{ acc, elem }, acc) orelse return null;
        self.ensureAssignable(program, want, mc.args[0], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        mc.array_acc_type = acc;
        mc.array_result_type = acc;
        return acc;
    }

    // indexOf(x: T): int  /  includes(x: T): bool
    if (eq(u8, name, "indexOf") or eq(u8, name, "includes")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, elem, mc.args[0], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        const res: types.Type = if (eq(u8, name, "includes")) .bool else .i32;
        mc.array_result_type = res;
        return res;
    }

    // join(sep?: string): string
    if (eq(u8, name, "join")) {
        if (mc.args.len > 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        if (mc.args.len == 1) {
            self.ensureAssignable(program, .string, mc.args[0], line, col) catch {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            };
        }
        mc.array_result_type = .string;
        return .string;
    }

    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
    return null;
}

/// Validate a method call on a `Map<K,V>` receiver and return its result type.
pub fn mapMethod(self: *Checker, program: *ast.Program, mc: anytype, obj_type: types.Type, line: u32, col: u32) ?types.Type {
    mc.container_type = obj_type;
    const key = obj_type.map_type.key.*;
    const value = obj_type.map_type.value.*;
    const name = mc.name;
    const eq = std.mem.eql;

    if (eq(u8, name, "set")) {
        if (mc.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, key, mc.args[0], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        self.ensureAssignable(program, value, mc.args[1], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        return .void;
    }
    if (eq(u8, name, "get")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, key, mc.args[0], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        const inner = self.arena.create(types.Type) catch return null;
        inner.* = value;
        return .{ .optional = inner };
    }
    if (eq(u8, name, "has") or eq(u8, name, "delete")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, key, mc.args[0], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        return .bool;
    }
    if (eq(u8, name, "keys")) {
        if (mc.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        return types.arrayOf(key) orelse {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
    }
    if (eq(u8, name, "values")) {
        if (mc.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        return types.arrayOf(value) orelse {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
    }
    if (eq(u8, name, "forEach")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const want = self.makeFuncType(&.{ value, key }, .void) orelse return null;
        self.ensureAssignable(program, want, mc.args[0], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        return .void;
    }
    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
    return null;
}

/// Validate a method call on a `Set<T>` receiver and return its result type.
pub fn setMethod(self: *Checker, program: *ast.Program, mc: anytype, obj_type: types.Type, line: u32, col: u32) ?types.Type {
    mc.container_type = obj_type;
    const elem = obj_type.set_type.*;
    const name = mc.name;
    const eq = std.mem.eql;

    if (eq(u8, name, "add")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, elem, mc.args[0], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        return .void;
    }
    if (eq(u8, name, "has") or eq(u8, name, "delete")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, elem, mc.args[0], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        return .bool;
    }
    if (eq(u8, name, "values")) {
        if (mc.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        return types.arrayOf(elem) orelse {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
    }
    if (eq(u8, name, "forEach")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const want = self.makeFuncType(&.{elem}, .void) orelse return null;
        self.ensureAssignable(program, want, mc.args[0], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        return .void;
    }
    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
    return null;
}

/// Validate an instance method call on a `string` receiver and return its
/// statically-known result type. Mirrors `arrayMethod`.
pub fn stringMethod(self: *Checker, program: *ast.Program, mc: anytype, line: u32, col: u32) ?types.Type {
    mc.string_method = true;
    const name = mc.name;
    const eq = std.mem.eql;

    const ArgKind = enum { string, int };
    const Spec = struct { min: usize, max: usize, kinds: []const ArgKind, result: types.Type };

    // Each method's expected argument shape and result type.
    const spec: Spec = blk: {
        if (eq(u8, name, "charAt")) break :blk .{ .min = 1, .max = 1, .kinds = &.{.int}, .result = .string };
        if (eq(u8, name, "charCodeAt")) break :blk .{ .min = 1, .max = 1, .kinds = &.{.int}, .result = .i32 };
        if (eq(u8, name, "indexOf")) break :blk .{ .min = 1, .max = 1, .kinds = &.{.string}, .result = .i32 };
        if (eq(u8, name, "includes")) break :blk .{ .min = 1, .max = 1, .kinds = &.{.string}, .result = .bool };
        if (eq(u8, name, "startsWith")) break :blk .{ .min = 1, .max = 1, .kinds = &.{.string}, .result = .bool };
        if (eq(u8, name, "endsWith")) break :blk .{ .min = 1, .max = 1, .kinds = &.{.string}, .result = .bool };
        if (eq(u8, name, "slice")) break :blk .{ .min = 1, .max = 2, .kinds = &.{ .int, .int }, .result = .string };
        if (eq(u8, name, "substring")) break :blk .{ .min = 1, .max = 2, .kinds = &.{ .int, .int }, .result = .string };
        if (eq(u8, name, "repeat")) break :blk .{ .min = 1, .max = 1, .kinds = &.{.int}, .result = .string };
        if (eq(u8, name, "padStart")) break :blk .{ .min = 2, .max = 2, .kinds = &.{ .int, .string }, .result = .string };
        if (eq(u8, name, "replace")) break :blk .{ .min = 2, .max = 2, .kinds = &.{ .string, .string }, .result = .string };
        if (eq(u8, name, "toUpperCase")) break :blk .{ .min = 0, .max = 0, .kinds = &.{}, .result = .string };
        if (eq(u8, name, "toLowerCase")) break :blk .{ .min = 0, .max = 0, .kinds = &.{}, .result = .string };
        if (eq(u8, name, "trim")) break :blk .{ .min = 0, .max = 0, .kinds = &.{}, .result = .string };
        if (eq(u8, name, "split")) break :blk .{ .min = 1, .max = 1, .kinds = &.{.string}, .result = types.arrayOf(.string).? };
        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
        return null;
    };

    if (mc.args.len < spec.min or mc.args.len > spec.max) {
        _ = self.fail(line, col, "E_ARG_COUNT") catch {};
        return null;
    }
    for (mc.args, 0..) |arg, i| {
        switch (spec.kinds[i]) {
            .string => self.ensureAssignable(program, .string, arg, line, col) catch {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            },
            .int => {
                const at = self.exprType(program, arg, line, col) orelse return null;
                if (!types.isInteger(at)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
            },
        }
    }
    mc.array_result_type = spec.result;
    return spec.result;
}

pub fn staticCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.namespace, "Math")) return self.mathCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "String")) return self.stringCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "Array")) return self.arrayCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "fs")) return self.fsCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "Promise")) return self.promiseCallType(program, call, line, col);
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

pub fn fsCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "readFileSync")) {
        if (call.args.len != 1 and call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        if (call.args.len == 2) {
            const encoding_type = self.exprType(program, call.args[1], line, col) orelse return null;
            if (!types.same(.string, encoding_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        program.uses_io = true;
        program.needs_read_file_sync = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "existsSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_exists_sync = true;
        call.checked_type = .bool;
        return .bool;
    }
    if (std.mem.eql(u8, call.name, "writeFileSync") or std.mem.eql(u8, call.name, "appendFileSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const data_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.same(.string, data_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        if (std.mem.eql(u8, call.name, "writeFileSync")) program.needs_write_file_sync = true else program.needs_append_file_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "mkdirSync")) {
        if (call.args.len != 1 and call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        if (call.args.len == 2) {
            const recursive_type = self.exprType(program, call.args[1], line, col) orelse return null;
            if (!types.same(.bool, recursive_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        program.uses_io = true;
        program.needs_mkdir_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "unlinkSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_unlink_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "renameSync") or std.mem.eql(u8, call.name, "copyFileSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const a_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const b_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, a_type) or !types.same(.string, b_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        if (std.mem.eql(u8, call.name, "renameSync")) program.needs_rename_sync = true else program.needs_copy_file_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "rmdirSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_rmdir_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "rmSync")) {
        if (call.args.len != 1 and call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        if (call.args.len == 2) {
            const recursive_type = self.exprType(program, call.args[1], line, col) orelse return null;
            if (!types.same(.bool, recursive_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        program.uses_io = true;
        program.needs_rm_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "truncateSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const len_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.isInteger(len_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_truncate_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "linkSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const a_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const b_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, a_type) or !types.same(.string, b_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_link_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "symlinkSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const a_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const b_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, a_type) or !types.same(.string, b_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_symlink_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "readlinkSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_readlink_sync = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "chmodSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const mode_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.isInteger(mode_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_chmod_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "accessSync")) {
        if (call.args.len != 1 and call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        if (call.args.len == 2) {
            const mode_type = self.exprType(program, call.args[1], line, col) orelse return null;
            if (!types.isInteger(mode_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        program.uses_io = true;
        program.needs_access_sync = true;
        call.checked_type = .bool;
        return .bool;
    }
    if (std.mem.eql(u8, call.name, "cpSync")) {
        if (call.args.len != 2 and call.args.len != 3) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const a_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const b_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, a_type) or !types.same(.string, b_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        if (call.args.len == 3) {
            const recursive_type = self.exprType(program, call.args[2], line, col) orelse return null;
            if (!types.same(.bool, recursive_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        program.uses_io = true;
        program.needs_cp_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "mkdtempSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const prefix_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, prefix_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_mkdtemp_sync = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "statSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        // A builtin record return: lazily register a synthetic record type
        // (`__LumenStat`) the first time statSync is used, then return it like
        // any user-declared `type X = {...}`. This is a deliberate deviation
        // from Node: isFile/isDirectory are plain bool fields here, not
        // methods (Lumen has no method dispatch on a builtin-record type yet).
        if (self.type_decls.get("__LumenStat") == null) {
            const fields = self.arena.alloc(ast.TypeField, 4) catch return null;
            fields[0] = .{ .name = "size", .annotation = "int", .checked_type = .i32 };
            fields[1] = .{ .name = "isFile", .annotation = "bool", .checked_type = .bool };
            fields[2] = .{ .name = "isDirectory", .annotation = "bool", .checked_type = .bool };
            fields[3] = .{ .name = "mtimeMs", .annotation = "int", .checked_type = .i32 };
            self.type_decls.put(self.arena, "__LumenStat", .{ .fields = fields }) catch return null;
        }
        program.uses_io = true;
        program.needs_stat_sync = true;
        call.checked_type = .{ .named = "__LumenStat" };
        return .{ .named = "__LumenStat" };
    }
    if (std.mem.eql(u8, call.name, "openSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const flags_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.same(.string, flags_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fd_api = true;
        call.checked_type = .i32;
        return .i32;
    }
    if (std.mem.eql(u8, call.name, "closeSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isInteger(fd_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fd_api = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "readSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const len_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.isInteger(fd_type) or !types.isInteger(len_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fd_api = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "writeSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const data_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.isInteger(fd_type) or !types.same(.string, data_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fd_api = true;
        call.checked_type = .i32;
        return .i32;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

pub fn promiseCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    // `Promise.resolve(v)` -> an already-resolved `Promise<typeof v>`.
    if (std.mem.eql(u8, call.name, "resolve")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const inner = self.exprType(program, call.args[0], line, col) orelse return null;
        const p = self.arena.create(types.Type) catch return null;
        p.* = inner;
        const result = types.Type{ .promise_type = p };
        // Inner type drives `__promiseResolved(T, v)`; result is `Promise<T>`.
        call.checked_arg_type = inner;
        call.checked_type = result;
        program.uses_io = true;
        program.needs_async = true;
        return result;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

pub fn mathCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "abs") or std.mem.eql(u8, call.name, "sign") or std.mem.eql(u8, call.name, "sqrt")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const arg_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isNumeric(arg_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        call.checked_arg_type = arg_type;
        call.checked_type = if (std.mem.eql(u8, call.name, "sign")) .i32 else if (std.mem.eql(u8, call.name, "sqrt")) .f64 else arg_type;
        return call.checked_type;
    }
    if (std.mem.eql(u8, call.name, "max") or std.mem.eql(u8, call.name, "min")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const left_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const right_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.isNumeric(left_type) or !types.same(left_type, right_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        call.checked_arg_type = left_type;
        call.checked_type = left_type;
        return left_type;
    }
    if (std.mem.eql(u8, call.name, "clamp")) {
        if (call.args.len != 3) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const value_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const min_type = self.exprType(program, call.args[1], line, col) orelse return null;
        const max_type = self.exprType(program, call.args[2], line, col) orelse return null;
        if (!types.isNumeric(value_type) or !types.same(value_type, min_type) or !types.same(value_type, max_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        call.checked_arg_type = value_type;
        call.checked_type = value_type;
        return value_type;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

pub fn stringCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "isEmpty")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const arg_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, arg_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        call.checked_type = .bool;
        return .bool;
    }
    if (std.mem.eql(u8, call.name, "contains") or std.mem.eql(u8, call.name, "startsWith")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const left_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const right_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, left_type) or !types.same(.string, right_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        call.checked_type = .bool;
        return .bool;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

pub fn arrayCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (!std.mem.eql(u8, call.name, "isEmpty")) {
        _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
        return null;
    }
    if (call.args.len != 1) {
        _ = self.fail(line, col, "E_ARG_COUNT") catch {};
        return null;
    }
    const arg_type = self.exprType(program, call.args[0], line, col) orelse return null;
    if (!types.isArray(arg_type)) {
        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
        return null;
    }
    call.checked_type = .bool;
    return .bool;
}
