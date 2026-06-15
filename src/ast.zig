//! Abstract syntax tree. M1 adds statements (declarations, blocks) and the identifier /
//! assignment expressions on top of the M0 expression grammar (ECMA-262 §13–§14).
pub const UnaryOp = enum { plus, minus, not };

pub const BinaryOp = enum {
    add, // §13.15 Additive
    sub,
    mul, // §13.7 Multiplicative
    div,
    mod,
    lt, // §13.10 Relational
    gt,
    le,
    ge,
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
    member: struct { object: *const Node, name: []const u8 }, // §13.3.2  a.b
    index: struct { object: *const Node, key: *const Node }, // §13.3.3  a[expr]
    assign_member: struct { object: *const Node, name: []const u8, value: *const Node }, // a.b = v
    assign_index: struct { object: *const Node, key: *const Node, value: *const Node }, // a[expr] = v
    function: *const Function, // §15.2 function expression
    call: struct { callee: *const Node, args: []const *const Node }, // §13.3.6 call
    this, // §13.2.1 ThisExpression
};

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
};

pub const Program = struct { statements: []const Stmt };
