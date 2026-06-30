//! Class codegen: lowers a `ClassDecl` to a Zig struct with fields, a `new`
//! constructor, and methods. Handles single inheritance by flattening the
//! `extends` chain (`collectChain`): parent fields/methods are copied down
//! (Zig has no struct inheritance), and `super.m(...)` calls
//! (`collectSuperInStmt`/`collectSuperInExpr`) are rewritten to call the
//! parent's emitted method directly.
//!
//! Pulled out of `lumen_emit.zig` as the "declaring a class" concern,
//! separate from statement/expression emission (which this calls into for
//! method/constructor bodies) and array/string method codegen.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const diag_mod = @import("lumen_diag.zig");
const emit_mod = @import("lumen_emit.zig");
const analysis = @import("lumen_emit_analysis.zig");

const CompileError = diag_mod.CompileError;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const CompileOptions = emit_mod.CompileOptions;
const emitStmtWithThrow = emit_mod.emitStmtWithThrow;
const emitExpr = emit_mod.emitExpr;
const bodyUsesThis = analysis.bodyUsesThis;
const emitUnusedParamDiscards = analysis.emitUnusedParamDiscards;
const zigZeroValue = analysis.zigZeroValue;

pub fn collectChain(c: *const ast.ClassDecl, arena: std.mem.Allocator) CompileError![]*const ast.ClassDecl {
    var list: std.ArrayListUnmanaged(*const ast.ClassDecl) = .empty;
    var cur: ?*const ast.ClassDecl = c;
    while (cur) |cc| {
        try list.append(arena, cc);
        cur = if (cc.parent) |p| emit_mod.findClass(p) else null;
    }
    // Reverse to root-first order.
    const items = list.items;
    var i: usize = 0;
    while (i < items.len / 2) : (i += 1) {
        const t = items[i];
        items[i] = items[items.len - 1 - i];
        items[items.len - 1 - i] = t;
    }
    return items;
}

/// A zero/default initializer literal for a static field of the given type.
pub fn zeroValue(ty: types.Type) []const u8 {
    return switch (ty) {
        .i32, .i64 => "0",
        .f64 => "0",
        .bool => "false",
        .string => "\"\"",
        else => "undefined",
    };
}

