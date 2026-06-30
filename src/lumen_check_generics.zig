//! Generic function/class/type-alias specialization (monomorphization).
//!
//! Lumen's generics are resolved entirely at compile time: a generic
//! `function f<T>(...)`/`class C<T>`/`type X<T>` is never emitted as-is.
//! Instead, each concrete use (`f<int>(...)`, `new C<string>()`, ...) triggers
//! `specializeFunction`/`specializeClass`/`specializeType`, which substitutes the
//! type parameter into a fresh clone of the declaration's AST (`cloneBody`/
//! `cloneExpr`/`cloneStmt`/...), mangles a unique name for it
//! (`mangledName`), and type-checks the clone like any other declaration. A
//! `needed` set on the `Checker` dedups by mangled name so the same
//! instantiation is only emitted once.
//!
//! `substAnnotation`/`annotationMentions`/`unifyAnnotation`/`inferTypeArgs` do
//! the annotation-string-level substitution and inference (Lumen keeps type
//! annotations as source-text strings until `typeFromAnnotation` resolves
//! them, so substitution happens on the string before resolution).
//!
//! Pulled out of `lumen_check.zig` because it is the single largest
//! self-contained concern in the checker and changes only when generics
//! themselves change.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const diag_mod = @import("lumen_diag.zig");
const check_mod = @import("lumen_check.zig");

const Checker = check_mod.Checker;
const CompileError = diag_mod.CompileError;

pub fn isGenericTemplateStmt(self: *Checker, stmt: *const ast.Stmt) bool {
    _ = self;
    return switch (stmt.*) {
        .function_decl => |d| d.type_params.len > 0,
        .class_decl => |d| d.type_params.len > 0,
        .type_decl => |d| d.type_params.len > 0,
        else => false,
    };
}

pub fn appendStmt(self: *Checker, stmts: []ast.Stmt, stmt: ast.Stmt) ![]ast.Stmt {
    const grown = try self.arena.alloc(ast.Stmt, stmts.len + 1);
    @memcpy(grown[0..stmts.len], stmts);
    grown[stmts.len] = stmt;
    return grown;
}

// ── generics: monomorphization ─────────────────────────────────────────────

pub fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '$';
}

/// Token-aware substitution of type parameters by concrete annotation
/// strings inside an annotation. Whole identifiers matching a parameter name
/// are replaced; substrings of larger identifiers are left intact.
pub fn substAnnotation(self: *Checker, ann: []const u8, params: []const []const u8, args: []const []const u8) CompileError![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < ann.len) {
        const c = ann[i];
        if (isIdentChar(c) and !(c >= '0' and c <= '9')) {
            var j = i;
            while (j < ann.len and isIdentChar(ann[j])) j += 1;
            const word = ann[i..j];
            var replaced = false;
            for (params, 0..) |p, k| {
                if (std.mem.eql(u8, p, word)) {
                    out.appendSlice(self.arena, args[k]) catch return error.OutOfMemory;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) out.appendSlice(self.arena, word) catch return error.OutOfMemory;
            i = j;
        } else {
            out.append(self.arena, c) catch return error.OutOfMemory;
            i += 1;
        }
    }
    return out.items;
}

/// True if a type parameter name occurs as a whole identifier in `ann`.
pub fn annotationMentions(param: []const u8, ann: []const u8) bool {
    var i: usize = 0;
    while (i < ann.len) {
        if (isIdentChar(ann[i]) and !(ann[i] >= '0' and ann[i] <= '9')) {
            var j = i;
            while (j < ann.len and isIdentChar(ann[j])) j += 1;
            if (std.mem.eql(u8, ann[i..j], param)) return true;
            i = j;
        } else i += 1;
    }
    return false;
}

