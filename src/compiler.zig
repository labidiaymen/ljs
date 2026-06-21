//! AST → bytecode compiler for the ljs VM (spec 111 — Phase 0). `compile(params, body)` returns a
//! `*Chunk` for the supported subset, or **null** for anything it doesn't handle yet — the caller then
//! runs that function on the existing tree-walk (the fallback that keeps semantics intact while VM
//! coverage grows). Phase 0 subset: simple-identifier params, `var` locals (function-scoped), `block`/
//! `if`/`while`/`do-while`/`for`(C-style)/`return`/`break`/`continue`(unlabeled)/expression statements;
//! number/string/boolean/identifier literals, binary & relational & equality ops, `&&`/`||`/`?:`,
//! unary `! - +`, `=`/compound-assign to an identifier, calls, and member/index READS. Everything else
//! (let/const, closures, try/catch, ++/--, destructuring, member writes, objects/arrays, this/super,
//! generators/async, with/eval, …) → null → tree-walk.
const std = @import("std");
const ast = @import("ast.zig");
const Value = @import("value.zig").Value;
const bc = @import("bytecode.zig");
const Chunk = bc.Chunk;
const Op = bc.Op;

const Loop = struct {
    breaks: std.ArrayListUnmanaged(usize) = .empty, // jump operands to patch → loop end
    continues: std.ArrayListUnmanaged(usize) = .empty, // jump operands to patch → continue target
};

