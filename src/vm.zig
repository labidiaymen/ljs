//! The ljs bytecode VM (spec 111 — Phase 0). Executes a `Chunk` (see `bytecode.zig`) produced by
//! `compiler.zig`. It is a thin DRIVER over the existing runtime: every operator / property / call
//! opcode delegates to the SAME helpers the tree-walk uses (`interp_ops.applyNumericOrStringOp`,
//! `relationalV`, `getProperty`, `callFunction`, …) — so observable semantics are identical and the
//! 95.1% conformance is preserved by construction. Only the *dispatch* changes: a flat `while/switch`
//! loop over bytecode instead of recursive AST descent, with locals in slot array (no hashmap walks).
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const Environment = @import("environment.zig").Environment;
const bc = @import("bytecode.zig");
const Op = bc.Op;
const Chunk = bc.Chunk;
const ast = @import("ast.zig");
const ops = @import("abstract_ops.zig");
const interp_ops = @import("interp_ops.zig");
const interp_expr = @import("interp_expr.zig");
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const bigint = @import("bigint.zig");

inline fn readU16(code: []const u8, ip: *usize) u16 {
    const v: u16 = @as(u16, code[ip.*]) | (@as(u16, code[ip.* +| 1]) << 8);
    ip.* += 2;
    return v;
}

