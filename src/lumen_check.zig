const std = @import("std");
const ast = @import("lumen_ast.zig");
const diag_mod = @import("lumen_diag.zig");
const types = @import("lumen_types.zig");

const CompileError = diag_mod.CompileError;
const Diag = diag_mod.Diag;

const TypeDeclInfo = struct {
    fields: []ast.TypeField,
    string_literals: ?[][]const u8 = null,
    int_literals: ?[]i64 = null,
};

const FunctionInfo = struct {
    params: []ast.FunctionParam,
    return_type: types.Type,
};

const EnumInfo = struct {
    is_string: bool,
    members: []ast.EnumMember,
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
    enums: std.StringHashMapUnmanaged(EnumInfo) = .empty,
    funcs: std.StringHashMapUnmanaged(FunctionInfo) = .empty,
    next_binding_id: u32 = 0,
    current_return_type: ?types.Type = null,
    nested_stmt_depth: u32 = 0,
    loop_depth: u32 = 0,
    switch_depth: u32 = 0,
    test_depth: u32 = 0,
    narrowed: std.ArrayListUnmanaged([]const u8) = .empty,
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

    fn isNarrowed(self: *Checker, name: []const u8) bool {
        for (self.narrowed.items) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    /// If `cond` is `x != null` / `x !== null` (or undefined) returns the binding
    /// narrowed in the then-branch; `x == null` returns it for the else-branch.
    /// `in_then` says which branch the non-optional narrowing applies to.
    fn narrowTarget(cond: *ast.Expr) ?struct { name: []const u8, in_then: bool } {
        if (cond.* != .cmp) return null;
        const c = cond.cmp;
        const is_ne = std.mem.eql(u8, c.op, "!=");
        const is_eq = std.mem.eql(u8, c.op, "==");
        if (!is_ne and !is_eq) return null;
        var name: ?[]const u8 = null;
        if (c.l.* == .var_ref and c.r.* == .null_lit) name = c.l.var_ref.name;
        if (c.r.* == .var_ref and c.l.* == .null_lit) name = c.r.var_ref.name;
        const n = name orelse return null;
        return .{ .name = n, .in_then = is_ne };
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
        const param_type = param.checked_type orelse try self.typeFromAnnotation(param.annotation, line, col);
        scope.put(self.arena, param.name, .{ .ty = param_type, .mutable = true, .emit_name = param.name }) catch return error.OutOfMemory;
    }

    fn declareCatch(self: *Checker, stmt: *ast.TryStmt) CompileError!void {
        const scope = self.currentScope();
        if (scope.get(stmt.catch_name) != null) return self.fail(stmt.line, stmt.col, "E_DUPLICATE_BINDING");
        const emit_name = try self.freshEmitName(stmt.catch_name);
        stmt.catch_emit_name = emit_name;
        scope.put(self.arena, stmt.catch_name, .{ .ty = .error_obj, .mutable = false, .emit_name = emit_name }) catch return error.OutOfMemory;
    }

    fn declareType(self: *Checker, name: []const u8, fields: []ast.TypeField, string_literals: ?[][]const u8, int_literals: ?[]i64, line: u32, col: u32) CompileError!void {
        if (self.type_decls.get(name) != null) return self.fail(line, col, "E_DUPLICATE_BINDING");
        self.type_decls.put(self.arena, name, .{ .fields = fields, .string_literals = string_literals, .int_literals = int_literals }) catch return error.OutOfMemory;
    }

    fn funcSigType(self: *Checker, finfo: FunctionInfo) CompileError!types.Type {
        const params = self.arena.alloc(types.Type, finfo.params.len) catch return error.OutOfMemory;
        for (finfo.params, 0..) |p, i| params[i] = p.checked_type orelse return error.ParseError;
        const ret_p = self.arena.create(types.Type) catch return error.OutOfMemory;
        ret_p.* = finfo.return_type;
        const sig = self.arena.create(types.FuncSig) catch return error.OutOfMemory;
        sig.* = .{ .params = params, .ret = ret_p };
        return .{ .func_type = sig };
    }

    fn typeFromAnnotation(self: *Checker, annotation: []const u8, line: u32, col: u32) CompileError!types.Type {
        // Function type: `(T,...)=>R`
        if (annotation.len > 0 and annotation[0] == '(') {
            var depth: u32 = 0;
            var close: usize = 0;
            var found = false;
            for (annotation, 0..) |ch, i| {
                if (ch == '(') {
                    depth += 1;
                } else if (ch == ')') {
                    depth -= 1;
                    if (depth == 0) {
                        close = i;
                        found = true;
                        break;
                    }
                }
            }
            if (found and std.mem.startsWith(u8, annotation[close + 1 ..], "=>")) {
                const params_str = annotation[1..close];
                const ret_str = annotation[close + 3 ..];
                var params: std.ArrayListUnmanaged(types.Type) = .empty;
                if (params_str.len > 0) {
                    var it = std.mem.splitScalar(u8, params_str, ',');
                    while (it.next()) |ps| {
                        try params.append(self.arena, try self.typeFromAnnotation(ps, line, col));
                    }
                }
                const ret_p = self.arena.create(types.Type) catch return error.OutOfMemory;
                ret_p.* = try self.typeFromAnnotation(ret_str, line, col);
                const sig = self.arena.create(types.FuncSig) catch return error.OutOfMemory;
                sig.* = .{ .params = try params.toOwnedSlice(self.arena), .ret = ret_p };
                return .{ .func_type = sig };
            }
        }
        if (std.mem.endsWith(u8, annotation, "?")) {
            const inner = try self.typeFromAnnotation(annotation[0 .. annotation.len - 1], line, col);
            const p = self.arena.create(types.Type) catch return error.OutOfMemory;
            p.* = inner;
            return .{ .optional = p };
        }
        if (self.enums.get(annotation)) |einfo| {
            return .{ .enum_type = .{ .name = annotation, .is_string = einfo.is_string } };
        }
        if (self.type_decls.get(annotation)) |decl| {
            if (decl.string_literals != null) return .{ .string_literal_union = annotation };
            if (decl.int_literals != null) return .{ .int_literal_union = annotation };
        }
        return types.fromAnnotation(annotation);
    }

    fn declareFunction(self: *Checker, decl: *ast.FunctionDecl) CompileError!void {
        if (self.funcs.get(decl.name) != null) return self.fail(decl.line, decl.col, "E_DUPLICATE_BINDING");
        const return_type = try self.typeFromAnnotation(decl.return_annotation, decl.line, decl.col);
        for (decl.params) |*param| {
            param.checked_type = try self.typeFromAnnotation(param.annotation, decl.line, decl.col);
        }
        decl.checked_return_type = return_type;
        self.funcs.put(self.arena, decl.name, .{ .params = decl.params, .return_type = return_type }) catch return error.OutOfMemory;
    }

    fn checkProgram(self: *Checker, program: *ast.Program) CompileError!void {
        try self.pushScope();
        for (program.stmts) |*stmt| {
            if (stmt.* == .type_decl) try self.declareType(stmt.type_decl.name, stmt.type_decl.fields, stmt.type_decl.string_literals, stmt.type_decl.int_literals, stmt.type_decl.line, stmt.type_decl.col);
        }
        for (program.stmts) |*stmt| {
            if (stmt.* == .enum_decl) {
                const e = stmt.enum_decl;
                if (self.enums.get(e.name) != null or self.type_decls.get(e.name) != null) return self.fail(e.line, e.col, "E_DUPLICATE_BINDING");
                self.enums.put(self.arena, e.name, .{ .is_string = e.is_string, .members = e.members }) catch return error.OutOfMemory;
            }
        }
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

        const return_type = decl.checked_return_type orelse try self.typeFromAnnotation(decl.return_annotation, decl.line, decl.col);
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
            .throw_stmt => true,
            else => false,
        };
    }

    fn checkStmt(self: *Checker, program: *ast.Program, stmt: *ast.Stmt) CompileError!void {
        switch (stmt.*) {
            .type_decl => |*decl| {
                for (decl.fields) |*field| {
                    field.checked_type = try self.typeFromAnnotation(field.annotation, decl.line, decl.col);
                }
            },
            .enum_decl => {}, // registered during the hoisting pre-pass
            .test_decl => |*t| {
                self.test_depth += 1;
                defer self.test_depth -= 1;
                try self.checkBlock(program, t.body);
            },

            .function_decl => |*decl| {
                if (self.nested_stmt_depth > 0) return self.fail(decl.line, decl.col, "E_UNSUPPORTED_NESTED_FUNCTION");
                if (decl.checked_return_type == null) try self.declareFunction(decl);
                try self.checkFunctionBody(program, decl);
            },
            .var_decl => |*decl| {
                const final_type = if (decl.annotation) |ann|
                    try self.typeFromAnnotation(ann, decl.line, decl.col)
                else
                    self.exprType(program, decl.init, decl.line, decl.col) orelse
                        return self.inferenceFail(decl.line, decl.col, "cannot infer variable type");
                if (final_type == .void) return self.fail(decl.line, decl.col, "E_VOID_VALUE");
                if (final_type == .none) return self.inferenceFail(decl.line, decl.col, "cannot infer type of null; annotate as T | null");

                try self.ensureAssignable(program, final_type, decl.init, decl.line, decl.col);
                decl.checked_type = final_type;
                try self.declare(decl.name, decl, final_type, decl.line, decl.col);
            },
            .destructure_decl => |*d| {
                const src_type = self.exprType(program, d.source, d.line, d.col) orelse
                    return self.inferenceFail(d.line, d.col, "cannot infer destructured source type");
                if (d.is_object) {
                    const type_name = switch (src_type) {
                        .named => |n| n,
                        else => return self.fail(d.line, d.col, "E_TYPE_MISMATCH"),
                    };
                    for (d.bindings) |*b| {
                        const field_type = self.fieldType(type_name, b.name, d.line, d.col) orelse return error.ParseError;
                        b.checked_type = field_type;
                        const scope = self.currentScope();
                        if (scope.get(b.name) != null) return self.fail(d.line, d.col, "E_DUPLICATE_BINDING");
                        const emit_name = try self.freshEmitName(b.name);
                        b.emit_name = emit_name;
                        scope.put(self.arena, b.name, .{ .ty = field_type, .mutable = d.mutable, .emit_name = emit_name }) catch return error.OutOfMemory;
                    }
                } else {
                    if (!types.isArray(src_type)) return self.fail(d.line, d.col, "E_TYPE_MISMATCH");
                    const elem = types.arrayElem(src_type) orelse return self.fail(d.line, d.col, "E_TYPE_MISMATCH");
                    for (d.bindings) |*b| {
                        b.checked_type = elem;
                        const scope = self.currentScope();
                        if (scope.get(b.name) != null) return self.fail(d.line, d.col, "E_DUPLICATE_BINDING");
                        const emit_name = try self.freshEmitName(b.name);
                        b.emit_name = emit_name;
                        scope.put(self.arena, b.name, .{ .ty = elem, .mutable = d.mutable, .emit_name = emit_name }) catch return error.OutOfMemory;
                    }
                }
            },
            .assign => |*assignment| {
                const found_binding = self.bindingPtr(assignment.name) orelse
                    return self.undefined_(assignment.name, assignment.line, assignment.col);
                if (!found_binding.mutable) {
                    return self.fail(assignment.line, assignment.col, "E_CONST_ASSIGNMENT");
                }
                const expected_type = found_binding.ty;
                if (std.mem.eql(u8, assignment.op, "=")) {
                    switch (expected_type) {
                        .named, .named_array, .string_literal_union, .int_literal_union, .optional => {},
                        else => if (self.exprType(program, assignment.value, assignment.line, assignment.col)) |actual_type| {
                            if (!types.same(expected_type, actual_type)) {
                                return self.fail(assignment.line, assignment.col, "E_TYPE_MISMATCH");
                            }
                        } else return self.inferenceFail(assignment.line, assignment.col, "cannot infer assignment type"),
                    }
                    try self.ensureAssignable(program, expected_type, assignment.value, assignment.line, assignment.col);
                } else {
                    const actual_type = self.exprType(program, assignment.value, assignment.line, assignment.col) orelse
                        return self.inferenceFail(assignment.line, assignment.col, "cannot infer assignment type");
                    if (!types.isNumeric(expected_type) or !types.same(expected_type, actual_type)) {
                        return self.fail(assignment.line, assignment.col, "E_TYPE_MISMATCH");
                    }
                }
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
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                try self.checkBlock(program, loop.body);
            },
            .do_while_stmt => |*loop| {
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                try self.checkBlock(program, loop.body);
                const cond_type = self.exprType(program, loop.cond, loop.line, loop.col) orelse
                    return self.inferenceFail(loop.line, loop.col, "cannot infer do-while condition type");
                if (!types.same(.bool, cond_type)) return self.fail(loop.line, loop.col, "E_TYPE_MISMATCH");
            },
            .for_stmt => |*loop| {
                try self.pushScope();
                defer self.popScope();
                var init_stmt: ast.Stmt = .{ .var_decl = loop.init };
                try self.checkStmt(program, &init_stmt);
                const cond_type = self.exprType(program, loop.cond, loop.line, loop.col) orelse
                    return self.inferenceFail(loop.line, loop.col, "cannot infer for condition type");
                if (!types.same(.bool, cond_type)) return self.fail(loop.line, loop.col, "E_TYPE_MISMATCH");
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                try self.checkBlock(program, loop.body);
                var update_stmt: ast.Stmt = .{ .assign = loop.update };
                try self.checkStmt(program, &update_stmt);
                loop.init = init_stmt.var_decl;
                loop.update = update_stmt.assign;
            },
            .for_of_stmt => |*loop| {
                const iter_type = self.exprType(program, loop.iterable, loop.line, loop.col) orelse
                    return self.inferenceFail(loop.line, loop.col, "cannot infer for-of iterable type");
                const elem_type: types.Type = if (types.isArray(iter_type))
                    (types.arrayElem(iter_type) orelse return self.fail(loop.line, loop.col, "E_TYPE_MISMATCH"))
                else if (types.isStringLike(iter_type))
                    .string
                else
                    return self.fail(loop.line, loop.col, "E_TYPE_MISMATCH");
                loop.iter_type = iter_type;
                loop.elem_type = elem_type;
                try self.pushScope();
                defer self.popScope();
                const scope = self.currentScope();
                const emit_name = try self.freshEmitName(loop.binding);
                loop.binding_emit_name = emit_name;
                scope.put(self.arena, loop.binding, .{ .ty = elem_type, .mutable = loop.mutable, .emit_name = emit_name }) catch return error.OutOfMemory;
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                try self.checkBlock(program, loop.body);
            },
            .if_stmt => |*branch| {
                const cond_type = self.exprType(program, branch.cond, branch.line, branch.col) orelse
                    return self.inferenceFail(branch.line, branch.col, "cannot infer if condition type");
                if (!types.same(.bool, cond_type)) return self.fail(branch.line, branch.col, "E_TYPE_MISMATCH");
                const narrow = narrowTarget(branch.cond);
                {
                    const active = narrow != null and narrow.?.in_then;
                    if (active) self.narrowed.append(self.arena, narrow.?.name) catch return error.OutOfMemory;
                    defer if (active) {
                        self.narrowed.items.len -= 1;
                    };
                    try self.checkBlock(program, branch.then_body);
                }
                if (branch.else_body) |else_body| {
                    const active = narrow != null and !narrow.?.in_then;
                    if (active) self.narrowed.append(self.arena, narrow.?.name) catch return error.OutOfMemory;
                    defer if (active) {
                        self.narrowed.items.len -= 1;
                    };
                    try self.checkBlock(program, else_body);
                }
            },
            .switch_stmt => |*switch_stmt| {
                const switch_type = self.exprType(program, switch_stmt.value, switch_stmt.line, switch_stmt.col) orelse
                    return self.inferenceFail(switch_stmt.line, switch_stmt.col, "cannot infer switch value type");
                switch_stmt.checked_type = switch_type;
                self.switch_depth += 1;
                defer self.switch_depth -= 1;
                for (switch_stmt.cases) |*case| {
                    switch (switch_type) {
                        .string_literal_union, .int_literal_union => try self.ensureAssignable(program, switch_type, case.value, case.line, case.col),
                        else => {
                            const case_type = self.exprType(program, case.value, case.line, case.col) orelse
                                return self.inferenceFail(case.line, case.col, "cannot infer switch case type");
                            if (!types.same(switch_type, case_type)) return self.fail(case.line, case.col, "E_TYPE_MISMATCH");
                        },
                    }
                    try self.checkBlock(program, case.body);
                }
                if (switch_stmt.default_body) |default_body| try self.checkBlock(program, default_body);
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
                self.ensureAssignable(program, expected_return, value, ret.line, ret.col) catch return self.fail(ret.line, ret.col, "E_RETURN_TYPE");
                ret.checked_type = expected_return;
            },
            .throw_stmt => |throw_stmt| {
                const thrown_type = self.exprType(program, throw_stmt.value, throw_stmt.line, throw_stmt.col) orelse
                    return self.inferenceFail(throw_stmt.line, throw_stmt.col, "cannot infer throw type");
                if (!types.same(.error_obj, thrown_type)) return self.fail(throw_stmt.line, throw_stmt.col, "E_THROW_TYPE");
            },
            .try_stmt => |*try_stmt| {
                try self.checkBlock(program, try_stmt.try_body);
                try self.pushScope();
                defer self.popScope();
                try self.declareCatch(try_stmt);
                self.nested_stmt_depth += 1;
                defer self.nested_stmt_depth -= 1;
                for (try_stmt.catch_body) |*catch_stmt| try self.checkStmt(program, catch_stmt);
                if (try_stmt.finally_body) |finally_body| {
                    try self.checkBlock(program, finally_body);
                }
            },
            .defer_stmt => |*d| {
                try self.checkBlock(program, d.body);
            },
            .break_stmt => |control| {
                if (self.loop_depth == 0 and self.switch_depth == 0) return self.fail(control.line, control.col, "E_BREAK_OUTSIDE_LOOP");
            },
            .continue_stmt => |control| {
                if (self.loop_depth == 0) return self.fail(control.line, control.col, "E_CONTINUE_OUTSIDE_LOOP");
            },
        }
    }

    fn ensureAssignable(self: *Checker, program: *ast.Program, expected: types.Type, value: *ast.Expr, line: u32, col: u32) CompileError!void {
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
                // Reject fields not declared on the target type.
                for (provided) |pf| {
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
                    if (findField(provided, expected_field.name)) |value_field| {
                        try self.ensureAssignable(program, expected_field_type, value_field.value, line, col);
                        ordered[i] = value_field;
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
                for (value.array) |item| {
                    try self.ensureAssignable(program, elem_type, item, line, col);
                }
            },
            else => {
                const actual_type = self.exprType(program, value, line, col) orelse return self.fail(line, col, "E_TYPE_MISMATCH");
                if (!types.same(expected, actual_type)) return self.fail(line, col, "E_TYPE_MISMATCH");
            },
        }
    }

    fn exprType(self: *Checker, program: *ast.Program, e: *ast.Expr, line: u32, col: u32) ?types.Type {
        return switch (e.*) {
            .var_ref => |*ref| blk: {
                const found_binding = self.binding(ref.name) orelse {
                    // A top-level function name used as a value.
                    if (self.funcs.get(ref.name)) |finfo| {
                        ref.is_func_ref = true;
                        break :blk self.funcSigType(finfo) catch return null;
                    }
                    _ = self.undefined_(ref.name, line, col) catch {};
                    return null;
                };
                ref.emit_name = found_binding.emit_name;
                if (found_binding.ty == .optional and self.isNarrowed(ref.name)) {
                    ref.unwrap = true;
                    break :blk found_binding.ty.optional.*;
                }
                ref.unwrap = false;
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
            .bnot => |inner| {
                const inner_type = self.exprType(program, inner, line, col) orelse return null;
                if (!types.isInteger(inner_type)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                return inner_type;
            },
            .bin => |*bin| {
                const left_type = self.exprType(program, bin.l, line, col) orelse return null;
                const right_type = self.exprType(program, bin.r, line, col) orelse return null;
                if (bin.op == '+' and types.same(.string, left_type) and types.same(.string, right_type)) {
                    bin.checked_type = .string;
                    return .string;
                }
                // Bitwise and shift operators require integer operands.
                if (bin.op == '&' or bin.op == '|' or bin.op == '^' or bin.op == 'L' or bin.op == 'R') {
                    if (!types.isInteger(left_type) or !types.isInteger(right_type) or !types.same(left_type, right_type)) {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                    bin.checked_type = left_type;
                    return left_type;
                }
                if (!types.isNumeric(left_type) or !types.same(left_type, right_type)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                bin.checked_type = left_type;
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
                if ((std.mem.eql(u8, cmp.op, "==") or std.mem.eql(u8, cmp.op, "!=")) and types.isStringLike(left_type) and types.isStringLike(right_type)) {
                    cmp.checked_operand_type = .string;
                    return .bool;
                }
                // Comparing an optional value against null/undefined (the
                // narrowing condition `x != null`) is allowed and yields bool.
                if ((std.mem.eql(u8, cmp.op, "==") or std.mem.eql(u8, cmp.op, "!=")) and
                    (left_type == .optional or left_type == .none) and
                    (right_type == .optional or right_type == .none))
                {
                    return .bool;
                }
                // A numeric literal union compares like its integer backing type.
                if ((std.mem.eql(u8, cmp.op, "==") or std.mem.eql(u8, cmp.op, "!=")) and
                    ((left_type == .int_literal_union and (right_type == .i32 or right_type == .int_literal_union)) or
                        (right_type == .int_literal_union and left_type == .i32)))
                {
                    return .bool;
                }
                // String-backed enum equality uses content comparison.
                if ((std.mem.eql(u8, cmp.op, "==") or std.mem.eql(u8, cmp.op, "!=")) and
                    left_type == .enum_type and right_type == .enum_type and
                    std.mem.eql(u8, left_type.enum_type.name, right_type.enum_type.name) and left_type.enum_type.is_string)
                {
                    cmp.checked_operand_type = .string;
                    return .bool;
                }
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
            .ternary => |ternary| {
                const cond_type = self.exprType(program, ternary.cond, line, col) orelse return null;
                if (!types.same(.bool, cond_type)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                const then_type = self.exprType(program, ternary.then_expr, line, col) orelse return null;
                const else_type = self.exprType(program, ternary.else_expr, line, col) orelse return null;
                if (!types.same(then_type, else_type)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                return then_type;
            },
            .arrow => |arrow| {
                for (arrow.params) |*p| {
                    p.checked_type = self.typeFromAnnotation(p.annotation, line, col) catch return null;
                }
                // Check the body in an isolated scope containing only the params,
                // so referencing an enclosing local is rejected (no capture in V1).
                const saved_scopes = self.scopes;
                const saved_ret = self.current_return_type;
                const saved_nested = self.nested_stmt_depth;
                const saved_narrowed = self.narrowed;
                self.scopes = .empty;
                self.narrowed = .empty;
                self.pushScope() catch return null;
                for (arrow.params) |p| {
                    self.currentScope().put(self.arena, p.name, .{ .ty = p.checked_type.?, .mutable = true, .emit_name = p.name }) catch return null;
                }
                const body_type = self.exprType(program, arrow.body_expr, line, col);
                self.scopes = saved_scopes;
                self.current_return_type = saved_ret;
                self.nested_stmt_depth = saved_nested;
                self.narrowed = saved_narrowed;
                const bt = body_type orelse return null;
                var ret: types.Type = bt;
                if (arrow.return_annotation.len > 0) {
                    ret = self.typeFromAnnotation(arrow.return_annotation, line, col) catch return null;
                    if (!types.same(ret, bt)) {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                }
                arrow.checked_return_type = ret;
                const params = self.arena.alloc(types.Type, arrow.params.len) catch return null;
                for (arrow.params, 0..) |p, i| params[i] = p.checked_type.?;
                const ret_p = self.arena.create(types.Type) catch return null;
                ret_p.* = ret;
                const sig = self.arena.create(types.FuncSig) catch return null;
                sig.* = .{ .params = params, .ret = ret_p };
                return .{ .func_type = sig };
            },
            .template => |parts| {
                for (parts) |*part| {
                    if (part.expr) |hole| {
                        const ht = self.exprType(program, hole, line, col) orelse return null;
                        if (!types.isStringLike(ht) and !types.isNumeric(ht) and ht != .bool) {
                            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                            return null;
                        }
                        part.expr_type = ht;
                    }
                }
                return .string;
            },
            .coalesce => |*c| {
                const left_type = self.exprType(program, c.l, line, col) orelse return null;
                if (left_type != .optional) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                const inner = left_type.optional.*;
                self.ensureAssignable(program, inner, c.r, line, col) catch return null;
                return inner;
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
                // Enum member access: `EnumName.Member` resolves to the enum type
                // and carries the member's backing value for emission.
                if (field.obj.* == .var_ref) {
                    if (self.enums.get(field.obj.var_ref.name)) |einfo| {
                        for (einfo.members) |m| {
                            if (std.mem.eql(u8, m.name, field.name)) {
                                field.enum_value = if (einfo.is_string) .{ .str = m.str_value orelse "" } else .{ .int = m.int_value };
                                return .{ .enum_type = .{ .name = field.obj.var_ref.name, .is_string = einfo.is_string } };
                            }
                        }
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                }
                const obj_type = self.exprType(program, field.obj, line, col) orelse return null;
                if (field.optional_chain) {
                    if (obj_type != .optional) {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                    const inner = obj_type.optional.*;
                    const field_type = switch (inner) {
                        .named => |type_name| self.fieldType(type_name, field.name, line, col) orelse return null,
                        else => {
                            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                            return null;
                        },
                    };
                    field.chain_field_type = field_type;
                    const p = self.arena.create(types.Type) catch return null;
                    p.* = field_type;
                    return .{ .optional = p };
                }
                if ((types.isStringLike(obj_type) or types.isArray(obj_type)) and std.mem.eql(u8, field.name, "length")) {
                    field.builtin = .length;
                    return .i64;
                }
                if (obj_type == .error_obj and std.mem.eql(u8, field.name, "message")) {
                    field.builtin = .error_message;
                    return .string;
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
            .call => |*call| {
                if (std.mem.eql(u8, call.name, "Error")) {
                    if (call.args.len != 1) {
                        _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                        return null;
                    }
                    const message_type = self.exprType(program, call.args[0], line, col) orelse return null;
                    if (!types.same(.string, message_type)) {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                    return .error_obj;
                }
                if (std.mem.eql(u8, call.name, "expect")) {
                    if (self.test_depth == 0) {
                        _ = self.fail(line, col, "expect is only allowed inside a test block") catch {};
                        return null;
                    }
                    if (call.args.len != 1) {
                        _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                        return null;
                    }
                    const cond_type = self.exprType(program, call.args[0], line, col) orelse return null;
                    if (!types.same(.bool, cond_type)) {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                    return .void;
                }
                if (std.mem.eql(u8, call.name, "argsCount")) {
                    if (call.args.len != 0) {
                        _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                        return null;
                    }
                    program.uses_io = true;
                    program.needs_args = true;
                    return .i32;
                }
                if (std.mem.eql(u8, call.name, "arg")) {
                    if (call.args.len != 1) {
                        _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                        return null;
                    }
                    const index_type = self.exprType(program, call.args[0], line, col) orelse return null;
                    if (!types.same(.i32, index_type)) {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                    program.uses_io = true;
                    program.needs_args = true;
                    return .string;
                }
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
                    // Calling a function-typed binding (parameter or local).
                    if (self.binding(call.name)) |b| {
                        if (b.ty == .func_type) {
                            const sig = b.ty.func_type;
                            if (call.args.len != sig.params.len) {
                                _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                                return null;
                            }
                            for (call.args, sig.params) |arg, pt| {
                                self.ensureAssignable(program, pt, arg, line, col) catch {
                                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                                    return null;
                                };
                            }
                            call.emit_name = b.emit_name;
                            return sig.ret.*;
                        }
                    }
                    _ = self.fail(line, col, "unknown function") catch {};
                    return null;
                };
                if (call.args.len != func.params.len) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                for (call.args, func.params) |arg, param| {
                    const param_type = param.checked_type orelse {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    };
                    self.ensureAssignable(program, param_type, arg, line, col) catch {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    };
                }
                return func.return_type;
            },
            .static_call => |*call| {
                return self.staticCallType(program, call, line, col);
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

    fn staticCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
        if (std.mem.eql(u8, call.namespace, "Math")) return self.mathCallType(program, call, line, col);
        if (std.mem.eql(u8, call.namespace, "String")) return self.stringCallType(program, call, line, col);
        if (std.mem.eql(u8, call.namespace, "Array")) return self.arrayCallType(program, call, line, col);
        if (std.mem.eql(u8, call.namespace, "fs")) return self.fsCallType(program, call, line, col);
        _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
        return null;
    }

    fn fsCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
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
        _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
        return null;
    }

    fn mathCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
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

    fn stringCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
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

    fn arrayCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
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
