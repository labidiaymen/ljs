//! Optimization passes over the AST -- the "allocate less" passes.
//!
//! These run after type checking, feeding the codegen in `lumen_compiler.zig`.
//! They never change what a program computes; they rewrite/tag the AST so the
//! codegen can emit Zig that avoids arena allocations in common patterns:
//!   * string-builder accumulators: a `let s = ""` that is only ever extended via
//!     `s = s + ...` becomes a reused `ArrayList` buffer instead of reallocating on
//!     every `+`;
//!   * destination-passing: a function that builds and returns a string is handed a
//!     hidden output buffer so it writes straight into the caller's storage;
//!   * concat flattening: `a + b + c + ...` is collected into a single
//!     `std.mem.concat(&.{...})` rather than nested two-operand concatenations.
//!
//! Every rewrite is guarded by conservative checks (the `acc*` / `*Disq*` helpers)
//! that bail out unless the rewrite is provably safe -- so correctness never
//! depends on a pass firing, only speed does. The codegen reads the flags these
//! passes set (e.g. `is_accumulator` on a declaration / var-ref).
//!
//! Public entry points the codegen calls: `markAccumulators`,
//! `collectDestPassable`, `markBuilderParts`, `collectStrConcat`.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const diag_mod = @import("lumen_diag.zig");

const CompileError = diag_mod.CompileError;
const Expr = ast.Expr;
const Stmt = ast.Stmt;

/// Flattens a left-associated string-concat chain (`a + b + c + …`) into its leaf
/// parts so it can be emitted as a single `std.mem.concat(&.{…})` instead of
/// nested concats — one allocation and one copy of each part, rather than
/// reallocating and recopying the growing left operand at every `+`.
pub fn collectStrConcat(e: *const Expr, parts: *std.ArrayListUnmanaged(*const Expr), arena: std.mem.Allocator) CompileError!void {
    switch (e.*) {
        .bin => |b| {
            if (b.op == '+' and b.checked_type != null and b.checked_type.? == .string) {
                try collectStrConcat(b.l, parts, arena);
                try collectStrConcat(b.r, parts, arena);
                return;
            }
        },
        else => {},
    }
    try parts.append(arena, e);
}

// ---- destination-passing for string-builder functions ------------------------
fn collectReturns(body: []const Stmt, list: *std.ArrayListUnmanaged(*const Expr), arena: std.mem.Allocator) CompileError!void {
    for (body) |*s| try collectReturnsStmt(s, list, arena);
}
fn collectReturnsStmt(s: *const Stmt, list: *std.ArrayListUnmanaged(*const Expr), arena: std.mem.Allocator) CompileError!void {
    switch (s.*) {
        .return_stmt => |r| {
            if (r.value) |v| try list.append(arena, v);
        },
        .while_stmt => |w| try collectReturns(w.body, list, arena),
        .do_while_stmt => |w| try collectReturns(w.body, list, arena),
        .for_stmt => |f| try collectReturns(f.body, list, arena),
        .for_of_stmt => |f| try collectReturns(f.body, list, arena),
        .if_stmt => |b| {
            try collectReturns(b.then_body, list, arena);
            if (b.else_body) |eb| try collectReturns(eb, list, arena);
        },
        .switch_stmt => |sw| {
            for (sw.cases) |cse| try collectReturns(cse.body, list, arena);
            if (sw.default_body) |db| try collectReturns(db, list, arena);
        },
        .try_stmt => |t| {
            try collectReturns(t.try_body, list, arena);
            try collectReturns(t.catch_body, list, arena);
            if (t.finally_body) |fb| try collectReturns(fb, list, arena);
        },
        .defer_stmt => |d| try collectReturns(d.body, list, arena),
        else => {},
    }
}