/// Run `chunk` with the given local `slots` (params + body locals, pre-bound by the caller) and
/// closure `env` (for free-variable lookups). Returns the function's completion (a `.normal` return
/// value, or an abrupt `.throw`). The operand stack is arena-allocated to the compiler-computed depth.
pub fn run(self: *Interpreter, chunk: *const Chunk, slots: []Value, env: *Environment) EvalError!Completion {
    const code = chunk.code.items;
    const consts = chunk.consts.items;
    // Operand stack: on the Zig stack for the common small case (no per-call heap alloc), else arena.
    var buf: [64]Value = undefined;
    const stack = if (chunk.max_stack <= buf.len) buf[0..@max(chunk.max_stack, 1)] else (self.arena.alloc(Value, chunk.max_stack) catch return error.OutOfMemory);
    var sp: usize = 0;
    var ip: usize = 0;

    while (ip < code.len) {
        const op: Op = @enumFromInt(code[ip]);
        ip += 1;
        switch (op) {
            .load_const => {
                const k = readU16(code, &ip);
                stack[sp] = consts[k];
                sp += 1;
            },
            .load_undef => {
                stack[sp] = .undefined;
                sp += 1;
            },
            .load_null => {
                stack[sp] = .null;
                sp += 1;
            },
            .load_true => {
                stack[sp] = .{ .boolean = true };
                sp += 1;
            },
            .load_false => {
                stack[sp] = .{ .boolean = false };
                sp += 1;
            },
            .load_slot => {
                const s = readU16(code, &ip);
                stack[sp] = slots[s];
                sp += 1;
            },
            .store_slot => {
                const s = readU16(code, &ip);
                sp -= 1;
                slots[s] = stack[sp];
            },
            .load_global => {
                const k = readU16(code, &ip);
                const name = consts[k].string;
                if (env.lookup(name)) |b| {
                    if (!b.initialized) return self.throwError("ReferenceError", name);
                    stack[sp] = b.value;
                } else if (interp_expr.globalObjectHas(self, name)) {
                    const gc = try self.getProperty(.{ .object = interp_expr.globalObject(self).? }, name);
                    if (gc.isAbrupt()) return gc;
                    stack[sp] = gc.normal;
                } else return self.throwError("ReferenceError", name);
                sp += 1;
            },
            .store_global => {
                const k = readU16(code, &ip);
                const name = consts[k].string;
                sp -= 1;
                const v = stack[sp];
                if (env.lookup(name)) |b| {
                    if (!b.mutable) return self.throwError("TypeError", "Assignment to constant variable.");
                    b.value = v;
                    b.initialized = true;
                } else {
                    const sc = try self.setProperty(.{ .object = interp_expr.globalObject(self).? }, name, v);
                    if (sc.isAbrupt()) return sc;
                }
            },
            .pop => sp -= 1,
            .dup => {
                stack[sp] = stack[sp - 1];
                sp += 1;
            },
            // ── arithmetic: inline the number×number fast path (no helper/Completion round-trip);
            //    delegate the polymorphic cases (string concat, ToPrimitive, BigInt) to interp_ops ──
            inline .add, .sub, .mul, .div, .mod => |comptime_op| {
                sp -= 1;
                const r = stack[sp];
                const l = stack[sp - 1];
                if (l == .number and r == .number) {
                    const a = l.number;
                    const b = r.number;
                    stack[sp - 1] = .{ .number = switch (comptime_op) {
                        .add => a + b,
                        .sub => a - b,
                        .mul => a * b,
                        .div => a / b,
                        .mod => @rem(a, b),
                        else => unreachable,
                    } };
                } else {
                    const astop: ast.BinaryOp = comptime switch (comptime_op) {
                        .add => .add,
                        .sub => .sub,
                        .mul => .mul,
                        .div => .div,
                        .mod => .mod,
                        else => unreachable,
                    };
                    const c = try interp_ops.applyNumericOrStringOp(self, astop, l, r);
                    if (c.isAbrupt()) return c;
                    stack[sp - 1] = c.normal;
                }
            },
            inline .exp, .bit_and, .bit_or, .bit_xor, .shl, .shr, .shr_un => |comptime_op| {
                const astop: ast.BinaryOp = comptime switch (comptime_op) {
                    .exp => .exp,
                    .bit_and => .bit_and,
                    .bit_or => .bit_or,
                    .bit_xor => .bit_xor,
                    .shl => .shl,
                    .shr => .shr,
                    .shr_un => .shr_un,
                    else => unreachable,
                };
                sp -= 1;
                const c = try interp_ops.applyNumericOrStringOp(self, astop, stack[sp - 1], stack[sp]);
                if (c.isAbrupt()) return c;
                stack[sp - 1] = c.normal;
            },
            inline .lt, .gt, .le, .ge => |comptime_op| {
                sp -= 1;
                const r = stack[sp];
                const l = stack[sp - 1];
                if (l == .number and r == .number) {
                    const a = l.number;
                    const b = r.number;
                    stack[sp - 1] = .{ .boolean = switch (comptime_op) {
                        .lt => a < b,
                        .gt => a > b,
                        .le => a <= b,
                        .ge => a >= b,
                        else => unreachable,
                    } };
                } else {
                    const relop: ops.RelOp = comptime switch (comptime_op) {
                        .lt => .lt,
                        .gt => .gt,
                        .le => .le,
                        .ge => .ge,
                        else => unreachable,
                    };
                    const c = try interp_ops.relationalV(self, l, r, relop);
                    if (c.isAbrupt()) return c;
                    stack[sp - 1] = c.normal;
                }
            },
            .eq, .ne => |o| {
                sp -= 1;
                const r = stack[sp];
                const l = stack[sp - 1];
                const c = try interp_ops.looseEqualsV(self, l, r);
                if (c.isAbrupt()) return c;
                stack[sp - 1] = .{ .boolean = if (o == .ne) !c.normal.boolean else c.normal.boolean };
            },
            .seq, .sne => |o| {
                sp -= 1;
                const r = stack[sp];
                const l = stack[sp - 1];
                const eqv = ops.strictEquals(l, r);
                stack[sp - 1] = .{ .boolean = if (o == .sne) !eqv else eqv };
            },
            // ── unary ──
            .neg => {
                const v = stack[sp - 1];
                if (v == .bigint) {
                    stack[sp - 1] = .{ .bigint = bigint.neg(self.arena, v.bigint) catch return error.OutOfMemory };
                } else {
                    const nc = try self.toNumberV(v);
                    if (nc.isAbrupt()) return nc;
                    stack[sp - 1] = .{ .number = -nc.normal.number };
                }
            },
            .pos => {
                const nc = try self.toNumberV(stack[sp - 1]);
                if (nc.isAbrupt()) return nc;
                stack[sp - 1] = nc.normal;
            },
            .not_ => {
                stack[sp - 1] = .{ .boolean = !ops.toBoolean(stack[sp - 1]) };
            },
            .bit_not, .typeof_ => unreachable, // Phase 0: compiler never emits these (falls back)
            // ── control flow ──
            .jump => ip = readU16(code, &ip),
            .jump_if_false => {
                const t = readU16(code, &ip);
                sp -= 1;
                if (!ops.toBoolean(stack[sp])) ip = t;
            },
            .jump_if_true => {
                const t = readU16(code, &ip);
                sp -= 1;
                if (ops.toBoolean(stack[sp])) ip = t;
            },
            .jump_if_false_keep => {
                const t = readU16(code, &ip);
                if (!ops.toBoolean(stack[sp - 1])) ip = t else sp -= 1;
            },
            .jump_if_true_keep => {
                const t = readU16(code, &ip);
                if (ops.toBoolean(stack[sp - 1])) ip = t else sp -= 1;
            },
            // ── calls / property reads ──
            .call => {
                const argc = readU16(code, &ip);
                const args = stack[sp - argc .. sp];
                const callee = stack[sp - argc - 1];
                if (callee != .object or callee.object.kind != .function)
                    return self.throwError("TypeError", "value is not a function");
                const c = try self.callFunction(callee.object, args, .undefined);
                if (c.isAbrupt()) return c;
                sp = sp - argc - 1;
                stack[sp] = c.normal;
                sp += 1;
            },
            .call_method => {
                const k = readU16(code, &ip);
                const argc = readU16(code, &ip);
                const args = stack[sp - argc .. sp];
                const obj = stack[sp - argc - 1];
                const mc = try self.getProperty(obj, consts[k].string);
                if (mc.isAbrupt()) return mc;
                if (mc.normal != .object or mc.normal.object.kind != .function)
                    return self.throwError("TypeError", "value is not a function");
                const c = try self.callFunction(mc.normal.object, args, obj);
                if (c.isAbrupt()) return c;
                sp = sp - argc - 1;
                stack[sp] = c.normal;
                sp += 1;
            },
            .get_prop => {
                const k = readU16(code, &ip);
                const gc = try self.getProperty(stack[sp - 1], consts[k].string);
                if (gc.isAbrupt()) return gc;
                stack[sp - 1] = gc.normal;
            },
            .get_index => {
                sp -= 1;
                const key = stack[sp];
                const gc = try self.getPropertyV(stack[sp - 1], key);
                if (gc.isAbrupt()) return gc;
                stack[sp - 1] = gc.normal;
            },
            .ret => {
                sp -= 1;
                return .{ .normal = stack[sp] };
            },
            .ret_undef => return .{ .normal = .undefined },
        }
    }
    return .{ .normal = .undefined };
}