const Compiler = struct {
    arena: std.mem.Allocator,
    chunk: *Chunk,
    slots: std.StringHashMapUnmanaged(u16) = .empty, // local name → slot index
    n_slots: u16 = 0,
    depth: i32 = 0, // current operand-stack height
    max_depth: i32 = 0,
    loops: std.ArrayListUnmanaged(*Loop) = .empty,
    ok: bool = true,

    fn fail(self: *Compiler) void {
        self.ok = false;
    }
    fn adj(self: *Compiler, delta: i32) void {
        self.depth += delta;
        if (self.depth > self.max_depth) self.max_depth = self.depth;
    }
    fn slotOf(self: *Compiler, name: []const u8) ?u16 {
        return self.slots.get(name);
    }
    fn addSlot(self: *Compiler, name: []const u8) std.mem.Allocator.Error!u16 {
        if (self.slots.get(name)) |s| return s;
        const s = self.n_slots;
        try self.slots.put(self.arena, name, s);
        self.n_slots += 1;
        return s;
    }

    // ── emit helpers (each keeps `depth`/`max_depth` correct) ──
    fn op(self: *Compiler, o: Op, delta: i32) std.mem.Allocator.Error!void {
        try self.chunk.emit(self.arena, o);
        self.adj(delta);
    }
    fn op1(self: *Compiler, o: Op, v: u16, delta: i32) std.mem.Allocator.Error!usize {
        const at = try self.chunk.emitOp1(self.arena, o, v);
        self.adj(delta);
        return at;
    }
    fn constOp(self: *Compiler, v: Value) std.mem.Allocator.Error!void {
        const k = try self.chunk.addConst(self.arena, v);
        _ = try self.op1(.load_const, k, 1);
    }

    // ── statements ──
    fn stmt(self: *Compiler, s: *const ast.Stmt) std.mem.Allocator.Error!void {
        if (!self.ok) return;
        switch (s.*) {
            .expr => |e| {
                try self.expr(e);
                try self.op(.pop, -1); // discard the statement's value
            },
            .declaration => |d| {
                if (d.kind != .var_decl) return self.fail(); // let/const → fallback (TDZ/block scope)
                for (d.decls) |dec| {
                    if (dec.target.* != .identifier) return self.fail();
                    const slot = try self.addSlot(dec.target.identifier);
                    if (dec.init) |init_e| {
                        try self.expr(init_e);
                        _ = try self.op1(.store_slot, slot, -1);
                    }
                }
            },
            .block => |b| for (b) |*st| try self.stmt(st),
            .ret => |maybe| {
                if (maybe) |e| {
                    try self.expr(e);
                    try self.op(.ret, -1);
                } else try self.op(.ret_undef, 0);
            },
            .if_stmt => |f| {
                try self.expr(f.cond);
                const else_jmp = try self.op1(.jump_if_false, 0xffff, -1);
                try self.stmt(f.then);
                if (f.otherwise) |els| {
                    const end_jmp = try self.op1(.jump, 0xffff, 0);
                    self.chunk.patchJumpHere(else_jmp);
                    try self.stmt(els);
                    self.chunk.patchJumpHere(end_jmp);
                } else self.chunk.patchJumpHere(else_jmp);
            },
            .while_stmt => |w| {
                const top = self.chunk.here();
                var loop = Loop{};
                try self.loops.append(self.arena, &loop);
                try self.expr(w.cond);
                const exit = try self.op1(.jump_if_false, 0xffff, -1);
                try self.stmt(w.body);
                _ = try self.op1(.jump, top, 0);
                self.chunk.patchJumpHere(exit);
                for (loop.breaks.items) |b| self.chunk.patchJumpHere(b);
                for (loop.continues.items) |c| patchTo(self.chunk, c, top);
                _ = self.loops.pop();
            },
            .do_while_stmt => |w| {
                const top = self.chunk.here();
                var loop = Loop{};
                try self.loops.append(self.arena, &loop);
                try self.stmt(w.body);
                const cont = self.chunk.here();
                try self.expr(w.cond);
                _ = try self.op1(.jump_if_true, top, -1);
                for (loop.breaks.items) |b| self.chunk.patchJumpHere(b);
                for (loop.continues.items) |c| patchTo(self.chunk, c, cont);
                _ = self.loops.pop();
            },
            .for_stmt => |f| {
                if (f.init) |i| try self.stmt(i);
                const top = self.chunk.here();
                var loop = Loop{};
                try self.loops.append(self.arena, &loop);
                var exit: ?usize = null;
                if (f.cond) |c| {
                    try self.expr(c);
                    exit = try self.op1(.jump_if_false, 0xffff, -1);
                }
                try self.stmt(f.body);
                const cont = self.chunk.here();
                if (f.update) |u| {
                    try self.expr(u);
                    try self.op(.pop, -1);
                }
                _ = try self.op1(.jump, top, 0);
                if (exit) |e| self.chunk.patchJumpHere(e);
                for (loop.breaks.items) |b| self.chunk.patchJumpHere(b);
                for (loop.continues.items) |c| patchTo(self.chunk, c, cont);
                _ = self.loops.pop();
            },
            .break_stmt => |label| {
                if (label != null) return self.fail();
                const cur = self.loops.items.len;
                if (cur == 0) return self.fail();
                const at = try self.op1(.jump, 0xffff, 0);
                try self.loops.items[cur - 1].breaks.append(self.arena, at);
            },
            .continue_stmt => |label| {
                if (label != null) return self.fail();
                const cur = self.loops.items.len;
                if (cur == 0) return self.fail();
                const at = try self.op1(.jump, 0xffff, 0);
                try self.loops.items[cur - 1].continues.append(self.arena, at);
            },
            else => self.fail(),
        }
    }

    // ── expressions (each leaves exactly one value on the stack) ──
    fn expr(self: *Compiler, n: *const ast.Node) std.mem.Allocator.Error!void {
        if (!self.ok) return;
        switch (n.*) {
            .number => |x| try self.constOp(.{ .number = x }),
            .string => |x| try self.constOp(.{ .string = x }),
            .boolean => |b| try self.op(if (b) .load_true else .load_false, 1),
            .null => try self.op(.load_null, 1),
            .identifier => |name| {
                if (self.slotOf(name)) |s| {
                    _ = try self.op1(.load_slot, s, 1);
                } else {
                    const k = try self.chunk.addConst(self.arena, .{ .string = name });
                    _ = try self.op1(.load_global, k, 1);
                }
            },
            .binary => |b| {
                try self.expr(b.left);
                try self.expr(b.right);
                const o = binOp(b.op) orelse return self.fail();
                try self.op(o, -1);
            },
            .logical => |l| {
                if (l.op == .coalesce) return self.fail(); // `??` is null/undefined-based, not truthy
                try self.expr(l.left);
                // &&: if falsey keep+jump to end; ||: if truthy keep+jump to end.
                const keep: Op = if (l.op == .and_) .jump_if_false_keep else .jump_if_true_keep;
                const jmp = try self.op1(keep, 0xffff, -1); // pops on the fall-through path
                try self.expr(l.right);
                self.chunk.patchJumpHere(jmp);
            },
            .conditional => |c| {
                try self.expr(c.cond);
                const else_jmp = try self.op1(.jump_if_false, 0xffff, -1);
                try self.expr(c.then);
                const end_jmp = try self.op1(.jump, 0xffff, 0);
                self.chunk.patchJumpHere(else_jmp);
                self.depth -= 1; // both arms produce one value at the same height
                try self.expr(c.otherwise);
                self.chunk.patchJumpHere(end_jmp);
            },
            .unary => |u| {
                try self.expr(u.operand);
                switch (u.op) {
                    .not => try self.op(.not_, 0),
                    .minus => try self.op(.neg, 0),
                    .plus => try self.op(.pos, 0),
                    else => self.fail(),
                }
            },
            .assign => |a| {
                try self.expr(a.value);
                try self.op(.dup, 1); // leave the assigned value as the expression's result
                try self.storeName(a.name);
            },
            .compound_assign => |a| {
                if (a.target.* != .identifier) return self.fail();
                const name = a.target.identifier;
                try self.loadName(name);
                try self.expr(a.value);
                const o = binOp(a.op) orelse return self.fail();
                try self.op(o, -1);
                try self.op(.dup, 1);
                try self.storeName(name);
            },
            .call => |c| {
                if (c.callee.* == .member) {
                    // method call: keep `this` = the object
                    try self.expr(c.callee.member.object);
                    for (c.args) |arg| {
                        if (arg.* == .spread) return self.fail();
                        try self.expr(arg);
                    }
                    const k = try self.chunk.addConst(self.arena, .{ .string = c.callee.member.name });
                    // stack: obj, args...  → result. net: -(argc) (obj+args consumed, result pushed)
                    _ = try self.op2(.call_method, k, @intCast(c.args.len), -@as(i32, @intCast(c.args.len)));
                } else {
                    try self.expr(c.callee);
                    for (c.args) |arg| {
                        if (arg.* == .spread) return self.fail();
                        try self.expr(arg);
                    }
                    _ = try self.op1(.call, @intCast(c.args.len), -@as(i32, @intCast(c.args.len)) - 1 + 1);
                    // callee+args consumed, result pushed: net = -(argc+1)+1
                }
            },
            .member => |m| {
                try self.expr(m.object);
                const k = try self.chunk.addConst(self.arena, .{ .string = m.name });
                _ = try self.op1(.get_prop, k, 0);
            },
            .index => |ix| {
                try self.expr(ix.object);
                try self.expr(ix.key);
                try self.op(.get_index, -1);
            },
            else => self.fail(),
        }
    }

    fn op2(self: *Compiler, o: Op, a: u16, b: u16, delta: i32) std.mem.Allocator.Error!void {
        try self.chunk.emit(self.arena, o);
        try self.chunk.emitU16(self.arena, a);
        try self.chunk.emitU16(self.arena, b);
        self.adj(delta);
    }
    fn loadName(self: *Compiler, name: []const u8) std.mem.Allocator.Error!void {
        if (self.slotOf(name)) |s| {
            _ = try self.op1(.load_slot, s, 1);
        } else {
            const k = try self.chunk.addConst(self.arena, .{ .string = name });
            _ = try self.op1(.load_global, k, 1);
        }
    }
    fn storeName(self: *Compiler, name: []const u8) std.mem.Allocator.Error!void {
        if (self.slotOf(name)) |s| {
            _ = try self.op1(.store_slot, s, -1);
        } else {
            const k = try self.chunk.addConst(self.arena, .{ .string = name });
            _ = try self.op1(.store_global, k, -1);
        }
    }
};