/// A short, identifier-safe tag for a concrete annotation, for mangled names.
pub fn annTag(self: *Checker, ann: []const u8) CompileError![]const u8 {
    const buf = self.arena.alloc(u8, ann.len) catch return error.OutOfMemory;
    var n: usize = 0;
    for (ann) |ch| {
        if (ch == '[' or ch == ']') {
            buf[n] = 'A';
        } else if (isIdentChar(ch)) {
            buf[n] = ch;
        } else {
            buf[n] = '_';
        }
        n += 1;
    }
    return buf[0..n];
}

pub fn mangledName(self: *Checker, base: []const u8, args: []const []const u8) CompileError![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(self.arena, base) catch return error.OutOfMemory;
    for (args) |a| {
        out.append(self.arena, '_') catch return error.OutOfMemory;
        out.append(self.arena, '_') catch return error.OutOfMemory;
        out.appendSlice(self.arena, try self.annTag(a)) catch return error.OutOfMemory;
    }
    return out.items;
}

/// Split a canonical type-argument string `a,b<c,d>,e[]` on top-level commas,
/// respecting nested `<...>`, `[...]`, and `(...)` so nested generics survive.
pub fn splitTypeArgs(self: *Checker, s: []const u8, line: u32, col: u32) CompileError![][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var depth: i32 = 0;
    var start: usize = 0;
    for (s, 0..) |c, i| {
        switch (c) {
            '<', '[', '(' => depth += 1,
            '>', ']', ')' => depth -= 1,
            ',' => if (depth == 0) {
                out.append(self.arena, std.mem.trim(u8, s[start..i], " ")) catch return error.OutOfMemory;
                start = i + 1;
            },
            else => {},
        }
    }
    if (depth != 0) return self.fail(line, col, "E_TYPE_ARG_COUNT");
    const last = std.mem.trim(u8, s[start..], " ");
    if (last.len > 0) out.append(self.arena, last) catch return error.OutOfMemory;
    return out.items;
}

/// Resolve an explicit type-argument list (length-checked) into concrete
/// annotation strings, rejecting any that still name a type parameter.
pub fn resolveExplicitTypeArgs(self: *Checker, type_params: []const []const u8, type_args: []const []const u8, line: u32, col: u32) CompileError![][]const u8 {
    if (type_args.len != type_params.len) return self.fail(line, col, "E_TYPE_ARG_COUNT");
    const out = self.arena.alloc([]const u8, type_args.len) catch return error.OutOfMemory;
    for (type_args, 0..) |a, i| {
        // Validate the argument names a real, concrete type.
        _ = try self.typeFromAnnotation(a, line, col);
        out[i] = a;
    }
    return out;
}

/// Infer the concrete annotation for each type parameter by unifying every
/// parameter annotation against the corresponding argument's inferred type.
/// Supports `T`, `T[]`, and `Array<T>` (already desugared to `T[]`) patterns.
pub fn inferTypeArgs(self: *Checker, program: *ast.Program, type_params: []const []const u8, params: []const ast.FunctionParam, args: []const *ast.Expr, line: u32, col: u32) CompileError![][]const u8 {
    const found = self.arena.alloc(?[]const u8, type_params.len) catch return error.OutOfMemory;
    for (found) |*f| f.* = null;
    for (params, 0..) |p, idx| {
        if (idx >= args.len) break;
        // Only parameters that mention a type parameter drive inference.
        var mentions = false;
        for (type_params) |tp| {
            if (annotationMentions(tp, p.annotation)) mentions = true;
        }
        if (!mentions) continue;
        const arg_type = self.exprType(program, args[idx], line, col) orelse return self.fail(line, col, "E_TYPE_INFER");
        try self.unifyAnnotation(type_params, found, p.annotation, arg_type, line, col);
    }
    const out = self.arena.alloc([]const u8, type_params.len) catch return error.OutOfMemory;
    for (found, 0..) |f, i| out[i] = f orelse return self.fail(line, col, "E_TYPE_INFER");
    return out;
}

