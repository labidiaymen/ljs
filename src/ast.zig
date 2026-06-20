//! Abstract syntax tree. M1 adds statements (declarations, blocks) and the identifier /
//! assignment expressions on top of the M0 expression grammar (ECMA-262 §13–§14).
const std = @import("std");

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
    /// §12.9.3.2 BigIntLiteral — the value parsed at lex/parse time, arena-owned (immutable `Const`).
    bigint: *const std.math.big.int.Const,
    string: []const u8,
    boolean: bool,
    null,
    /// §13.2.7 RegularExpressionLiteral `/pattern/flags` — evaluated to a fresh RegExp object.
    regex_literal: struct { pattern: []const u8, flags: []const u8 },
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
    /// §13.15.2 compound AssignmentExpression `target op= value` (arithmetic/bitwise/string `op`, NOT
    /// the logical forms). Like `logical_assign`, the reference (`target`: identifier / member `a.b` /
    /// index `a[k]` / private `a.#x`) is evaluated ONCE — base + key coerced a single time — then the
    /// current value is read, combined with `value` via `op`, and written back. Kept intact (rather than
    /// desugared to `t = t op v`) so a side-effecting base/key expression runs exactly once (§13.15.2).
    compound_assign: struct { op: BinaryOp, target: *const Node, value: *const Node },
    function: *const Function, // §15.2 function expression
    call: struct { callee: *const Node, args: []const *const Node }, // §13.3.6 call
    /// §13.3.10 ImportCall — the dynamic `import( specifier [, options] )` expression. `specifier`
    /// is the AssignmentExpression first argument; `options` (non-null) is the optional second
    /// argument (import options / attributes object). ImportCall is a CallExpression but NOT a
    /// NewExpression target and NOT a simple assignment target (the parser enforces both). With no
    /// module loader, the interpreter ToString-es the specifier and returns a Promise rejected with
    /// a TypeError (a throwing ToString rejects the promise instead).
    import_call: struct { specifier: *const Node, options: ?*const Node },
    new_expr: struct { callee: *const Node, args: []const *const Node }, // §13.3.5 new
    logical: struct { op: LogicalOp, left: *const Node, right: *const Node }, // §13.13
    conditional: struct { cond: *const Node, then: *const Node, otherwise: *const Node }, // §13.14 ?:
    update: struct { op: UpdateOp, prefix: bool, target: *const Node }, // §13.4 ++ / --
    /// §13.2.8 TemplateLiteral `a${x}b`. `quasis` are the COOKED (TV) string segments (one more than
    /// `exprs`); `raw` are the matching TRV raw segments (§12.9.6). For an UNTAGGED template a cooked
    /// segment is always present; for a TAGGED template a quasi whose escape sequence was illegal has
    /// `cooked = null` (§12.9.6.1 — the array slot becomes `undefined`), so cooked segments are
    /// `?[]const u8`. Untagged evaluation never sees a null (the parser rejects an invalid escape in a
    /// non-tagged template as a SyntaxError); only `GetTemplateObject` reads `null` as `undefined`.
    template: struct { quasis: []const ?[]const u8, raw: []const []const u8, exprs: []const *const Node }, // §13.2.8 `a${x}b`
    /// §13.2.8.3 TaggedTemplate `tag\`a${x}b\``. `tag` is the function being applied; `quasi` is the
    /// `.template` node it is applied to (its AST identity is the §13.2.8.3 cache key — the same source
    /// site yields the SAME frozen template object on every evaluation within a realm).
    tagged_template: struct { tag: *const Node, quasi: *const Node },
    spread: *const Node, // §13.2.4 / §13.3 spread element `...expr` (in array literals & call args)
    this, // §13.2.1 ThisExpression
    /// §13.3.12 NewTarget MetaProperty `new` `.` `target` — evaluates to the active function's
    /// [[NewTarget]]: the constructor when the function was invoked via `new` (or through a `super()`
    /// chain), else `undefined`. An arrow inherits its enclosing non-arrow function's value (lexical,
    /// like `this`). A SyntaxError outside any function body (parse-restricted to function contexts).
    new_target,
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
    /// §13.3.5/§6.2.5.6 `super.name = v` / `super[key] = v` — a plain assignment whose SuperProperty
    /// reference is written with `this` as the receiver. `key` (non-null) is the computed index.
    super_assign: struct { name: []const u8 = "", key: ?*const Node = null, value: *const Node },
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
    /// §15.8 AwaitExpression — `await UnaryExpression`. Legal only inside an async function / async
    /// arrow / async method body (a parse-phase SyntaxError otherwise, §15.8.1). Parses at the
    /// UnaryExpression precedence level (like a prefix unary operator). At runtime (§27.7.5.3, M11
    /// Cycle 2) it suspends the async body via the generator thread substrate and resumes on the
    /// awaited value's settlement (a fulfill/reject reaction Job on PromiseResolve(value)).
    await_expr: *const Node,
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
    /// §B.3.1 `__proto__` Property Names in Object Initializers — set iff this is a `.init` colon
    /// property whose LITERAL (non-computed) PropertyName is `__proto__` (`{__proto__: v}` or
    /// `{"__proto__": v}`). Such a property sets the object's [[Prototype]] (when `v` is Object or
    /// null) instead of creating an own `__proto__` property; a primitive `v` is ignored. A computed
    /// `{["__proto__"]: v}`, a shorthand `{__proto__}`, or a method `{__proto__(){}}` is NOT this (it
    /// is an ordinary own property). Two such colon-properties in one literal is a §B.3.1 Early Error.
    is_proto: bool = false,
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

