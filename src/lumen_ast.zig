const types = @import("lumen_types.zig");

pub const FieldInit = struct { name: []const u8, value: *Expr };

pub const TypeField = struct { name: []const u8, annotation: []const u8, checked_type: ?types.Type = null };

pub const EnumValue = union(enum) { int: i64, str: []const u8 };

pub const EnumMember = struct {
    name: []const u8,
    int_value: i64 = 0,
    str_value: ?[]const u8 = null,
};

pub const EnumDecl = struct {
    name: []const u8,
    is_string: bool = false,
    members: []EnumMember,
    line: u32,
    col: u32,
};

pub const TypeDecl = struct {
    name: []const u8,
    fields: []TypeField = &.{},
    string_literals: ?[][]const u8 = null,
    int_literals: ?[]i64 = null,
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

pub const DestructBinding = struct {
    name: []const u8,
    emit_name: ?[]const u8 = null,
    checked_type: ?types.Type = null,
};

pub const DestructureDecl = struct {
    mutable: bool,
    is_object: bool, // true: { x, y } from a record; false: [ a, b ] from an array
    bindings: []DestructBinding,
    source: *Expr,
    line: u32,
    col: u32,
};

pub const Assign = struct {
    name: []const u8,
    emit_name: ?[]const u8 = null,
    op: []const u8 = "=",
    value: *Expr,
    line: u32,
    col: u32,
};

pub const ConsoleLog = struct {
    method: []const u8 = "log",
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

pub const DoWhileStmt = struct {
    body: []Stmt,
    cond: *Expr,
    line: u32,
    col: u32,
};

pub const ForStmt = struct {
    init: VarDecl,
    cond: *Expr,
    update: Assign,
    body: []Stmt,
    line: u32,
    col: u32,
};

pub const ForOfStmt = struct {
    mutable: bool,
    binding: []const u8,
    binding_emit_name: ?[]const u8 = null,
    iterable: *Expr,
    iter_type: ?types.Type = null,
    elem_type: ?types.Type = null,
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

pub const SwitchCase = struct {
    value: *Expr,
    body: []Stmt,
    line: u32,
    col: u32,
};

pub const SwitchStmt = struct {
    value: *Expr,
    cases: []SwitchCase,
    default_body: ?[]Stmt = null,
    checked_type: ?types.Type = null,
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

pub const ControlStmt = struct {
    line: u32,
    col: u32,
};

pub const DeferStmt = struct {
    body: []Stmt,
    line: u32,
    col: u32,
};

pub const StaticCall = struct {
    namespace: []const u8,
    name: []const u8,
    args: []*Expr,
    checked_type: ?types.Type = null,
    checked_arg_type: ?types.Type = null,
};

pub const Stmt = union(enum) {
    type_decl: TypeDecl,
    enum_decl: EnumDecl,
    function_decl: FunctionDecl,
    var_decl: VarDecl,
    destructure_decl: DestructureDecl,
    assign: Assign,
    console_log: ConsoleLog,
    while_stmt: WhileStmt,
    do_while_stmt: DoWhileStmt,
    for_stmt: ForStmt,
    for_of_stmt: ForOfStmt,
    if_stmt: IfStmt,
    switch_stmt: SwitchStmt,
    return_stmt: ReturnStmt,
    throw_stmt: ThrowStmt,
    try_stmt: TryStmt,
    break_stmt: ControlStmt,
    continue_stmt: ControlStmt,
    defer_stmt: DeferStmt,
    expr_stmt: ExprStmt,
};

pub const Program = struct {
    stmts: []Stmt,
    uses_io: bool = false,
    needs_args: bool = false,
    needs_read_file_sync: bool = false,
    needs_httpget: bool = false,
    needs_serve: bool = false,
};

pub const Expr = union(enum) {
    num: i64,
    float: f64,
    bool: bool,
    str: []const u8,
    null_lit, // null / undefined
    array: []*Expr,
    var_ref: struct { name: []const u8, emit_name: ?[]const u8 = null, unwrap: bool = false, is_func_ref: bool = false },
    neg: *Expr,
    not: *Expr,
    bnot: *Expr, // bitwise ~
    bin: struct { op: u8, l: *Expr, r: *Expr, checked_type: ?types.Type = null }, // + - * / % & | ^ and L=<< R=>> P=**
    bool_bin: struct { op: []const u8, l: *Expr, r: *Expr }, // && ||
    cmp: struct { op: []const u8, l: *Expr, r: *Expr, checked_operand_type: ?types.Type = null }, // < > <= >= == !=
    ternary: struct { cond: *Expr, then_expr: *Expr, else_expr: *Expr },
    coalesce: struct { l: *Expr, r: *Expr }, // a ?? b
    arrow: *ArrowExpr, // (x: T) => expr
    template: []TemplatePart, // `text ${expr} ...`
    obj: []FieldInit,
    field: struct { obj: *Expr, name: []const u8, builtin: ?FieldBuiltin = null, enum_value: ?EnumValue = null, optional_chain: bool = false, chain_field_type: ?types.Type = null },
    index: struct { obj: *Expr, value: *Expr, checked_element_type: ?types.Type = null },
    call: struct { name: []const u8, args: []*Expr, emit_name: ?[]const u8 = null }, // builtin / user / function-value call
    static_call: StaticCall,
};

pub const FieldBuiltin = enum {
    length,
    error_message,
};

/// Arrow function expression `(x: T) => expr` (V1: typed params, expression
/// body, no capture of enclosing locals).
pub const ArrowExpr = struct {
    params: []FunctionParam,
    return_annotation: []const u8 = "",
    checked_return_type: ?types.Type = null,
    body_expr: *Expr,
};

/// One segment of a template literal: either literal `text` or an interpolated
/// `expr` (with its checked type filled in for formatting).
pub const TemplatePart = struct {
    text: ?[]const u8 = null,
    expr: ?*Expr = null,
    expr_type: ?types.Type = null,
};