/// The accumulator a string-builder function returns (so it can be retargeted to
/// a caller buffer), or null. Eligible when it returns `string` and every return
/// is `return <acc>` (one accumulator) or `return E` with E not using that acc.
fn destPassableAcc(fd: *const ast.FunctionDecl, arena: std.mem.Allocator) CompileError!?[]const u8 {
    const ret = fd.checked_return_type orelse return null;
    if (ret != .string) return null;
    if (fd.is_async) return null;
    var rets: std.ArrayListUnmanaged(*const Expr) = .empty;
    try collectReturns(fd.body, &rets, arena);
    var acc_name: ?[]const u8 = null; // source name (for analysis)
    var acc_emit: ?[]const u8 = null; // emit name (for codegen)
    for (rets.items) |v| {
        if (v.* == .var_ref and v.var_ref.is_accumulator) {
            if (acc_name) |a| {
                if (!std.mem.eql(u8, a, v.var_ref.name)) return null;
            } else {
                acc_name = v.var_ref.name;
                acc_emit = v.var_ref.emit_name orelse v.var_ref.name;
            }
        }
    }
    const an = acc_name orelse return null;
    for (rets.items) |v| {
        const is_acc = v.* == .var_ref and v.var_ref.is_accumulator and std.mem.eql(u8, v.var_ref.name, an);
        if (!is_acc and exprUsesName(v, an)) return null;
    }
    return acc_emit;
}

pub fn collectDestPassable(stmts: []Stmt, map: *std.StringHashMapUnmanaged([]const u8), arena: std.mem.Allocator) CompileError!void {
    for (stmts) |*s| switch (s.*) {
        .function_decl => |*fd| {
            if (try destPassableAcc(fd, arena)) |acc| try map.put(arena, fd.name, acc);
            try collectDestPassable(fd.body, map, arena);
        },
        .class_decl => |*cd| for (cd.methods) |*m| {
            if (try destPassableAcc(m, arena)) |acc| try map.put(arena, m.name, acc);
            try collectDestPassable(m.body, map, arena);
        },
        .while_stmt => |*w| try collectDestPassable(w.body, map, arena),
        .do_while_stmt => |*w| try collectDestPassable(w.body, map, arena),
        .for_stmt => |*f| try collectDestPassable(f.body, map, arena),
        .for_of_stmt => |*f| try collectDestPassable(f.body, map, arena),
        .if_stmt => |*b| {
            try collectDestPassable(b.then_body, map, arena);
            if (b.else_body) |eb| try collectDestPassable(eb, map, arena);
        },
        else => {},
    };
}

fn collectStrConcatMut(e: *Expr, parts: *std.ArrayListUnmanaged(*Expr), arena: std.mem.Allocator) CompileError!void {
    switch (e.*) {
        .bin => |b| if (b.op == '+' and b.checked_type != null and b.checked_type.? == .string) {
            try collectStrConcatMut(b.l, parts, arena);
            try collectStrConcatMut(b.r, parts, arena);
            return;
        },
        else => {},
    }
    try parts.append(arena, e);
}

pub fn markBuilderParts(stmts: []Stmt, map: *const std.StringHashMapUnmanaged([]const u8), arena: std.mem.Allocator) CompileError!void {
    for (stmts) |*s| try markBuilderPartsStmt(s, map, arena);
}
fn markBuilderPartsStmt(s: *Stmt, map: *const std.StringHashMapUnmanaged([]const u8), arena: std.mem.Allocator) CompileError!void {
    switch (s.*) {
        .assign => |*a| if (a.is_accumulator) {
            var parts: std.ArrayListUnmanaged(*Expr) = .empty;
            try collectStrConcatMut(a.value, &parts, arena);
            for (parts.items) |p| if (p.* == .call and !p.call.is_closure and map.contains(p.call.name)) {
                p.call.is_into_call = true;
            };
        },
        .while_stmt => |*w| try markBuilderParts(w.body, map, arena),
        .do_while_stmt => |*w| try markBuilderParts(w.body, map, arena),
        .for_stmt => |*f| try markBuilderParts(f.body, map, arena),
        .for_of_stmt => |*f| try markBuilderParts(f.body, map, arena),
        .if_stmt => |*b| {
            try markBuilderParts(b.then_body, map, arena);
            if (b.else_body) |eb| try markBuilderParts(eb, map, arena);
        },
        .switch_stmt => |*sw| {
            for (sw.cases) |*cse| try markBuilderParts(cse.body, map, arena);
            if (sw.default_body) |db| try markBuilderParts(db, map, arena);
        },
        .try_stmt => |*t| {
            try markBuilderParts(t.try_body, map, arena);
            try markBuilderParts(t.catch_body, map, arena);
            if (t.finally_body) |fb| try markBuilderParts(fb, map, arena);
        },
        .defer_stmt => |*d| try markBuilderParts(d.body, map, arena),
        .function_decl => |*fd| try markBuilderParts(fd.body, map, arena),
        .class_decl => |*cd| for (cd.methods) |*m| try markBuilderParts(m.body, map, arena),
        else => {},
    }
}