/// One `key: target = default` property of an object binding pattern. `key` is the static
/// PropertyName (identifier / string / ToString'd numeric literal). For a ComputedPropertyName
/// `{ [expr]: target }`, `computed` holds the key expression — evaluated (ToPropertyKey) at bind
/// time — and `key` is unused (empty).
pub const ObjectBindingProperty = struct {
    key: []const u8,
    target: *const Pattern,
    default: ?*const Node = null,
    computed: ?*const Node = null,
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
    /// §15.8 AsyncFunctionDeclaration / AsyncFunctionExpression / async arrow / async method
    /// (`async function f(){}`, `async () => …`, `async m(){}`). When set, `await` is the §15.8
    /// operator inside the body. May combine with `is_generator` (§15.6 AsyncGeneratorDeclaration
    /// `async function* g(){}`, where both `await` and `yield` are operators) and with `is_arrow`
    /// (async arrows). At runtime (M11 Cycle 2) calling it returns a Promise and runs the body on the
    /// generator thread substrate, suspending at each `await` (§27.7).
    is_async: bool = false,
    /// §15.4 MethodDefinition (class/object method, getter, setter, async method) — a function created
    /// via DefineMethod / OrdinaryFunctionCreate with `kind: method`. Per §10.2.5 MakeMethod such a
    /// function is NOT a constructor and gets NO own `prototype` property — EXCEPT a *generator* or
    /// *async-generator* method, which (being a GeneratorFunction) still receives its generator
    /// `prototype`. Plain function declarations/expressions and class constructors leave this false.
    is_method: bool = false,
    /// §11.2.2 strict-mode flag for THIS function's body: true if the body inherits strictness from an
    /// enclosing strict scope, carries its own `"use strict"` directive prologue, or is a class member
    /// (class bodies are always strict). Computed at parse time. The interpreter restores its runtime
    /// strict state to this value around the body so §6.2.5.6 PutValue to an unresolved name throws
    /// ReferenceError (strict) versus creating a global property (sloppy).
    strict: bool = false,
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

/// §14.3 declaration kind. `using_decl` / `await_using_decl` (§14.3.1 Explicit Resource Management)
/// are block-scoped like `let`, but each declarator's initialized value is also registered as a
/// DisposableResource on the enclosing scope's dispose stack: at scope exit its `[@@dispose]`
/// (`await using`: `[@@asyncDispose]`) is invoked in reverse declaration order (§ER DisposeResources).
pub const DeclKind = enum { var_decl, let_decl, const_decl, using_decl, await_using_decl };

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
    /// §14.7.2 `do Statement while ( Expression ) ;` — the body runs first, then the condition is
    /// tested and the loop repeats while it is truthy. The body always executes at least once.
    do_while_stmt: struct { cond: *const Node, body: *const Stmt },
    for_stmt: struct { init: ?*const Stmt, cond: ?*const Node, update: ?*const Node, body: *const Stmt }, // §14.7.4
    /// §14.7.5 `for (HEAD in EXPR) BODY` — enumerate the enumerable string-keyed property names of EXPR
    /// and its prototype chain (each once), binding each to HEAD. A null/undefined EXPR runs the body 0×.
    for_in_stmt: struct { head: ForHead, right: *const Node, body: *const Stmt },
    /// §14.7.5 `for (HEAD of EXPR) BODY` — iterate the values of the iterable EXPR (Array elements /
    /// String chars in this M-subset), binding each to HEAD. A non-iterable EXPR is a TypeError.
    /// `is_await` marks a `for await (HEAD of EXPR) BODY` (§14.7.5.6 ForIn/OfBodyEvaluation with the
    /// `async` iteration hint): GetIterator(EXPR, async), and each step `await`s `iterator.next()` and
    /// the value. Legal only in an async context (the parser rejects it otherwise).
    for_of_stmt: struct { head: ForHead, right: *const Node, body: *const Stmt, is_await: bool = false },
    throw_stmt: *const Node, // §14.14
    try_stmt: struct { // §14.15
        block: []const Stmt,
        catch_param: ?*const Pattern, // §14.15 CatchParameter — BindingIdentifier or BindingPattern
        catch_block: ?[]const Stmt,
        finally_block: ?[]const Stmt,
    },
    /// §14.9 BreakStatement `break [LabelIdentifier] ;` — `label` is null for an unlabeled break
    /// (targets the innermost iteration/switch), or the target label name otherwise.
    break_stmt: ?[]const u8,
    /// §14.8 ContinueStatement `continue [LabelIdentifier] ;` — `label` is null for an unlabeled
    /// continue (targets the innermost iteration), or the target loop's label name otherwise.
    continue_stmt: ?[]const u8,
    switch_stmt: struct { discriminant: *const Node, cases: []const Case }, // §14.12
    with_stmt: struct { object: *const Node, body: *const Stmt }, // §14.11 WithStatement (sloppy-only)
    /// §14.13 LabelledStatement `LabelIdentifier : Statement`. `label` is the label name; `body` is
    /// the labelled statement. A labelled iteration statement is the target of `break label` /
    /// `continue label`; any other labelled statement is the target of `break label` only. Multiple
    /// labels (`a: b: stmt`) nest as `labeled_stmt{ a, labeled_stmt{ b, stmt } }`.
    labeled_stmt: struct { label: []const u8, body: *const Stmt },
};

