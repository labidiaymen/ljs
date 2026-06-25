const std = @import("std");
const ast = @import("lumen_ast.zig");
const diag_mod = @import("lumen_diag.zig");
const types = @import("lumen_types.zig");

const CompileError = diag_mod.CompileError;
const Diag = diag_mod.Diag;

const Checker = struct {
    arena: std.mem.Allocator,
    vars: std.StringHashMapUnmanaged(types.Type) = .empty,
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

    fn declare(self: *Checker, name: []const u8, t: types.Type) CompileError!void {
        self.vars.put(self.arena, name, t) catch return error.OutOfMemory;
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
            },
            .var_decl => |*decl| {
                const final_type = if (decl.annotation) |ann|
                    types.fromAnnotation(ann)
                else
                    self.exprType(program, decl.init, decl.line, decl.col) orelse
                        return self.fail(decl.line, decl.col, "cannot infer variable type");

                decl.checked_type = final_type;
                try self.declare(decl.name, final_type);
            },
            .assign => |assignment| {
                const expected_type = self.vars.get(assignment.name) orelse
                    return self.undefined_(assignment.name, assignment.line, assignment.col);
                const actual_type = self.exprType(program, assignment.value, assignment.line, assignment.col) orelse
                    return self.fail(assignment.line, assignment.col, "cannot infer assignment type");
                if (!types.same(expected_type, actual_type)) {
                    return self.fail(assignment.line, assignment.col, "E_TYPE_MISMATCH");
                }
            },
            .console_log => |log| {
                _ = self.exprType(program, log.value, log.line, log.col) orelse
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

    fn exprType(self: *Checker, program: *ast.Program, e: *const ast.Expr, line: u32, col: u32) ?types.Type {
        return switch (e.*) {
            .var_ref => |name| self.vars.get(name) orelse {
                _ = self.undefined_(name, line, col) catch {};
                return null;
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
            .field => |field| self.exprType(program, field.obj, line, col),
            .obj => null,
            .call => |call| {
                if (std.mem.eql(u8, call.name, "httpGet")) {
                    program.uses_io = true;
                    program.needs_httpget = true;
                    for (call.args) |arg| _ = self.exprType(program, arg, line, col) orelse return null;
                    return .i64;
                }
                if (std.mem.eql(u8, call.name, "serve")) {
                    program.uses_io = true;
                    program.needs_serve = true;
                    for (call.args) |arg| _ = self.exprType(program, arg, line, col) orelse return null;
                    return .void;
                }
                return null;
            },
            else => types.inferExprType(e),
        };
    }
};

pub fn checkProgram(arena: std.mem.Allocator, program: *ast.Program, diag: *Diag) CompileError!void {
    var checker = Checker{ .arena = arena };
    checker.checkProgram(program) catch |e| {
        diag.* = .{ .line = checker.last_line, .col = checker.last_col, .msg = checker.last_err };
        return e;
    };
}
