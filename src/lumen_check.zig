const std = @import("std");
const ast = @import("lumen_ast.zig");
const diag_mod = @import("lumen_diag.zig");
const types = @import("lumen_types.zig");

const CompileError = diag_mod.CompileError;
const Diag = diag_mod.Diag;

const TypeDeclInfo = struct {
    fields: []ast.TypeField,
};

const FunctionInfo = struct {
    params: []ast.FunctionParam,
    return_type: types.Type,
};

const Binding = struct {
    ty: types.Type,
    mutable: bool,
    decl: ?*ast.VarDecl = null,
    emit_name: []const u8,
};

const Scope = std.StringHashMapUnmanaged(Binding);

const Checker = struct {
    arena: std.mem.Allocator,
    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    type_decls: std.StringHashMapUnmanaged(TypeDeclInfo) = .empty,
    funcs: std.StringHashMapUnmanaged(FunctionInfo) = .empty,
    next_binding_id: u32 = 0,
    current_return_type: ?types.Type = null,
    nested_stmt_depth: u32 = 0,
    last_line: u32 = 1,
    last_col: u32 = 1,
    last_err: []const u8 = "syntax error",

    fn fail(self: *Checker, line: u32, col: u32, msg: []const u8) CompileError {
        self.last_line = line;
        self.last_col = col;
        self.last_err = msg;
        return error.ParseError;
    }

    fn inferenceFail(self: *Checker, line: u32, col: u32, msg: []const u8) CompileError {
        if (self.last_line == line and self.last_col == col and !std.mem.eql(u8, self.last_err, "syntax error")) {
            return error.ParseError;
        }
        return self.fail(line, col, msg);
    }

    fn undefined_(self: *Checker, name: []const u8, line: u32, col: u32) CompileError {
        self.last_err = std.fmt.allocPrint(self.arena, "undefined variable '{s}'", .{name}) catch "undefined variable";
        self.last_line = line;
        self.last_col = col;
        return error.ParseError;
    }

    fn currentScope(self: *Checker) *Scope {
        return &self.scopes.items[self.scopes.items.len - 1];
    }

    fn pushScope(self: *Checker) CompileError!void {
        self.scopes.append(self.arena, .empty) catch return error.OutOfMemory;
    }

    fn popScope(self: *Checker) void {
        self.scopes.items.len -= 1;
    }

    fn binding(self: *Checker, name: []const u8) ?Binding {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name)) |found| return found;
        }
        return null;
    }

    fn bindingPtr(self: *Checker, name: []const u8) ?*Binding {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].getPtr(name)) |found| return found;
        }
        return null;
    }

    fn freshEmitName(self: *Checker, name: []const u8) CompileError![]const u8 {
        const id = self.next_binding_id;
        self.next_binding_id += 1;
        return std.fmt.allocPrint(self.arena, "__lumen_{d}_{s}", .{ id, name }) catch error.OutOfMemory;
    }

    fn declare(self: *Checker, name: []const u8, decl: *ast.VarDecl, ty: types.Type, line: u32, col: u32) CompileError!void {
        const scope = self.currentScope();
        if (scope.get(name) != null) return self.fail(line, col, "E_DUPLICATE_BINDING");
        const emit_name = try self.freshEmitName(name);
        decl.emit_name = emit_name;
        scope.put(self.arena, name, .{ .ty = ty, .mutable = decl.mutable, .decl = decl, .emit_name = emit_name }) catch return error.OutOfMemory;
    }

    fn declareParam(self: *Checker, param: ast.FunctionParam, line: u32, col: u32) CompileError!void {
        const scope = self.currentScope();
        if (scope.get(param.name) != null) return self.fail(line, col, "E_DUPLICATE_BINDING");
        const param_type = param.checked_type orelse types.fromAnnotation(param.annotation);
        scope.put(self.arena, param.name, .{ .ty = param_type, .mutable = true, .emit_name = param.name }) catch return error.OutOfMemory;
    }

    fn declareType(self: *Checker, name: []const u8, fields: []ast.TypeField, line: u32, col: u32) CompileError!void {
        if (self.type_decls.get(name) != null) return self.fail(line, col, "E_DUPLICATE_BINDING");
        self.type_decls.put(self.arena, name, .{ .fields = fields }) catch return error.OutOfMemory;
    }

    fn declareFunction(self: *Checker, decl: *ast.FunctionDecl) CompileError!void {
        if (self.funcs.get(decl.name) != null) return self.fail(decl.line, decl.col, "E_DUPLICATE_BINDING");
        const return_type = types.fromAnnotation(decl.return_annotation);
        for (decl.params) |*param| {
            param.checked_type = types.fromAnnotation(param.annotation);
        }
        decl.checked_return_type = return_type;
        self.funcs.put(self.arena, decl.name, .{ .params = decl.params, .return_type = return_type }) catch return error.OutOfMemory;
    }

    fn checkProgram(self: *Checker, program: *ast.Program) CompileError!void {
        try self.pushScope();
        for (program.stmts) |*stmt| {
            if (stmt.* == .function_decl) try self.declareFunction(&stmt.function_decl);
        }
        for (program.stmts) |*stmt| try self.checkStmt(program, stmt);
    }

    fn checkBlock(self: *Checker, program: *ast.Program, body: []ast.Stmt) CompileError!void {
        try self.pushScope();
        defer self.popScope();
        self.nested_stmt_depth += 1;
        defer self.nested_stmt_depth -= 1;
        for (body) |*body_stmt| try self.checkStmt(program, body_stmt);
    }

    fn checkFunctionBody(self: *Checker, program: *ast.Program, decl: *ast.FunctionDecl) CompileError!void {
        const previous_return_type = self.current_return_type;
        self.current_return_type = decl.checked_return_type;
        defer self.current_return_type = previous_return_type;

        try self.pushScope();
        defer self.popScope();
        for (decl.params) |param| try self.declareParam(param, decl.line, decl.col);
        self.nested_stmt_depth += 1;
        defer self.nested_stmt_depth -= 1;
        for (decl.body) |*body_stmt| try self.checkStmt(program, body_stmt);

        const return_type = decl.checked_return_type orelse types.fromAnnotation(decl.return_annotation);
        if (return_type != .void and !blockReturns(decl.body)) {
            return self.fail(decl.line, decl.col, "E_MISSING_RETURN");
        }
    }

    fn blockReturns(body: []ast.Stmt) bool {
        for (body) |stmt| {
            if (stmtReturns(stmt)) return true;
        }
        return false;
    }

    fn stmtReturns(stmt: ast.Stmt) bool {
        return switch (stmt) {
            .return_stmt => true,
            .if_stmt => |branch| branch.else_body != null and blockReturns(branch.then_body) and blockReturns(branch.else_body.?),
            else => false,
        };
    }

    fn checkStmt(self: *Checker, program: *ast.Program, stmt: *ast.Stmt) CompileError!void {
        switch (stmt.*) {
            .type_decl => |*decl| {
                for (decl.fields) |*field| {
                    field.checked_type = types.fromAnnotation(field.annotation);
                }
                try self.declareType(decl.name, decl.fields, decl.line, decl.col);
            },
            .function_decl => |*decl| {
                if (self.nested_stmt_depth > 0) return self.fail(decl.line, decl.col, "E_UNSUPPORTED_NESTED_FUNCTION");
                if (decl.checked_return_type == null) try self.declareFunction(decl);
                try self.checkFunctionBody(program, decl);
            },
            .var_decl => |*decl| {
                const final_type = if (decl.annotation) |ann|
                    types.fromAnnotation(ann)
                else
                    self.exprType(program, decl.init, decl.line, decl.col) orelse
                        return self.inferenceFail(decl.line, decl.col, "cannot infer variable type");
                if (final_type == .void) return self.fail(decl.line, decl.col, "E_VOID_VALUE");

                try self.ensureAssignable(program, final_type, decl.init, decl.line, decl.col);
                decl.checked_type = final_type;
                try self.declare(decl.name, decl, final_type, decl.line, decl.col);
            },
            .assign => |*assignment| {
                const found_binding = self.bindingPtr(assignment.name) orelse
                    return self.undefined_(assignment.name, assignment.line, assignment.col);
                if (!found_binding.mutable) {
                    return self.fail(assignment.line, assignment.col, "E_CONST_ASSIGNMENT");
                }
                const expected_type = found_binding.ty;
                if (self.exprType(program, assignment.value, assignment.line, assignment.col)) |actual_type| {
                    if (!types.same(expected_type, actual_type)) {
                        return self.fail(assignment.line, assignment.col, "E_TYPE_MISMATCH");
                    }
                } else switch (expected_type) {
                    .named => {},
                    else => return self.inferenceFail(assignment.line, assignment.col, "cannot infer assignment type"),
                }
                try self.ensureAssignable(program, expected_type, assignment.value, assignment.line, assignment.col);
                if (found_binding.decl) |decl| decl.reassigned = true;
                assignment.emit_name = found_binding.emit_name;
            },
            .console_log => |*log| {
                const log_type = self.exprType(program, log.value, log.line, log.col) orelse
                    return self.inferenceFail(log.line, log.col, "cannot infer console.log argument type");
                if (log_type == .void) return self.fail(log.line, log.col, "E_VOID_VALUE");
                log.checked_type = log_type;
            },
            .while_stmt => |*loop| {
                const cond_type = self.exprType(program, loop.cond, loop.line, loop.col) orelse
                    return self.inferenceFail(loop.line, loop.col, "cannot infer while condition type");
                if (!types.same(.bool, cond_type)) return self.fail(loop.line, loop.col, "E_TYPE_MISMATCH");
                try self.checkBlock(program, loop.body);
            },
            .if_stmt => |*branch| {
                const cond_type = self.exprType(program, branch.cond, branch.line, branch.col) orelse
                    return self.inferenceFail(branch.line, branch.col, "cannot infer if condition type");
                if (!types.same(.bool, cond_type)) return self.fail(branch.line, branch.col, "E_TYPE_MISMATCH");
                try self.checkBlock(program, branch.then_body);
                if (branch.else_body) |else_body| {
                    try self.checkBlock(program, else_body);
                }
            },
            .expr_stmt => |expr_stmt| {
                _ = self.exprType(program, expr_stmt.value, expr_stmt.line, expr_stmt.col) orelse
                    return self.inferenceFail(expr_stmt.line, expr_stmt.col, "cannot infer expression type");
            },
            .return_stmt => |*ret| {
                const expected_return = self.current_return_type orelse
                    return self.fail(ret.line, ret.col, "E_RETURN_OUTSIDE_FUNCTION");
                const value = ret.value orelse {
                    if (expected_return == .void) {
                        ret.checked_type = .void;
                        return;
                    }
                    return self.fail(ret.line, ret.col, "E_RETURN_TYPE");
                };
                const actual_return = self.exprType(program, value, ret.line, ret.col) orelse
                    return self.inferenceFail(ret.line, ret.col, "cannot infer return type");
                if (!types.same(expected_return, actual_return)) return self.fail(ret.line, ret.col, "E_RETURN_TYPE");
                ret.checked_type = actual_return;
            },
        }
    }

    fn ensureAssignable(self: *Checker, program: *ast.Program, expected: types.Type, value: *ast.Expr, line: u32, col: u32) CompileError!void {
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
            .i32_array, .i64_array, .f64_array, .bool_array, .string_array => {
                if (value.* != .array) return self.fail(line, col, "E_TYPE_MISMATCH");
                const elem_type = types.arrayElem(expected) orelse return self.fail(line, col, "E_TYPE_MISMATCH");
                for (value.array) |item| {
                    const item_type = self.exprType(program, item, line, col) orelse return self.fail(line, col, "cannot infer array element type");
                    if (!types.same(elem_type, item_type)) return self.fail(line, col, "E_TYPE_MISMATCH");
                }
            },
            else => {},
        }
    }

    fn exprType(self: *Checker, program: *ast.Program, e: *ast.Expr, line: u32, col: u32) ?types.Type {
        return switch (e.*) {
            .var_ref => |*ref| blk: {
                const found_binding = self.binding(ref.name) orelse {
                    _ = self.undefined_(ref.name, line, col) catch {};
                    return null;
                };
                ref.emit_name = found_binding.emit_name;
                break :blk found_binding.ty;
            },
            .neg => |inner| self.exprType(program, inner, line, col),
            .not => |inner| {
                const inner_type = self.exprType(program, inner, line, col) orelse return null;
                if (!types.same(.bool, inner_type)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                return .bool;
            },
            .bin => |bin| {
                const left_type = self.exprType(program, bin.l, line, col) orelse return null;
                const right_type = self.exprType(program, bin.r, line, col) orelse return null;
                if (!types.isNumeric(left_type) or !types.same(left_type, right_type)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                return left_type;
            },
            .bool_bin => |bin| {
                const left_type = self.exprType(program, bin.l, line, col) orelse return null;
                const right_type = self.exprType(program, bin.r, line, col) orelse return null;
                if (!types.same(.bool, left_type) or !types.same(.bool, right_type)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                return .bool;
            },
            .cmp => |*cmp| {
                const left_type = self.exprType(program, cmp.l, line, col) orelse return null;
                const right_type = self.exprType(program, cmp.r, line, col) orelse return null;
                if (!types.same(left_type, right_type)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                if (!std.mem.eql(u8, cmp.op, "==") and !std.mem.eql(u8, cmp.op, "!=") and !types.isNumeric(left_type)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                cmp.checked_operand_type = left_type;
                return .bool;
            },
            .array => |items| {
                if (items.len == 0) {
                    _ = self.fail(line, col, "cannot infer array type") catch {};
                    return null;
                }
                const first_type = self.exprType(program, items[0], line, col) orelse return null;
                for (items[1..]) |item| {
                    const item_type = self.exprType(program, item, line, col) orelse return null;
                    if (!types.same(first_type, item_type)) {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                }
                return types.arrayOf(first_type) orelse {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                };
            },
            .field => |*field| {
                const obj_type = self.exprType(program, field.obj, line, col) orelse return null;
                if ((obj_type == .string or types.isArray(obj_type)) and std.mem.eql(u8, field.name, "length")) {
                    field.builtin = .length;
                    return .i64;
                }
                return switch (obj_type) {
                    .named => |type_name| self.fieldType(type_name, field.name, line, col),
                    else => null,
                };
            },
            .index => |*index| {
                const obj_type = self.exprType(program, index.obj, line, col) orelse return null;
                const index_type = self.exprType(program, index.value, line, col) orelse return null;
                if (!types.same(.i32, index_type) and !types.same(.i64, index_type)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                const elem_type = types.arrayElem(obj_type) orelse {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                };
                index.checked_element_type = elem_type;
                return elem_type;
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
                const func = self.funcs.get(call.name) orelse {
                    _ = self.fail(line, col, "unknown function") catch {};
                    return null;
                };
                if (call.args.len != func.params.len) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                for (call.args, func.params) |arg, param| {
                    const arg_type = self.exprType(program, arg, line, col) orelse return null;
                    const param_type = param.checked_type orelse types.fromAnnotation(param.annotation);
                    if (!types.same(param_type, arg_type)) {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                }
                return func.return_type;
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
