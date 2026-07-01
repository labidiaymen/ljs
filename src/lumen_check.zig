//! The type checker -- stage 3, between parsing and codegen.
//!
//! Walks the AST the parser produced, computes and validates a `Type` for every
//! expression and declaration, and writes the resolved types back onto the AST
//! nodes (the `?types.Type` fields) so the codegen never re-derives them. Type
//! errors become diagnostics (`lumen_diag.zig`); the first error aborts the build.
//!
//! This is one of the two large files (the other is the codegen). It is a `Checker`
//! struct that threads scope/binding/narrowing state, with one method per construct
//! (expressions, statements, declarations, classes, methods, imports). `exprType`
//! is the heart: given an expression it returns its `Type`, or null plus a
//! diagnostic on error. If you are adding a language feature, this is where its
//! typing rules live; keep the resolved-type fields it sets in sync with what the
//! codegen reads.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const diag_mod = @import("lumen_diag.zig");
const types = @import("lumen_types.zig");
const check_stdlib = @import("lumen_check_stdlib.zig");
const check_generics = @import("lumen_check_generics.zig");
const check_class = @import("lumen_check_class.zig");
const check_stmt = @import("lumen_check_stmt.zig");
const check_assign = @import("lumen_check_assign.zig");
const check_expr = @import("lumen_check_expr.zig");

const CompileError = diag_mod.CompileError;
const Diag = diag_mod.Diag;

const TypeDeclInfo = struct {
    fields: []ast.TypeField,
    string_literals: ?[][]const u8 = null,
    int_literals: ?[]i64 = null,
};

/// One variant of a discriminated union: its record name and the discriminant
/// literal value that selects it.
const UnionVariant = struct { name: []const u8, disc_value: []const u8 };

const UnionInfo = struct {
    variants: []UnionVariant,
    discriminant: []const u8, // shared discriminant field name
};

/// A union binding narrowed (inside a switch case / if branch) to one variant.
const NarrowedVariant = struct { name: []const u8, variant: []const u8 };

const FunctionInfo = struct {
    params: []ast.FunctionParam,
    return_type: types.Type,
    is_extern: bool = false,
};

const EnumInfo = struct {
    is_string: bool,
    members: []ast.EnumMember,
};

const ClassInfo = struct {
    fields: []ast.TypeField,
    methods: []ast.FunctionDecl,
    ctor_params: []ast.FunctionParam,
    has_ctor: bool,
    parent: ?[]const u8 = null,
};

const Binding = struct {
    ty: types.Type,
    mutable: bool,
    decl: ?*ast.VarDecl = null,
    emit_name: []const u8,
    // True for a scalar `Ref<T>` parameter: reads and assignments of this name
    // lower through the pointer (`name.*`).
    ref_scalar: bool = false,
    // True for any `Ref<T>` parameter. A record `Ref<T>` is mutable through its
    // pointer, so field writes on it are allowed (unlike plain V1 records).
    is_ref: bool = false,
};

const Scope = std.StringHashMapUnmanaged(Binding);

