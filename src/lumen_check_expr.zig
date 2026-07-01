//! Expression type-checking -- `exprType` is the heart of the checker: given
//! any `*ast.Expr`, return its `Type` (or `null` plus a diagnostic). One case
//! per `Expr` union variant (literals, binary/unary ops, calls, field access,
//! indexing, object/array literals, closures, ...), recording resolved types
//! and emission hints back onto the node so the codegen never re-derives them.
//! `fieldType` resolves a named record's field type by name, used both here
//! (plain `.field` access) and by callers checking object-literal shapes.
//!
//! This is the single largest piece of the checker (every other module here
//! -- assignability, class resolution, generics, stdlib calls, statements --
//! exists to be called FROM `exprType`, directly or via `checkStmt`). It is
//! kept in its own file because of size, not because it is more separable
//! than the rest: expect it to call into `self.*` methods defined all over
//! the other `lumen_check_*.zig` files.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const diag_mod = @import("lumen_diag.zig");
const check_mod = @import("lumen_check.zig");

const Checker = check_mod.Checker;
const CompileError = diag_mod.CompileError;

pub fn exprType(self: *Checker, program: *ast.Program, e: *ast.Expr, line: u32, col: u32) ?types.Type {
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
            if (std.mem.eql(u8, call.name, "setTimeout") or std.mem.eql(u8, call.name, "setInterval")) {
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
                // A handle (spec 038), like an fs.openSync fd -- not `void`
                // anymore, so `clearTimeout`/`clearInterval` have something
                // to cancel.
                return .i32;
            }
            if (std.mem.eql(u8, call.name, "clearTimeout") or std.mem.eql(u8, call.name, "clearInterval")) {
                if (call.args.len != 1) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                const id_type = self.exprType(program, call.args[0], line, col) orelse return null;
                if (!types.same(.i32, id_type)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                // clearTimeout/clearInterval are the same runtime function
                // under the hood (spec 038) -- both just flip a
                // cancellation flag looked up by id.
                call.name = "__clearTimer";
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
                        if (i >= call.args.len or !check_mod.isAddressable(call.args[i]) or !self.refRootMutable(call.args[i])) {
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

pub fn fieldType(self: *Checker, type_name: []const u8, field_name: []const u8, line: u32, col: u32) ?types.Type {
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