/// Lower a class to a Zig struct: ancestor fields are flattened in, instance
/// methods (own + inherited, with overrides) are emitted bound to the struct,
/// `super.method` copies are emitted under internal names, statics become struct
/// globals/free functions, and getters/setters become `__get_`/`__set_` methods.
pub fn emitClass(c: *const ast.ClassDecl, decls: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, throw_target: ?[]const u8, switch_break_target: ?[]const u8, options: CompileOptions) CompileError!void {
    const chain = try collectChain(c, arena);

    try decls.print(arena, "const {s} = struct {{\n", .{c.name});

    // Instance fields, ancestors first (flattened layout).
    for (chain) |cc| {
        for (cc.fields) |field| {
            if (field.is_static) continue;
            try decls.print(arena, "    {s}: {s},\n", .{ field.name, try types.zigName(arena, field.checked_type orelse return error.ParseError) });
        }
    }

    // Static fields -> struct-scoped vars with a zero default. Declared only on
    // the owning class so the whole hierarchy shares one storage location,
    // accessed as `Owner.__static_Owner_field`.
    for (c.fields) |field| {
        if (!field.is_static) continue;
        const ty = field.checked_type orelse return error.ParseError;
        try decls.print(arena, "    var __static_{s}_{s}: {s} = {s};\n", .{ c.name, field.name, try types.zigName(arena, ty), zeroValue(ty) });
    }

    // Constructor: resolve the nearest ctor among the chain that the most
    // derived class provides; if the class has none, inherit the parent's.
    try decls.print(arena, "    fn __init(", .{});
    var ctor_owner: *const ast.ClassDecl = c;
    if (!c.has_ctor) {
        var k: usize = chain.len;
        while (k > 0) {
            k -= 1;
            if (chain[k].has_ctor) {
                ctor_owner = chain[k];
                break;
            }
        }
    }
    for (ctor_owner.ctor_params, 0..) |param, i| {
        if (i > 0) try decls.appendSlice(arena, ", ");
        try decls.print(arena, "{s}: {s}", .{ param.name, try types.zigName(arena, param.checked_type orelse return error.ParseError) });
    }
    try decls.print(arena, ") *{s} {{\n", .{c.name});
    try decls.print(arena, "    const self = __sa().create({s}) catch unreachable;\n", .{c.name});
    try emitUnusedParamDiscards(ctor_owner.ctor_params, ctor_owner.ctor_body, decls, arena);
    for (ctor_owner.ctor_body) |*body_stmt| try emitStmtWithThrow(body_stmt, decls, decls, arena, throw_target, switch_break_target, options);
    try decls.appendSlice(arena, "    return self;\n    }\n");

    // Instance methods, getters, setters: most-derived definition wins. Walk the
    // chain root-first; a later (more derived) definition overwrites an earlier
    // one by emitting under the same name, so emit only the resolved definition.
    var emitted: std.StringHashMapUnmanaged(void) = .empty;
    var d: usize = chain.len;
    while (d > 0) {
        d -= 1;
        const cc = chain[d];
        for (cc.methods) |m| {
            if (m.is_static) continue;
            const key = switch (m.accessor) {
                .none => try std.fmt.allocPrint(arena, "m:{s}", .{m.name}),
                .getter => try std.fmt.allocPrint(arena, "g:{s}", .{m.name}),
                .setter => try std.fmt.allocPrint(arena, "s:{s}", .{m.name}),
            };
            if (emitted.contains(key)) continue;
            try emitted.put(arena, key, {});
            try emitClassMethod(c.name, m, decls, arena, throw_target, switch_break_target, options);
        }
    }

    // `super.method` copies: for each super call in the class's methods/ctor,
    // emit a copy of the resolved ancestor method as `__super_<owner>_<name>`.
    var super_emitted: std.StringHashMapUnmanaged(void) = .empty;
    for (c.methods) |m| try emitSuperCopies(c, m.body, decls, arena, &super_emitted, throw_target, switch_break_target, options);
    try emitSuperCopies(c, c.ctor_body, decls, arena, &super_emitted, throw_target, switch_break_target, options);

    // `super(...)` parent-constructor helpers: emit `__superctor_<owner>` for
    // each ancestor that has a constructor, bound to the most-derived struct so
    // its parameters live in their own scope (no shadowing of the child ctor).
    for (chain) |cc| {
        if (std.mem.eql(u8, cc.name, c.name)) continue; // not the class itself
        if (!cc.has_ctor) continue;
        try decls.print(arena, "    fn __superctor_{s}(self: *{s}", .{ cc.name, c.name });
        for (cc.ctor_params) |param| {
            try decls.print(arena, ", {s}: {s}", .{ param.name, try types.zigName(arena, param.checked_type orelse return error.ParseError) });
        }
        try decls.appendSlice(arena, ") void {\n");
        if (!bodyUsesThis(cc.ctor_body)) try decls.appendSlice(arena, "    _ = self;\n");
        try emitUnusedParamDiscards(cc.ctor_params, cc.ctor_body, decls, arena);
        for (cc.ctor_body) |*body_stmt| try emitStmtWithThrow(body_stmt, decls, decls, arena, throw_target, switch_break_target, options);
        try decls.appendSlice(arena, "    }\n");
    }

    // Static methods -> struct-scoped free functions `__static_m_<name>`,
    // declared only on their owning class and called as `Owner.__static_m_x`.
    {
        const cc = c;
        for (cc.methods) |m| {
            if (!m.is_static) continue;
            try decls.print(arena, "    fn __static_m_{s}(", .{m.name});
            for (m.params, 0..) |param, i| {
                if (i > 0) try decls.appendSlice(arena, ", ");
                try decls.print(arena, "{s}: {s}", .{ param.name, try types.zigName(arena, param.checked_type orelse return error.ParseError) });
            }
            try decls.print(arena, ") {s} {{\n", .{try types.zigName(arena, m.checked_return_type orelse return error.ParseError)});
            try emitUnusedParamDiscards(m.params, m.body, decls, arena);
            for (m.body) |*body_stmt| try emitStmtWithThrow(body_stmt, decls, decls, arena, throw_target, switch_break_target, options);
            try decls.appendSlice(arena, "    }\n");
        }
    }

    try decls.appendSlice(arena, "};\n");
}

pub fn emitClassMethod(self_type: []const u8, m: ast.FunctionDecl, decls: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, throw_target: ?[]const u8, switch_break_target: ?[]const u8, options: CompileOptions) CompileError!void {
    const fn_name = switch (m.accessor) {
        .none => m.name,
        .getter => try std.fmt.allocPrint(arena, "__get_{s}", .{m.name}),
        .setter => try std.fmt.allocPrint(arena, "__set_{s}", .{m.name}),
    };
    try decls.print(arena, "    fn {s}(self: *{s}", .{ fn_name, self_type });
    for (m.params) |param| {
        const pt = param.checked_type orelse return error.ParseError;
        const ztype = if (param.is_ref) try types.refZigName(arena, pt) else try types.zigName(arena, pt);
        try decls.print(arena, ", {s}: {s}", .{ param.name, ztype });
    }
    try decls.print(arena, ") {s} {{\n", .{try types.zigName(arena, m.checked_return_type orelse return error.ParseError)});
    if (!bodyUsesThis(m.body)) try decls.appendSlice(arena, "    _ = self;\n");
    try emitUnusedParamDiscards(m.params, m.body, decls, arena);
    for (m.body) |*body_stmt| try emitStmtWithThrow(body_stmt, decls, decls, arena, throw_target, switch_break_target, options);
    try decls.appendSlice(arena, "    }\n");
}

