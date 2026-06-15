//! Abstract syntax tree for the M0 expression grammar. Nodes are arena-allocated; child
//! pointers reference nodes in the same arena. Maps to ECMA-262 §13 (Expressions).
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
    unary: struct { op: UnaryOp, operand: *const Node },
    binary: struct { op: BinaryOp, left: *const Node, right: *const Node },
};

/// A program is a sequence of expression statements (M0 has no other statement kinds).
pub const Program = struct {
    statements: []const *const Node,
};
