//! Statement and function/class-body type-checking.
//!
//! `checkStmt` is the statement-level dispatch (the `Stmt`-union counterpart of
//! `exprType`): one case per statement kind (`if`/`while`/`for`/`switch`/
//! `try`/`return`/declarations/...), walking the body and recursing into
//! nested blocks. `checkFunctionBody`/`checkClass`/`checkMemberAssign` set up
//! the scope (parameters, `this`, fields) before checking a function/class/
//! field-write's body, and `blockReturns`/`stmtReturns` decide whether a
//! function body returns on every path (so `return`-less branches type-check
//! `void`).
//!
//! Pulled out of `lumen_check.zig` as the "checking a construct's body"
//! concern, separate from generics/class-lookup/stdlib-call typing and from
//! `exprType`/`ensureAssignable` (single-expression typing), which this module
//! calls into but does not define.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const diag_mod = @import("lumen_diag.zig");
const check_mod = @import("lumen_check.zig");

const Checker = check_mod.Checker;
const CompileError = diag_mod.CompileError;

pub fn declareExtern(self: *Checker, decl: *ast.ExternDecl) CompileError!void {
    if (self.funcs.get(decl.name) != null) return self.fail(decl.line, decl.col, "E_DUPLICATE_BINDING");
    const ret = try self.typeFromAnnotation(decl.return_annotation, decl.line, decl.col);
    if (!check_mod.isCSafe(ret) and ret != .void) return self.fail(decl.line, decl.col, "E_FFI_TYPE");
    decl.checked_return_type = ret;
    for (decl.params) |*param| {
        // `Ref<T>` is not part of the C ABI surface.
        if (check_mod.refInner(param.annotation) != null) return self.fail(decl.line, decl.col, "E_FFI_TYPE");
        param.checked_type = try self.typeFromAnnotation(param.annotation, decl.line, decl.col);
        if (!check_mod.isCSafe(param.checked_type.?)) return self.fail(decl.line, decl.col, "E_FFI_TYPE");
    }
    self.funcs.put(self.arena, decl.name, .{ .params = decl.params, .return_type = ret, .is_extern = true }) catch return error.OutOfMemory;
}

pub fn checkBlock(self: *Checker, program: *ast.Program, body: []ast.Stmt) CompileError!void {
    try self.pushScope();
    defer self.popScope();
    self.nested_stmt_depth += 1;
    defer self.nested_stmt_depth -= 1;
    for (body) |*body_stmt| try self.checkStmt(program, body_stmt);
}

pub fn checkFunctionBody(self: *Checker, program: *ast.Program, decl: *ast.FunctionDecl) CompileError!void {
    const previous_return_type = self.current_return_type;
    // Inside an async body, a `return v;` resolves the promise with `v`, so the
    // return value is checked against the promise's inner type `T`.
    self.current_return_type = if (decl.is_async and decl.checked_return_type != null and decl.checked_return_type.? == .promise_type)
        decl.checked_return_type.?.promise_type.*
    else
        decl.checked_return_type;
    defer self.current_return_type = previous_return_type;
    const previous_in_async = self.in_async;
    const previous_in_function = self.in_function;
    self.in_async = decl.is_async;
    self.in_function = true;
    // An async function lowers to a Promise-returning function, so the runtime
    // is required even when the body never awaits.
    if (decl.is_async) program.needs_async = true;
    defer {
        self.in_async = previous_in_async;
        self.in_function = previous_in_function;
    }

    // A default value must be assignable to its parameter's declared type.
    for (decl.params) |param| {
        if (param.default) |d| {
            const pt = param.checked_type orelse return self.fail(decl.line, decl.col, "E_TYPE_MISMATCH");
            self.ensureAssignable(program, pt, d, decl.line, decl.col) catch {
                return self.fail(decl.line, decl.col, "E_TYPE_MISMATCH");
            };
        }
    }
    try self.pushScope();
    defer self.popScope();
    for (decl.params) |param| try self.declareParam(param, decl.line, decl.col);
    self.nested_stmt_depth += 1;
    defer self.nested_stmt_depth -= 1;
    for (decl.body) |*body_stmt| try self.checkStmt(program, body_stmt);

    // The effective return type: for an async function this is the promise's
    // inner type (`Promise<void>` need not return), set in current_return_type.
    const return_type = self.current_return_type orelse decl.checked_return_type orelse try self.typeFromAnnotation(decl.return_annotation, decl.line, decl.col);
    if (return_type != .void and !blockReturns(decl.body)) {
        return self.fail(decl.line, decl.col, "E_MISSING_RETURN");
    }
}

