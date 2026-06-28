const types = @import("lumen_types.zig");

/// An object-literal entry. A normal field has a `name`; a spread entry
/// (`{...src}`) has `is_spread = true`, `name = ""`, and `value` is the source.
pub const FieldInit = struct { name: []const u8, value: *Expr, is_spread: bool = false };

pub const Visibility = enum { public, private, protected };

pub const TypeField = struct {
    name: []const u8,
    annotation: []const u8,
    checked_type: ?types.Type = null,
    visibility: Visibility = .public,
    is_static: bool = false,
    is_readonly: bool = false,
};

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
    // `type X = <annotation>;` — an alias over an existing spellable type.
    alias: ?[]const u8 = null,
    // `type U = A | B | C;` — a discriminated union over named record variants.
    union_variants: ?[][]const u8 = null,
    // Type parameters for a generic interface/type alias, e.g. `Pair<A, B>`.
    // When non-empty the declaration is a template specialized on use.
    type_params: [][]const u8 = &.{},
    line: u32,
    col: u32,
};

pub const FunctionParam = struct {
    name: []const u8,
    annotation: []const u8,
    checked_type: ?types.Type = null,
    // `...rest: T[]` — collects trailing arguments into an array. The annotation
    // names the array type; `checked_type` holds the array type.
    is_rest: bool = false,
    // `x: T = expr` — default value used when the call omits this trailing arg.
    default: ?*Expr = null,
};

/// `extern function name(params): ret;` — an external C-ABI function. No body;
/// resolved at link time. Params/return are restricted to C-safe scalar types.
pub const ExternDecl = struct {
    name: []const u8,
    params: []FunctionParam,
    return_annotation: []const u8,
    checked_return_type: ?types.Type = null,
    line: u32,
    col: u32,
};

pub const ClassDecl = struct {
    name: []const u8,
    fields: []TypeField,
    has_ctor: bool = false,
    ctor_params: []FunctionParam = &.{},
    ctor_body: []Stmt = &.{},
    methods: []FunctionDecl = &.{},
    // Single-inheritance parent class name from `extends Parent`.
    parent: ?[]const u8 = null,
    // Interface names from `implements I, J`.
    implements: [][]const u8 = &.{},
    // Type parameters for a generic class, e.g. `Box<T>`. When non-empty the
    // class is a template; concrete copies are generated per `new C<...>`.
    type_params: [][]const u8 = &.{},
    line: u32,
    col: u32,
};

/// Field/property write. When `obj` is null this is `this.field = value` inside a
/// method/constructor; otherwise it is `obj.field = value` (instance field,
/// static field, or setter property) from anywhere.
pub const MemberAssign = struct {
    field: []const u8,
    op: []const u8 = "=",
    value: *Expr,
    obj: ?*Expr = null,
    // Filled by the checker for emission routing.
    class_name: ?[]const u8 = null,
    is_static: bool = false,
    is_setter: bool = false,
    line: u32,
    col: u32,
};

pub const Accessor = enum { none, getter, setter };