// ---- string-builder (accumulator) optimization -------------------------------
// A string local that is only ever appended to (`v = v + …`) is compiled to a
// growable `ArrayListUnmanaged(u8)` instead of an immutable slice, so the build
// is O(n) (append) rather than O(n²) (realloc+recopy on every `+`). The analysis
// is conservative: a variable qualifies only when EVERY use is a provable append
// or a plain read; anything unusual (reset, `+=`, capture, Ref, shadowing) bails.

fn accIsEmptyStr(e: *const Expr) bool {
    return e.* == .str and e.str.len == 0;
}

/// `value` is an append into `name`: a string-concat chain whose first leaf reads
/// `name` and where `name` appears nowhere else (so the source slices stay valid
/// across the in-place append).
fn accIsAppend(value: *const Expr, name: []const u8, arena: std.mem.Allocator) CompileError!bool {
    var parts: std.ArrayListUnmanaged(*const Expr) = .empty;
    try collectStrConcat(value, &parts, arena);
    if (parts.items.len == 0) return false;
    const first = parts.items[0];
    if (!(first.* == .var_ref and std.mem.eql(u8, first.var_ref.name, name))) return false;
    for (parts.items[1..]) |p| if (exprUsesName(p, name)) return false;
    return true;
}

/// True if any read of `name` in `e` is a closure capture or a `Ref` deref.
fn accBadRef(e: *const Expr, name: []const u8) bool {
    return switch (e.*) {
        .var_ref => |r| std.mem.eql(u8, r.name, name) and (r.capture or r.deref),
        .array => |a| blk: {
            for (a.items) |it| if (accBadRef(it, name)) break :blk true;
            break :blk false;
        },
        .tuple_lit => |t| blk: {
            for (t.items) |it| if (accBadRef(it, name)) break :blk true;
            break :blk false;
        },
        .spread => |inner| accBadRef(inner, name),
        .neg, .not, .bnot, .await_expr => |inner| accBadRef(inner, name),
        .bin => |b| accBadRef(b.l, name) or accBadRef(b.r, name),
        .bool_bin => |b| accBadRef(b.l, name) or accBadRef(b.r, name),
        .cmp => |b| accBadRef(b.l, name) or accBadRef(b.r, name),
        .ternary => |t| accBadRef(t.cond, name) or accBadRef(t.then_expr, name) or accBadRef(t.else_expr, name),
        .coalesce => |c| accBadRef(c.l, name) or accBadRef(c.r, name),
        .arrow => |a| accBadRef(a.body_expr, name),
        .new_expr => |ne| blk: {
            for (ne.args) |it| if (accBadRef(it, name)) break :blk true;
            break :blk false;
        },
        .method_call => |mc| blk: {
            if (accBadRef(mc.obj, name)) break :blk true;
            for (mc.args) |it| if (accBadRef(it, name)) break :blk true;
            break :blk false;
        },
        .super_call => |sc| blk: {
            for (sc.args) |it| if (accBadRef(it, name)) break :blk true;
            break :blk false;
        },
        .template => |parts| blk: {
            for (parts) |pt| if (pt.expr) |x| {
                if (accBadRef(x, name)) break :blk true;
            };
            break :blk false;
        },
        .obj => |fields| blk: {
            for (fields) |f| if (accBadRef(f.value, name)) break :blk true;
            break :blk false;
        },
        .field => |f| accBadRef(f.obj, name),
        .index => |idx| accBadRef(idx.obj, name) or accBadRef(idx.value, name),
        .call => |cl| blk: {
            for (cl.args) |it| if (accBadRef(it, name)) break :blk true;
            break :blk false;
        },
        .static_call => |sc| blk: {
            for (sc.args) |it| if (accBadRef(it, name)) break :blk true;
            break :blk false;
        },
        .cast => |c| accBadRef(c.inner, name),
        else => false,
    };
}

fn accDisqBody(body: []const Stmt, name: []const u8, arena: std.mem.Allocator) CompileError!bool {
    for (body) |*s| if (try accDisqStmt(s, name, arena)) return true;
    return false;
}