/// Emit `__super_<owner>_<name>` method copies for every `super.method` call
/// referenced inside `body`, bound to the most-derived struct `c`.
pub fn emitSuperCopies(c: *const ast.ClassDecl, body: []const Stmt, decls: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, seen: *std.StringHashMapUnmanaged(void), throw_target: ?[]const u8, switch_break_target: ?[]const u8, options: CompileOptions) CompileError!void {
    for (body) |*stmt| try collectSuperInStmt(c, stmt, decls, arena, seen, throw_target, switch_break_target, options);
}

pub fn collectSuperInStmt(c: *const ast.ClassDecl, stmt: *const Stmt, decls: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, seen: *std.StringHashMapUnmanaged(void), throw_target: ?[]const u8, switch_break_target: ?[]const u8, options: CompileOptions) CompileError!void {
    switch (stmt.*) {
        .expr_stmt => |x| try collectSuperInExpr(c, x.value, decls, arena, seen, throw_target, switch_break_target, options),
        .return_stmt => |r| if (r.value) |v| try collectSuperInExpr(c, v, decls, arena, seen, throw_target, switch_break_target, options),
        .var_decl => |v| try collectSuperInExpr(c, v.init, decls, arena, seen, throw_target, switch_break_target, options),
        .member_assign => |ma| try collectSuperInExpr(c, ma.value, decls, arena, seen, throw_target, switch_break_target, options),
        .console_log => |log| try collectSuperInExpr(c, log.value, decls, arena, seen, throw_target, switch_break_target, options),
        .if_stmt => |b| {
            try collectSuperInExpr(c, b.cond, decls, arena, seen, throw_target, switch_break_target, options);
            try emitSuperCopies(c, b.then_body, decls, arena, seen, throw_target, switch_break_target, options);
            if (b.else_body) |eb| try emitSuperCopies(c, eb, decls, arena, seen, throw_target, switch_break_target, options);
        },
        .while_stmt => |w| try emitSuperCopies(c, w.body, decls, arena, seen, throw_target, switch_break_target, options),
        .for_stmt => |f| try emitSuperCopies(c, f.body, decls, arena, seen, throw_target, switch_break_target, options),
        .for_of_stmt => |f| try emitSuperCopies(c, f.body, decls, arena, seen, throw_target, switch_break_target, options),
        else => {},
    }
}

pub fn collectSuperInExpr(c: *const ast.ClassDecl, e: *const Expr, decls: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, seen: *std.StringHashMapUnmanaged(void), throw_target: ?[]const u8, switch_break_target: ?[]const u8, options: CompileOptions) CompileError!void {
    switch (e.*) {
        .super_call => |sc| {
            const owner = sc.parent orelse return;
            const key = try std.fmt.allocPrint(arena, "{s}:{s}", .{ owner, sc.name });
            for (sc.args) |a| try collectSuperInExpr(c, a, decls, arena, seen, throw_target, switch_break_target, options);
            if (seen.contains(key)) return;
            try seen.put(arena, key, {});
            // Find the resolved ancestor method and emit a copy bound to `c`.
            const oc = emit_mod.findClass(owner) orelse return;
            for (oc.methods) |m| {
                if (m.accessor == .none and !m.is_static and std.mem.eql(u8, m.name, sc.name)) {
                    var copy = m;
                    copy.name = try std.fmt.allocPrint(arena, "__super_{s}_{s}", .{ owner, sc.name });
                    try emitClassMethod(c.name, copy, decls, arena, throw_target, switch_break_target, options);
                    return;
                }
            }
        },
        .bin => |b| {
            try collectSuperInExpr(c, b.l, decls, arena, seen, throw_target, switch_break_target, options);
            try collectSuperInExpr(c, b.r, decls, arena, seen, throw_target, switch_break_target, options);
        },
        .method_call => |mc| {
            try collectSuperInExpr(c, mc.obj, decls, arena, seen, throw_target, switch_break_target, options);
            for (mc.args) |a| try collectSuperInExpr(c, a, decls, arena, seen, throw_target, switch_break_target, options);
        },
        .call => |cl| for (cl.args) |a| try collectSuperInExpr(c, a, decls, arena, seen, throw_target, switch_break_target, options),
        .field => |f| try collectSuperInExpr(c, f.obj, decls, arena, seen, throw_target, switch_break_target, options),
        else => {},
    }
}