fn patchTo(chunk: *Chunk, at: usize, target: u16) void {
    chunk.code.items[at] = @truncate(target & 0xff);
    chunk.code.items[at + 1] = @truncate(target >> 8);
}

fn binOp(o: ast.BinaryOp) ?Op {
    return switch (o) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .exp => .exp,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        .shl => .shl,
        .shr => .shr,
        .shr_un => .shr_un,
        .lt => .lt,
        .gt => .gt,
        .le => .le,
        .ge => .ge,
        .eq => .eq,
        .ne => .ne,
        .seq => .seq,
        .sne => .sne,
        else => null, // in_op / instanceof_ → fallback
    };
}

/// Compile a function `params` + `body` to a `Chunk`, or null if it uses anything outside the Phase 0
/// subset. `n_param_slots` (out) is how many leading slots are parameters (the caller binds args there).
pub fn compile(arena: std.mem.Allocator, params: []const ast.Param, body: []const ast.Stmt, n_param_slots: *u16) ?*Chunk {
    const chunk = arena.create(Chunk) catch return null;
    chunk.* = .{};
    var c = Compiler{ .arena = arena, .chunk = chunk };
    // Params: simple identifiers only, each a leading slot.
    for (params) |p| {
        if (p.default != null or p.pattern.* != .identifier) return null;
        _ = c.addSlot(p.pattern.identifier) catch return null;
    }
    n_param_slots.* = c.n_slots;
    for (body) |*st| {
        c.stmt(st) catch return null;
        if (!c.ok) return null;
    }
    if (!c.ok) return null;
    // Implicit `return undefined` at the end (a body that falls off the end).
    c.op(.ret_undef, 0) catch return null;
    chunk.n_slots = c.n_slots;
    chunk.max_stack = @intCast(@max(c.max_depth, 1));
    return chunk;
}