/// Disqualify `name` from the accumulator transform if it is mutated by anything
/// other than an append, captured, deref'd, or rebound.
fn accDisqStmt(stmt: *const Stmt, name: []const u8, arena: std.mem.Allocator) CompileError!bool {
    switch (stmt.*) {
        .var_decl => |d| return accBadRef(d.init, name),
        .assign => |a| {
            if (std.mem.eql(u8, a.name, name)) {
                if (!std.mem.eql(u8, a.op, "=")) return true;
                return !(try accIsAppend(a.value, name, arena));
            }
            return accBadRef(a.value, name);
        },
        .member_assign => |ma| return accBadRef(ma.value, name) or (ma.obj != null and accBadRef(ma.obj.?, name)),
        .console_log => |log| return accBadRef(log.value, name),
        .return_stmt => |r| return if (r.value) |x| accBadRef(x, name) else false,
        .throw_stmt => |t| return accBadRef(t.value, name),
        .expr_stmt => |x| return accBadRef(x.value, name),
        .while_stmt => |w| return accBadRef(w.cond, name) or (try accDisqBody(w.body, name, arena)),
        .do_while_stmt => |w| return accBadRef(w.cond, name) or (try accDisqBody(w.body, name, arena)),
        .for_stmt => |f| {
            if (std.mem.eql(u8, f.update.name, name)) return true;
            return accBadRef(f.init.init, name) or accBadRef(f.cond, name) or accBadRef(f.update.value, name) or (try accDisqBody(f.body, name, arena));
        },
        .for_of_stmt => |f| {
            if (std.mem.eql(u8, f.binding, name)) return true;
            return accBadRef(f.iterable, name) or (try accDisqBody(f.body, name, arena));
        },
        .if_stmt => |b| return accBadRef(b.cond, name) or (try accDisqBody(b.then_body, name, arena)) or (b.else_body != null and (try accDisqBody(b.else_body.?, name, arena))),
        .switch_stmt => |sw| {
            if (accBadRef(sw.value, name)) return true;
            for (sw.cases) |cse| {
                if (accBadRef(cse.value, name)) return true;
                if (try accDisqBody(cse.body, name, arena)) return true;
            }
            if (sw.default_body) |db| if (try accDisqBody(db, name, arena)) return true;
            return false;
        },
        .try_stmt => |t| return (try accDisqBody(t.try_body, name, arena)) or (try accDisqBody(t.catch_body, name, arena)) or (t.finally_body != null and (try accDisqBody(t.finally_body.?, name, arena))),
        .defer_stmt => |d| return accDisqBody(d.body, name, arena),
        .destructure_decl => |d| {
            for (d.bindings) |b| if (std.mem.eql(u8, b.name, name)) return true;
            return accBadRef(d.source, name);
        },
        .using_decl => |u| {
            if (u.defer_body) |b| if (try accDisqBody(b, name, arena)) return true;
            if (u.dispose_call) |dc| if (accBadRef(dc, name)) return true;
            return accBadRef(u.init, name);
        },
        .function_decl => |fd| return bodyUsesName(fd.body, name),
        else => return false,
    }
}

fn accCountDecls(body: []const Stmt, name: []const u8) usize {
    var n: usize = 0;
    for (body) |*s| n += accCountDeclsStmt(s, name);
    return n;
}
fn accCountDeclsStmt(stmt: *const Stmt, name: []const u8) usize {
    return switch (stmt.*) {
        .var_decl => |d| @as(usize, if (std.mem.eql(u8, d.name, name)) 1 else 0),
        .while_stmt => |w| accCountDecls(w.body, name),
        .do_while_stmt => |w| accCountDecls(w.body, name),
        .for_stmt => |f| accCountDecls(f.body, name),
        .for_of_stmt => |f| accCountDecls(f.body, name),
        .if_stmt => |b| accCountDecls(b.then_body, name) + (if (b.else_body) |eb| accCountDecls(eb, name) else 0),
        .switch_stmt => |sw| blk: {
            var c: usize = 0;
            for (sw.cases) |cse| c += accCountDecls(cse.body, name);
            if (sw.default_body) |db| c += accCountDecls(db, name);
            break :blk c;
        },
        .try_stmt => |t| accCountDecls(t.try_body, name) + accCountDecls(t.catch_body, name) + (if (t.finally_body) |fb| accCountDecls(fb, name) else 0),
        .defer_stmt => |d| accCountDecls(d.body, name),
        else => 0,
    };
}

