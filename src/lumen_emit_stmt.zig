//! Statement codegen -- the `Stmt`-union counterpart of `emitExpr`.
//!
//! `emitStmtWithThrow` is the main dispatch (one case per statement kind),
//! threading the current try/switch "where do I jump on throw/break" targets
//! through nested blocks; `emitStmt` is the common case (no throw target) that
//! delegates to it. Also handles `=`/`+=`/...  assignment lowering
//! (`emitAssignExpr`) and `switch` case-match comparisons
//! (`emitSwitchCaseMatch`).
//!
//! This is the single largest emission concern (every control-flow construct
//! in the language), pulled out of `lumen_emit.zig` as its own file; it calls
//! back into `emitExpr` (still in `lumen_emit.zig`) for every expression a
//! statement contains.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const diag_mod = @import("lumen_diag.zig");
const emit_mod = @import("lumen_emit.zig");
const analysis = @import("lumen_emit_analysis.zig");
const emit_class = @import("lumen_emit_class.zig");
const emitClass = emit_class.emitClass;
const lumen_opt = @import("lumen_opt.zig");
const collectStrConcat = lumen_opt.collectStrConcat;
const bodyUsesName = lumen_opt.bodyUsesName;

const CompileError = diag_mod.CompileError;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const CompileOptions = emit_mod.CompileOptions;
const emitExpr = emit_mod.emitExpr;

pub fn emitStmt(stmt: *const Stmt, decls: *std.ArrayListUnmanaged(u8), body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, options: CompileOptions) CompileError!void {
    return emitStmtWithThrow(stmt, decls, body, arena, null, null, options);
}

pub fn emitAssignExpr(assignment: ast.Assign, body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    const base = assignment.emit_name orelse assignment.name;
    // A scalar by-reference (`Ref<T>`) param assigns through its pointer.
    const name = if (assignment.deref) try std.fmt.allocPrint(arena, "{s}.*", .{base}) else base;
    try body.print(arena, "{s} = ", .{name});
    if (std.mem.eql(u8, assignment.op, "=")) {
        try emitExpr(assignment.value, body, arena);
    } else if (assignment.op[0] == '/') {
        try body.print(arena, "@divTrunc({s}, ", .{name});
        try emitExpr(assignment.value, body, arena);
        try body.append(arena, ')');
    } else if (assignment.op[0] == '%') {
        try body.print(arena, "@rem({s}, ", .{name});
        try emitExpr(assignment.value, body, arena);
        try body.append(arena, ')');
    } else {
        try body.print(arena, "({s} {c} ", .{ name, assignment.op[0] });
        try emitExpr(assignment.value, body, arena);
        try body.append(arena, ')');
    }
}

/// Whether a switch case/default body contains a `break` that targets the switch
/// itself. Descends through `if`/`try`/`defer` blocks but not into nested loops
/// or switches, whose own `break` binds to that inner construct.
pub fn bodyHasSwitchBreak(body: []const Stmt) bool {
    for (body) |*s| {
        switch (s.*) {
            .break_stmt => return true,
            .if_stmt => |b| {
                if (bodyHasSwitchBreak(b.then_body)) return true;
                if (b.else_body) |eb| if (bodyHasSwitchBreak(eb)) return true;
            },
            .try_stmt => |t| {
                if (bodyHasSwitchBreak(t.try_body)) return true;
                if (bodyHasSwitchBreak(t.catch_body)) return true;
                if (t.finally_body) |fb| if (bodyHasSwitchBreak(fb)) return true;
            },
            .defer_stmt => |d| if (bodyHasSwitchBreak(d.body)) return true,
            else => {},
        }
    }
    return false;
}