pub const Checker = struct {
    // Builtin/stdlib call type-checking lives in lumen_check_stdlib.zig (it grows
    // independently of the rest of the checker); aliased back so `self.foo(...)`
    // call sites elsewhere in this file are unchanged.
    pub const arrayMethod = check_stdlib.arrayMethod;
    pub const mapMethod = check_stdlib.mapMethod;
    pub const setMethod = check_stdlib.setMethod;
    pub const stringMethod = check_stdlib.stringMethod;
    pub const staticCallType = check_stdlib.staticCallType;
    pub const fsCallType = check_stdlib.fsCallType;
    pub const pathCallType = check_stdlib.pathCallType;
    pub const processCallType = check_stdlib.processCallType;
    pub const osCallType = check_stdlib.osCallType;
    pub const cryptoCallType = check_stdlib.cryptoCallType;
    pub const urlCallType = check_stdlib.urlCallType;
    pub const childProcessCallType = check_stdlib.childProcessCallType;
    pub const assertCallType = check_stdlib.assertCallType;
    pub const timeCallType = check_stdlib.timeCallType;
    pub const promiseCallType = check_stdlib.promiseCallType;
    pub const mathCallType = check_stdlib.mathCallType;
    pub const stringCallType = check_stdlib.stringCallType;
    pub const arrayCallType = check_stdlib.arrayCallType;

    // Generic function/class/type specialization lives in lumen_check_generics.zig.
    pub const isGenericTemplateStmt = check_generics.isGenericTemplateStmt;
    pub const appendStmt = check_generics.appendStmt;
    pub const isIdentChar = check_generics.isIdentChar;
    pub const substAnnotation = check_generics.substAnnotation;
    pub const annTag = check_generics.annTag;
    pub const mangledName = check_generics.mangledName;
    pub const splitTypeArgs = check_generics.splitTypeArgs;
    pub const resolveExplicitTypeArgs = check_generics.resolveExplicitTypeArgs;
    pub const inferTypeArgs = check_generics.inferTypeArgs;
    pub const unifyAnnotation = check_generics.unifyAnnotation;
    pub const specializeFunction = check_generics.specializeFunction;
    pub const specializeClass = check_generics.specializeClass;
    pub const specializeType = check_generics.specializeType;
    pub const substCur = check_generics.substCur;
    pub const cloneBody = check_generics.cloneBody;
    pub const cloneExpr = check_generics.cloneExpr;
    pub const cloneVarDecl = check_generics.cloneVarDecl;
    pub const cloneAssign = check_generics.cloneAssign;
    pub const cloneStmt = check_generics.cloneStmt;

    // Class member resolution lives in lumen_check_class.zig.
    pub const classField = check_class.classField;
    pub const resolveField = check_class.resolveField;
    pub const resolveStaticField = check_class.resolveStaticField;
    pub const resolveMethod = check_class.resolveMethod;
    pub const resolveStaticMethod = check_class.resolveStaticMethod;
    pub const resolveAccessor = check_class.resolveAccessor;
    pub const isSubclassOf = check_class.isSubclassOf;
    pub const checkVisibility = check_class.checkVisibility;
    pub const visibilityOk = check_class.visibilityOk;

    // Statement/function-body/class-body checking lives in lumen_check_stmt.zig.
    pub const declareExtern = check_stmt.declareExtern;
    pub const checkBlock = check_stmt.checkBlock;
    pub const checkFunctionBody = check_stmt.checkFunctionBody;
    pub const checkClass = check_stmt.checkClass;
    pub const checkMemberAssign = check_stmt.checkMemberAssign;
    pub const assignField = check_stmt.assignField;
    pub const checkStmt = check_stmt.checkStmt;

    // Assignability/cast checking lives in lumen_check_assign.zig.
    pub const ensureAssignable = check_assign.ensureAssignable;
    pub const castAllowed = check_assign.castAllowed;

    // Expression type-checking (the core dispatch) lives in lumen_check_expr.zig.
    pub const exprType = check_expr.exprType;
    pub const fieldType = check_expr.fieldType;

    arena: std.mem.Allocator,
    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    type_decls: std.StringHashMapUnmanaged(TypeDeclInfo) = .empty,
    // `type X = <annotation>;` aliases, resolved transitively in typeFromAnnotation.
    aliases: std.StringHashMapUnmanaged([]const u8) = .empty,
    // Discriminated unions keyed by union name.
    unions: std.StringHashMapUnmanaged(UnionInfo) = .empty,
    enums: std.StringHashMapUnmanaged(EnumInfo) = .empty,
    classes: std.StringHashMapUnmanaged(ClassInfo) = .empty,
    funcs: std.StringHashMapUnmanaged(FunctionInfo) = .empty,
    // Generic templates, keyed by base name. These are specialized on use
    // (monomorphization) rather than declared directly into the registries above.
    generic_funcs: std.StringHashMapUnmanaged(*ast.FunctionDecl) = .empty,
    generic_classes: std.StringHashMapUnmanaged(*ast.ClassDecl) = .empty,
    generic_types: std.StringHashMapUnmanaged(*ast.TypeDecl) = .empty,
    // Mangled names of already-emitted specializations (dedup) and the new
    // concrete declarations to append to the program for the emitter.
    specialized: std.StringHashMapUnmanaged(void) = .empty,
    // Heap-allocated so the worklist may grow (nested specializations) without
    // moving the in-progress declaration a `checkStmt` is currently mutating.
    pending_specializations: std.ArrayListUnmanaged(*ast.Stmt) = .empty,
    // Active substitution (type-parameter names -> concrete annotations) used to
    // rewrite annotations inside a generic body while it is being cloned.
    subst_params: []const []const u8 = &.{},
    subst_args: []const []const u8 = &.{},
    current_class: ?[]const u8 = null,
    in_constructor: bool = false,
    next_binding_id: u32 = 0,
    current_return_type: ?types.Type = null,
    // True while checking the body of an `async function` (gates `await`).
    in_async: bool = false,
    // True while checking inside any function/method body (top-level `await` is
    // allowed; `await` inside a non-async function body is rejected).
    in_function: bool = false,
    nested_stmt_depth: u32 = 0,
    loop_depth: u32 = 0,
    switch_depth: u32 = 0,
    test_depth: u32 = 0,
    narrowed: std.ArrayListUnmanaged([]const u8) = .empty,
    narrowed_variants: std.ArrayListUnmanaged(NarrowedVariant) = .empty,
    arrow_base: usize = 0, // scope index at which the current arrow's params start
    current_captures: ?*std.ArrayListUnmanaged(ast.Capture) = null,
    last_line: u32 = 1,
    last_col: u32 = 1,
    last_err: []const u8 = "syntax error",

    pub fn fail(self: *Checker, line: u32, col: u32, msg: []const u8) CompileError {
        self.last_line = line;
        self.last_col = col;
        self.last_err = msg;
        return error.ParseError;
    }

    pub fn inferenceFail(self: *Checker, line: u32, col: u32, msg: []const u8) CompileError {
        if (self.last_line == line and self.last_col == col and !std.mem.eql(u8, self.last_err, "syntax error")) {
            return error.ParseError;
        }
        return self.fail(line, col, msg);
    }

    pub fn undefined_(self: *Checker, name: []const u8, line: u32, col: u32) CompileError {
        self.last_err = std.fmt.allocPrint(self.arena, "undefined variable '{s}'", .{name}) catch "undefined variable";
        self.last_line = line;
        self.last_col = col;
        return error.ParseError;
    }

    pub fn currentScope(self: *Checker) *Scope {
        return &self.scopes.items[self.scopes.items.len - 1];
    }

    pub fn isNarrowed(self: *Checker, name: []const u8) bool {
        for (self.narrowed.items) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    /// The variant a union binding is currently narrowed to (innermost wins), or
    /// null if it is not narrowed.
    pub fn narrowedVariant(self: *Checker, name: []const u8) ?[]const u8 {
        var i = self.narrowed_variants.items.len;
        while (i > 0) {
            i -= 1;
            const nv = self.narrowed_variants.items[i];
            if (std.mem.eql(u8, nv.name, name)) return nv.variant;
        }
        return null;
    }

    /// If `cond` is `x != null` / `x !== null` (or undefined) returns the binding
    /// narrowed in the then-branch; `x == null` returns it for the else-branch.
    /// `in_then` says which branch the non-optional narrowing applies to.
    pub fn narrowTarget(cond: *ast.Expr) ?struct { name: []const u8, in_then: bool } {
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

    /// If `expr` is `s.disc` where `s` is a union binding and `disc` is that
    /// union's discriminant field, returns the binding name and union name.
    pub fn discriminantAccess(self: *Checker, expr: *ast.Expr) ?struct { name: []const u8, union_name: []const u8 } {
        if (expr.* != .field) return null;
        const fa = expr.field;
        if (fa.obj.* != .var_ref) return null;
        const var_name = fa.obj.var_ref.name;
        const b = self.binding(var_name) orelse return null;
        if (b.ty != .union_type) return null;
        const uinfo = self.unions.get(b.ty.union_type) orelse return null;
        if (!std.mem.eql(u8, fa.name, uinfo.discriminant)) return null;
        return .{ .name = var_name, .union_name = b.ty.union_type };
    }

    /// The variant of `union_name` selected by discriminant literal `value`.
    pub fn variantForValue(self: *Checker, union_name: []const u8, value: []const u8) ?[]const u8 {
        const uinfo = self.unions.get(union_name) orelse return null;
        for (uinfo.variants) |v| {
            if (std.mem.eql(u8, v.disc_value, value)) return v.name;
        }
        return null;
    }

    pub fn pushScope(self: *Checker) CompileError!void {
        self.scopes.append(self.arena, .empty) catch return error.OutOfMemory;
    }

    pub fn popScope(self: *Checker) void {
        self.scopes.items.len -= 1;
    }

    pub fn binding(self: *Checker, name: []const u8) ?Binding {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name)) |found| return found;
        }
        return null;
    }

    pub fn bindingDepth(self: *Checker, name: []const u8) ?usize {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name) != null) return i;
        }
        return null;
    }

    pub fn bindingPtr(self: *Checker, name: []const u8) ?*Binding {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].getPtr(name)) |found| return found;
        }
        return null;
    }

    pub fn freshEmitName(self: *Checker, name: []const u8) CompileError![]const u8 {
        const id = self.next_binding_id;
        self.next_binding_id += 1;
        return std.fmt.allocPrint(self.arena, "__lumen_{d}_{s}", .{ id, name }) catch error.OutOfMemory;
    }

    pub fn declare(self: *Checker, name: []const u8, decl: *ast.VarDecl, ty: types.Type, line: u32, col: u32) CompileError!void {
        const scope = self.currentScope();
        if (scope.get(name) != null) return self.fail(line, col, "E_DUPLICATE_BINDING");
        const emit_name = try self.freshEmitName(name);
        decl.emit_name = emit_name;
        scope.put(self.arena, name, .{ .ty = ty, .mutable = decl.mutable, .decl = decl, .emit_name = emit_name }) catch return error.OutOfMemory;
    }

    pub fn declareParam(self: *Checker, param: ast.FunctionParam, line: u32, col: u32) CompileError!void {
        const scope = self.currentScope();
        if (scope.get(param.name) != null) return self.fail(line, col, "E_DUPLICATE_BINDING");
        const param_type = param.checked_type orelse try self.typeFromAnnotation(param.annotation, line, col);
        scope.put(self.arena, param.name, .{ .ty = param_type, .mutable = true, .emit_name = param.name, .ref_scalar = param.ref_scalar, .is_ref = param.is_ref }) catch return error.OutOfMemory;
    }

    pub fn declareCatch(self: *Checker, stmt: *ast.TryStmt) CompileError!void {
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

    /// Resolve an alias target annotation, following nested aliases up to a depth
    /// bound (cycles fail rather than loop).
    fn resolveAlias(self: *Checker, annotation: []const u8, line: u32, col: u32) CompileError!types.Type {
        var current = annotation;
        var depth: u32 = 0;
        while (self.aliases.get(current)) |next| {
            depth += 1;
            if (depth > 32) return self.fail(line, col, "E_TYPE_MISMATCH"); // alias cycle
            current = next;
        }
        return self.typeFromAnnotation(current, line, col);
    }

    /// Validate a discriminated union: every variant is a declared record sharing
    /// one string-literal discriminant field, and record the variant map plus the
    /// merged flat-struct field set written back onto the declaration.
    fn declareUnion(self: *Checker, decl: *ast.TypeDecl) CompileError!void {
        if (self.type_decls.get(decl.name) != null or self.aliases.get(decl.name) != null or self.unions.get(decl.name) != null) {
            return self.fail(decl.line, decl.col, "E_DUPLICATE_BINDING");
        }
        const variant_names = decl.union_variants orelse return error.ParseError;
        if (variant_names.len < 2) return self.fail(decl.line, decl.col, "E_TYPE_MISMATCH");
        var discriminant: ?[]const u8 = null;
        var variants: std.ArrayListUnmanaged(UnionVariant) = .empty;
        var merged: std.ArrayListUnmanaged(ast.TypeField) = .empty;
        for (variant_names) |vname| {
            const vinfo = self.type_decls.get(vname) orelse return self.fail(decl.line, decl.col, "E_TYPE_MISMATCH");
            if (vinfo.string_literals != null or vinfo.int_literals != null) return self.fail(decl.line, decl.col, "E_TYPE_MISMATCH");
            // Find this variant's discriminant: a field with a string-literal type.
            var disc_field: ?[]const u8 = null;
            var disc_value: ?[]const u8 = null;
            for (self.declFields(vname)) |f| {
                if (f.annotation.len >= 2 and f.annotation[0] == '"' and f.annotation[f.annotation.len - 1] == '"') {
                    if (disc_field != null) return self.fail(decl.line, decl.col, "E_TYPE_MISMATCH"); // ambiguous: two literal fields
                    disc_field = f.name;
                    disc_value = f.annotation[1 .. f.annotation.len - 1];
                }
            }
            const df = disc_field orelse return self.fail(decl.line, decl.col, "E_TYPE_MISMATCH"); // no discriminant
            if (discriminant) |d| {
                if (!std.mem.eql(u8, d, df)) return self.fail(decl.line, decl.col, "E_TYPE_MISMATCH"); // mismatched discriminant field
            } else discriminant = df;
            try variants.append(self.arena, .{ .name = vname, .disc_value = disc_value.? });
            // Merge fields (dedup by name) into the flat struct.
            for (self.declFields(vname)) |f| {
                var present = false;
                for (merged.items) |m| {
                    if (std.mem.eql(u8, m.name, f.name)) present = true;
                }
                if (!present) {
                    try merged.append(self.arena, .{ .name = f.name, .annotation = f.annotation, .checked_type = try self.typeFromAnnotation(f.annotation, decl.line, decl.col) });
                }
            }
        }
        decl.fields = try merged.toOwnedSlice(self.arena);
        self.unions.put(self.arena, decl.name, .{ .variants = try variants.toOwnedSlice(self.arena), .discriminant = discriminant.? }) catch return error.OutOfMemory;
    }

    /// The declared fields of a record type by name (empty if not a record).
    fn declFields(self: *Checker, type_name: []const u8) []ast.TypeField {
        if (self.type_decls.get(type_name)) |info| return info.fields;
        return &.{};
    }

    /// The declared type of one record field, or null if the type is not a known
    /// record or lacks that field.
    pub fn recordFieldType(self: *Checker, type_name: []const u8, field: []const u8) ?types.Type {
        for (self.declFields(type_name)) |f| {
            if (std.mem.eql(u8, f.name, field)) {
                return f.checked_type orelse (self.typeFromAnnotation(f.annotation, 0, 0) catch null);
            }
        }
        return null;
    }

    /// Force the root variable of an lvalue path to emit as a mutable (`var`)
    /// binding so the backend can take its address for a by-reference argument.
    pub fn markReassignedRoot(self: *Checker, e: *const ast.Expr) void {
        switch (e.*) {
            .var_ref => |r| if (self.bindingPtr(r.name)) |b| {
                if (b.decl) |d| d.reassigned = true;
            },
            .field => |f| self.markReassignedRoot(f.obj),
            else => {},
        }
    }

    /// Whether an lvalue path's root variable is a mutable binding (a `let`/`var`
    /// or a parameter), so it may be passed by reference.
    pub fn refRootMutable(self: *Checker, e: *const ast.Expr) bool {
        return switch (e.*) {
            .var_ref => |r| if (self.binding(r.name)) |b| b.mutable else false,
            .field => |f| self.refRootMutable(f.obj),
            else => false,
        };
    }

    /// Whether an lvalue path is rooted in a by-reference (`Ref<T>`) parameter, so
    /// writes through it are allowed (the underlying value is mutable in place).
    pub fn refRooted(self: *Checker, e: *const ast.Expr) bool {
        return switch (e.*) {
            .var_ref => |r| if (self.binding(r.name)) |b| b.is_ref else false,
            .field => |f| self.refRooted(f.obj),
            else => false,
        };
    }

    pub fn funcSigType(self: *Checker, finfo: FunctionInfo) CompileError!types.Type {
        const params = self.arena.alloc(types.Type, finfo.params.len) catch return error.OutOfMemory;
        for (finfo.params, 0..) |p, i| params[i] = p.checked_type orelse return error.ParseError;
        const ret_p = self.arena.create(types.Type) catch return error.OutOfMemory;
        ret_p.* = finfo.return_type;
        const sig = self.arena.create(types.FuncSig) catch return error.OutOfMemory;
        sig.* = .{ .params = params, .ret = ret_p };
        return .{ .func_type = sig };
    }

    pub fn typeFromAnnotation(self: *Checker, annotation: []const u8, line: u32, col: u32) CompileError!types.Type {
        // A string-literal member type `"value"` (e.g. a discriminant field) is
        // a single-value string; it erases to `string` for storage and emission.
        if (annotation.len >= 2 and annotation[0] == '"' and annotation[annotation.len - 1] == '"') {
            return .string;
        }
        // Resolve `type X = <annotation>;` aliases transitively (bounded depth).
        if (self.aliases.get(annotation)) |target| {
            return self.resolveAlias(target, line, col);
        }
        // A discriminated union name resolves to its union type.
        if (self.unions.get(annotation) != null) return .{ .union_type = annotation };
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
        // Tuple type `[A, B, ...]` — a bracketed, comma-separated positional list.
        // (Array element annotations end with `[]` and are handled by
        // fromAnnotation, so a leading `[` with matching `]` is always a tuple.)
        if (annotation.len >= 2 and annotation[0] == '[' and annotation[annotation.len - 1] == ']') {
            const inner = annotation[1 .. annotation.len - 1];
            const parts = try self.splitTypeArgs(inner, line, col);
            if (parts.len == 0) return self.fail(line, col, "E_TYPE_MISMATCH");
            const elems = self.arena.alloc(types.Type, parts.len) catch return error.OutOfMemory;
            for (parts, 0..) |p, i| elems[i] = try self.typeFromAnnotation(p, line, col);
            return .{ .tuple_type = elems };
        }
        // Generic type reference `Name<arg, ...>` (interface or class). Specialize
        // the template on demand and resolve to the concrete named/class type.
        if (std.mem.indexOfScalar(u8, annotation, '<')) |lt| {
            if (std.mem.endsWith(u8, annotation, ">")) {
                const base = annotation[0..lt];
                const args = try self.splitTypeArgs(annotation[lt + 1 .. annotation.len - 1], line, col);
                // Built-in generic containers Map<K,V> and Set<T>.
                if (std.mem.eql(u8, base, "Map")) {
                    if (args.len != 2) return self.fail(line, col, "E_TYPE_ARG_COUNT");
                    const k = self.arena.create(types.Type) catch return error.OutOfMemory;
                    const v = self.arena.create(types.Type) catch return error.OutOfMemory;
                    k.* = try self.typeFromAnnotation(args[0], line, col);
                    v.* = try self.typeFromAnnotation(args[1], line, col);
                    const m = self.arena.create(types.MapType) catch return error.OutOfMemory;
                    m.* = .{ .key = k, .value = v };
                    return .{ .map_type = m };
                }
                if (std.mem.eql(u8, base, "Set")) {
                    if (args.len != 1) return self.fail(line, col, "E_TYPE_ARG_COUNT");
                    const e = self.arena.create(types.Type) catch return error.OutOfMemory;
                    e.* = try self.typeFromAnnotation(args[0], line, col);
                    return .{ .set_type = e };
                }
                if (std.mem.eql(u8, base, "Promise")) {
                    if (args.len != 1) return self.fail(line, col, "E_TYPE_ARG_COUNT");
                    const e = self.arena.create(types.Type) catch return error.OutOfMemory;
                    e.* = try self.typeFromAnnotation(args[0], line, col);
                    return .{ .promise_type = e };
                }
                if (self.generic_types.get(base)) |gt| {
                    if (args.len != gt.type_params.len) return self.fail(line, col, "E_TYPE_ARG_COUNT");
                    const mname = try self.specializeType(gt, args, line, col);
                    return .{ .named = mname };
                }
                if (self.generic_classes.get(base)) |gc| {
                    if (args.len != gc.type_params.len) return self.fail(line, col, "E_TYPE_ARG_COUNT");
                    const mname = try self.specializeClass(gc, args, line, col);
                    return .{ .class_type = mname };
                }
                return self.fail(line, col, "unknown generic type");
            }
        }
        if (self.enums.get(annotation)) |einfo| {
            return .{ .enum_type = .{ .name = annotation, .is_string = einfo.is_string } };
        }
        if (self.classes.get(annotation) != null) {
            return .{ .class_type = annotation };
        }
        if (self.type_decls.get(annotation)) |decl| {
            if (decl.string_literals != null) return .{ .string_literal_union = annotation };
            if (decl.int_literals != null) return .{ .int_literal_union = annotation };
        }
        return types.fromAnnotation(annotation);
    }

    /// Resolve a function/method parameter annotation, intercepting the built-in
    /// by-reference marker `Ref<T>` before the generics machinery treats `Ref` as
    /// a user generic. A `Ref<T>` parameter type-checks as `T` (its `checked_type`
    /// is the inner type) but is passed by single pointer; the inner type must be
    /// a value type (record/interface, scalar, union, enum, or tuple). Classes,
    /// arrays, strings, maps, sets, and promises are already reference-like and
    /// are rejected. A rest `Ref<T>[]` is not supported.
    fn resolveParam(self: *Checker, param: *ast.FunctionParam, line: u32, col: u32) CompileError!void {
        if (refInner(param.annotation)) |inner_ann| {
            if (param.is_rest) return self.fail(line, col, "E_REF_TARGET");
            const inner = try self.typeFromAnnotation(inner_ann, line, col);
            if (inner == .class_type) return self.fail(line, col, "E_REF_TARGET");
            if (!types.isRefAllowed(inner)) return self.fail(line, col, "E_REF_TARGET");
            param.is_ref = true;
            param.ref_scalar = types.isRefScalar(inner);
            param.checked_type = inner;
            return;
        }
        param.checked_type = try self.typeFromAnnotation(param.annotation, line, col);
    }

    pub fn declareFunction(self: *Checker, decl: *ast.FunctionDecl) CompileError!void {
        if (self.funcs.get(decl.name) != null) return self.fail(decl.line, decl.col, "E_DUPLICATE_BINDING");
        const return_type = try self.typeFromAnnotation(decl.return_annotation, decl.line, decl.col);
        // An async function must declare a `Promise<T>` return type.
        if (decl.is_async and return_type != .promise_type) return self.fail(decl.line, decl.col, "E_ASYNC_RETURN");
        for (decl.params) |*param| {
            try self.resolveParam(param, decl.line, decl.col);
        }
        try self.validateParamSignature(decl.params);
        decl.checked_return_type = return_type;
        self.funcs.put(self.arena, decl.name, .{ .params = decl.params, .return_type = return_type }) catch return error.OutOfMemory;
    }

    /// Validates structural default-value and rest-parameter rules over a resolved
    /// parameter list: a rest param must be the last and array-typed; once a
    /// parameter has a default, every following non-rest parameter must also have
    /// one. Default-value *types* are checked later in checkFunctionBody (where the
    /// program context is available).
    fn validateParamSignature(self: *Checker, params: []ast.FunctionParam) CompileError!void {
        var seen_default = false;
        for (params, 0..) |*param, i| {
            if (param.is_rest) {
                if (i != params.len - 1) return self.fail(0, 0, "E_REST_NOT_LAST");
                const pt = param.checked_type orelse return self.fail(0, 0, "E_TYPE_MISMATCH");
                if (!types.isArray(pt)) return self.fail(0, 0, "E_REST_NOT_ARRAY");
                continue;
            }
            if (param.default != null) {
                seen_default = true;
            } else if (seen_default) {
                // A required parameter after an optional one is not allowed.
                return self.fail(0, 0, "E_REQUIRED_AFTER_OPTIONAL");
            }
        }
    }

    /// Validates a call's arguments against a parameter list that may include
    /// defaults and a trailing rest parameter, and returns a normalized argument
    /// slice with exactly one entry per parameter (defaults filled in, rest
    /// collected into an array literal). Spread arguments (`...src`) are only
    /// permitted feeding a rest parameter. Returns null after recording a
    /// diagnostic on any mismatch.
    pub fn checkCallArgs(self: *Checker, program: *ast.Program, params: []const ast.FunctionParam, args: []const *ast.Expr, line: u32, col: u32) ?[]*ast.Expr {
        const has_rest = params.len > 0 and params[params.len - 1].is_rest;
        const fixed_count = if (has_rest) params.len - 1 else params.len;

        // Minimum required positional args: fixed params without a default.
        var required: usize = 0;
        for (params[0..fixed_count]) |p| {
            if (p.default == null) required += 1;
        }

        // A spread argument is only valid when it lands in the rest slot.
        for (args, 0..) |a, i| {
            if (a.* == .spread and !(has_rest and i >= fixed_count)) {
                _ = self.fail(line, col, "E_SPREAD_TARGET") catch {};
                return null;
            }
        }

        if (args.len < required or (!has_rest and args.len > fixed_count)) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }

        var out: std.ArrayListUnmanaged(*ast.Expr) = .empty;

        // Fixed parameters: use the positional arg or fall back to the default.
        for (params[0..fixed_count], 0..) |p, i| {
            const pt = p.checked_type orelse {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            };
            if (i < args.len) {
                self.ensureAssignable(program, pt, args[i], line, col) catch {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                };
                out.append(self.arena, args[i]) catch return null;
            } else {
                out.append(self.arena, p.default.?) catch return null;
            }
        }

        if (has_rest) {
            const rest_param = params[params.len - 1];
            const rest_type = rest_param.checked_type orelse {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            };
            const elem_type = types.arrayElem(rest_type) orelse {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            };
            const rest_args = args[fixed_count..];
            // Build an array literal node from the trailing args; spread entries
            // carry their array source, plain entries their element value.
            const items = self.arena.alloc(*ast.Expr, rest_args.len) catch return null;
            var has_spread = false;
            for (rest_args, 0..) |a, i| {
                if (a.* == .spread) {
                    has_spread = true;
                    self.ensureAssignable(program, rest_type, a.spread, line, col) catch {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    };
                } else {
                    self.ensureAssignable(program, elem_type, a, line, col) catch {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    };
                }
                items[i] = a;
            }
            const arr_node = self.arena.create(ast.Expr) catch return null;
            // Use the runtime-concat form (carry elem_type) when spreading or when
            // empty, so the slice gets an explicit element type Zig can coerce.
            const need_typed = has_spread or rest_args.len == 0;
            arr_node.* = .{ .array = .{ .items = items, .elem_type = if (need_typed) elem_type else null } };
            out.append(self.arena, arr_node) catch return null;
        }

        return out.toOwnedSlice(self.arena) catch return null;
    }

    fn checkProgram(self: *Checker, program: *ast.Program) CompileError!void {
        try self.pushScope();
        for (program.stmts) |*stmt| {
            if (stmt.* == .type_decl) {
                if (stmt.type_decl.type_params.len > 0) {
                    if (self.generic_types.get(stmt.type_decl.name) != null) return self.fail(stmt.type_decl.line, stmt.type_decl.col, "E_DUPLICATE_BINDING");
                    self.generic_types.put(self.arena, stmt.type_decl.name, &stmt.type_decl) catch return error.OutOfMemory;
                    continue;
                }
                if (stmt.type_decl.alias) |target| {
                    if (self.aliases.get(stmt.type_decl.name) != null or self.type_decls.get(stmt.type_decl.name) != null) return self.fail(stmt.type_decl.line, stmt.type_decl.col, "E_DUPLICATE_BINDING");
                    self.aliases.put(self.arena, stmt.type_decl.name, target) catch return error.OutOfMemory;
                    continue;
                }
                if (stmt.type_decl.union_variants != null) continue; // validated in the union pass below
                try self.declareType(stmt.type_decl.name, stmt.type_decl.fields, stmt.type_decl.string_literals, stmt.type_decl.int_literals, stmt.type_decl.line, stmt.type_decl.col);
            }
        }
        // Union pass: variants must already be declared records sharing a single
        // string-literal discriminant field. Build the merged flat-struct fields.
        for (program.stmts) |*stmt| {
            if (stmt.* == .type_decl and stmt.type_decl.union_variants != null) {
                try self.declareUnion(&stmt.type_decl);
            }
        }
        for (program.stmts) |*stmt| {
            if (stmt.* == .enum_decl) {
                const e = stmt.enum_decl;
                if (self.enums.get(e.name) != null or self.type_decls.get(e.name) != null) return self.fail(e.line, e.col, "E_DUPLICATE_BINDING");
                self.enums.put(self.arena, e.name, .{ .is_string = e.is_string, .members = e.members }) catch return error.OutOfMemory;
            }
        }
        // Register class names (pass A) so cross-references resolve, then fill
        // field/method/constructor types (pass B).
        for (program.stmts) |*stmt| {
            if (stmt.* == .class_decl) {
                const c = &stmt.class_decl;
                if (c.type_params.len > 0) {
                    if (self.generic_classes.get(c.name) != null) return self.fail(c.line, c.col, "E_DUPLICATE_BINDING");
                    self.generic_classes.put(self.arena, c.name, c) catch return error.OutOfMemory;
                    continue;
                }
                if (self.classes.get(c.name) != null) return self.fail(c.line, c.col, "E_DUPLICATE_BINDING");
                self.classes.put(self.arena, c.name, .{ .fields = c.fields, .methods = c.methods, .ctor_params = c.ctor_params, .has_ctor = c.has_ctor, .parent = c.parent }) catch return error.OutOfMemory;
            }
        }
        for (program.stmts) |*stmt| {
            if (stmt.* == .class_decl and stmt.class_decl.type_params.len == 0) try self.fillClassTypes(&stmt.class_decl);
        }
        for (program.stmts) |*stmt| {
            if (stmt.* == .extern_decl) try self.declareExtern(&stmt.extern_decl);
        }
        for (program.stmts) |*stmt| {
            if (stmt.* == .function_decl) {
                if (stmt.function_decl.type_params.len > 0) {
                    if (self.generic_funcs.get(stmt.function_decl.name) != null or self.funcs.get(stmt.function_decl.name) != null) return self.fail(stmt.function_decl.line, stmt.function_decl.col, "E_DUPLICATE_BINDING");
                    self.generic_funcs.put(self.arena, stmt.function_decl.name, &stmt.function_decl) catch return error.OutOfMemory;
                    continue;
                }
                try self.declareFunction(&stmt.function_decl);
            }
        }
        for (program.stmts) |*stmt| {
            if (self.isGenericTemplateStmt(stmt)) continue;
            try self.checkStmt(program, stmt);
        }
        // Specializations discovered while checking may themselves reference more
        // generics, so drain the worklist until it stops growing. Each entry is a
        // stable heap pointer, so appending more during a check is safe.
        var i: usize = 0;
        while (i < self.pending_specializations.items.len) : (i += 1) {
            try self.checkStmt(program, self.pending_specializations.items[i]);
        }
        // Append the concrete specializations so the emitter outputs them.
        for (self.pending_specializations.items) |spec| {
            program.stmts = self.appendStmt(program.stmts, spec.*) catch return error.OutOfMemory;
        }
    }

    /// True for a generic template declaration (skipped by the main check loop
    /// and the emitter; only its specializations are checked/emitted).
    pub fn fillClassTypes(self: *Checker, c: *ast.ClassDecl) CompileError!void {
        for (c.fields) |*field| {
            field.checked_type = try self.typeFromAnnotation(field.annotation, c.line, c.col);
        }
        for (c.ctor_params) |*param| {
            // Constructor params become fields; by-reference params are not
            // storable as fields, so reject `Ref<T>` here.
            if (refInner(param.annotation) != null) return self.fail(c.line, c.col, "E_REF_TARGET");
            param.checked_type = try self.typeFromAnnotation(param.annotation, c.line, c.col);
        }
        for (c.methods) |*m| {
            for (m.params) |*param| try self.resolveParam(param, m.line, m.col);
            m.checked_return_type = try self.typeFromAnnotation(m.return_annotation, m.line, m.col);
        }
    }

    pub const ResolvedField = struct { field: ast.TypeField, owner: []const u8 };
    pub const ResolvedMethod = struct { method: ast.FunctionDecl, owner: []const u8 };

    pub fn makeFuncType(self: *Checker, params: []const types.Type, ret: types.Type) ?types.Type {
        const ps = self.arena.alloc(types.Type, params.len) catch return null;
        for (params, 0..) |p, i| ps[i] = p;
        const ret_p = self.arena.create(types.Type) catch return null;
        ret_p.* = ret;
        const sig = self.arena.create(types.FuncSig) catch return null;
        sig.* = .{ .params = ps, .ret = ret_p };
        return .{ .func_type = sig };
    }
};