/// Unify a single parameter annotation pattern against a concrete argument
/// type, recording (and consistency-checking) bindings for type parameters.
pub fn unifyAnnotation(self: *Checker, type_params: []const []const u8, found: []?[]const u8, pattern: []const u8, arg_type: types.Type, line: u32, col: u32) CompileError!void {
    // Bare type parameter `T` binds to the whole argument type.
    for (type_params, 0..) |tp, k| {
        if (std.mem.eql(u8, pattern, tp)) {
            const ann = (try types.toAnnotation(self.arena, arg_type)) orelse return self.fail(line, col, "E_TYPE_INFER");
            if (found[k]) |existing| {
                if (!std.mem.eql(u8, existing, ann)) return self.fail(line, col, "E_TYPE_MISMATCH");
            } else found[k] = ann;
            return;
        }
    }
    // `T[]` binds `T` to the argument's element type.
    if (std.mem.endsWith(u8, pattern, "[]")) {
        const inner_pat = pattern[0 .. pattern.len - 2];
        const elem = types.arrayElem(arg_type) orelse return self.fail(line, col, "E_TYPE_MISMATCH");
        return self.unifyAnnotation(type_params, found, inner_pat, elem, line, col);
    }
    // Other patterns are concrete; nothing to infer here.
}

/// Specialize a generic function for a concrete type-argument tuple, creating
/// (once) a concrete `FunctionDecl`, queuing it for checking/emission, and
/// returning its mangled name and substituted return type.
pub fn specializeFunction(self: *Checker, decl: *const ast.FunctionDecl, type_args: []const []const u8, line: u32, col: u32) CompileError!struct { name: []const u8, ret: types.Type } {
    const mname = try self.mangledName(decl.name, type_args);
    // Build the substituted return type for the caller regardless of cache.
    const ret_ann = try self.substAnnotation(decl.return_annotation, decl.type_params, type_args);
    const ret_type = try self.typeFromAnnotation(ret_ann, line, col);
    if (self.specialized.get(mname) != null) return .{ .name = mname, .ret = ret_type };
    self.specialized.put(self.arena, mname, {}) catch return error.OutOfMemory;

    const saved_params = self.subst_params;
    const saved_args = self.subst_args;
    self.subst_params = decl.type_params;
    self.subst_args = type_args;
    defer {
        self.subst_params = saved_params;
        self.subst_args = saved_args;
    }
    const new_params = self.arena.alloc(ast.FunctionParam, decl.params.len) catch return error.OutOfMemory;
    for (decl.params, 0..) |p, i| {
        new_params[i] = .{ .name = p.name, .annotation = try self.substCur(p.annotation), .is_rest = p.is_rest, .default = if (p.default) |d| try self.cloneExpr(d) else null };
    }
    const body = try self.cloneBody(decl.body);
    const spec = self.arena.create(ast.FunctionDecl) catch return error.OutOfMemory;
    spec.* = .{
        .name = mname,
        .params = new_params,
        .return_annotation = ret_ann,
        .body = body,
        .type_params = &.{},
        .line = decl.line,
        .col = decl.col,
    };
    // Register so recursive/self calls resolve, then queue for body checking.
    try self.declareFunction(spec);
    const stmt_ptr = self.arena.create(ast.Stmt) catch return error.OutOfMemory;
    stmt_ptr.* = .{ .function_decl = spec.* };
    self.pending_specializations.append(self.arena, stmt_ptr) catch return error.OutOfMemory;
    return .{ .name = mname, .ret = ret_type };
}

