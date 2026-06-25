pub const FieldInit = struct { name: []const u8, value: *Expr };

pub const Expr = union(enum) {
    num: i64,
    str: []const u8,
    var_ref: []const u8,
    neg: *Expr,
    bin: struct { op: u8, l: *Expr, r: *Expr }, // + - * / %
    cmp: struct { op: []const u8, l: *Expr, r: *Expr }, // < > <= >= == !=
    obj: []FieldInit,
    field: struct { obj: *Expr, name: []const u8 },
    call: struct { name: []const u8, args: []*Expr }, // builtin call, e.g. httpGet(url) / serve(port, body)
};
