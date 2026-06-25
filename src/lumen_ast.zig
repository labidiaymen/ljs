pub const FieldInit = struct { name: []const u8, value: *Expr };

pub const TypeField = struct { name: []const u8, zty: []const u8 };

pub const TypeDecl = struct {
    name: []const u8,
    fields: []TypeField,
    line: u32,
    col: u32,
};

pub const VarDecl = struct {
    mutable: bool,
    name: []const u8,
    annotation: ?[]const u8,
    checked_type: ?[]const u8 = null,
    init: *Expr,
    line: u32,
    col: u32,
};

pub const Assign = struct {
    name: []const u8,
    value: *Expr,
    line: u32,
    col: u32,
};

pub const ConsoleLog = struct {
    value: *Expr,
    line: u32,
    col: u32,
};

pub const WhileStmt = struct {
    cond: *Expr,
    body: []Stmt,
    line: u32,
    col: u32,
};

pub const ExprStmt = struct {
    value: *Expr,
    line: u32,
    col: u32,
};

pub const Stmt = union(enum) {
    type_decl: TypeDecl,
    var_decl: VarDecl,
    assign: Assign,
    console_log: ConsoleLog,
    while_stmt: WhileStmt,
    expr_stmt: ExprStmt,
};

pub const Program = struct {
    stmts: []Stmt,
    uses_io: bool = false,
    needs_httpget: bool = false,
    needs_serve: bool = false,
};

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
