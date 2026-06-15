//! Abstract syntax tree. M1 adds statements (declarations, blocks) and the identifier /
//! assignment expressions on top of the M0 expression grammar (ECMA-262 §13–§14).
pub const UnaryOp = enum { plus, minus, not, typeof_, bit_not }; // §13.5

pub const LogicalOp = enum { or_, and_ }; // §13.13 (short-circuit)

pub const BinaryOp = enum {
    add, // §13.15 Additive
    sub,
    mul, // §13.7 Multiplicative
    div,
    mod,
    exp, // §13.6 Exponentiation (**), right-assoc
    bit_and, // §13.12 Binary bitwise
    bit_or,
    bit_xor,
    shl, // §13.9 Bitwise shift
    shr,
    shr_un,
    lt, // §13.10 Relational
    gt,
    le,
    ge,
    instanceof_, // §13.10.2
    in_op, // §13.10.2 (RelationalExpression `in`)
    eq, // §13.11 Equality (==)
    ne, // !=
    seq, // === (strict)
    sne, // !==
};

pub const Node = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
    null,
    identifier: []const u8, // §13.1 IdentifierReference
    unary: struct { op: UnaryOp, operand: *const Node },
    binary: struct { op: BinaryOp, left: *const Node, right: *const Node },
    assign: struct { name: []const u8, value: *const Node }, // §13.15 Assignment (identifier target)
    object_literal: []const Property, // §13.2.5  { k: v, ... }
    array_literal: []const *const Node, // §13.2.4  [ a, b, ... ]
    member: struct { object: *const Node, name: []const u8 }, // §13.3.2  a.b
    index: struct { object: *const Node, key: *const Node }, // §13.3.3  a[expr]
    assign_member: struct { object: *const Node, name: []const u8, value: *const Node }, // a.b = v
    assign_index: struct { object: *const Node, key: *const Node, value: *const Node }, // a[expr] = v
    function: *const Function, // §15.2 function expression
    call: struct { callee: *const Node, args: []const *const Node }, // §13.3.6 call
    new_expr: struct { callee: *const Node, args: []const *const Node }, // §13.3.5 new
    logical: struct { op: LogicalOp, left: *const Node, right: *const Node }, // §13.13
    conditional: struct { cond: *const Node, then: *const Node, otherwise: *const Node }, // §13.14 ?:
    update: struct { op: UpdateOp, prefix: bool, target: *const Node }, // §13.4 ++ / --
    template: struct { quasis: []const []const u8, exprs: []const *const Node }, // §13.2.8 `a${x}b`
    this, // §13.2.1 ThisExpression
};

pub const UpdateOp = enum { inc, dec };

pub const Property = struct { key: []const u8, value: *const Node };

pub const Function = struct {
    name: ?[]const u8,
    params: []const []const u8,
    body: []const Stmt,
};

pub const DeclKind = enum { var_decl, let_decl, const_decl };

pub const Declarator = struct { name: []const u8, init: ?*const Node };

pub const Stmt = union(enum) {
    expr: *const Node,
    declaration: struct { kind: DeclKind, decls: []const Declarator }, // §14.3
    block: []const Stmt, // §14.2
    func_decl: *const Function, // §15.2 function declaration
    ret: ?*const Node, // §14.10 return statement
    if_stmt: struct { cond: *const Node, then: *const Stmt, otherwise: ?*const Stmt }, // §14.6
    while_stmt: struct { cond: *const Node, body: *const Stmt }, // §14.7.3
    for_stmt: struct { init: ?*const Stmt, cond: ?*const Node, update: ?*const Node, body: *const Stmt }, // §14.7.4
    throw_stmt: *const Node, // §14.14
    try_stmt: struct { // §14.15
        block: []const Stmt,
        catch_param: ?[]const u8,
        catch_block: ?[]const Stmt,
        finally_block: ?[]const Stmt,
    },
    break_stmt, // §14.9
    continue_stmt, // §14.8
    switch_stmt: struct { discriminant: *const Node, cases: []const Case }, // §14.12
};

/// A `switch` case; `test_expr == null` for `default`.
pub const Case = struct { test_expr: ?*const Node, body: []const Stmt };

pub const Program = struct { statements: []const Stmt };
