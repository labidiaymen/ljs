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

const Checker = struct {
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

    /// The variant a union binding is currently narrowed to (innermost wins), or
    /// null if it is not narrowed.
    fn narrowedVariant(self: *Checker, name: []const u8) ?[]const u8 {
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

    /// If `expr` is `s.disc` where `s` is a union binding and `disc` is that
    /// union's discriminant field, returns the binding name and union name.
    fn discriminantAccess(self: *Checker, expr: *ast.Expr) ?struct { name: []const u8, union_name: []const u8 } {
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
    fn variantForValue(self: *Checker, union_name: []const u8, value: []const u8) ?[]const u8 {
        const uinfo = self.unions.get(union_name) orelse return null;
        for (uinfo.variants) |v| {
            if (std.mem.eql(u8, v.disc_value, value)) return v.name;
        }
        return null;
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

    fn bindingDepth(self: *Checker, name: []const u8) ?usize {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name) != null) return i;
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
        scope.put(self.arena, param.name, .{ .ty = param_type, .mutable = true, .emit_name = param.name, .ref_scalar = param.ref_scalar, .is_ref = param.is_ref }) catch return error.OutOfMemory;
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
    fn recordFieldType(self: *Checker, type_name: []const u8, field: []const u8) ?types.Type {
        for (self.declFields(type_name)) |f| {
            if (std.mem.eql(u8, f.name, field)) {
                return f.checked_type orelse (self.typeFromAnnotation(f.annotation, 0, 0) catch null);
            }
        }
        return null;
    }

    /// Force the root variable of an lvalue path to emit as a mutable (`var`)
    /// binding so the backend can take its address for a by-reference argument.
    fn markReassignedRoot(self: *Checker, e: *const ast.Expr) void {
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
    fn refRootMutable(self: *Checker, e: *const ast.Expr) bool {
        return switch (e.*) {
            .var_ref => |r| if (self.binding(r.name)) |b| b.mutable else false,
            .field => |f| self.refRootMutable(f.obj),
            else => false,
        };
    }

    /// Whether an lvalue path is rooted in a by-reference (`Ref<T>`) parameter, so
    /// writes through it are allowed (the underlying value is mutable in place).
    fn refRooted(self: *Checker, e: *const ast.Expr) bool {
        return switch (e.*) {
            .var_ref => |r| if (self.binding(r.name)) |b| b.is_ref else false,
            .field => |f| self.refRooted(f.obj),
            else => false,
        };
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

    fn declareFunction(self: *Checker, decl: *ast.FunctionDecl) CompileError!void {
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
    fn checkCallArgs(self: *Checker, program: *ast.Program, params: []const ast.FunctionParam, args: []const *ast.Expr, line: u32, col: u32) ?[]*ast.Expr {
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
    fn isGenericTemplateStmt(self: *Checker, stmt: *const ast.Stmt) bool {
        _ = self;
        return switch (stmt.*) {
            .function_decl => |d| d.type_params.len > 0,
            .class_decl => |d| d.type_params.len > 0,
            .type_decl => |d| d.type_params.len > 0,
            else => false,
        };
    }

    fn appendStmt(self: *Checker, stmts: []ast.Stmt, stmt: ast.Stmt) ![]ast.Stmt {
        const grown = try self.arena.alloc(ast.Stmt, stmts.len + 1);
        @memcpy(grown[0..stmts.len], stmts);
        grown[stmts.len] = stmt;
        return grown;
    }

    // ── generics: monomorphization ─────────────────────────────────────────────

    fn isIdentChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '$';
    }

    /// Token-aware substitution of type parameters by concrete annotation
    /// strings inside an annotation. Whole identifiers matching a parameter name
    /// are replaced; substrings of larger identifiers are left intact.
    fn substAnnotation(self: *Checker, ann: []const u8, params: []const []const u8, args: []const []const u8) CompileError![]const u8 {
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
    fn annotationMentions(param: []const u8, ann: []const u8) bool {
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
    fn annTag(self: *Checker, ann: []const u8) CompileError![]const u8 {
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

    fn mangledName(self: *Checker, base: []const u8, args: []const []const u8) CompileError![]const u8 {
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
    fn splitTypeArgs(self: *Checker, s: []const u8, line: u32, col: u32) CompileError![][]const u8 {
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
    fn resolveExplicitTypeArgs(self: *Checker, type_params: []const []const u8, type_args: []const []const u8, line: u32, col: u32) CompileError![][]const u8 {
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
    fn inferTypeArgs(self: *Checker, program: *ast.Program, type_params: []const []const u8, params: []const ast.FunctionParam, args: []const *ast.Expr, line: u32, col: u32) CompileError![][]const u8 {
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
    fn unifyAnnotation(self: *Checker, type_params: []const []const u8, found: []?[]const u8, pattern: []const u8, arg_type: types.Type, line: u32, col: u32) CompileError!void {
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
    fn specializeFunction(self: *Checker, decl: *const ast.FunctionDecl, type_args: []const []const u8, line: u32, col: u32) CompileError!struct { name: []const u8, ret: types.Type } {
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
    fn specializeClass(self: *Checker, decl: *const ast.ClassDecl, type_args: []const []const u8, line: u32, col: u32) CompileError![]const u8 {
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
    fn specializeType(self: *Checker, decl: *const ast.TypeDecl, type_args: []const []const u8, line: u32, col: u32) CompileError![]const u8 {
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
    fn substCur(self: *Checker, ann: []const u8) CompileError![]const u8 {
        if (self.subst_params.len == 0) return ann;
        return self.substAnnotation(ann, self.subst_params, self.subst_args);
    }

    fn cloneBody(self: *Checker, body: []const ast.Stmt) CompileError![]ast.Stmt {
        const out = self.arena.alloc(ast.Stmt, body.len) catch return error.OutOfMemory;
        for (body, 0..) |s, i| out[i] = try self.cloneStmt(s);
        return out;
    }

    fn cloneExpr(self: *Checker, e: *const ast.Expr) CompileError!*ast.Expr {
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

    fn cloneVarDecl(self: *Checker, d: ast.VarDecl) CompileError!ast.VarDecl {
        const ann = if (d.annotation) |a| try self.substCur(a) else null;
        return .{ .mutable = d.mutable, .name = d.name, .annotation = ann, .init = try self.cloneExpr(d.init), .line = d.line, .col = d.col };
    }

    fn cloneAssign(self: *Checker, a: ast.Assign) CompileError!ast.Assign {
        return .{ .name = a.name, .op = a.op, .value = try self.cloneExpr(a.value), .line = a.line, .col = a.col };
    }

    fn cloneStmt(self: *Checker, s: ast.Stmt) CompileError!ast.Stmt {
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

    fn fillClassTypes(self: *Checker, c: *ast.ClassDecl) CompileError!void {
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

    fn classField(self: *Checker, class_name: []const u8, field: []const u8) ?types.Type {
        if (self.resolveField(class_name, field)) |r| return r.field.checked_type;
        return null;
    }

    const ResolvedField = struct { field: ast.TypeField, owner: []const u8 };
    const ResolvedMethod = struct { method: ast.FunctionDecl, owner: []const u8 };

    /// Find an instance field by name, walking the inheritance chain. Static
    /// fields are excluded (looked up separately via `resolveStaticField`).
    fn resolveField(self: *Checker, class_name: []const u8, field: []const u8) ?ResolvedField {
        var cur: ?[]const u8 = class_name;
        while (cur) |name| {
            const info = self.classes.get(name) orelse return null;
            for (info.fields) |f| {
                if (!f.is_static and std.mem.eql(u8, f.name, field)) return .{ .field = f, .owner = name };
            }
            cur = info.parent;
        }
        return null;
    }

    fn resolveStaticField(self: *Checker, class_name: []const u8, field: []const u8) ?ResolvedField {
        var cur: ?[]const u8 = class_name;
        while (cur) |name| {
            const info = self.classes.get(name) orelse return null;
            for (info.fields) |f| {
                if (f.is_static and std.mem.eql(u8, f.name, field)) return .{ .field = f, .owner = name };
            }
            cur = info.parent;
        }
        return null;
    }

    /// Find an instance method/accessor by name, walking the chain. The most
    /// derived definition wins (override).
    fn resolveMethod(self: *Checker, class_name: []const u8, name: []const u8) ?ResolvedMethod {
        var cur: ?[]const u8 = class_name;
        while (cur) |cname| {
            const info = self.classes.get(cname) orelse return null;
            for (info.methods) |m| {
                if (!m.is_static and m.accessor == .none and std.mem.eql(u8, m.name, name)) return .{ .method = m, .owner = cname };
            }
            cur = info.parent;
        }
        return null;
    }

    fn resolveStaticMethod(self: *Checker, class_name: []const u8, name: []const u8) ?ResolvedMethod {
        var cur: ?[]const u8 = class_name;
        while (cur) |cname| {
            const info = self.classes.get(cname) orelse return null;
            for (info.methods) |m| {
                if (m.is_static and m.accessor == .none and std.mem.eql(u8, m.name, name)) return .{ .method = m, .owner = cname };
            }
            cur = info.parent;
        }
        return null;
    }

    fn resolveAccessor(self: *Checker, class_name: []const u8, name: []const u8, kind: ast.Accessor) ?ResolvedMethod {
        var cur: ?[]const u8 = class_name;
        while (cur) |cname| {
            const info = self.classes.get(cname) orelse return null;
            for (info.methods) |m| {
                if (m.accessor == kind and std.mem.eql(u8, m.name, name)) return .{ .method = m, .owner = cname };
            }
            cur = info.parent;
        }
        return null;
    }

    /// True if `sub` is `ancestor` or a (transitive) subclass of it.
    fn isSubclassOf(self: *Checker, sub: []const u8, ancestor: []const u8) bool {
        var cur: ?[]const u8 = sub;
        while (cur) |name| {
            if (std.mem.eql(u8, name, ancestor)) return true;
            const info = self.classes.get(name) orelse return false;
            cur = info.parent;
        }
        return false;
    }

    /// Enforce member visibility for an access whose member is declared in
    /// `owner` with `vis`, from the currently-checked class context.
    fn checkVisibility(self: *Checker, vis: ast.Visibility, owner: []const u8, line: u32, col: u32) CompileError!void {
        switch (vis) {
            .public => {},
            .private => {
                const here = self.current_class orelse return self.fail(line, col, "E_PRIVATE_ACCESS");
                if (!std.mem.eql(u8, here, owner)) return self.fail(line, col, "E_PRIVATE_ACCESS");
            },
            .protected => {
                const here = self.current_class orelse return self.fail(line, col, "E_PROTECTED_ACCESS");
                if (!self.isSubclassOf(here, owner)) return self.fail(line, col, "E_PROTECTED_ACCESS");
            },
        }
    }

    /// Non-erroring visibility check for use inside `exprType` (which returns
    /// `?Type`). Records the diagnostic and returns false on violation.
    fn visibilityOk(self: *Checker, vis: ast.Visibility, owner: []const u8, line: u32, col: u32) bool {
        self.checkVisibility(vis, owner, line, col) catch return false;
        return true;
    }

    /// Build a function type `(params...) => ret` for callback validation.
    fn makeFuncType(self: *Checker, params: []const types.Type, ret: types.Type) ?types.Type {
        const ps = self.arena.alloc(types.Type, params.len) catch return null;
        for (params, 0..) |p, i| ps[i] = p;
        const ret_p = self.arena.create(types.Type) catch return null;
        ret_p.* = ret;
        const sig = self.arena.create(types.FuncSig) catch return null;
        sig.* = .{ .params = ps, .ret = ret_p };
        return .{ .func_type = sig };
    }

    /// Type-check a higher-order / value array method `arr.m(args)` on an array
    /// receiver and return its result type, recording resolved element/result
    /// types on the node for emission.
    fn arrayMethod(self: *Checker, program: *ast.Program, mc: anytype, obj_type: types.Type, line: u32, col: u32) ?types.Type {
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
    fn mapMethod(self: *Checker, program: *ast.Program, mc: anytype, obj_type: types.Type, line: u32, col: u32) ?types.Type {
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
    fn setMethod(self: *Checker, program: *ast.Program, mc: anytype, obj_type: types.Type, line: u32, col: u32) ?types.Type {
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
    fn stringMethod(self: *Checker, program: *ast.Program, mc: anytype, line: u32, col: u32) ?types.Type {
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

    fn declareExtern(self: *Checker, decl: *ast.ExternDecl) CompileError!void {
        if (self.funcs.get(decl.name) != null) return self.fail(decl.line, decl.col, "E_DUPLICATE_BINDING");
        const ret = try self.typeFromAnnotation(decl.return_annotation, decl.line, decl.col);
        if (!isCSafe(ret) and ret != .void) return self.fail(decl.line, decl.col, "E_FFI_TYPE");
        decl.checked_return_type = ret;
        for (decl.params) |*param| {
            // `Ref<T>` is not part of the C ABI surface.
            if (refInner(param.annotation) != null) return self.fail(decl.line, decl.col, "E_FFI_TYPE");
            param.checked_type = try self.typeFromAnnotation(param.annotation, decl.line, decl.col);
            if (!isCSafe(param.checked_type.?)) return self.fail(decl.line, decl.col, "E_FFI_TYPE");
        }
        self.funcs.put(self.arena, decl.name, .{ .params = decl.params, .return_type = ret, .is_extern = true }) catch return error.OutOfMemory;
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

    fn checkClass(self: *Checker, program: *ast.Program, c: *ast.ClassDecl) CompileError!void {
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

    fn checkMemberAssign(self: *Checker, program: *ast.Program, ma: *ast.MemberAssign) CompileError!void {
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

    fn assignField(self: *Checker, program: *ast.Program, field_type: types.Type, ma: *ast.MemberAssign) CompileError!void {
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
                const narrow = narrowTarget(branch.cond);
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
                    if (findField(provided, expected_field.name)) |value_field| {
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
                const disc_field = findField(value.obj, uinfo.discriminant) orelse return self.fail(line, col, "E_TYPE_MISMATCH");
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

    fn exprType(self: *Checker, program: *ast.Program, e: *ast.Expr, line: u32, col: u32) ?types.Type {
        return switch (e.*) {
            .var_ref => |*ref| blk: {
                const found_binding = self.binding(ref.name) orelse {
                    // A top-level function name used as a value.
                    if (self.funcs.get(ref.name)) |finfo| {
                        ref.is_func_ref = true;
                        const t = self.funcSigType(finfo) catch return null;
                        ref.func_sig = t.func_type;
                        break :blk t;
                    }
                    _ = self.undefined_(ref.name, line, col) catch {};
                    return null;
                };
                ref.emit_name = found_binding.emit_name;
                ref.deref = found_binding.ref_scalar;
                // Inside an arrow body, a reference to a binding declared outside
                // the arrow is a capture (stored in the closure's heap env).
                if (self.current_captures) |caps| {
                    if (self.bindingDepth(ref.name)) |depth| {
                        if (depth < self.arrow_base) {
                            ref.capture = true;
                            var present = false;
                            for (caps.items) |c| {
                                if (std.mem.eql(u8, c.emit_name, found_binding.emit_name)) present = true;
                            }
                            if (!present) caps.append(self.arena, .{ .emit_name = found_binding.emit_name, .ty = found_binding.ty }) catch return null;
                        }
                    }
                }
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
            .await_expr => |inner| {
                // `await` is only valid inside an async function body or at the
                // top level of the program (not inside a non-async function).
                if (self.in_function and !self.in_async) {
                    _ = self.fail(line, col, "E_AWAIT_OUTSIDE_ASYNC") catch {};
                    return null;
                }
                const operand_type = self.exprType(program, inner, line, col) orelse return null;
                if (operand_type != .promise_type) {
                    _ = self.fail(line, col, "E_AWAIT_NOT_PROMISE") catch {};
                    return null;
                }
                program.needs_async = true;
                return operand_type.promise_type.*;
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
                // Check the body with outer scopes still visible; references to
                // bindings declared outside the arrow are recorded as captures.
                const saved_base = self.arrow_base;
                const saved_caps = self.current_captures;
                var caps: std.ArrayListUnmanaged(ast.Capture) = .empty;
                self.pushScope() catch return null;
                self.arrow_base = self.scopes.items.len - 1;
                self.current_captures = &caps;
                for (arrow.params) |p| {
                    self.currentScope().put(self.arena, p.name, .{ .ty = p.checked_type.?, .mutable = true, .emit_name = p.name }) catch return null;
                }
                // Arrow functions are not async in this subset, so `await` inside an
                // arrow body is rejected (it is not on an awaiting code path).
                const saved_in_async = self.in_async;
                const saved_in_function = self.in_function;
                self.in_async = false;
                self.in_function = true;
                const body_type = self.exprType(program, arrow.body_expr, line, col);
                self.in_async = saved_in_async;
                self.in_function = saved_in_function;
                self.popScope();
                self.arrow_base = saved_base;
                self.current_captures = saved_caps;
                arrow.captures = caps.toOwnedSlice(self.arena) catch return null;
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
            .array => |*arr| {
                const items = arr.items;
                if (items.len == 0) {
                    _ = self.fail(line, col, "cannot infer array type") catch {};
                    return null;
                }
                // The element type of each entry: a normal entry contributes its
                // own type; a `...src` spread contributes its source array's
                // element type. All entries must agree.
                var elem_type: ?types.Type = null;
                var has_spread = false;
                for (items) |item| {
                    var this_elem: types.Type = undefined;
                    if (item.* == .spread) {
                        has_spread = true;
                        const src_type = self.exprType(program, item.spread, line, col) orelse return null;
                        if (!types.isArray(src_type)) {
                            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                            return null;
                        }
                        this_elem = types.arrayElem(src_type) orelse {
                            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                            return null;
                        };
                    } else {
                        this_elem = self.exprType(program, item, line, col) orelse return null;
                    }
                    if (elem_type) |et| {
                        if (!types.same(et, this_elem)) {
                            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                            return null;
                        }
                    } else elem_type = this_elem;
                }
                const result = types.arrayOf(elem_type.?) orelse {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                };
                if (has_spread) arr.elem_type = elem_type;
                return result;
            },
            .tuple_lit => |t| t.tuple_type,
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
                    // `ClassName.staticField` — a static member read. Only when the
                    // name is a class and not shadowed by a local binding.
                    if (self.bindingPtr(field.obj.var_ref.name) == null) {
                        if (self.classes.get(field.obj.var_ref.name) != null) {
                            const cname = field.obj.var_ref.name;
                            const rf = self.resolveStaticField(cname, field.name) orelse {
                                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                                return null;
                            };
                            if (!self.visibilityOk(rf.field.visibility, rf.owner, line, col)) return null;
                            field.is_static = true;
                            field.class_name = rf.owner;
                            return rf.field.checked_type;
                        }
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
                    // `int` (i32) is the language's integer; typing length as i32
                    // lets the common `for`/`while (i < x.length)` index idiom and
                    // `charAt(i)`/`substring(...)` compose without an unusable i64.
                    return .i32;
                }
                if ((types.isMap(obj_type) or types.isSet(obj_type)) and std.mem.eql(u8, field.name, "size")) {
                    field.builtin = .container_size;
                    return .i32;
                }
                if (obj_type == .error_obj and std.mem.eql(u8, field.name, "message")) {
                    field.builtin = .error_message;
                    return .string;
                }
                if (obj_type == .regexp and (std.mem.eql(u8, field.name, "source") or std.mem.eql(u8, field.name, "flags"))) {
                    return .string;
                }
                return switch (obj_type) {
                    .named => |type_name| self.fieldType(type_name, field.name, line, col),
                    .union_type => |union_name| blk2: {
                        // If the union binding is narrowed to a variant, read that
                        // variant's fields; otherwise only the discriminant field.
                        if (field.obj.* == .var_ref) {
                            if (self.narrowedVariant(field.obj.var_ref.name)) |variant| {
                                break :blk2 self.fieldType(variant, field.name, line, col);
                            }
                        }
                        const uinfo = self.unions.get(union_name) orelse return null;
                        if (std.mem.eql(u8, field.name, uinfo.discriminant)) break :blk2 .string;
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    },
                    .class_type => |class_name| blk3: {
                        // Instance field read, walking the inheritance chain.
                        if (self.resolveField(class_name, field.name)) |rf| {
                            if (!self.visibilityOk(rf.field.visibility, rf.owner, line, col)) return null;
                            field.class_name = rf.owner;
                            break :blk3 rf.field.checked_type;
                        }
                        // Getter accessor read: `obj.prop`.
                        if (self.resolveAccessor(class_name, field.name, .getter)) |ra| {
                            if (!self.visibilityOk(ra.method.visibility, ra.owner, line, col)) return null;
                            field.is_getter = true;
                            field.class_name = class_name;
                            break :blk3 ra.method.checked_return_type orelse return null;
                        }
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    },
                    else => null,
                };
            },
            .this_expr => blk: {
                const cls = self.current_class orelse {
                    _ = self.fail(line, col, "E_RETURN_OUTSIDE_FUNCTION") catch {};
                    return null;
                };
                break :blk .{ .class_type = cls };
            },
            .new_expr => |*ne| {
                // Built-in container instantiation `new Map<K,V>()` / `new Set<T>()`.
                if (std.mem.eql(u8, ne.class_name, "Map") and self.classes.get("Map") == null) {
                    if (ne.type_args.len != 2) {
                        _ = self.fail(line, col, "E_TYPE_ARG_COUNT") catch {};
                        return null;
                    }
                    if (ne.args.len != 0) {
                        _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                        return null;
                    }
                    const k = self.arena.create(types.Type) catch return null;
                    const v = self.arena.create(types.Type) catch return null;
                    k.* = self.typeFromAnnotation(ne.type_args[0], line, col) catch return null;
                    v.* = self.typeFromAnnotation(ne.type_args[1], line, col) catch return null;
                    const m = self.arena.create(types.MapType) catch return null;
                    m.* = .{ .key = k, .value = v };
                    const ct = types.Type{ .map_type = m };
                    ne.container_type = ct;
                    program.needs_map = true;
                    return ct;
                }
                if (std.mem.eql(u8, ne.class_name, "Set") and self.classes.get("Set") == null) {
                    if (ne.type_args.len != 1) {
                        _ = self.fail(line, col, "E_TYPE_ARG_COUNT") catch {};
                        return null;
                    }
                    if (ne.args.len != 0) {
                        _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                        return null;
                    }
                    const set_elem = self.arena.create(types.Type) catch return null;
                    set_elem.* = self.typeFromAnnotation(ne.type_args[0], line, col) catch return null;
                    const ct = types.Type{ .set_type = set_elem };
                    ne.container_type = ct;
                    program.needs_set = true;
                    return ct;
                }
                // Generic class instantiation `new C<...>(...)`: specialize the
                // class and retarget `new` to the concrete mangled class.
                if (self.generic_classes.get(ne.class_name)) |gcls| {
                    const type_args = self.resolveExplicitTypeArgs(gcls.type_params, ne.type_args, line, col) catch return null;
                    const mname = self.specializeClass(gcls, type_args, line, col) catch return null;
                    ne.class_name = mname;
                    ne.type_args = &.{}; // retargeted to a concrete class; keep re-checks idempotent
                    // fall through to the concrete validation below
                } else if (ne.type_args.len > 0) {
                    // Type arguments on a non-generic class are an error.
                    _ = self.fail(line, col, "E_TYPE_ARG_COUNT") catch {};
                    return null;
                }
                const info = self.classes.get(ne.class_name) orelse {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                };
                // Resolve the effective constructor: the class's own, else the
                // nearest inherited one.
                var ctor_params: []ast.FunctionParam = info.ctor_params;
                var has_ctor = info.has_ctor;
                if (!has_ctor) {
                    var cur = info.parent;
                    while (cur) |pname| {
                        const pinfo = self.classes.get(pname) orelse break;
                        if (pinfo.has_ctor) {
                            ctor_params = pinfo.ctor_params;
                            has_ctor = true;
                            break;
                        }
                        cur = pinfo.parent;
                    }
                }
                if (has_ctor) {
                    if (ne.args.len != ctor_params.len) {
                        _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                        return null;
                    }
                    for (ne.args, ctor_params) |arg, p| {
                        const pt = p.checked_type orelse return null;
                        self.ensureAssignable(program, pt, arg, line, col) catch {
                            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                            return null;
                        };
                    }
                } else if (ne.args.len != 0) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                return .{ .class_type = ne.class_name };
            },
            .method_call => |*mc| {
                // `ClassName.staticMethod(args)` — static method call.
                if (mc.obj.* == .var_ref and self.bindingPtr(mc.obj.var_ref.name) == null and self.classes.get(mc.obj.var_ref.name) != null) {
                    const cname = mc.obj.var_ref.name;
                    const rm = self.resolveStaticMethod(cname, mc.name) orelse {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    };
                    if (!self.visibilityOk(rm.method.visibility, rm.owner, line, col)) return null;
                    if (mc.args.len != rm.method.params.len) {
                        _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                        return null;
                    }
                    for (mc.args, rm.method.params) |arg, p| {
                        self.ensureAssignable(program, p.checked_type orelse return null, arg, line, col) catch {
                            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                            return null;
                        };
                    }
                    mc.is_static = true;
                    mc.class_name = rm.owner;
                    return rm.method.checked_return_type orelse return null;
                }
                const obj_type = self.exprType(program, mc.obj, line, col) orelse return null;
                if (obj_type == .regexp) {
                    // `re.test(s)` -> bool. (Other regex methods arrive in later cycles.)
                    if (!std.mem.eql(u8, mc.name, "test")) {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                    if (mc.args.len != 1) {
                        _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                        return null;
                    }
                    self.ensureAssignable(program, .string, mc.args[0], line, col) catch {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    };
                    mc.container_type = .regexp; // sentinel for codegen
                    return .bool;
                }
                if (types.isArray(obj_type)) {
                    return self.arrayMethod(program, mc, obj_type, line, col);
                }
                if (types.isStringLike(obj_type)) {
                    return self.stringMethod(program, mc, line, col);
                }
                if (types.isMap(obj_type)) {
                    return self.mapMethod(program, mc, obj_type, line, col);
                }
                if (types.isSet(obj_type)) {
                    return self.setMethod(program, mc, obj_type, line, col);
                }
                if (obj_type != .class_type) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                const cls = obj_type.class_type;
                const rm = self.resolveMethod(cls, mc.name) orelse {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                };
                if (!self.visibilityOk(rm.method.visibility, rm.owner, line, col)) return null;
                if (mc.args.len != rm.method.params.len) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                for (mc.args, rm.method.params) |arg, p| {
                    self.ensureAssignable(program, p.checked_type orelse return null, arg, line, col) catch {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    };
                }
                // Methods are emitted on the most-derived struct (flattened), so
                // the call dispatches on the static receiver class.
                mc.class_name = cls;
                return rm.method.checked_return_type orelse return null;
            },
            .super_call => |*sc| {
                const cls = self.current_class orelse {
                    _ = self.fail(line, col, "E_RETURN_OUTSIDE_FUNCTION") catch {};
                    return null;
                };
                const parent = (self.classes.get(cls) orelse return null).parent orelse {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                };
                const rm = self.resolveMethod(parent, sc.name) orelse {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                };
                if (sc.args.len != rm.method.params.len) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                for (sc.args, rm.method.params) |arg, p| {
                    self.ensureAssignable(program, p.checked_type orelse return null, arg, line, col) catch {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    };
                }
                sc.parent = rm.owner;
                return rm.method.checked_return_type orelse return null;
            },
            .index => |*index| {
                const obj_type = self.exprType(program, index.obj, line, col) orelse return null;
                // Tuple indexed access: requires an integer-literal index in range.
                if (obj_type == .tuple_type) {
                    const elems = obj_type.tuple_type;
                    if (index.value.* != .num or index.value.num < 0 or index.value.num >= @as(i64, @intCast(elems.len))) {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                    const pos: usize = @intCast(index.value.num);
                    index.tuple_index = pos;
                    index.checked_element_type = elems[pos];
                    return elems[pos];
                }
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
                // Matcher form `expect(actual).toBe(expected)` / `.toEqual(...)`:
                // both operands must share a type; lowers to std.testing.expectEqual.
                if (std.mem.eql(u8, call.name, "__expectToBe") or std.mem.eql(u8, call.name, "__expectToEqual")) {
                    if (self.test_depth == 0) {
                        _ = self.fail(line, col, "expect is only allowed inside a test block") catch {};
                        return null;
                    }
                    if (call.args.len != 2) {
                        _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                        return null;
                    }
                    const actual_type = self.exprType(program, call.args[0], line, col) orelse return null;
                    const expected_type = self.exprType(program, call.args[1], line, col) orelse return null;
                    if (!types.same(actual_type, expected_type)) {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                    // Strings compare by bytes, not slice identity, so route the
                    // string case to a distinct lowering.
                    if (types.same(.string, actual_type)) {
                        call.name = "__expectStrEqual";
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
                if (std.mem.eql(u8, call.name, "setTimeout")) {
                    if (call.args.len != 2) {
                        _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                        return null;
                    }
                    // First arg: a `() => void` callback function value.
                    const cb_type = self.exprType(program, call.args[0], line, col) orelse return null;
                    const cb_ok = cb_type == .func_type and cb_type.func_type.params.len == 0 and cb_type.func_type.ret.* == .void;
                    if (!cb_ok) {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                    // Second arg: an integer millisecond delay.
                    const ms_type = self.exprType(program, call.args[1], line, col) orelse return null;
                    if (!types.isInteger(ms_type)) {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                    program.uses_io = true;
                    program.needs_async = true;
                    return .void;
                }
                // A call to a generic function: resolve type arguments
                // (explicit or inferred), specialize, and retarget the call.
                if (self.generic_funcs.get(call.name)) |gdecl| {
                    const type_args = if (call.type_args.len > 0)
                        (self.resolveExplicitTypeArgs(gdecl.type_params, call.type_args, line, col) catch return null)
                    else
                        (self.inferTypeArgs(program, gdecl.type_params, gdecl.params, call.args, line, col) catch return null);
                    const spec = self.specializeFunction(gdecl, type_args, line, col) catch return null;
                    const info = self.funcs.get(spec.name) orelse return null;
                    if (call.args.len != info.params.len) {
                        _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                        return null;
                    }
                    for (call.args, info.params) |arg, param| {
                        const pt = param.checked_type orelse return null;
                        self.ensureAssignable(program, pt, arg, line, col) catch {
                            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                            return null;
                        };
                    }
                    call.emit_name = spec.name;
                    return spec.ret;
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
                            call.is_closure = true;
                            return sig.ret.*;
                        }
                    }
                    _ = self.fail(line, col, "unknown function") catch {};
                    return null;
                };
                // A by-reference (`Ref<T>`) parameter requires an addressable
                // lvalue argument; mark each so the emitter inserts `&arg`.
                var any_ref = false;
                for (func.params) |p| {
                    if (p.is_ref) any_ref = true;
                }
                if (any_ref) {
                    const flags = self.arena.alloc(bool, func.params.len) catch return null;
                    for (func.params, 0..) |p, i| {
                        flags[i] = p.is_ref;
                        if (p.is_ref) {
                            if (i >= call.args.len or !isAddressable(call.args[i]) or !self.refRootMutable(call.args[i])) {
                                _ = self.fail(line, col, "E_REF_ARG") catch {};
                                return null;
                            }
                            // Taking the address of a local requires a mutable
                            // (`var`) binding; force one for the root variable.
                            self.markReassignedRoot(call.args[i]);
                        }
                    }
                    call.ref_args = flags;
                }
                call.args = self.checkCallArgs(program, func.params, call.args, line, col) orelse return null;
                if (func.is_extern) {
                    // Mark string params/return so the emitter inserts the FFI
                    // marshalling glue (NUL-terminate in, copy out).
                    const flags = self.arena.alloc(bool, func.params.len) catch return null;
                    var any_string = func.return_type == .string;
                    for (func.params, 0..) |p, i| {
                        flags[i] = (p.checked_type orelse types.Type.void) == .string;
                        if (flags[i]) any_string = true;
                    }
                    call.ffi_string_args = flags;
                    call.ffi_string_return = func.return_type == .string;
                    // The marshalling glue uses the shared `__alloc`, which is
                    // only emitted when the program uses I/O plumbing.
                    if (any_string) program.uses_io = true;
                }
                return func.return_type;
            },
            .static_call => |*call| {
                return self.staticCallType(program, call, line, col);
            },
            .cast => |*c| {
                const target = self.typeFromAnnotation(c.annotation, line, col) catch return null;
                const source = self.exprType(program, c.inner, line, col) orelse return null;
                if (!self.castAllowed(source, target)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                c.checked_type = target;
                return target;
            },
            else => types.inferExprType(e),
        };
    }

    /// Whether `expr as T` is in the safe, representation-preserving subset: the
    /// assertion is erased to the operand, so source and target must share the
    /// same emitted layout. This covers identity, alias <-> underlying type, and
    /// literal-union widening (`"a" | "b"` -> string, `1 | 2` -> int).
    fn castAllowed(self: *Checker, source: types.Type, target: types.Type) bool {
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
        if (std.mem.eql(u8, call.namespace, "Promise")) return self.promiseCallType(program, call, line, col);
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
        _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
        return null;
    }

    fn promiseCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
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

/// Types allowed in extern function signatures: C-ABI scalars plus `string`,
/// which is marshalled to/from a NUL-terminated C `const char*` at the call
/// boundary. Arrays, records, and function types remain rejected (E_FFI_TYPE).
/// If `annotation` is the by-reference marker `Ref<T>`, returns the inner `T`
/// annotation (trimmed); otherwise null. `Ref` is reserved as a built-in marker,
/// so it is matched here before the generics machinery resolves type references.
fn refInner(annotation: []const u8) ?[]const u8 {
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
fn isAddressable(e: *const ast.Expr) bool {
    return switch (e.*) {
        .var_ref => true,
        .field => |f| f.enum_value == null and f.builtin == null and !f.is_static and !f.optional_chain and isAddressable(f.obj),
        else => false,
    };
}

fn isCSafe(t: types.Type) bool {
    return switch (t) {
        .i32, .i64, .f64, .bool, .string => true,
        else => false,
    };
}

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