pub fn checkClass(self: *Checker, program: *ast.Program, c: *ast.ClassDecl) CompileError!void {
    const prev = self.current_class;
    self.current_class = c.name;
    defer self.current_class = prev;

    // Validate the parent reference and reject inheritance cycles.
    if (c.parent) |pname| {
        if (self.classes.get(pname) == null) return self.fail(c.line, c.col, "E_TYPE_MISMATCH");
        var cur: ?[]const u8 = pname;
        while (cur) |name| {
            if (std.mem.eql(u8, name, c.name)) return self.fail(c.line, c.col, "E_TYPE_MISMATCH");
            cur = (self.classes.get(name) orelse break).parent;
        }
    }

    // `implements I`: every interface member must be provided by the class
    // (own or inherited).
    for (c.implements) |iface| {
        const tinfo = self.type_decls.get(iface) orelse return self.fail(c.line, c.col, "E_TYPE_MISMATCH");
        for (tinfo.fields) |req| {
            if (self.resolveField(c.name, req.name) != null) continue;
            if (self.resolveMethod(c.name, req.name) != null) continue;
            if (self.resolveAccessor(c.name, req.name, .getter) != null) continue;
            return self.fail(c.line, c.col, "E_MISSING_MEMBER");
        }
    }

    // Whether the parent has a parameterized constructor that requires a
    // matching `super(...)` call in this child's constructor.
    const parent_needs_super = blk: {
        var cur = c.parent;
        while (cur) |pname| {
            const pinfo = self.classes.get(pname) orelse break;
            if (pinfo.has_ctor) break :blk pinfo.ctor_params.len > 0;
            cur = pinfo.parent;
        }
        break :blk false;
    };

    if (c.has_ctor) {
        try self.pushScope();
        defer self.popScope();
        for (c.ctor_params) |param| try self.declareParam(param, c.line, c.col);
        self.nested_stmt_depth += 1;
        defer self.nested_stmt_depth -= 1;
        self.in_constructor = true;
        defer self.in_constructor = false;
        // A `super(...)` call, if present, must be the first statement.
        var has_super = false;
        for (c.ctor_body, 0..) |*body_stmt, i| {
            if (body_stmt.* == .super_ctor) {
                if (i != 0) return self.fail(c.line, c.col, "E_MISSING_SUPER");
                has_super = true;
            }
        }
        if (parent_needs_super and !has_super) return self.fail(c.line, c.col, "E_MISSING_SUPER");
        for (c.ctor_body) |*body_stmt| try self.checkStmt(program, body_stmt);
    } else if (parent_needs_super) {
        // No constructor at all but the parent demands super args.
        return self.fail(c.line, c.col, "E_MISSING_SUPER");
    }
    for (c.methods) |*m| try self.checkFunctionBody(program, m);
}

pub fn checkMemberAssign(self: *Checker, program: *ast.Program, ma: *ast.MemberAssign) CompileError!void {
    // `obj.field = value` / `Class.staticField = value` / setter write.
    if (ma.obj) |obj| {
        // Static field write: `Class.field = value`.
        if (obj.* == .var_ref and self.bindingPtr(obj.var_ref.name) == null and self.classes.get(obj.var_ref.name) != null) {
            const cname = obj.var_ref.name;
            const rf = self.resolveStaticField(cname, ma.field) orelse return self.fail(ma.line, ma.col, "E_TYPE_MISMATCH");
            try self.checkVisibility(rf.field.visibility, rf.owner, ma.line, ma.col);
            if (rf.field.is_readonly) return self.fail(ma.line, ma.col, "E_READONLY_ASSIGNMENT");
            ma.is_static = true;
            ma.class_name = rf.owner;
            try self.assignField(program, rf.field.checked_type orelse return error.ParseError, ma);
            return;
        }
        const obj_type = self.exprType(program, obj, ma.line, ma.col) orelse
            return self.inferenceFail(ma.line, ma.col, "cannot infer assignment target type");
        // A record `Ref<T>` parameter is mutable through its pointer: writes to
        // its fields (or fields of a sub-record reached from it) are allowed.
        if (obj_type == .named and self.refRooted(obj)) {
            const ft = self.recordFieldType(obj_type.named, ma.field) orelse
                return self.fail(ma.line, ma.col, "E_TYPE_MISMATCH");
            try self.assignField(program, ft, ma);
            return;
        }
        // Records and other non-class shapes are immutable in V1: writing a
        // field on them is a dynamic property write.
        if (obj_type != .class_type) return self.fail(ma.line, ma.col, "E_DYNAMIC_PROPERTY_WRITE");
        const cls = obj_type.class_type;
        // Setter property write: `obj.prop = value`.
        if (self.resolveField(cls, ma.field) == null) {
            if (self.resolveAccessor(cls, ma.field, .setter)) |ra| {
                try self.checkVisibility(ra.method.visibility, ra.owner, ma.line, ma.col);
                if (!std.mem.eql(u8, ma.op, "=")) return self.fail(ma.line, ma.col, "E_TYPE_MISMATCH");
                ma.is_setter = true;
                ma.class_name = cls;
                const pt = if (ra.method.params.len == 1) ra.method.params[0].checked_type orelse return error.ParseError else return self.fail(ma.line, ma.col, "E_ARG_COUNT");
                try self.ensureAssignable(program, pt, ma.value, ma.line, ma.col);
                return;
            }
            return self.fail(ma.line, ma.col, "E_TYPE_MISMATCH");
        }
        const rf = self.resolveField(cls, ma.field).?;
        try self.checkVisibility(rf.field.visibility, rf.owner, ma.line, ma.col);
        // External writes to readonly fields are never allowed.
        if (rf.field.is_readonly) return self.fail(ma.line, ma.col, "E_READONLY_ASSIGNMENT");
        ma.class_name = rf.owner;
        try self.assignField(program, rf.field.checked_type orelse return error.ParseError, ma);
        return;
    }
    // `this.field = value` inside a method/constructor.
    const cls = self.current_class orelse return self.fail(ma.line, ma.col, "E_RETURN_OUTSIDE_FUNCTION");
    const rf = self.resolveField(cls, ma.field) orelse return self.fail(ma.line, ma.col, "E_TYPE_MISMATCH");
    // readonly: writable only inside a constructor.
    if (rf.field.is_readonly and !self.in_constructor) return self.fail(ma.line, ma.col, "E_READONLY_ASSIGNMENT");
    ma.class_name = rf.owner;
    try self.assignField(program, rf.field.checked_type orelse return error.ParseError, ma);
}

