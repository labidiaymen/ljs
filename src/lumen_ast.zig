const types = @import("lumen_types.zig");

pub const FieldInit = struct { name: []const u8, value: *Expr };

pub const TypeField = struct { name: []const u8, annotation: []const u8, checked_type: ?types.Type = null };

pub const TypeDecl = struct {
    name: []const u8,
    fields: []TypeField,
    line: u32,
    col: u32,
};

pub const FunctionParam = struct {
    name: []const u8,
    annotation: []const u8,
    checked_type: ?types.Type = null,
};

pub const FunctionDecl = struct {
    name: []const u8,
    params: []FunctionParam,
    return_annotation: []const u8,
    checked_return_type: ?types.Type = null,
    body: []Stmt,
    line: u32,
    col: u32,
};

pub const VarDecl = struct {
    mutable: bool,
    name: []const u8,
    emit_name: ?[]const u8 = null,
    annotation: ?[]const u8,
    checked_type: ?types.Type = null,
    reassigned: bool = false,
    init: *Expr,
    line: u32,
    col: u32,
};

pub const Assign = struct {
    name: []const u8,
    emit_name: ?[]const u8 = null,
    value: *Expr,
    line: u32,
    col: u32,
};

pub const ConsoleLog = struct {
    value: *Expr,
    checked_type: ?types.Type = null,
    line: u32,
    col: u32,
};

pub const WhileStmt = struct {
    cond: *Expr,
    body: []Stmt,
    line: u32,
    col: u32,
};

pub const IfStmt = struct {
    cond: *Expr,
    then_body: []Stmt,
    else_body: ?[]Stmt = null,
    line: u32,
    col: u32,
};

pub const ExprStmt = struct {
    value: *Expr,
    line: u32,
    col: u32,
};

pub const ReturnStmt = struct {
    value: ?*Expr = null,
    checked_type: ?types.Type = null,
    line: u32,
    col: u32,
};

pub const ThrowStmt = struct {
    value: *Expr,
    line: u32,
    col: u32,
};

pub const TryStmt = struct {
    try_body: []Stmt,
    catch_name: []const u8,
    catch_emit_name: ?[]const u8 = null,
    catch_body: []Stmt,
    finally_body: ?[]Stmt = null,
    line: u32,
    col: u32,
};

pub const Stmt = union(enum) {
    type_decl: TypeDecl,
    function_decl: FunctionDecl,
    var_decl: VarDecl,
    assign: Assign,
    console_log: ConsoleLog,
    while_stmt: WhileStmt,
    if_stmt: IfStmt,
    return_stmt: ReturnStmt,
    throw_stmt: ThrowStmt,
    try_stmt: TryStmt,
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
    bool: bool,
    str: []const u8,
    array: []*Expr,
    var_ref: struct { name: []const u8, emit_name: ?[]const u8 = null },
    neg: *Expr,
    not: *Expr,
    bin: struct { op: u8, l: *Expr, r: *Expr, checked_type: ?types.Type = null }, // + - * / %
    bool_bin: struct { op: []const u8, l: *Expr, r: *Expr }, // && ||
    cmp: struct { op: []const u8, l: *Expr, r: *Expr, checked_operand_type: ?types.Type = null }, // < > <= >= == !=
    obj: []FieldInit,
    field: struct { obj: *Expr, name: []const u8, builtin: ?FieldBuiltin = null },
    index: struct { obj: *Expr, value: *Expr, checked_element_type: ?types.Type = null },
    call: struct { name: []const u8, args: []*Expr }, // builtin call, e.g. httpGet(url) / serve(port, body)
    static_call: struct { namespace: []const u8, name: []const u8, args: []*Expr, checked_type: ?types.Type = null },
};

pub const FieldBuiltin = enum {
    length,
    error_message,
};