fn markAccBody(body: []Stmt, name: []const u8) void {
    for (body) |*s| markAccStmt(s, name);
}
fn markAccStmt(stmt: *Stmt, name: []const u8) void {
    switch (stmt.*) {
        .var_decl => |*d| markAccExpr(d.init, name),
        .assign => |*a| {
            if (std.mem.eql(u8, a.name, name)) a.is_accumulator = true;
            markAccExpr(a.value, name);
        },
        .member_assign => |*ma| {
            markAccExpr(ma.value, name);
            if (ma.obj) |o| markAccExpr(o, name);
        },
        .console_log => |*log| markAccExpr(log.value, name),
        .return_stmt => |*r| {
            if (r.value) |x| markAccExpr(x, name);
        },
        .throw_stmt => |*t| markAccExpr(t.value, name),
        .expr_stmt => |*x| markAccExpr(x.value, name),
        .while_stmt => |*w| {
            markAccExpr(w.cond, name);
            markAccBody(w.body, name);
        },
        .do_while_stmt => |*w| {
            markAccExpr(w.cond, name);
            markAccBody(w.body, name);
        },
        .for_stmt => |*f| {
            markAccExpr(f.init.init, name);
            markAccExpr(f.cond, name);
            markAccExpr(f.update.value, name);
            markAccBody(f.body, name);
        },
        .for_of_stmt => |*f| {
            markAccExpr(f.iterable, name);
            markAccBody(f.body, name);
        },
        .if_stmt => |*b| {
            markAccExpr(b.cond, name);
            markAccBody(b.then_body, name);
            if (b.else_body) |eb| markAccBody(eb, name);
        },
        .switch_stmt => |*sw| {
            markAccExpr(sw.value, name);
            for (sw.cases) |*cse| {
                markAccExpr(cse.value, name);
                markAccBody(cse.body, name);
            }
            if (sw.default_body) |db| markAccBody(db, name);
        },
        .try_stmt => |*t| {
            markAccBody(t.try_body, name);
            markAccBody(t.catch_body, name);
            if (t.finally_body) |fb| markAccBody(fb, name);
        },
        .defer_stmt => |*d| markAccBody(d.body, name),
        .using_decl => |*u| {
            if (u.defer_body) |b| markAccBody(b, name);
            if (u.dispose_call) |dc| markAccExpr(dc, name);
            markAccExpr(u.init, name);
        },
        .destructure_decl => |*d| markAccExpr(d.source, name),
        else => {},
    }
}
fn markAccExpr(e: *Expr, name: []const u8) void {
    switch (e.*) {
        .var_ref => |*r| {
            if (std.mem.eql(u8, r.name, name)) r.is_accumulator = true;
        },
        .array => |a| for (a.items) |it| markAccExpr(it, name),
        .tuple_lit => |t| for (t.items) |it| markAccExpr(it, name),
        .spread => |inner| markAccExpr(inner, name),
        .neg, .not, .bnot, .await_expr => |inner| markAccExpr(inner, name),
        .bin => |b| {
            markAccExpr(b.l, name);
            markAccExpr(b.r, name);
        },
        .bool_bin => |b| {
            markAccExpr(b.l, name);
            markAccExpr(b.r, name);
        },
        .cmp => |b| {
            markAccExpr(b.l, name);
            markAccExpr(b.r, name);
        },
        .ternary => |t| {
            markAccExpr(t.cond, name);
            markAccExpr(t.then_expr, name);
            markAccExpr(t.else_expr, name);
        },
        .coalesce => |c| {
            markAccExpr(c.l, name);
            markAccExpr(c.r, name);
        },
        .arrow => |a| markAccExpr(a.body_expr, name),
        .new_expr => |ne| for (ne.args) |it| markAccExpr(it, name),
        .method_call => |mc| {
            markAccExpr(mc.obj, name);
            for (mc.args) |it| markAccExpr(it, name);
        },
        .super_call => |sc| for (sc.args) |it| markAccExpr(it, name),
        .template => |parts| for (parts) |pt| {
            if (pt.expr) |x| markAccExpr(x, name);
        },
        .obj => |fields| for (fields) |f| markAccExpr(f.value, name),
        .field => |f| markAccExpr(f.obj, name),
        .index => |idx| {
            markAccExpr(idx.obj, name);
            markAccExpr(idx.value, name);
        },
        .call => |cl| for (cl.args) |it| markAccExpr(it, name),
        .static_call => |sc| for (sc.args) |it| markAccExpr(it, name),
        .cast => |c| markAccExpr(c.inner, name),
        else => {},
    }
}