pub fn assignField(self: *Checker, program: *ast.Program, field_type: types.Type, ma: *ast.MemberAssign) CompileError!void {
    if (std.mem.eql(u8, ma.op, "=")) {
        try self.ensureAssignable(program, field_type, ma.value, ma.line, ma.col);
    } else {
        const value_type = self.exprType(program, ma.value, ma.line, ma.col) orelse
            return self.inferenceFail(ma.line, ma.col, "cannot infer assignment type");
        if (!types.isNumeric(field_type) or !types.same(field_type, value_type)) {
            return self.fail(ma.line, ma.col, "E_TYPE_MISMATCH");
        }
    }
}

pub fn blockReturns(body: []ast.Stmt) bool {
    for (body) |stmt| {
        if (stmtReturns(stmt)) return true;
    }
    return false;
}

pub fn stmtReturns(stmt: ast.Stmt) bool {
    return switch (stmt) {
        .return_stmt => true,
        .if_stmt => |branch| branch.else_body != null and blockReturns(branch.then_body) and blockReturns(branch.else_body.?),
        .throw_stmt => true,
        else => false,
    };
}

pub fn checkStmt(self: *Checker, program: *ast.Program, stmt: *ast.Stmt) CompileError!void {
    switch (stmt.*) {
        .type_decl => |*decl| {
            for (decl.fields) |*field| {
                field.checked_type = try self.typeFromAnnotation(field.annotation, decl.line, decl.col);
            }
        },
        .enum_decl => {}, // registered during the hoisting pre-pass
        .extern_decl => {}, // registered during the hoisting pre-pass
        .class_decl => |*c| try self.checkClass(program, c),
        .member_assign => |*ma| try self.checkMemberAssign(program, ma),
        .super_ctor => |*sc| {
            const cls = self.current_class orelse return self.fail(sc.line, sc.col, "E_RETURN_OUTSIDE_FUNCTION");
            if (!self.in_constructor) return self.fail(sc.line, sc.col, "E_TYPE_MISMATCH");
            const parent = (self.classes.get(cls) orelse return self.fail(sc.line, sc.col, "E_TYPE_MISMATCH")).parent orelse
                return self.fail(sc.line, sc.col, "E_TYPE_MISMATCH");
            sc.parent = parent;
            // Resolve the parent's effective constructor params.
            var ctor_params: []ast.FunctionParam = &.{};
            var has_ctor = false;
            var cur: ?[]const u8 = parent;
            while (cur) |pname| {
                const pinfo = self.classes.get(pname) orelse break;
                if (pinfo.has_ctor) {
                    ctor_params = pinfo.ctor_params;
                    has_ctor = true;
                    sc.parent = pname;
                    break;
                }
                cur = pinfo.parent;
            }
            const want: usize = if (has_ctor) ctor_params.len else 0;
            if (sc.args.len != want) return self.fail(sc.line, sc.col, "E_ARG_COUNT");
            for (sc.args, 0..) |arg, i| {
                try self.ensureAssignable(program, ctor_params[i].checked_type orelse return error.ParseError, arg, sc.line, sc.col);
            }
        },
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
        .using_decl => |*decl| {
            if (decl.defer_body) |body| {
                // `using x = defer(() => BODY);` — the helper body runs at scope
                // exit. Check it like a defer block; no value binding is made
                // (the bound name is an opaque Disposable).
                try self.checkBlock(program, body);
            } else {
                // `using r = EXPR;` — the value must be a class instance that
                // exposes `dispose(): void`. Bind `r`, then synthesize and check
                // a `r.dispose()` call to run at scope exit.
                const final_type = if (decl.annotation) |ann|
                    try self.typeFromAnnotation(ann, decl.line, decl.col)
                else
                    self.exprType(program, decl.init, decl.line, decl.col) orelse
                        return self.inferenceFail(decl.line, decl.col, "cannot infer using-declaration type");
                if (final_type != .class_type) return self.fail(decl.line, decl.col, "E_NOT_DISPOSABLE");
                try self.ensureAssignable(program, final_type, decl.init, decl.line, decl.col);
                decl.checked_type = final_type;

                const cls = final_type.class_type;
                const rm = self.resolveMethod(cls, "dispose") orelse return self.fail(decl.line, decl.col, "E_NOT_DISPOSABLE");
                if (rm.method.params.len != 0) return self.fail(decl.line, decl.col, "E_NOT_DISPOSABLE");

                // Declare the binding in the current scope.
                const scope = self.currentScope();
                if (scope.get(decl.name) != null) return self.fail(decl.line, decl.col, "E_DUPLICATE_BINDING");
                const emit_name = try self.freshEmitName(decl.name);
                decl.emit_name = emit_name;
                scope.put(self.arena, decl.name, .{ .ty = final_type, .mutable = false, .emit_name = emit_name }) catch return error.OutOfMemory;

                // Synthesize `name.dispose()` and check it so class_name/emit_name fill in.
                const recv = try self.arena.create(ast.Expr);
                recv.* = .{ .var_ref = .{ .name = decl.name } };
                const call = try self.arena.create(ast.Expr);
                call.* = .{ .method_call = .{ .obj = recv, .name = "dispose", .args = &.{} } };
                _ = self.exprType(program, call, decl.line, decl.col);
                decl.dispose_call = call;
            }
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
                    .named, .named_array, .union_type, .string_literal_union, .int_literal_union, .optional => {},
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
            assignment.deref = found_binding.ref_scalar;
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
            const narrow = Checker.narrowTarget(branch.cond);
            // Discriminant narrowing: `if (s.kind === "circle")` narrows `s` to
            // the matching variant in the then-branch.
            var var_narrowed = false;
            if (branch.cond.* == .cmp) {
                const c = branch.cond.cmp;
                if (std.mem.eql(u8, c.op, "==") or std.mem.eql(u8, c.op, "===")) {
                    var disc_expr: ?*ast.Expr = null;
                    var lit: ?[]const u8 = null;
                    if (c.r.* == .str) {
                        disc_expr = c.l;
                        lit = c.r.str;
                    } else if (c.l.* == .str) {
                        disc_expr = c.r;
                        lit = c.l.str;
                    }
                    if (disc_expr) |de| {
                        if (self.discriminantAccess(de)) |d| {
                            const variant = self.variantForValue(d.union_name, lit.?) orelse return self.fail(branch.line, branch.col, "E_TYPE_MISMATCH");
                            self.narrowed_variants.append(self.arena, .{ .name = d.name, .variant = variant }) catch return error.OutOfMemory;
                            var_narrowed = true;
                        }
                    }
                }
            }
            {
                const active = narrow != null and narrow.?.in_then;
                if (active) self.narrowed.append(self.arena, narrow.?.name) catch return error.OutOfMemory;
                defer if (active) {
                    self.narrowed.items.len -= 1;
                };
                defer if (var_narrowed) {
                    self.narrowed_variants.items.len -= 1;
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
            // A `switch (s.kind)` over a union discriminant narrows `s` to the
            // matching variant inside each case body.
            const disc = self.discriminantAccess(switch_stmt.value);
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
                var narrowed = false;
                if (disc) |d| {
                    if (case.value.* == .str) {
                        const variant = self.variantForValue(d.union_name, case.value.str) orelse return self.fail(case.line, case.col, "E_TYPE_MISMATCH");
                        self.narrowed_variants.append(self.arena, .{ .name = d.name, .variant = variant }) catch return error.OutOfMemory;
                        narrowed = true;
                    }
                }
                defer if (narrowed) {
                    self.narrowed_variants.items.len -= 1;
                };
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
