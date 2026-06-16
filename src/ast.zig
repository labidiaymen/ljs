//! Abstract syntax tree. M1 adds statements (declarations, blocks) and the identifier /
//! assignment expressions on top of the M0 expression grammar (ECMA-262 §13–§14).
pub const UnaryOp = enum { plus, minus, not, typeof_, void_, delete_, bit_not }; // §13.5

pub const LogicalOp = enum { or_, and_, coalesce }; // §13.13 (short-circuit; `coalesce` = `??`)

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
    /// §13.16 Comma / sequence operator `a, b` — evaluate `left` (for side effects, discarding its
    /// value), then `right`, yielding `right`. Only produced where a full *Expression* is allowed
    /// (expression statements, parenthesized expressions, `for` clauses); NOT for the comma-separated
    /// AssignmentExpression lists of call args / array elements / params / declarators.
    comma: struct { left: *const Node, right: *const Node },
    binary: struct { op: BinaryOp, left: *const Node, right: *const Node },
    assign: struct { name: []const u8, value: *const Node }, // §13.15 Assignment (identifier target)
    /// §13.15.5 DestructuringAssignment — `[ … ] = expr` / `({ … } = expr)`. Cover grammar: `target`
    /// is the original `array_literal`/`object_literal` node, REFINED to an AssignmentPattern at parse
    /// time (validated assignable, CoverInitializedName allowed). The interpreter's `assignPattern`
    /// walks the literal node as a pattern, PUTting each value into an existing reference (identifier /
    /// member / index / nested pattern). The whole expression yields the RHS value.
    assign_pattern: struct { target: *const Node, value: *const Node },
    object_literal: []const Property, // §13.2.5  { k: v, ... }
    array_literal: []const *const Node, // §13.2.4  [ a, b, ... ]
    /// §13.2.4 Elision — an array-literal hole (`[a, , b]` / `[, x]`). As a literal element it
    /// evaluates to `undefined` (M-subset: no sparse model); as an AssignmentPattern element it is a
    /// skipped position. Only ever appears inside `array_literal` element lists.
    elision,
    member: struct { object: *const Node, name: []const u8 }, // §13.3.2  a.b
    index: struct { object: *const Node, key: *const Node }, // §13.3.3  a[expr]
    assign_member: struct { object: *const Node, name: []const u8, value: *const Node }, // a.b = v
    assign_index: struct { object: *const Node, key: *const Node, value: *const Node }, // a[expr] = v
    /// §13.15.2 LogicalAssignment `&&=` / `||=` / `??=`. Short-circuit: the reference is evaluated
    /// once, its current value read, and the guard (`op`) decides whether `value` is evaluated and
    /// written. `target` is the assignment target (identifier / member `a.b` / index `a[k]`); the
    /// interpreter destructures it to read-once / write-once without re-evaluating the base.
    logical_assign: struct { op: LogicalOp, target: *const Node, value: *const Node },
    function: *const Function, // §15.2 function expression
    call: struct { callee: *const Node, args: []const *const Node }, // §13.3.6 call
    new_expr: struct { callee: *const Node, args: []const *const Node }, // §13.3.5 new
    logical: struct { op: LogicalOp, left: *const Node, right: *const Node }, // §13.13
    conditional: struct { cond: *const Node, then: *const Node, otherwise: *const Node }, // §13.14 ?:
    update: struct { op: UpdateOp, prefix: bool, target: *const Node }, // §13.4 ++ / --
    template: struct { quasis: []const []const u8, exprs: []const *const Node }, // §13.2.8 `a${x}b`
    spread: *const Node, // §13.2.4 / §13.3 spread element `...expr` (in array literals & call args)
    this, // §13.2.1 ThisExpression
    class_expr: *const Class, // §15.7 ClassExpression
    /// §13.3.9 OptionalExpression — one access link of an optional chain applied to `base`.
    /// `optional` is true for the `?.` form (this link short-circuits when `base` is nullish);
    /// false for a plain `.`/`[]`/`()` that *follows* a `?.` in the same chain (it rides the chain
    /// so the short-circuit propagates, but does not itself test for nullish). If the base short-
    /// circuits, the WHOLE chain evaluates to `undefined` (§13.3.9.1, the `Return undefined` step).
    optional: struct { base: *const Node, optional: bool, link: OptionalLink },
    /// §13.3.7 SuperCall `super(args)` — only valid in a derived-class constructor. Calls the
    /// superclass constructor with the current `this` (parse-restricted to derived constructors).
    super_call: []const *const Node,
    /// §13.3.5 SuperProperty `super.name` / `super[key]` — looks up starting at the active method's
    /// [[HomeObject]].[[Prototype]], but reads/invokes with `this` = the current `this`. `name` is a
    /// static IdentifierName; `key` (non-null) is the computed `super[expr]` index. Parse-restricted
    /// to method bodies.
    super_member: struct { name: []const u8 = "", key: ?*const Node = null },
    /// §13.3.2 MemberExpression `.` PrivateIdentifier — a private member access `obj.#x`. `name`
    /// includes the leading `#`. Resolved against `object`'s per-instance private slot (§15.7); a
    /// missing brand is a runtime TypeError. Parse-restricted to class bodies.
    private_member: struct { object: *const Node, name: []const u8 },
    /// `obj.#x = v` — assignment to a private member. `name` includes the `#`.
    private_assign: struct { object: *const Node, name: []const u8, value: *const Node },
    /// §13.10.1 RelationalExpression PrivateIdentifier `in` ShiftExpression — the ergonomic brand
    /// check `#x in obj` → boolean (does `obj` carry the private name `#x`?). `name` includes the `#`.
    private_in: struct { name: []const u8, object: *const Node },
    /// §14.4 YieldExpression — `yield` / `yield AssignmentExpression` / `yield* AssignmentExpression`.
    /// Legal only inside a generator body (a parse-phase SyntaxError otherwise, §15.5.1). `argument` is
    /// null for a bare `yield` (yields `undefined`); `delegate` marks the `yield*` delegation form
    /// (§15.5.5 — parsed in Cycle 1, full delegation semantics deferred to Cycle 2). `yield` has very
    /// low precedence (just above the comma/sequence operator, below assignment).
    yield_expr: struct { argument: ?*const Node, delegate: bool },
};