/// Marks string-builder accumulators in one function-body scope, then recurses
/// into nested function scopes.
pub fn markAccumulators(stmts: []Stmt, params: []const ast.FunctionParam, arena: std.mem.Allocator) CompileError!void {
    for (stmts) |*s| {
        if (s.* == .var_decl) {
            const d = s.var_decl;
            if (d.mutable and d.reassigned and d.checked_type != null and d.checked_type.? == .string and accIsEmptyStr(d.init) and
                accCountDecls(stmts, d.name) == 1 and !accParamHas(params, d.name) and !(try accDisqBody(stmts, d.name, arena)))
            {
                s.var_decl.is_accumulator = true;
                markAccBody(stmts, d.name);
            }
        }
    }
    for (stmts) |*s| try accRecurseFns(s, arena);
}
fn accParamHas(params: []const ast.FunctionParam, name: []const u8) bool {
    for (params) |p| if (std.mem.eql(u8, p.name, name)) return true;
    return false;
}
fn accRecurseFns(stmt: *Stmt, arena: std.mem.Allocator) CompileError!void {
    switch (stmt.*) {
        .function_decl => |*fd| try markAccumulators(fd.body, fd.params, arena),
        .class_decl => |*cd| {
            for (cd.methods) |*m| try markAccumulators(m.body, m.params, arena);
            try markAccumulators(cd.ctor_body, cd.ctor_params, arena);
        },
        .while_stmt => |*w| for (w.body) |*b| try accRecurseFns(b, arena),
        .do_while_stmt => |*w| for (w.body) |*b| try accRecurseFns(b, arena),
        .for_stmt => |*f| for (f.body) |*b| try accRecurseFns(b, arena),
        .for_of_stmt => |*f| for (f.body) |*b| try accRecurseFns(b, arena),
        .if_stmt => |*b| {
            for (b.then_body) |*x| try accRecurseFns(x, arena);
            if (b.else_body) |eb| for (eb) |*x| try accRecurseFns(x, arena);
        },
        .try_stmt => |*t| {
            for (t.try_body) |*x| try accRecurseFns(x, arena);
            for (t.catch_body) |*x| try accRecurseFns(x, arena);
            if (t.finally_body) |fb| for (fb) |*x| try accRecurseFns(x, arena);
        },
        .defer_stmt => |*d| for (d.body) |*b| try accRecurseFns(b, arena),
        else => {},
    }
}
/// Whether `name` is referenced anywhere in an expression (as a variable read
/// or a function-value call target). Used to discard unused parameters so the
/// emitted Zig compiles (Zig forbids unused parameters/locals).
pub fn exprUsesName(e: *const Expr, name: []const u8) bool {
    return switch (e.*) {
        .num, .float, .bool, .str, .regex, .null_lit, .this_expr => false,
        .var_ref => |r| std.mem.eql(u8, r.name, name),
        .array => |a| blk: {
            for (a.items) |it| if (exprUsesName(it, name)) break :blk true;
            break :blk false;
        },
        .tuple_lit => |t| blk: {
            for (t.items) |it| if (exprUsesName(it, name)) break :blk true;
            break :blk false;
        },
        .spread => |inner| exprUsesName(inner, name),
        .neg, .not, .bnot, .await_expr => |inner| exprUsesName(inner, name),
        .bin => |b| exprUsesName(b.l, name) or exprUsesName(b.r, name),
        .bool_bin => |b| exprUsesName(b.l, name) or exprUsesName(b.r, name),
        .cmp => |b| exprUsesName(b.l, name) or exprUsesName(b.r, name),
        .ternary => |t| exprUsesName(t.cond, name) or exprUsesName(t.then_expr, name) or exprUsesName(t.else_expr, name),
        .coalesce => |c| exprUsesName(c.l, name) or exprUsesName(c.r, name),
        .arrow => |a| exprUsesName(a.body_expr, name),
        .new_expr => |ne| blk: {
            for (ne.args) |it| if (exprUsesName(it, name)) break :blk true;
            break :blk false;
        },
        .method_call => |mc| blk: {
            if (exprUsesName(mc.obj, name)) break :blk true;
            for (mc.args) |it| if (exprUsesName(it, name)) break :blk true;
            break :blk false;
        },
        .super_call => |sc| blk: {
            for (sc.args) |it| if (exprUsesName(it, name)) break :blk true;
            break :blk false;
        },
        .template => |parts| blk: {
            for (parts) |pt| if (pt.expr) |x| {
                if (exprUsesName(x, name)) break :blk true;
            };
            break :blk false;
        },
        .obj => |fields| blk: {
            for (fields) |f| if (exprUsesName(f.value, name)) break :blk true;
            break :blk false;
        },
        .field => |f| exprUsesName(f.obj, name),
        .index => |idx| exprUsesName(idx.obj, name) or exprUsesName(idx.value, name),
        .call => |cl| blk: {
            if (cl.is_closure and std.mem.eql(u8, cl.name, name)) break :blk true;
            for (cl.args) |it| if (exprUsesName(it, name)) break :blk true;
            break :blk false;
        },
        .static_call => |sc| blk: {
            for (sc.args) |it| if (exprUsesName(it, name)) break :blk true;
            break :blk false;
        },
        .cast => |c| exprUsesName(c.inner, name),
    };
}