// ── tests ──────────────────────────────────────────────────────────────────────
const Parser = @import("parser.zig").Parser;
const builtins = @import("builtins.zig");
const Environment = @import("environment.zig").Environment;
const vm = @import("vm.zig");
const Interpreter = @import("interpreter.zig").Interpreter;

/// Compile `src` (a single top-level function declaration) + run it on the VM with `args`; assert the
/// numeric result. Validates the compiler+VM end-to-end against the tree-walk's own helpers.
fn expectVm(src: []const u8, args: []const Value, expected: f64) !void {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const global = try Environment.create(arena, null);
    try builtins.setup(arena, global);
    var gen_registry: std.ArrayListUnmanaged(*@import("object.zig").Generator) = .empty;
    var job_queue: std.ArrayListUnmanaged(@import("object.zig").Job) = .empty;
    var interp = Interpreter{ .arena = arena, .step_limit = std.math.maxInt(u64), .globals = global, .gen_registry = &gen_registry, .job_queue = &job_queue };

    const program = try Parser.parseMode(arena, src, false);
    // Expect the first statement to be a function declaration.
    const fdecl = program.statements[0].func_decl;
    var n_params: u16 = 0;
    const chunk = compile(arena, fdecl.params, fdecl.body, &n_params) orelse return error.CompileReturnedNull;

    const slots = try arena.alloc(Value, @max(chunk.n_slots, 1));
    for (slots) |*s| s.* = .undefined;
    for (args, 0..) |a, i| if (i < n_params) {
        slots[i] = a;
    };
    const c = try vm.run(&interp, chunk, slots, global);
    try std.testing.expect(c == .normal);
    try std.testing.expect(c.normal == .number);
    try std.testing.expectEqual(expected, c.normal.number);
}

test "vm: arithmetic + return" {
    try expectVm("function f(a, b){ return a * b + 1; }", &.{ .{ .number = 6 }, .{ .number = 7 } }, 43);
}
test "vm: while loop sum" {
    try expectVm("function f(n){ var s = 0; var i = 0; while (i < n) { s = s + i; i = i + 1; } return s; }", &.{.{ .number = 100 }}, 4950);
}
test "vm: for loop + if + compound assign" {
    try expectVm("function f(n){ var s = 0; for (var i = 0; i < n; i = i + 1) { if (i % 2 === 0) s += i; } return s; }", &.{.{ .number = 10 }}, 20);
}
test "vm: conditional + logical" {
    try expectVm("function f(a){ return (a > 0 && a < 10) ? a * 2 : -1; }", &.{.{ .number = 5 }}, 10);
}
