const std = @import("std");
const ast = @import("lumen_ast.zig");
const diag_mod = @import("lumen_diag.zig");
const types = @import("lumen_types.zig");

const CompileError = diag_mod.CompileError;
const Diag = diag_mod.Diag;

const TypeDeclInfo = struct {
    fields: []ast.TypeField,
};

const Binding = struct {
    ty: types.Type,
    mutable: bool,
    decl: *ast.VarDecl,
};

const Checker = struct {
    arena: std.mem.Allocator,
    vars: std.StringHashMapUnmanaged(Binding) = .empty,
    type_decls: std.StringHashMapUnmanaged(TypeDeclInfo) = .empty,
    last_line: u32 = 1,
    last_col: u32 = 1,
    last_err: []const u8 = "syntax error",

    fn fail(self: *Checker, line: u32, col: u32, msg: []const u8) CompileError {
        self.last_line = line;
        self.last_col = col;
        self.last_err = msg;
        return error.ParseError;
    }

    fn undefined_(self: *Checker, name: []const u8, line: u32, col: u32) CompileError {
        self.last_err = std.fmt.allocPrint(self.arena, "undefined variable '{s}'", .{name}) catch "undefined variable";
        self.last_line = line;
        self.last_col = col;
        return error.ParseError;
    }

    fn declare(self: *Checker, name: []const u8, binding: Binding) CompileError!void {
        self.vars.put(self.arena, name, binding) catch return error.OutOfMemory;
    }

    fn declareType(self: *Checker, name: []const u8, fields: []ast.TypeField) CompileError!void {
        self.type_decls.put(self.arena, name, .{ .fields = fields }) catch return error.OutOfMemory;
    }

    fn checkProgram(self: *Checker, program: *ast.Program) CompileError!void {
        for (program.stmts) |*stmt| try self.checkStmt(program, stmt);
    }

    fn checkStmt(self: *Checker, program: *ast.Program, stmt: *ast.Stmt) CompileError!void {
        switch (stmt.*) {
            .type_decl => |*decl| {
                for (decl.fields) |*field| {
                    field.checked_type = types.fromAnnotation(field.annotation);
                }
                try self.declareType(decl.name, decl.fields);
            },
            .var_decl => |*decl| {
                const final_type = if (decl.annotation) |ann|
                    types.fromAnnotation(ann)
                else
                    self.exprType(program, decl.init, decl.line, decl.col) orelse
                        return self.fail(decl.line, decl.col, "cannot infer variable type");

                try self.ensureAssignable(program, final_type, decl.init, decl.line, decl.col);
                decl.checked_type = final_type;
                try self.declare(decl.name, .{ .ty = final_type, .mutable = decl.mutable, .decl = decl });
            },
            .assign => |assignment| {
                const binding = self.vars.getPtr(assignment.name) orelse
                    return self.undefined_(assignment.name, assignment.line, assignment.col);
                if (!binding.mutable) {
                    return self.fail(assignment.line, assignment.col, "E_CONST_ASSIGNMENT");
                }
                const expected_type = binding.ty;
                if (self.exprType(program, assignment.value, assignment.line, assignment.col)) |actual_type| {
                    if (!types.same(expected_type, actual_type)) {
                        return self.fail(assignment.line, assignment.col, "E_TYPE_MISMATCH");
                    }
                } else switch (expected_type) {
                    .named => {},
                    else => return self.fail(assignment.line, assignment.col, "cannot infer assignment type"),
                }
                try self.ensureAssignable(program, expected_type, assignment.value, assignment.line, assignment.col);
                binding.decl.reassigned = true;
            },
            .console_log => |*log| {
                log.checked_type = self.exprType(program, log.value, log.line, log.col) orelse
                    return self.fail(log.line, log.col, "cannot infer console.log argument type");
            },
            .while_stmt => |*loop| {
                _ = self.exprType(program, loop.cond, loop.line, loop.col) orelse
                    return self.fail(loop.line, loop.col, "cannot infer while condition type");
                for (loop.body) |*body_stmt| try self.checkStmt(program, body_stmt);
            },
            .expr_stmt => |expr_stmt| {
                _ = self.exprType(program, expr_stmt.value, expr_stmt.line, expr_stmt.col) orelse
                    return self.fail(expr_stmt.line, expr_stmt.col, "cannot infer expression type");
            },
        }
    }

    fn ensureAssignable(self: *Checker, program: *ast.Program, expected: types.Type, value: *const ast.Expr, line: u32, col: u32) CompileError!void {
        switch (expected) {
            .named => |type_name| {
                const decl = self.type_decls.get(type_name) orelse return self.fail(line, col, "unknown type name");
                if (value.* != .obj) return self.fail(line, col, "E_TYPE_MISMATCH");
                const fields = value.obj;
                if (fields.len != decl.fields.len) return self.fail(line, col, "E_TYPE_MISMATCH");
                for (decl.fields) |expected_field| {
                    const expected_field_type = expected_field.checked_type orelse return self.fail(line, col, "unknown field type");
                    const value_field = findField(fields, expected_field.name) orelse return self.fail(line, col, "E_TYPE_MISMATCH");
                    const actual_field_type = self.exprType(program, value_field.value, line, col) orelse return self.fail(line, col, "cannot infer object field type");
                    if (!types.same(expected_field_type, actual_field_type)) return self.fail(line, col, "E_TYPE_MISMATCH");
                }
            },
            else => {},
        }
    }

    fn exprType(self: *Checker, program: *ast.Program, e: *const ast.Expr, line: u32, col: u32) ?types.Type {
        return switch (e.*) {
            .var_ref => |name| blk: {
                const binding = self.vars.get(name) orelse {
                    _ = self.undefined_(name, line, col) catch {};
                    return null;
                };
                break :blk binding.ty;
            },
            .neg => |inner| self.exprType(program, inner, line, col),
            .bin => |bin| {
                _ = self.exprType(program, bin.l, line, col) orelse return null;
                _ = self.exprType(program, bin.r, line, col) orelse return null;
                return .i32;
            },
            .cmp => |cmp| {
                _ = self.exprType(program, cmp.l, line, col) orelse return null;
                _ = self.exprType(program, cmp.r, line, col) orelse return null;
                return .bool;
            },
            .field => |field| {
                const obj_type = self.exprType(program, field.obj, line, col) orelse return null;
                return switch (obj_type) {
                    .named => |type_name| self.fieldType(type_name, field.name, line, col),
                    else => null,
                };
            },
            .obj => null,
            .call => |call| {
                if (std.mem.eql(u8, call.name, "httpGet")) {
                    for (call.args) |arg| _ = self.exprType(program, arg, line, col) orelse return null;
                    program.uses_io = true;
                    program.needs_httpget = true;
                    return .i64;
                }
                if (std.mem.eql(u8, call.name, "serve")) {
                    for (call.args) |arg| _ = self.exprType(program, arg, line, col) orelse return null;
                    program.uses_io = true;
                    program.needs_serve = true;
                    return .void;
                }
                return null;
            },
            else => types.inferExprType(e),
        };
    }

    fn fieldType(self: *Checker, type_name: []const u8, field_name: []const u8, line: u32, col: u32) ?types.Type {
        const decl = self.type_decls.get(type_name) orelse {
            _ = self.fail(line, col, "unknown type name") catch {};
            return null;
        };
        for (decl.fields) |field| {
            if (std.mem.eql(u8, field.name, field_name)) {
                return field.checked_type orelse {
                    _ = self.fail(line, col, "unknown field type") catch {};
                    return null;
                };
            }
        }
        _ = self.fail(line, col, "unknown field") catch {};
        return null;
    }
};

fn findField(fields: []ast.FieldInit, name: []const u8) ?ast.FieldInit {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field;
    }
    return null;
}

pub fn checkProgram(arena: std.mem.Allocator, program: *ast.Program, diag: *Diag) CompileError!void {
    var checker = Checker{ .arena = arena };
    checker.checkProgram(program) catch |e| {
        diag.* = .{ .line = checker.last_line, .col = checker.last_col, .msg = checker.last_err };
        return e;
    };
}