/// Specialize a generic class for a concrete type-argument tuple, creating
/// (once) a concrete `ClassDecl` registered under the mangled name.
pub fn specializeClass(self: *Checker, decl: *const ast.ClassDecl, type_args: []const []const u8, line: u32, col: u32) CompileError![]const u8 {
    _ = line;
    _ = col;
    const mname = try self.mangledName(decl.name, type_args);
    if (self.specialized.get(mname) != null) return mname;
    self.specialized.put(self.arena, mname, {}) catch return error.OutOfMemory;

    // Substitute type parameters in every member annotation AND in cloned
    // member/ctor bodies (e.g. `let x: T` inside a method).
    const saved_params = self.subst_params;
    const saved_args = self.subst_args;
    self.subst_params = decl.type_params;
    self.subst_args = type_args;
    defer {
        self.subst_params = saved_params;
        self.subst_args = saved_args;
    }

    const new_fields = self.arena.alloc(ast.TypeField, decl.fields.len) catch return error.OutOfMemory;
    for (decl.fields, 0..) |f, i| {
        new_fields[i] = .{ .name = f.name, .annotation = try self.substCur(f.annotation) };
    }
    const new_ctor = self.arena.alloc(ast.FunctionParam, decl.ctor_params.len) catch return error.OutOfMemory;
    for (decl.ctor_params, 0..) |p, i| {
        new_ctor[i] = .{ .name = p.name, .annotation = try self.substCur(p.annotation) };
    }
    const new_methods = self.arena.alloc(ast.FunctionDecl, decl.methods.len) catch return error.OutOfMemory;
    for (decl.methods, 0..) |m, i| {
        const mparams = self.arena.alloc(ast.FunctionParam, m.params.len) catch return error.OutOfMemory;
        for (m.params, 0..) |p, j| {
            mparams[j] = .{ .name = p.name, .annotation = try self.substCur(p.annotation) };
        }
        new_methods[i] = .{
            .name = m.name,
            .params = mparams,
            .return_annotation = try self.substCur(m.return_annotation),
            .body = try self.cloneBody(m.body),
            .line = m.line,
            .col = m.col,
        };
    }
    const spec = self.arena.create(ast.ClassDecl) catch return error.OutOfMemory;
    spec.* = .{
        .name = mname,
        .fields = new_fields,
        .has_ctor = decl.has_ctor,
        .ctor_params = new_ctor,
        .ctor_body = try self.cloneBody(decl.ctor_body),
        .methods = new_methods,
        .type_params = &.{},
        .line = decl.line,
        .col = decl.col,
    };
    // Register and fill member types so uses see the concrete shape, then
    // queue for full body checking + emission.
    self.classes.put(self.arena, mname, .{ .fields = spec.fields, .methods = spec.methods, .ctor_params = spec.ctor_params, .has_ctor = spec.has_ctor }) catch return error.OutOfMemory;
    try self.fillClassTypes(spec);
    // Reflect the filled member types back into the registry entry.
    self.classes.put(self.arena, mname, .{ .fields = spec.fields, .methods = spec.methods, .ctor_params = spec.ctor_params, .has_ctor = spec.has_ctor }) catch return error.OutOfMemory;
    const stmt_ptr = self.arena.create(ast.Stmt) catch return error.OutOfMemory;
    stmt_ptr.* = .{ .class_decl = spec.* };
    self.pending_specializations.append(self.arena, stmt_ptr) catch return error.OutOfMemory;
    return mname;
}

/// Specialize a generic interface/type alias into a concrete record `type`
/// declared under the mangled name; returns that name.
pub fn specializeType(self: *Checker, decl: *const ast.TypeDecl, type_args: []const []const u8, line: u32, col: u32) CompileError![]const u8 {
    const mname = try self.mangledName(decl.name, type_args);
    if (self.type_decls.get(mname) != null) return mname;
    const new_fields = self.arena.alloc(ast.TypeField, decl.fields.len) catch return error.OutOfMemory;
    for (decl.fields, 0..) |f, i| {
        const ann = try self.substAnnotation(f.annotation, decl.type_params, type_args);
        new_fields[i] = .{ .name = f.name, .annotation = ann, .checked_type = try self.typeFromAnnotation(ann, line, col) };
    }
    self.type_decls.put(self.arena, mname, .{ .fields = new_fields }) catch return error.OutOfMemory;
    const spec = self.arena.create(ast.TypeDecl) catch return error.OutOfMemory;
    spec.* = .{ .name = mname, .fields = new_fields, .type_params = &.{}, .line = decl.line, .col = decl.col };
    const stmt_ptr = self.arena.create(ast.Stmt) catch return error.OutOfMemory;
    stmt_ptr.* = .{ .type_decl = spec.* };
    self.pending_specializations.append(self.arena, stmt_ptr) catch return error.OutOfMemory;
    return mname;
}