pub fn emitSwitchCaseMatch(switch_type: types.Type, switch_value: *const Expr, case_value: *const Expr, body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    if (types.isStringLike(switch_type)) {
        try body.appendSlice(arena, "std.mem.eql(u8, ");
        try emitExpr(switch_value, body, arena);
        try body.appendSlice(arena, ", ");
        try emitExpr(case_value, body, arena);
        try body.append(arena, ')');
    } else {
        try body.append(arena, '(');
        try emitExpr(switch_value, body, arena);
        try body.appendSlice(arena, " == ");
        try emitExpr(case_value, body, arena);
        try body.append(arena, ')');
    }
}

pub fn emitStmtWithThrow(stmt: *const Stmt, decls: *std.ArrayListUnmanaged(u8), body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, throw_target: ?[]const u8, switch_break_target: ?[]const u8, options: CompileOptions) CompileError!void {
    if (options.runtime_locations) {
        const line_col: emit_mod.SourceLoc = switch (stmt.*) {
            .type_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .enum_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .extern_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .class_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .member_assign => |ma| .{ .line = ma.line, .col = ma.col },
            .super_ctor => |sc| .{ .line = sc.line, .col = sc.col },
            .test_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .function_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .var_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .using_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .destructure_decl => |d| .{ .line = d.line, .col = d.col },
            .assign => |assignment| .{ .line = assignment.line, .col = assignment.col },
            .console_log => |log| .{ .line = log.line, .col = log.col },
            .while_stmt => |loop| .{ .line = loop.line, .col = loop.col },
            .do_while_stmt => |loop| .{ .line = loop.line, .col = loop.col },
            .for_stmt => |loop| .{ .line = loop.line, .col = loop.col },
            .for_of_stmt => |loop| .{ .line = loop.line, .col = loop.col },
            .if_stmt => |branch| .{ .line = branch.line, .col = branch.col },
            .switch_stmt => |switch_stmt| .{ .line = switch_stmt.line, .col = switch_stmt.col },
            .return_stmt => |ret| .{ .line = ret.line, .col = ret.col },
            .throw_stmt => |throw_stmt| .{ .line = throw_stmt.line, .col = throw_stmt.col },
            .try_stmt => |try_stmt| .{ .line = try_stmt.line, .col = try_stmt.col },
            .break_stmt => |control| .{ .line = control.line, .col = control.col },
            .continue_stmt => |control| .{ .line = control.line, .col = control.col },
            .defer_stmt => |d| .{ .line = d.line, .col = d.col },
            .expr_stmt => |expr_stmt| .{ .line = expr_stmt.line, .col = expr_stmt.col },
        };
        try body.print(arena, "    __lumen_line = {d}; __lumen_col = {d};\n", .{ line_col.line, line_col.col });
    }

    switch (stmt.*) {
        .type_decl => |decl| {
            if (decl.string_literals != null) return;
            if (decl.int_literals != null) return;
            if (decl.alias != null) return; // aliases are erased: resolve to target
            if (decl.union_variants != null) {
                // A discriminated union lowers to a flat struct holding the union
                // of every variant's fields, each with a default so a single
                // variant's object literal initializes cleanly.
                try decls.print(arena, "const {s} = struct {{\n", .{decl.name});
                for (decl.fields) |field| {
                    const field_type = field.checked_type orelse return error.ParseError;
                    const zty = try types.zigName(arena, field_type);
                    try decls.print(arena, "    {s}: {s} = {s},\n", .{ field.name, zty, try analysis.zigZeroValue(arena, field_type) });
                }
                try decls.appendSlice(arena, "};\n");
                return;
            }
            if (decl.type_params.len > 0) return; // generic template: only specializations emit
            try decls.print(arena, "const {s} = struct {{\n", .{decl.name});
            for (decl.fields) |field| {
                const field_type = field.checked_type orelse return error.ParseError;
                try decls.print(arena, "    {s}: {s},\n", .{ field.name, try types.zigName(arena, field_type) });
            }
            try decls.appendSlice(arena, "};\n");
        },
        .enum_decl => {}, // members are inlined as constants at each use site
        .extern_decl => |decl| {
            // extern fn name(p0: T, ...) Ret;  -- resolved at link time.
            // A `string` parameter/return crosses the C ABI as a NUL-terminated
            // `const char*`, i.e. Zig `[*:0]const u8`; the call site marshals
            // between that and the Lumen `[]const u8` string.
            try decls.print(arena, "extern fn {s}(", .{decl.name});
            for (decl.params, 0..) |param, i| {
                if (i > 0) try decls.appendSlice(arena, ", ");
                try decls.print(arena, "{s}: {s}", .{ param.name, emit_mod.externZigName(param.checked_type orelse return error.ParseError, arena) });
            }
            try decls.print(arena, ") {s};\n", .{emit_mod.externZigName(decl.checked_return_type orelse return error.ParseError, arena)});
        },
        .class_decl => |*c| {
            if (c.type_params.len > 0) return; // generic template: only specializations emit
            try emitClass(c, decls, arena, throw_target, switch_break_target, options);
        },
        .super_ctor => |sc| {
            // super(args) -> self.__superctor_<Parent>(args);
            const parent = sc.parent orelse return;
            try body.print(arena, "    self.__superctor_{s}(", .{parent});
            for (sc.args, 0..) |arg, i| {
                if (i > 0) try body.appendSlice(arena, ", ");
                try emitExpr(arg, body, arena);
            }
            try body.appendSlice(arena, ");\n");
        },
        .member_assign => |ma| {
            // Resolve the receiver expression: `self.` (this), `Class.` (static),
            // a setter call, or `obj.` (external instance field).
            if (ma.is_setter) {
                // obj.prop = value  ->  obj.__set_prop(value);
                try body.appendSlice(arena, "    ");
                try emitExpr(ma.obj.?, body, arena);
                try body.print(arena, ".__set_{s}(", .{ma.field});
                try emitExpr(ma.value, body, arena);
                try body.appendSlice(arena, ");\n");
                return;
            }
            // Build the lvalue prefix string.
            var lv: std.ArrayListUnmanaged(u8) = .empty;
            if (ma.is_static) {
                const owner = ma.class_name orelse "";
                try lv.print(arena, "{s}.__static_{s}_{s}", .{ owner, owner, ma.field });
            } else if (ma.obj) |obj| {
                try emitExpr(obj, &lv, arena);
                try lv.print(arena, ".{s}", .{ma.field});
            } else {
                try lv.print(arena, "self.{s}", .{ma.field});
            }
            const lvs = lv.items;
            try body.print(arena, "    {s} = ", .{lvs});
            if (std.mem.eql(u8, ma.op, "=")) {
                try emitExpr(ma.value, body, arena);
            } else if (ma.op[0] == '/') {
                try body.print(arena, "@divTrunc({s}, ", .{lvs});
                try emitExpr(ma.value, body, arena);
                try body.append(arena, ')');
            } else if (ma.op[0] == '%') {
                try body.print(arena, "@rem({s}, ", .{lvs});
                try emitExpr(ma.value, body, arena);
                try body.append(arena, ')');
            } else {
                try body.print(arena, "({s} {c} ", .{ lvs, ma.op[0] });
                try emitExpr(ma.value, body, arena);
                try body.append(arena, ')');
            }
            try body.appendSlice(arena, ";\n");
        },
        .test_decl => |t| {
            // Emit a Zig `test "name" { ... }` block into the top-level decls.
            try decls.appendSlice(arena, "test \"");
            for (t.name) |ch| {
                if (ch == '"' or ch == '\\') try decls.append(arena, '\\');
                try decls.append(arena, ch);
            }
            try decls.appendSlice(arena, "\" {\n");
            for (t.body) |*test_stmt| try emitStmtWithThrow(test_stmt, decls, decls, arena, throw_target, switch_break_target, options);
            try decls.appendSlice(arena, "}\n");
        },
        .function_decl => |decl| {
            if (decl.type_params.len > 0) return; // generic template: only specializations emit
            const return_type = decl.checked_return_type orelse types.fromAnnotation(decl.return_annotation);
            try decls.print(arena, "fn {s}(", .{decl.name});
            for (decl.params, 0..) |param, i| {
                if (i > 0) try decls.appendSlice(arena, ", ");
                const param_type = param.checked_type orelse types.fromAnnotation(param.annotation);
                const ztype = if (param.is_ref) try types.refZigName(arena, param_type) else try types.zigName(arena, param_type);
                try decls.print(arena, "{s}: {s}", .{ param.name, ztype });
            }
            // An async function returns its declared `*LumenPromise(T)`; `return v`
            // statements in the body resolve the promise with `v`.
            try decls.print(arena, ") {s} {{\n", .{try types.zigName(arena, return_type)});
            const prev_async_inner = emit_mod.g_async_inner;
            if (decl.is_async and return_type == .promise_type) {
                emit_mod.g_async_inner = try types.zigName(arena, return_type.promise_type.*);
            } else {
                emit_mod.g_async_inner = null;
            }
            defer emit_mod.g_async_inner = prev_async_inner;
            try analysis.emitUnusedParamDiscards(decl.params, decl.body, decls, arena);
            for (decl.body) |*body_stmt| try emitStmt(body_stmt, decls, decls, arena, options);
            // An async `Promise<void>` body may legally fall through without a
            // `return`; emit a trailing resolved promise so the Promise-returning
            // function still returns a value. Skip it when the body already
            // returns on every path (the trailing return would be dead code).
            if (decl.is_async and return_type == .promise_type and return_type.promise_type.* == .void and !analysis.bodyAlwaysReturns(decl.body)) {
                try decls.appendSlice(arena, "    return __promiseResolved(void, {});\n");
            }
            try decls.appendSlice(arena, "}\n");
            // Destination-passing twin: appends straight into a caller buffer.
            if (emit_mod.g_dest_acc) |dm| if (dm.get(decl.name)) |accname| {
                try decls.print(arena, "fn {s}__into({s}: *std.ArrayListUnmanaged(u8)", .{ decl.name, accname });
                for (decl.params) |param| {
                    const param_type = param.checked_type orelse types.fromAnnotation(param.annotation);
                    const ztype = if (param.is_ref) try types.refZigName(arena, param_type) else try types.zigName(arena, param_type);
                    try decls.print(arena, ", {s}: {s}", .{ param.name, ztype });
                }
                try decls.appendSlice(arena, ") void {\n");
                const prev = emit_mod.g_cur_into_acc;
                emit_mod.g_cur_into_acc = accname;
                try analysis.emitUnusedParamDiscards(decl.params, decl.body, decls, arena);
                for (decl.body) |*body_stmt| try emitStmt(body_stmt, decls, decls, arena, options);
                emit_mod.g_cur_into_acc = prev;
                try decls.appendSlice(arena, "}\n");
            };
        },
        .var_decl => |decl| {
            // In an `__into` body the returned accumulator is the dest parameter,
            // so its local declaration is dropped.
            if (emit_mod.g_cur_into_acc != null and decl.is_accumulator and std.mem.eql(u8, decl.emit_name orelse decl.name, emit_mod.g_cur_into_acc.?)) return;
            if (decl.is_accumulator) {
                // String-builder: a growable buffer instead of an immutable slice.
                // The init is always `""`, so it starts empty.
                try body.print(arena, "    var {s}: std.ArrayListUnmanaged(u8) = .empty;\n", .{decl.emit_name orelse decl.name});
            } else {
                const final_zty = decl.checked_type orelse return error.ParseError;
                try body.print(arena, "    {s} {s}: {s} = ", .{ if (decl.mutable and decl.reassigned) "var" else "const", decl.emit_name orelse decl.name, try types.zigName(arena, final_zty) });
                try emitExpr(decl.init, body, arena);
                try body.appendSlice(arena, ";\n");
            }
        },
        .using_decl => |decl| {
            // `using` lowers to Zig `defer`, which already runs LIFO at scope
            // exit and interleaves correctly with `defer`-statement blocks.
            if (decl.defer_body) |defer_body| {
                // `using x = defer(() => BODY);` — run BODY at scope exit.
                try body.appendSlice(arena, "    defer {\n");
                for (defer_body) |*defer_stmt| try emitStmtWithThrow(defer_stmt, decls, body, arena, throw_target, switch_break_target, options);
                try body.appendSlice(arena, "    }\n");
            } else {
                // `using r = EXPR;` — bind the value, then `defer r.dispose();`.
                const final_zty = decl.checked_type orelse return error.ParseError;
                try body.print(arena, "    const {s}: {s} = ", .{ decl.emit_name orelse decl.name, try types.zigName(arena, final_zty) });
                try emitExpr(decl.init, body, arena);
                try body.appendSlice(arena, ";\n");
                const dispose = decl.dispose_call orelse return error.ParseError;
                try body.appendSlice(arena, "    defer {\n        _ = ");
                try emitExpr(dispose, body, arena);
                try body.appendSlice(arena, ";\n    }\n");
            }
        },
        .destructure_decl => |d| {
            // Bind a temp to the source, then one const per element/field. No
            // wrapping block, so the bindings remain in the enclosing scope.
            const src = try std.fmt.allocPrint(arena, "__lumen_ds_{d}_{d}", .{ d.line, d.col });
            try body.print(arena, "    const {s} = ", .{src});
            try emitExpr(d.source, body, arena);
            try body.appendSlice(arena, ";\n");
            for (d.bindings, 0..) |b, i| {
                const bty = b.checked_type orelse return error.ParseError;
                try body.print(arena, "    const {s}: {s} = ", .{ b.emit_name orelse b.name, try types.zigName(arena, bty) });
                if (d.is_object) {
                    try body.print(arena, "{s}.{s};\n", .{ src, b.name });
                } else {
                    try body.print(arena, "{s}[{d}];\n", .{ src, i });
                }
            }
        },
        .assign => |assignment| {
            if (assignment.is_accumulator) {
                // `v = v + a + b` -> append a, b in place (skip the leading `v`).
                var parts: std.ArrayListUnmanaged(*const Expr) = .empty;
                try collectStrConcat(assignment.value, &parts, arena);
                const vname = assignment.emit_name orelse assignment.name;
                // The buffer to pass to an `__into` call: the dest itself when this
                // accumulator IS the enclosing `__into` dest (already a pointer),
                // otherwise its address.
                const accptr = if (emit_mod.g_cur_into_acc != null and std.mem.eql(u8, emit_mod.g_cur_into_acc.?, vname)) vname else try std.fmt.allocPrint(arena, "&{s}", .{vname});
                if (parts.items.len >= 1) {
                    for (parts.items[1..]) |p| {
                        if (p.* == .call and p.call.is_into_call) {
                            try body.print(arena, "    {s}__into({s}", .{ p.call.name, accptr });
                            for (p.call.args) |arg| {
                                try body.appendSlice(arena, ", ");
                                try emitExpr(arg, body, arena);
                            }
                            try body.appendSlice(arena, ");\n");
                        } else {
                            try body.print(arena, "    {s}.appendSlice(__sa(), ", .{vname});
                            try emitExpr(p, body, arena);
                            try body.appendSlice(arena, ") catch std.process.exit(1);\n");
                        }
                    }
                }
            } else {
                try body.appendSlice(arena, "    ");
                try emitAssignExpr(assignment, body, arena);
                try body.appendSlice(arena, ";\n");
            }
        },
        .console_log => |log| {
            const log_type = log.checked_type orelse return error.ParseError;
            try body.print(arena, "    std.debug.print(\"{s}\\n\", .{{", .{analysis.printFormat(log_type)});
            try emitExpr(log.value, body, arena);
            try body.appendSlice(arena, "});\n");
        },
        .while_stmt => |loop| {
            try body.appendSlice(arena, "    while (");
            try emitExpr(loop.cond, body, arena);
            try body.appendSlice(arena, ") {\n");
            for (loop.body) |*body_stmt| try emitStmtWithThrow(body_stmt, decls, body, arena, throw_target, null, options);
            try body.appendSlice(arena, "    }\n");
        },
        .do_while_stmt => |loop| {
            try body.appendSlice(arena, "    while (true) : ({ if (!(");
            try emitExpr(loop.cond, body, arena);
            try body.appendSlice(arena, ")) break; }) {\n");
            for (loop.body) |*body_stmt| try emitStmtWithThrow(body_stmt, decls, body, arena, throw_target, null, options);
            try body.appendSlice(arena, "    }\n");
        },
        .for_stmt => |loop| {
            try body.appendSlice(arena, "    {\n");
            var init_stmt: Stmt = .{ .var_decl = loop.init };
            try emitStmtWithThrow(&init_stmt, decls, body, arena, throw_target, switch_break_target, options);
            try body.appendSlice(arena, "    while (");
            try emitExpr(loop.cond, body, arena);
            try body.appendSlice(arena, ") : (");
            try emitAssignExpr(loop.update, body, arena);
            try body.appendSlice(arena, ") {\n");
            for (loop.body) |*body_stmt| try emitStmtWithThrow(body_stmt, decls, body, arena, throw_target, null, options);
            try body.appendSlice(arena, "    }\n");
            try body.appendSlice(arena, "    }\n");
        },
        .for_of_stmt => |loop| {
            const iter_ty = loop.iter_type orelse return error.ParseError;
            const elem_ty = loop.elem_type orelse return error.ParseError;
            const seq = try std.fmt.allocPrint(arena, "__lumen_of_seq_{d}_{d}", .{ loop.line, loop.col });
            const idx = try std.fmt.allocPrint(arena, "__lumen_of_idx_{d}_{d}", .{ loop.line, loop.col });
            const binding = loop.binding_emit_name orelse loop.binding;
            const elem_zig = try types.zigName(arena, elem_ty);
            try body.appendSlice(arena, "    {\n");
            try body.print(arena, "    const {s} = ", .{seq});
            try emitExpr(loop.iterable, body, arena);
            try body.appendSlice(arena, ";\n");
            try body.print(arena, "    var {s}: usize = 0;\n", .{idx});
            try body.print(arena, "    while ({s} < {s}.len) : ({s} += 1) {{\n", .{ idx, seq, idx });
            // String iteration yields single-character substrings ([]const u8);
            // array iteration yields the element directly.
            if (types.isStringLike(iter_ty)) {
                try body.print(arena, "    const {s}: {s} = {s}[{s} .. {s} + 1];\n", .{ binding, elem_zig, seq, idx, idx });
            } else {
                try body.print(arena, "    const {s}: {s} = {s}[{s}];\n", .{ binding, elem_zig, seq, idx });
            }
            for (loop.body) |*body_stmt| try emitStmtWithThrow(body_stmt, decls, body, arena, throw_target, null, options);
            try body.appendSlice(arena, "    }\n");
            try body.appendSlice(arena, "    }\n");
        },
        .if_stmt => |branch| {
            try body.appendSlice(arena, "    if (");
            try emitExpr(branch.cond, body, arena);
            try body.appendSlice(arena, ") {\n");
            for (branch.then_body) |*body_stmt| try emitStmtWithThrow(body_stmt, decls, body, arena, throw_target, switch_break_target, options);
            try body.appendSlice(arena, "    }");
            if (branch.else_body) |else_body| {
                try body.appendSlice(arena, " else {\n");
                for (else_body) |*body_stmt| try emitStmtWithThrow(body_stmt, decls, body, arena, throw_target, switch_break_target, options);
                try body.appendSlice(arena, "    }");
            }
            try body.appendSlice(arena, "\n");
        },
        .switch_stmt => |switch_stmt| {
            const switch_type = switch_stmt.checked_type orelse return error.ParseError;
            // The break-target label is only emitted when a case actually breaks;
            // a switch whose cases all `return` (e.g. discriminated-union
            // dispatch) needs no label, which Zig would reject as unused.
            var needs_label = false;
            for (switch_stmt.cases) |case| {
                if (bodyHasSwitchBreak(case.body)) needs_label = true;
            }
            if (switch_stmt.default_body) |db| {
                if (bodyHasSwitchBreak(db)) needs_label = true;
            }
            const label = try std.fmt.allocPrint(arena, "__lumen_switch_{d}_{d}", .{ switch_stmt.line, switch_stmt.col });
            const label_target: ?[]const u8 = if (needs_label) label else null;
            if (needs_label) try body.print(arena, "    {s}: {{\n", .{label}) else try body.appendSlice(arena, "    {\n");
            for (switch_stmt.cases, 0..) |case, i| {
                try body.appendSlice(arena, if (i == 0) "    if (" else "    else if (");
                try emitSwitchCaseMatch(switch_type, switch_stmt.value, case.value, body, arena);
                try body.appendSlice(arena, ") {\n");
                for (case.body) |*case_stmt| try emitStmtWithThrow(case_stmt, decls, body, arena, throw_target, label_target, options);
                try body.appendSlice(arena, "    }\n");
            }
            if (switch_stmt.default_body) |default_body| {
                try body.appendSlice(arena, if (switch_stmt.cases.len == 0) "    {\n" else "    else {\n");
                for (default_body) |*default_stmt| try emitStmtWithThrow(default_stmt, decls, body, arena, throw_target, label_target, options);
                try body.appendSlice(arena, "    }\n");
            }
            try body.appendSlice(arena, "    }\n");
        },
        .return_stmt => |ret| {
            // In an `__into` body, `return <acc>` is already appended into dest -> bare
            // return; any other returned string is appended into dest, then return.
            if (emit_mod.g_cur_into_acc) |dest| {
                if (ret.value) |v| {
                    if (v.* == .var_ref and v.var_ref.is_accumulator and std.mem.eql(u8, v.var_ref.emit_name orelse v.var_ref.name, dest)) {
                        try body.appendSlice(arena, "    return;\n");
                    } else {
                        try body.print(arena, "    {s}.appendSlice(__sa(), ", .{dest});
                        try emitExpr(v, body, arena);
                        try body.appendSlice(arena, ") catch std.process.exit(1);\n    return;\n");
                    }
                } else try body.appendSlice(arena, "    return;\n");
                return;
            }
            if (ret.value) |value| {
                if (emit_mod.g_async_inner) |inner_zig| {
                    // Inside an async body: resolve the promise with the value.
                    try body.print(arena, "    return __promiseResolved({s}, ", .{inner_zig});
                    try emitExpr(value, body, arena);
                    try body.appendSlice(arena, ");\n");
                } else {
                    try body.appendSlice(arena, "    return ");
                    try emitExpr(value, body, arena);
                    try body.appendSlice(arena, ";\n");
                }
            } else if (emit_mod.g_async_inner) |inner_zig| {
                // `return;` in an async `Promise<void>` body resolves with void {}.
                try body.print(arena, "    return __promiseResolved({s}, {{}});\n", .{inner_zig});
            } else {
                try body.appendSlice(arena, "    return;\n");
            }
        },
        .throw_stmt => |throw_stmt| {
            if (throw_target) |target| {
                // Set the enclosing try's slot, then break out of its labeled
                // try block so the remaining try statements are skipped.
                const label = try std.mem.replaceOwned(u8, arena, target, "__lumen_throw_", "__lumen_try_");
                try body.print(arena, "    {s} = ", .{target});
                try emitExpr(throw_stmt.value, body, arena);
                try body.print(arena, ";\n    break :{s};\n", .{label});
            } else {
                try body.appendSlice(arena, "    @panic(");
                try emitExpr(throw_stmt.value, body, arena);
                try body.appendSlice(arena, ");\n");
            }
        },
        .try_stmt => |try_stmt| {
            const slot = try std.fmt.allocPrint(arena, "__lumen_throw_{d}_{d}", .{ try_stmt.line, try_stmt.col });
            const label = try std.fmt.allocPrint(arena, "__lumen_try_{d}_{d}", .{ try_stmt.line, try_stmt.col });
            const can_throw = analysis.bodyCanThrow(try_stmt.try_body);
            const slot_kw = if (can_throw) "var" else "const";
            try body.print(arena, "    {s} {s}: ?[]const u8 = null;\n", .{ slot_kw, slot });
            // Wrap the whole try/catch in an outer block. `finally` lowers to a
            // `defer` at the top of that block, so it always runs on every exit
            // — normal fallthrough, a caught throw, or a rethrow that breaks out
            // to an enclosing try (the defer unwinds before the break leaves).
            try body.appendSlice(arena, "    {\n");
            if (try_stmt.finally_body) |finally_body| {
                try body.appendSlice(arena, "    defer {\n");
                for (finally_body) |*finally_stmt| try emitStmtWithThrow(finally_stmt, decls, body, arena, throw_target, switch_break_target, options);
                try body.appendSlice(arena, "    }\n");
            }
            // The try body runs in a single block so its locals share one scope.
            // When it can throw, the block is labeled so a `throw` can set the
            // slot and break out, skipping the remaining try statements.
            if (can_throw) {
                try body.print(arena, "    {s}: {{\n", .{label});
            } else {
                try body.appendSlice(arena, "    {\n");
            }
            for (try_stmt.try_body) |*try_body_stmt| {
                try emitStmtWithThrow(try_body_stmt, decls, body, arena, slot, switch_break_target, options);
                // A `throw` lowers to a `break`; later siblings are dead code.
                if (analysis.stmtAlwaysThrows(try_body_stmt)) break;
            }
            try body.appendSlice(arena, "    }\n");
            const catch_emit = try_stmt.catch_emit_name orelse try_stmt.catch_name;
            try body.print(arena, "    if ({s}) |{s}| {{\n", .{ slot, catch_emit });
            // Zig rejects an unused capture, so discard the binding when the
            // catch body never reads it.
            if (!bodyUsesName(try_stmt.catch_body, try_stmt.catch_name)) {
                try body.print(arena, "    _ = {s};\n", .{catch_emit});
            }
            for (try_stmt.catch_body) |*catch_stmt| {
                try emitStmtWithThrow(catch_stmt, decls, body, arena, throw_target, switch_break_target, options);
                // A rethrow lowers to a `break`; later siblings are dead code.
                // Only meaningful when an enclosing try provides a throw target.
                if (throw_target != null and analysis.stmtAlwaysThrows(catch_stmt)) break;
            }
            try body.appendSlice(arena, "    }\n");
            try body.appendSlice(arena, "    }\n");
        },
        .defer_stmt => |d| {
            try body.appendSlice(arena, "    defer {\n");
            for (d.body) |*defer_stmt| try emitStmtWithThrow(defer_stmt, decls, body, arena, throw_target, switch_break_target, options);
            try body.appendSlice(arena, "    }\n");
        },
        .break_stmt => {
            if (switch_break_target) |target| {
                try body.print(arena, "    break :{s};\n", .{target});
            } else {
                try body.appendSlice(arena, "    break;\n");
            }
        },
        .continue_stmt => {
            try body.appendSlice(arena, "    continue;\n");
        },
        .expr_stmt => |expr_stmt| {
            const is_serve = expr_stmt.value.* == .call and std.mem.eql(u8, expr_stmt.value.call.name, "serve");
            try body.appendSlice(arena, if (is_serve) "    " else "    _ = ");
            try emitExpr(expr_stmt.value, body, arena);
            try body.appendSlice(arena, ";\n");
        },
    }
}