pub const FunctionDecl = struct {
    name: []const u8,
    params: []FunctionParam,
    return_annotation: []const u8,
    checked_return_type: ?types.Type = null,
    body: []Stmt,
    // Class-member modifiers (unused for free functions).
    visibility: Visibility = .public,
    is_static: bool = false,
    accessor: Accessor = .none,
    // `async function ...` — the declared return type must be `Promise<T>`; a
    // `return v;` resolves the promise with `v`.
    is_async: bool = false,
    // Type parameters for a generic function, e.g. `f<T, U>`. When non-empty the
    // function is a template; concrete copies are generated per call instance.
    type_params: [][]const u8 = &.{},
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

pub const TestDecl = struct {
    name: []const u8,
    body: []Stmt,
    line: u32,
    col: u32,
};

/// `super(args);` — invoke the parent constructor. Only valid as the first
/// statement of a child constructor. `parent` is filled by the checker.
pub const SuperCtor = struct {
    args: []*Expr,
    parent: ?[]const u8 = null,
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
    test_decl: TestDecl,
    extern_decl: ExternDecl,
    class_decl: ClassDecl,
    function_decl: FunctionDecl,
    var_decl: VarDecl,
    destructure_decl: DestructureDecl,
    member_assign: MemberAssign,
    super_ctor: SuperCtor,
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
    needs_map: bool = false,
    needs_set: bool = false,
    // Async/await: emit the event-loop + Promise runtime and drain the loop in main.
    needs_async: bool = false,
};

pub const Expr = union(enum) {
    num: i64,
    float: f64,
    bool: bool,
    str: []const u8,
    null_lit, // null / undefined
    array: struct { items: []*Expr, elem_type: ?types.Type = null }, // `[a, b, ...rest]`; elem_type is filled by the checker when a spread element is present
    spread: *Expr, // `...expr` element inside an array literal or call argument list
    tuple_lit: struct { items: []*Expr, tuple_type: ?types.Type = null }, // [a, b] checked against a tuple type
    var_ref: struct { name: []const u8, emit_name: ?[]const u8 = null, unwrap: bool = false, is_func_ref: bool = false, capture: bool = false, func_sig: ?*const types.FuncSig = null },
    neg: *Expr,
    not: *Expr,
    bnot: *Expr, // bitwise ~
    await_expr: *Expr, // `await <expr>` — operand is a Promise<T>; yields T
    bin: struct { op: u8, l: *Expr, r: *Expr, checked_type: ?types.Type = null }, // + - * / % & | ^ and L=<< R=>> P=**
    bool_bin: struct { op: []const u8, l: *Expr, r: *Expr }, // && ||
    cmp: struct { op: []const u8, l: *Expr, r: *Expr, checked_operand_type: ?types.Type = null }, // < > <= >= == !=
    ternary: struct { cond: *Expr, then_expr: *Expr, else_expr: *Expr },
    coalesce: struct { l: *Expr, r: *Expr }, // a ?? b
    arrow: *ArrowExpr, // (x: T) => expr
    this_expr, // `this` inside a method/constructor
    super_call: struct { name: []const u8, args: []*Expr, parent: ?[]const u8 = null }, // super.m(args)
    new_expr: struct { class_name: []const u8, args: []*Expr, type_args: [][]const u8 = &.{}, container_type: ?types.Type = null }, // new C(args) / new C<T>(args) / new Map/Set<...>()
    method_call: struct { obj: *Expr, name: []const u8, args: []*Expr, class_name: ?[]const u8 = null, is_static: bool = false, array_elem_type: ?types.Type = null, array_acc_type: ?types.Type = null, array_result_type: ?types.Type = null, string_method: bool = false, container_type: ?types.Type = null }, // obj.m(args) / Class.m(args) / Map|Set method
    template: []TemplatePart, // `text ${expr} ...`
    obj: []FieldInit,
    field: struct { obj: *Expr, name: []const u8, builtin: ?FieldBuiltin = null, enum_value: ?EnumValue = null, optional_chain: bool = false, chain_field_type: ?types.Type = null, class_name: ?[]const u8 = null, is_static: bool = false, is_getter: bool = false },
    index: struct { obj: *Expr, value: *Expr, checked_element_type: ?types.Type = null, tuple_index: ?usize = null },
    call: struct { name: []const u8, args: []*Expr, emit_name: ?[]const u8 = null, is_closure: bool = false, type_args: [][]const u8 = &.{}, ffi_string_args: []bool = &.{}, ffi_string_return: bool = false }, // builtin / user / function-value call; type_args from explicit f<T>(...). ffi_* mark a call to an `extern function` so the FFI string marshalling glue is emitted.
    static_call: StaticCall,
    cast: struct { inner: *Expr, annotation: []const u8, checked_type: ?types.Type = null }, // `expr as T` (safe-subset assertion; erased at emit)
};

pub const FieldBuiltin = enum {
    length,
    error_message,
    container_size,
};

/// A variable captured by a closure: stored by its outer emit-name in a heap
/// environment struct.
pub const Capture = struct { emit_name: []const u8, ty: types.Type };

/// Arrow function expression `(x: T) => expr` (V1: typed params, expression
/// body; may capture enclosing locals by value into a heap environment).
pub const ArrowExpr = struct {
    params: []FunctionParam,
    return_annotation: []const u8 = "",
    checked_return_type: ?types.Type = null,
    body_expr: *Expr,
    captures: []Capture = &.{},
};

/// One segment of a template literal: either literal `text` or an interpolated
/// `expr` (with its checked type filled in for formatting).
pub const TemplatePart = struct {
    text: ?[]const u8 = null,
    expr: ?*Expr = null,
    expr_type: ?types.Type = null,
};