// Each specialization needs its own AST: the checker writes resolved types,
// emit-names, and captures onto nodes, which differ per instantiation.

/// Apply the active type-parameter substitution to an annotation string
/// found inside a generic body (e.g. `let x: T`). A no-op when no
/// substitution is active or the annotation mentions no parameter.
pub fn substCur(self: *Checker, ann: []const u8) CompileError![]const u8 {
    if (self.subst_params.len == 0) return ann;
    return self.substAnnotation(ann, self.subst_params, self.subst_args);
}

pub fn cloneBody(self: *Checker, body: []const ast.Stmt) CompileError![]ast.Stmt {
    const out = self.arena.alloc(ast.Stmt, body.len) catch return error.OutOfMemory;
    for (body, 0..) |s, i| out[i] = try self.cloneStmt(s);
    return out;
}

pub fn cloneExpr(self: *Checker, e: *const ast.Expr) CompileError!*ast.Expr {
    const p = self.arena.create(ast.Expr) catch return error.OutOfMemory;
    p.* = switch (e.*) {
        .num, .float, .bool, .str, .regex, .null_lit, .this_expr => e.*,
        .array => |a| blk: {
            const c = self.arena.alloc(*ast.Expr, a.items.len) catch return error.OutOfMemory;
            for (a.items, 0..) |it, i| c[i] = try self.cloneExpr(it);
            break :blk .{ .array = .{ .items = c, .elem_type = a.elem_type } };
        },
        .tuple_lit => |t| blk: {
            const c = self.arena.alloc(*ast.Expr, t.items.len) catch return error.OutOfMemory;
            for (t.items, 0..) |it, i| c[i] = try self.cloneExpr(it);
            break :blk .{ .tuple_lit = .{ .items = c, .tuple_type = t.tuple_type } };
        },
        .var_ref => |r| .{ .var_ref = .{ .name = r.name } },
        .spread => |inner| .{ .spread = try self.cloneExpr(inner) },
        .neg => |inner| .{ .neg = try self.cloneExpr(inner) },
        .not => |inner| .{ .not = try self.cloneExpr(inner) },
        .bnot => |inner| .{ .bnot = try self.cloneExpr(inner) },
        .await_expr => |inner| .{ .await_expr = try self.cloneExpr(inner) },
        .bin => |b| .{ .bin = .{ .op = b.op, .l = try self.cloneExpr(b.l), .r = try self.cloneExpr(b.r) } },
        .bool_bin => |b| .{ .bool_bin = .{ .op = b.op, .l = try self.cloneExpr(b.l), .r = try self.cloneExpr(b.r) } },
        .cmp => |b| .{ .cmp = .{ .op = b.op, .l = try self.cloneExpr(b.l), .r = try self.cloneExpr(b.r) } },
        .ternary => |t| .{ .ternary = .{ .cond = try self.cloneExpr(t.cond), .then_expr = try self.cloneExpr(t.then_expr), .else_expr = try self.cloneExpr(t.else_expr) } },
        .coalesce => |c| .{ .coalesce = .{ .l = try self.cloneExpr(c.l), .r = try self.cloneExpr(c.r) } },
        .arrow => |a| blk: {
            const na = self.arena.create(ast.ArrowExpr) catch return error.OutOfMemory;
            const nparams = self.arena.alloc(ast.FunctionParam, a.params.len) catch return error.OutOfMemory;
            for (a.params, 0..) |pp, i| nparams[i] = .{ .name = pp.name, .annotation = try self.substCur(pp.annotation) };
            na.* = .{ .params = nparams, .return_annotation = try self.substCur(a.return_annotation), .body_expr = try self.cloneExpr(a.body_expr) };
            break :blk .{ .arrow = na };
        },
        .new_expr => |ne| blk: {
            const c = self.arena.alloc(*ast.Expr, ne.args.len) catch return error.OutOfMemory;
            for (ne.args, 0..) |it, i| c[i] = try self.cloneExpr(it);
            break :blk .{ .new_expr = .{ .class_name = ne.class_name, .args = c, .type_args = ne.type_args } };
        },
        .method_call => |mc| blk: {
            const c = self.arena.alloc(*ast.Expr, mc.args.len) catch return error.OutOfMemory;
            for (mc.args, 0..) |it, i| c[i] = try self.cloneExpr(it);
            break :blk .{ .method_call = .{ .obj = try self.cloneExpr(mc.obj), .name = mc.name, .args = c } };
        },
        .super_call => |sc| blk: {
            const c = self.arena.alloc(*ast.Expr, sc.args.len) catch return error.OutOfMemory;
            for (sc.args, 0..) |it, i| c[i] = try self.cloneExpr(it);
            break :blk .{ .super_call = .{ .name = sc.name, .args = c } };
        },
        .template => |parts| blk: {
            const c = self.arena.alloc(ast.TemplatePart, parts.len) catch return error.OutOfMemory;
            for (parts, 0..) |pt, i| c[i] = .{ .text = pt.text, .expr = if (pt.expr) |x| try self.cloneExpr(x) else null };
            break :blk .{ .template = c };
        },
        .obj => |fields| blk: {
            const c = self.arena.alloc(ast.FieldInit, fields.len) catch return error.OutOfMemory;
            for (fields, 0..) |f, i| c[i] = .{ .name = f.name, .value = try self.cloneExpr(f.value), .is_spread = f.is_spread };
            break :blk .{ .obj = c };
        },
        .field => |f| .{ .field = .{ .obj = try self.cloneExpr(f.obj), .name = f.name, .optional_chain = f.optional_chain } },
        .index => |idx| .{ .index = .{ .obj = try self.cloneExpr(idx.obj), .value = try self.cloneExpr(idx.value) } },
        .call => |cl| blk: {
            const c = self.arena.alloc(*ast.Expr, cl.args.len) catch return error.OutOfMemory;
            for (cl.args, 0..) |it, i| c[i] = try self.cloneExpr(it);
            break :blk .{ .call = .{ .name = cl.name, .args = c, .type_args = cl.type_args } };
        },
        .static_call => |sc| blk: {
            const c = self.arena.alloc(*ast.Expr, sc.args.len) catch return error.OutOfMemory;
            for (sc.args, 0..) |it, i| c[i] = try self.cloneExpr(it);
            break :blk .{ .static_call = .{ .namespace = sc.namespace, .name = sc.name, .args = c } };
        },
        .cast => |c| .{ .cast = .{ .inner = try self.cloneExpr(c.inner), .annotation = try self.substCur(c.annotation) } },
    };
    return p;
}