/// Types allowed in extern function signatures: C-ABI scalars plus `string`,
/// which is marshalled to/from a NUL-terminated C `const char*` at the call
/// boundary. Arrays, records, and function types remain rejected (E_FFI_TYPE).
/// If `annotation` is the by-reference marker `Ref<T>`, returns the inner `T`
/// annotation (trimmed); otherwise null. `Ref` is reserved as a built-in marker,
/// so it is matched here before the generics machinery resolves type references.
pub fn refInner(annotation: []const u8) ?[]const u8 {
    const a = std.mem.trim(u8, annotation, " ");
    if (!std.mem.startsWith(u8, a, "Ref<")) return null;
    if (!std.mem.endsWith(u8, a, ">")) return null;
    const inner = a["Ref<".len .. a.len - 1];
    return std.mem.trim(u8, inner, " ");
}

/// Whether an expression is an addressable lvalue eligible to be passed to a
/// by-reference (`Ref<T>`) parameter: a plain variable, or a field path rooted in
/// one (`obj.field`, `obj.a.b`). Literals, temporaries, and computed expressions
/// are rejected.
pub fn isAddressable(e: *const ast.Expr) bool {
    return switch (e.*) {
        .var_ref => true,
        .field => |f| f.enum_value == null and f.builtin == null and !f.is_static and !f.optional_chain and isAddressable(f.obj),
        else => false,
    };
}

pub fn isCSafe(t: types.Type) bool {
    return switch (t) {
        .i32, .i64, .f64, .bool, .string => true,
        else => false,
    };
}

pub fn findField(fields: []ast.FieldInit, name: []const u8) ?ast.FieldInit {
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