/// A `switch` case; `test_expr == null` for `default`.
pub const Case = struct { test_expr: ?*const Node, body: []const Stmt };

/// §16.2.2 ImportEntry Record — one binding introduced by an ImportDeclaration. `module_request`
/// is the specifier string. `import_name` is the name imported from the source module: `"*"` for a
/// namespace import (`import * as ns from "m"`), `"default"` for a default import, or a named
/// export. `local_name` is the binding introduced in the importing module's environment.
pub const ImportEntry = struct {
    module_request: []const u8,
    import_name: []const u8, // exported name in the source module, or "*"
    local_name: []const u8, // binding name in this module
};

/// §16.2.3 ExportEntry Record. Covers every export form:
///   • local export   `export {x}` / `export let x` / `export default …` →
///         `export_name` set, `local_name` set, `module_request`/`import_name` null.
///   • indirect export `export {x as y} from "m"` →
///         `export_name`+`import_name` set, `module_request` set, `local_name` null.
///   • star export     `export * from "m"` →
///         `module_request` set, `import_name == "*"`, `export_name` null (re-export all names).
///   • namespace export `export * as ns from "m"` →
///         `export_name` set, `import_name == "*"`, `module_request` set, `local_name` null.
pub const ExportEntry = struct {
    export_name: ?[]const u8 = null,
    module_request: ?[]const u8 = null,
    import_name: ?[]const u8 = null,
    local_name: ?[]const u8 = null,
};

/// §11.2.2: a Script is strict if it carries a `"use strict"` directive prologue (or the runner runs
/// it in strict `RunMode`). The interpreter reads this to gate runtime strict-mode semantics — most
/// notably §9.1.1.4.16 SetMutableBinding / §6.2.5.6 PutValue: an assignment to an unresolved name
/// CREATES a global property in sloppy code but throws ReferenceError in strict code.
///
/// §16.2.1.6 A Module additionally carries `is_module = true`, its ImportEntries / ExportEntries, and
/// the de-duplicated RequestedModules list (specifiers, in source order). These are empty for a
/// Script. The body `statements` hold the executable ModuleItems (an `export let x = 1` lowers to a
/// plain `declaration` stmt PLUS an export entry; an `export default <expr>` to a synthetic binding).
pub const Program = struct {
    statements: []const Stmt,
    strict: bool = false,
    is_module: bool = false,
    import_entries: []const ImportEntry = &.{},
    export_entries: []const ExportEntry = &.{},
    requested_modules: []const []const u8 = &.{},
    /// §16.2.1.6 [[HasTLA]] — true iff the module body contains a top-level AwaitExpression (`await`
    /// outside any nested function), a `for await`, or an `await using`. Such a module evaluates
    /// asynchronously (§16.2.1.6 ExecuteAsyncModule). Always false for a Script.
    has_top_level_await: bool = false,
};