pub fn cloneVarDecl(self: *Checker, d: ast.VarDecl) CompileError!ast.VarDecl {
    const ann = if (d.annotation) |a| try self.substCur(a) else null;
    return .{ .mutable = d.mutable, .name = d.name, .annotation = ann, .init = try self.cloneExpr(d.init), .line = d.line, .col = d.col };
}

pub fn cloneAssign(self: *Checker, a: ast.Assign) CompileError!ast.Assign {
    return .{ .name = a.name, .op = a.op, .value = try self.cloneExpr(a.value), .line = a.line, .col = a.col };
}

pub fn cloneStmt(self: *Checker, s: ast.Stmt) CompileError!ast.Stmt {
    return switch (s) {
        .var_decl => |d| .{ .var_decl = try self.cloneVarDecl(d) },
        .assign => |a| .{ .assign = try self.cloneAssign(a) },
        .member_assign => |ma| .{ .member_assign = .{ .field = ma.field, .op = ma.op, .value = try self.cloneExpr(ma.value), .obj = if (ma.obj) |o| try self.cloneExpr(o) else null, .line = ma.line, .col = ma.col } },
        .super_ctor => |sc| blk: {
            const c = self.arena.alloc(*ast.Expr, sc.args.len) catch return error.OutOfMemory;
            for (sc.args, 0..) |it, i| c[i] = try self.cloneExpr(it);
            break :blk .{ .super_ctor = .{ .args = c, .line = sc.line, .col = sc.col } };
        },
        .console_log => |log| .{ .console_log = .{ .method = log.method, .value = try self.cloneExpr(log.value), .line = log.line, .col = log.col } },
        .return_stmt => |r| .{ .return_stmt = .{ .value = if (r.value) |x| try self.cloneExpr(x) else null, .line = r.line, .col = r.col } },
        .throw_stmt => |t| .{ .throw_stmt = .{ .value = try self.cloneExpr(t.value), .line = t.line, .col = t.col } },
        .expr_stmt => |x| .{ .expr_stmt = .{ .value = try self.cloneExpr(x.value), .line = x.line, .col = x.col } },
        .while_stmt => |w| .{ .while_stmt = .{ .cond = try self.cloneExpr(w.cond), .body = try self.cloneBody(w.body), .line = w.line, .col = w.col } },
        .do_while_stmt => |w| .{ .do_while_stmt = .{ .body = try self.cloneBody(w.body), .cond = try self.cloneExpr(w.cond), .line = w.line, .col = w.col } },
        .for_stmt => |f| .{ .for_stmt = .{ .init = try self.cloneVarDecl(f.init), .cond = try self.cloneExpr(f.cond), .update = try self.cloneAssign(f.update), .body = try self.cloneBody(f.body), .line = f.line, .col = f.col } },
        .for_of_stmt => |f| .{ .for_of_stmt = .{ .mutable = f.mutable, .binding = f.binding, .iterable = try self.cloneExpr(f.iterable), .body = try self.cloneBody(f.body), .line = f.line, .col = f.col } },
        .if_stmt => |b| .{ .if_stmt = .{ .cond = try self.cloneExpr(b.cond), .then_body = try self.cloneBody(b.then_body), .else_body = if (b.else_body) |eb| try self.cloneBody(eb) else null, .line = b.line, .col = b.col } },
        .switch_stmt => |sw| blk: {
            const cases = self.arena.alloc(ast.SwitchCase, sw.cases.len) catch return error.OutOfMemory;
            for (sw.cases, 0..) |cse, i| cases[i] = .{ .value = try self.cloneExpr(cse.value), .body = try self.cloneBody(cse.body), .line = cse.line, .col = cse.col };
            break :blk .{ .switch_stmt = .{ .value = try self.cloneExpr(sw.value), .cases = cases, .default_body = if (sw.default_body) |db| try self.cloneBody(db) else null, .line = sw.line, .col = sw.col } };
        },
        .try_stmt => |t| .{ .try_stmt = .{ .try_body = try self.cloneBody(t.try_body), .catch_name = t.catch_name, .catch_body = try self.cloneBody(t.catch_body), .finally_body = if (t.finally_body) |fb| try self.cloneBody(fb) else null, .line = t.line, .col = t.col } },
        .defer_stmt => |d| .{ .defer_stmt = .{ .body = try self.cloneBody(d.body), .line = d.line, .col = d.col } },
        .break_stmt => |c| .{ .break_stmt = c },
        .continue_stmt => |c| .{ .continue_stmt = c },
        .destructure_decl => |d| blk: {
            const binds = self.arena.alloc(ast.DestructBinding, d.bindings.len) catch return error.OutOfMemory;
            for (d.bindings, 0..) |b, i| binds[i] = .{ .name = b.name };
            break :blk .{ .destructure_decl = .{ .mutable = d.mutable, .is_object = d.is_object, .bindings = binds, .source = try self.cloneExpr(d.source), .line = d.line, .col = d.col } };
        },
        // Declarations not expected inside a generic body are passed through
        // unchanged (nested functions/classes/types/enums are rejected
        // elsewhere or have no instantiation-specific state).
        else => s,
    };
}