pub fn bodyUsesName(body: []const Stmt, name: []const u8) bool {
    for (body) |*s| if (stmtUsesName(s, name)) return true;
    return false;
}

fn stmtUsesName(stmt: *const Stmt, name: []const u8) bool {
    return switch (stmt.*) {
        .var_decl => |d| exprUsesName(d.init, name),
        .destructure_decl => |d| exprUsesName(d.source, name),
        .assign => |a| std.mem.eql(u8, a.name, name) or exprUsesName(a.value, name),
        .member_assign => |ma| exprUsesName(ma.value, name) or (ma.obj != null and exprUsesName(ma.obj.?, name)),
        .super_ctor => |sc| blk: {
            for (sc.args) |it| if (exprUsesName(it, name)) break :blk true;
            break :blk false;
        },
        .console_log => |log| exprUsesName(log.value, name),
        .return_stmt => |r| if (r.value) |x| exprUsesName(x, name) else false,
        .throw_stmt => |t| exprUsesName(t.value, name),
        .expr_stmt => |x| exprUsesName(x.value, name),
        .while_stmt => |w| exprUsesName(w.cond, name) or bodyUsesName(w.body, name),
        .do_while_stmt => |w| exprUsesName(w.cond, name) or bodyUsesName(w.body, name),
        .for_stmt => |f| exprUsesName(f.init.init, name) or exprUsesName(f.cond, name) or exprUsesName(f.update.value, name) or bodyUsesName(f.body, name),
        .for_of_stmt => |f| exprUsesName(f.iterable, name) or bodyUsesName(f.body, name),
        .if_stmt => |b| exprUsesName(b.cond, name) or bodyUsesName(b.then_body, name) or (b.else_body != null and bodyUsesName(b.else_body.?, name)),
        .switch_stmt => |sw| blk: {
            if (exprUsesName(sw.value, name)) break :blk true;
            for (sw.cases) |cse| if (exprUsesName(cse.value, name) or bodyUsesName(cse.body, name)) break :blk true;
            if (sw.default_body) |db| if (bodyUsesName(db, name)) break :blk true;
            break :blk false;
        },
        .try_stmt => |t| bodyUsesName(t.try_body, name) or bodyUsesName(t.catch_body, name) or (t.finally_body != null and bodyUsesName(t.finally_body.?, name)),
        .defer_stmt => |d| bodyUsesName(d.body, name),
        .using_decl => |u| blk: {
            if (u.defer_body) |b| if (bodyUsesName(b, name)) break :blk true;
            if (u.dispose_call) |d| if (exprUsesName(d, name)) break :blk true;
            break :blk exprUsesName(u.init, name);
        },
        else => false,
    };
}