/// One link of an optional chain: the access applied to the (non-nullish) base. `call` carries the
/// `(args)` form (may contain spread); `member`/`index` the property forms.
pub const OptionalLink = union(enum) {
    member: []const u8, // .name  /  ?.name
    index: *const Node, // [key]  /  ?.[key]
    call: []const *const Node, // (args)  /  ?.(args)
};

pub const UpdateOp = enum { inc, dec };

/// §13.2.5 PropertyDefinition. One entry of an object literal. The `kind` selects how `key`/`value`
/// are interpreted:
///   • `.init`  — `key: value` (also shorthand `{x}` and method `{m(){…}}`, both normalized here).
///   • `.get`/`.set` — an accessor; `value` is a `function` node (the getter/setter).
///   • `.spread` — `{...expr}`; `value` is the spread source, `key`/`computed_key` unused.
/// `computed_key` (non-null) is a `[expr]` computed property name, evaluated at construction; when
/// present it supersedes the static `key`.
pub const PropertyKind = enum { init, get, set, spread };

pub const Property = struct {
    kind: PropertyKind = .init,
    key: []const u8 = "",
    computed_key: ?*const Node = null, // §13.2.5 ComputedPropertyName `[expr]`
    value: *const Node,
    /// §13.2.5.1 CoverInitializedName `{x = default}` / `{k: t = default}` — the `= AssignmentExpression`
    /// is ONLY legal once the object literal is refined to an AssignmentPattern (§13.15.5). In a real
    /// object literal it is a SyntaxError; the parser records it here and the evaluator rejects a
    /// literal that still carries it. Applied (when the matched value is `undefined`) by `assignPattern`.
    default: ?*const Node = null,
};

/// §13.3.3 BindingPattern (also reused for parameter binding, §15.1). A `Pattern` is the LHS of a
/// destructuring binding. The common case — a plain identifier — stays `.identifier` so simple
/// declarations/params never pay the recursive matching cost (see interpreter fast paths).
pub const Pattern = union(enum) {
    identifier: []const u8, // §13.3.3 BindingIdentifier
    array: ArrayPattern, // §13.3.3 ArrayBindingPattern  `[a, , b = 1, ...rest]`
    object: ObjectPattern, // §13.3.3 ObjectBindingPattern `{x, y: a, z = 1, ...rest}`
};

/// One slot of an array binding pattern. `target == null` ⇒ an elision/hole (`[a, , b]`).
/// `default` is the `= expr` initializer applied when the matched value is `undefined`.
pub const BindingElement = struct {
    target: ?*const Pattern,
    default: ?*const Node = null,
};

pub const ArrayPattern = struct {
    elements: []const BindingElement, // holes carried as `.target == null`
    rest: ?*const Pattern = null, // §13.3.3 BindingRestElement `...rest`
};

/// One `key: target = default` property of an object binding pattern. `computed` keys are not yet
/// supported (deferred with object-literal computed keys); keys are identifier/string literals.
pub const ObjectBindingProperty = struct {
    key: []const u8,
    target: *const Pattern,
    default: ?*const Node = null,
};

pub const ObjectPattern = struct {
    properties: []const ObjectBindingProperty,
    rest: ?[]const u8 = null, // §14.3.3 BindingRestProperty `...rest` (identifier only)
};

/// A function/method parameter: a binding pattern plus an optional `= expr` default (§15.1).
pub const Param = struct {
    pattern: *const Pattern,
    default: ?*const Node = null,
};

pub const Function = struct {
    name: ?[]const u8,
    params: []const Param,
    rest: ?*const Pattern = null, // §15.1 rest parameter `...xs` (may itself be a pattern)
    body: []const Stmt,
    /// §15.3 ArrowFunction: arrows have lexical `this` (no own binding) and are not constructors.
    /// An expression-body arrow (`x => x + 1`) is normalized at parse time into a body holding a
    /// single `return expr` statement, so `body` is uniform across function kinds.
    is_arrow: bool = false,
    /// §15.5 GeneratorDeclaration / GeneratorExpression (`function* g(){}`). When set, calling the
    /// function object returns a §27.5 Generator object (it does NOT run the body) and `yield` is the
    /// §14.4 yield operator inside the body. Mutually exclusive with `is_arrow` (arrows can't be
    /// generators in the grammar).
    is_generator: bool = false,
};

/// §15.7 Class Definitions. A `Class` is the shared shape of a ClassDeclaration (statement) and a
/// ClassExpression (primary). `name` is the optional binding identifier; `superclass` is the optional
/// `extends LeftHandSideExpression` (parsed in Cycle 1, linked in Cycle 2); `elements` are the
/// ClassBody members in source order.
pub const Class = struct {
    name: ?[]const u8,
    superclass: ?*const Node = null, // §15.7 ClassHeritage `extends LHS` (link deferred to Cycle 2)
    elements: []const ClassElement,
};

/// §15.7 ClassElement kind. `constructor` is the special method that becomes the class's [[Call]]
/// body; `method` is a normal prototype/static method; `get`/`set` are accessors (Cycle 3);
/// `field` is an instance/static field with an optional initializer; `static_block` is a §15.7.11
/// ClassStaticBlock `static { … }` (Cycle 4), run once at class definition with `this` = the ctor.
pub const ClassElementKind = enum { constructor, method, get, set, field, static_block };

/// §15.7 One ClassBody member. A `method`/`get`/`set`/`constructor` carries `value.func`; a `field`
/// carries `value.field_init` (the optional `= expr`); a `static_block` carries `value.block`.
/// `is_static` selects the constructor object (static) vs the `.prototype` (instance). `computed_key`
/// (non-null) supersedes the static `key` (Cycle 3). `is_private` (Cycle 4) marks a PrivateName member
/// (`#x`): its `key` includes the leading `#` and it is installed in the per-instance private slot
/// (§15.7) rather than as an ordinary property — `computed_key` is always null for a private member.
pub const ClassElement = struct {
    kind: ClassElementKind,
    is_static: bool = false,
    is_private: bool = false,
    key: []const u8 = "",
    computed_key: ?*const Node = null,
    value: ClassElementValue,
};

pub const ClassElementValue = union(enum) {
    func: *const Function, // method / accessor / constructor body
    field_init: ?*const Node, // §15.7 FieldDefinition initializer (`x = init` / bare `x`)
    block: []const Stmt, // §15.7.11 ClassStaticBlock body (static_block only)
};

pub const DeclKind = enum { var_decl, let_decl, const_decl };

/// §14.7.5 ForIn/ForOf head — the binding side of `for (HEAD in/of EXPR)`. Either a `var`/`let`/`const`
/// declaration of a single ForBinding (`.decl`), or an existing assignment target expression — a plain
/// identifier, a member `a.b`, or an index `a[k]` (`.target`). `bindForHead` in the interpreter writes
/// each enumerated name (for-in) / iterated value (for-of) to whichever shape this is.
pub const ForHead = union(enum) {
    decl: struct { kind: DeclKind, target: *const Pattern }, // §14.7.5 ForBinding
    target: *const Node, // an AssignmentTarget (identifier / member / index)
};

/// §14.3 LexicalBinding / VariableDeclaration. `target` is a binding pattern (commonly a single
/// identifier); `init` is the optional `= expr` initializer.
pub const Declarator = struct { target: *const Pattern, init: ?*const Node };

pub const Stmt = union(enum) {
    expr: *const Node,
    declaration: struct { kind: DeclKind, decls: []const Declarator }, // §14.3
    block: []const Stmt, // §14.2
    func_decl: *const Function, // §15.2 function declaration
    class_decl: *const Class, // §15.7 ClassDeclaration
    ret: ?*const Node, // §14.10 return statement
    if_stmt: struct { cond: *const Node, then: *const Stmt, otherwise: ?*const Stmt }, // §14.6
    while_stmt: struct { cond: *const Node, body: *const Stmt }, // §14.7.3
    for_stmt: struct { init: ?*const Stmt, cond: ?*const Node, update: ?*const Node, body: *const Stmt }, // §14.7.4
    /// §14.7.5 `for (HEAD in EXPR) BODY` — enumerate the enumerable string-keyed property names of EXPR
    /// and its prototype chain (each once), binding each to HEAD. A null/undefined EXPR runs the body 0×.
    for_in_stmt: struct { head: ForHead, right: *const Node, body: *const Stmt },
    /// §14.7.5 `for (HEAD of EXPR) BODY` — iterate the values of the iterable EXPR (Array elements /
    /// String chars in this M-subset), binding each to HEAD. A non-iterable EXPR is a TypeError.
    for_of_stmt: struct { head: ForHead, right: *const Node, body: *const Stmt },
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
