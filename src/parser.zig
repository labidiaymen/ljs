//! Recursive-descent / precedence-climbing parser (ECMA-262 §13–§14). M1 adds statements
//! (declarations, blocks, expression statements) and identifier / assignment expressions.
//! Reports SyntaxError on malformed input (the parse-phase error for negative Test262 cases).
const std = @import("std");
const ast = @import("ast.zig");
const lex = @import("lexer.zig");
const parse_validate = @import("parse_validate.zig");
const parse_expr = @import("parse_expr.zig");
const parse_class = @import("parse_class.zig");

pub const ParseError = error{ UnexpectedToken, UnexpectedEof } || lex.LexError;

/// DIAGNOSTICS: the lexeme of the token the parser was at when it last failed. Captured in
/// `parseProgram`'s error unwind (single site — `self.idx` points at the offending token). The lexeme
/// is a slice INTO the original source, so the engine derives the byte offset (and thus line:col) from
/// its pointer. Process-global is fine (parsing is single-threaded; read only right after a failed parse).
pub var last_error_lexeme: []const u8 = "";

/// 1-based line/column for `pos` in `src` (for SyntaxError messages).
pub fn lineColOf(src: []const u8, pos: usize) struct { line: usize, col: usize } {
    var line: usize = 1;
    var col: usize = 1;
    const end = @min(pos, src.len);
    var i: usize = 0;
    while (i < end) : (i += 1) {
        if (src[i] == '\n') {
            line += 1;
            col = 1;
        } else col += 1;
    }
    return .{ .line = line, .col = col };
}

// ── Aliases for early-error / scope-validation helpers extracted to parse_validate.zig.
// Keeps every retained call site (`isEvalOrArguments(…)`, `validateScope(…)`, …) unchanged.
const isEvalOrArguments = parse_validate.isEvalOrArguments;
const isEscapedReservedIdent = parse_validate.isEscapedReservedIdent;
const isStrictReservedBindingName = parse_validate.isStrictReservedBindingName;
const patternHasStrictReserved = parse_validate.patternHasStrictReserved;
const isSimpleAssignTarget = parse_validate.isSimpleAssignTarget;
const paramsHaveStrictReserved = parse_validate.paramsHaveStrictReserved;
const paramsHaveYield = parse_validate.paramsHaveYield;
const bodyVarDeclaresName = parse_validate.bodyVarDeclaresName;
const isSimpleParameterList = parse_validate.isSimpleParameterList;
const hasDuplicateBoundNames = parse_validate.hasDuplicateBoundNames;
const paramsConflictWithBodyLexical = parse_validate.paramsConflictWithBodyLexical;
const isIdentifierNameToken = parse_validate.isIdentifierNameToken;
const isValidBindingName = parse_validate.isValidBindingName;
const boundDeclNames = parse_validate.boundDeclNames;
const bodyHasUseStrict = parse_validate.bodyHasUseStrict;
const validateScope = parse_validate.validateScope;
const directivePrologueIsStrict = parse_validate.directivePrologueIsStrict;
const isKeywordName = parse_validate.isKeywordName;
const NameSet = parse_validate.NameSet;

pub const Parser = struct {
    tokens: []const lex.Token,
    idx: usize = 0,
    arena: std.mem.Allocator,
    /// The full source text (spec 119): a token's lexeme points into it, so a node's byte offset for
    /// stack traces is `lexeme.ptr - source.ptr`. Empty for sub-parsers (template substitutions).
    source: []const u8 = "",
    /// §13.13.1 mixing check: set true when the most recently parsed *operand* was a parenthesized
    /// expression `( … )`. Parentheses make `a ?? (b || c)` legal where `a ?? b || c` is not, but a
    /// parenthesized expression's AST node is indistinguishable from its content — so we record the
    /// paren here at parse time and consult it in `parseShortCircuit`.
    last_was_paren: bool = false,
    /// §11.2.2 strict-mode context. True once the enclosing Script/FunctionBody is strict (an
    /// explicit `"use strict"` directive prologue) — and, per the lexical-inheritance rule, stays
    /// true for every nested function/arrow/method body (strict-ness is never un-set going inward).
    /// Gates the §13.x strict-only Early Errors (reserved BindingIdentifiers, `delete` of a bare
    /// reference, `eval`/`arguments` assignment targets, duplicate params in normal functions).
    /// Saved/restored around each function body in `parseFunction`/`finishArrow`/method parsing.
    strict: bool = false,

    /// §13.3.5 SuperProperty context: true while parsing a method/accessor/constructor body (a
    /// MethodDefinition has a [[HomeObject]]). `super.x` / `super[x]` is a SyntaxError outside one
    /// (§15.7.1 / a SuperProperty must appear within a method). Saved/restored around every function
    /// body; an ordinary FunctionDeclaration/Expression/arrow resets it to false (it has no home).
    in_method: bool = false,
    /// §13.3.7 SuperCall context: true only inside a DERIVED class constructor (a constructor of a
    /// class with an `extends` heritage). `super(...)` is a SyntaxError anywhere else — including a
    /// non-derived constructor and any non-constructor method. Saved/restored like `in_method`.
    in_derived_ctor: bool = false,
    /// §13.3.12 NewTarget context: true while parsing inside any function body (ordinary function,
    /// method / accessor / constructor, async, generator, and — by lexical inheritance — arrow bodies)
    /// or a class static initialization block. The MetaProperty `new.target` is a §13.3.12.1 SyntaxError
    /// outside such a context (e.g. at Script top level). Set true around every non-arrow function body
    /// and static block; arrows deliberately leave it as-is so they inherit it lexically (like `this`).
    in_function: bool = false,
    /// §15.7 PrivateName context: true while parsing anything lexically inside a ClassBody (any
    /// nesting). A PrivateIdentifier (`#x`) — as a member access `obj.#x` or the brand check
    /// `#x in obj` — is a SyntaxError outside a class body. Set true around a ClassBody and inherited
    /// by nested functions/arrows; never un-set going inward, mirroring `strict`.
    in_class_body: bool = false,
    /// §15.7.1 AllPrivateNamesValid — the declared PrivateName names (`#x`, `#` included) of all
    /// enclosing ClassBodies. A `#x` reference (member access / `#x in`) must be a member of this set
    /// or it is a SyntaxError. Each class body pre-scans its PrivateBoundNames and appends them on
    /// entry (so a method may forward-reference a private name declared later in the same body),
    /// truncating back on exit. A flat list across nesting is sufficient — validity only needs union
    /// membership. Empty outside any class (so a `#x` outside a class is rejected by `in_class_body`).
    private_names: std.ArrayListUnmanaged([]const u8) = .empty,
    /// §15.7.11: inside a ClassStaticBlock body, `await` is a reserved word — it may not be used as a
    /// BindingIdentifier or IdentifierReference (`class await {}`, `({ await })`, …). True only
    /// directly within a static block; a nested ordinary function/arrow body un-reserves it (reset in
    /// `parseFunction`/`finishArrow`, like `in_method`).
    in_static_block: bool = false,
    /// §15.5 `[+Yield]` grammar parameter: true while parsing a generator FunctionBody. Inside one,
    /// `yield` is the §14.4 yield operator (not an IdentifierReference) and `yield` as a
    /// BindingIdentifier is a §15.5.1 SyntaxError; outside one, `yield` outside strict mode is an
    /// ordinary identifier and a `yield` operator is a SyntaxError. Saved/restored around every function
    /// body (`parseFunction`/`finishArrow`); an ordinary function/arrow un-sets it (yield does NOT cross
    /// into a nested non-generator), a `function*` sets it.
    in_generator: bool = false,
    /// §15.8 `[+Await]` grammar parameter: true while parsing an async function / async arrow / async
    /// method body. Inside one, `await` is the §15.8 AwaitExpression operator (not an
    /// IdentifierReference) and `await` as a BindingIdentifier is a §15.8.1 SyntaxError; outside one,
    /// `await` is an ordinary identifier (sloppy) and an `await` operator is a SyntaxError. Saved/
    /// restored around every function body (`parseFunction`/`finishArrow`/method parsing); an ordinary
    /// (non-async) function/arrow un-sets it (await does NOT cross into a nested non-async function),
    /// an `async function`/`async (…) =>`/`async m(){}` sets it. May coexist with `in_generator` for
    /// async generators (`async function* g(){}`), where both operators are live in the body.
    in_async: bool = false,
    /// §14.7.5 `[~In]` grammar: while parsing the FIRST clause of a `for (…)` header, the relational
    /// `in` operator is suppressed so `for (a in b)` is recognized as a for-in head (not the binary
    /// expression `a in b`). Honored in `parseExprFrom` (skips `kw_in` at the relational level). Reset
    /// to false inside any nested parenthesis/bracket/brace so `for ((a in b);;)` and `for (a[b in c];;)`
    /// keep `in` as a normal operator. Set only around `parseFor`'s first-clause parse.
    no_in: bool = false,

    /// §16.2 module goal: true while parsing a Module (set by `parseModule`). Module code is always
    /// strict (handled via `strict`), `import`/`export` declarations are legal at the top level only,
    /// and the import/export entry accumulators below are live. False for a Script (the common path,
    /// and the entire bench corpus) — module-item parsing is never reached.
    is_module: bool = false,
    /// §16.2.2 / §16.2.3 entry accumulators — populated by `parseImportDeclaration` /
    /// `parseExportDeclaration` while parsing module items; folded into the `Program` by `parseModule`.
    import_entries: std.ArrayListUnmanaged(ast.ImportEntry) = .empty,
    export_entries: std.ArrayListUnmanaged(ast.ExportEntry) = .empty,
    requested_modules: std.ArrayListUnmanaged([]const u8) = .empty,
    /// §16.2.1.6 [[HasTLA]]: set true when an AwaitExpression is parsed at MODULE top level (the module
    /// goal `in_async` is set AND we are NOT inside a nested function — `in_function` false). Drives the
    /// interpreter's async module-evaluation path. Never set for a Script (no module-goal `in_async`).
    saw_top_level_await: bool = false,

    /// §13.2.5.1 CoverInitializedName obligation counter. An object/array literal `{x = d}` / `[a = d]`
    /// records a `= default` that is ONLY legal once the literal is refined to an AssignmentPattern
    /// (§13.15.5) or a BindingPattern. Each recorded default increments this; `validateAssignmentPattern`
    /// discharges one per default it legitimizes. After a statement (or a directive-prologue expression)
    /// is fully parsed, a non-zero residue means an un-refined CoverInitializedName escaped as a real
    /// value (`({x = 1});`, `f({a = 1})`) — a §13.2.5.1 SyntaxError. Snapshotted/checked in `parseStmt`.
    cover_init: usize = 0,

    /// §B.3.1 duplicate-`__proto__` obligation counter (the inverse of `cover_init`). A SECOND
    /// `__proto__:` colon-property in an object literal is a §B.3.1 Early Error ONLY when the literal
    /// is a real ObjectLiteral value; it is ALLOWED once the literal is refined to an ObjectAssignment
    /// pattern (§13.15.1 — "this does not apply to Object Assignment patterns"). Like `cover_init`, the
    /// duplicate is recorded here at parse time and DISCHARGED by `validateAssignmentPattern` upon
    /// refinement; a non-zero residue at statement end means it escaped as a real value (a SyntaxError).
    proto_dup: usize = 0,

    /// §14.13.1 / §14.8.1 / §14.9.1 label & control-flow scope tracking (parse-phase Early Errors).
    /// `labels` is the set of LabelIdentifier names currently in scope (the enclosing
    /// LabelledStatements); a `break label` is a SyntaxError unless `label` ∈ `labels`. A subset,
    /// `iteration_labels`, holds only those labels that (transitively, through a chain of labels)
    /// label an *iteration* statement; a `continue label` is a SyntaxError unless `label` ∈
    /// `iteration_labels` (continuing to a non-loop label is illegal). `iteration_depth` / `switch_depth`
    /// count enclosing iteration / switch statements for unlabeled `break`/`continue` validity. All four
    /// are reset to empty/zero on entry to a function/arrow/method body (labels and the iteration nest
    /// do NOT cross a function boundary) and restored on exit.
    labels: std.ArrayListUnmanaged([]const u8) = .empty,
    iteration_labels: std.ArrayListUnmanaged([]const u8) = .empty,
    iteration_depth: usize = 0,
    switch_depth: usize = 0,

    /// §14.3.1.1 Explicit Resource Management Early Error: a UsingDeclaration is a Syntax Error in the
    /// Script goal unless contained (directly/indirectly) within a Block, ForStatement, ForInOfStatement,
    /// FunctionBody, GeneratorBody, AsyncGeneratorBody, AsyncFunctionBody, ClassStaticBlockBody, or
    /// ClassBody. We only parse the Script goal (module tests are skipped by the runner), so the rule
    /// reduces to "not at the top level of the Program statement list": this is `false` while parsing
    /// the Program's top-level StatementList and `true` once inside any Block / for-header / function
    /// body / static block. (`switch` case/default clauses are NOT in the allow-list — `using` there is
    /// a Syntax Error even inside a block-bearing switch — but a `{}`-wrapped clause body re-allows it.)
    using_allowed: bool = false,

    /// §12.9.6.1 / §13.2.8.3: set by `parseTemplate` when a TemplateLiteral it just parsed contained a
    /// NotEscapeSequence (an illegal escape, so a cooked segment is `null`). An UNTAGGED template with
    /// an illegal escape is a SyntaxError; a TAGGED template tolerates it (cooked → `undefined`). The
    /// `.template` primary checks-and-clears this flag and rejects when the template was not tagged
    /// (the tagged path consumes the `.template` token in `continuePostfix`, bypassing the check).
    template_invalid_escape: bool = false,

    pub const ParamList = struct { params: []const ast.Param, rest: ?*const ast.Pattern };
    pub const PropName = struct { key: []const u8, computed: ?*const ast.Node = null, is_ident: bool = false, had_escape: bool = false };

    /// `mode == .strict` starts the whole Script in strict context (the Test262 runner runs each
    /// test in both modes, expecting the engine to honor `RunMode`). An explicit `"use strict"`
    /// directive prologue is detected independently in `parseProgram`.
    pub fn parse(arena: std.mem.Allocator, src: []const u8) ParseError!ast.Program {
        return parseMode(arena, src, false);
    }

    pub fn parseMode(arena: std.mem.Allocator, src: []const u8, strict: bool) ParseError!ast.Program {
        var lexer = lex.Lexer.init(arena, src);
        var toks: std.ArrayList(lex.Token) = .empty;
        while (true) {
            const t = try lexer.next();
            try toks.append(arena, t);
            if (t.kind == .eof) break;
        }
        var p = Parser{ .tokens = toks.items, .arena = arena, .strict = strict, .source = src };
        return p.parseProgram();
    }

    /// §19.2.1.1 PerformEval context for a DIRECT eval: the eval code is a CONTINUATION of the
    /// caller's running context, so its body may legally use `super.x`/`super(...)` (when the caller is
    /// inside a method / derived constructor), `new.target` (inside any function), private references
    /// (inside a class body — `private_names` lists the visible spellings), and `await`/`yield` per the
    /// caller's goal. Seeded from the interpreter's current execution context; all false/empty for an
    /// indirect eval (which runs as fresh global code). `super(...)` is additionally gated on the eval
    /// not crossing a function boundary, matching §13.3.7.1 — captured here as `in_derived_ctor`.
    pub const EvalContext = struct {
        in_function: bool = false,
        in_method: bool = false,
        in_derived_ctor: bool = false,
        in_class_body: bool = false,
        in_generator: bool = false,
        in_async: bool = false,
        private_names: []const []const u8 = &.{},
    };

    /// §19.2.1.1 parse direct-eval source, seeding the §13.x lexical-context Early-Error flags from the
    /// caller's running execution context so `super`/`new.target`/private references that are legal in
    /// the surrounding method/class body are accepted in the eval code too.
    pub fn parseEvalMode(arena: std.mem.Allocator, src: []const u8, strict: bool, ctx: EvalContext) ParseError!ast.Program {
        var lexer = lex.Lexer.init(arena, src);
        var toks: std.ArrayList(lex.Token) = .empty;
        while (true) {
            const t = try lexer.next();
            try toks.append(arena, t);
            if (t.kind == .eof) break;
        }
        var p = Parser{ .tokens = toks.items, .arena = arena, .strict = strict, .source = src };
        p.in_function = ctx.in_function;
        p.in_method = ctx.in_method;
        p.in_derived_ctor = ctx.in_derived_ctor;
        p.in_class_body = ctx.in_class_body;
        p.in_generator = ctx.in_generator;
        p.in_async = ctx.in_async;
        for (ctx.private_names) |pn| try p.private_names.append(arena, pn);
        return p.parseProgram();
    }

    /// §16.2 parse the source text as a Module (the module goal). Module code is always strict
    /// (§11.2.2), `import`/`export` declarations are permitted at the top level, and the top-level
    /// `this` is undefined / `new.target` & `super` are restricted at runtime. Returns a `Program`
    /// with `is_module = true` plus its ImportEntries / ExportEntries / RequestedModules.
    pub fn parseModule(arena: std.mem.Allocator, src: []const u8) ParseError!ast.Program {
        var lexer = lex.Lexer.init(arena, src);
        var toks: std.ArrayList(lex.Token) = .empty;
        while (true) {
            const t = try lexer.next();
            try toks.append(arena, t);
            if (t.kind == .eof) break;
        }
        // §16.2.1.5: a Module's top-level code is `ModuleItem : StatementListItem[~Yield, +Await,
        // ~Return]`. The `[+Await]` means `await` at module top level is the §15.8 AwaitExpression
        // operator (top-level await), not an IdentifierReference, and `await` may not be a
        // BindingIdentifier. Reuse the `in_async` flag (which already gates the await operator in
        // `parseUnary`, rejects `await` bindings, and is reset across nested non-async functions so
        // `await` does NOT propagate into them, per §16.2.1.6 / the `early-does-not-propagate` tests).
        var p = Parser{ .tokens = toks.items, .arena = arena, .strict = true, .is_module = true, .in_async = true, .source = src };
        return p.parseModuleProgram();
    }

    pub fn peek(self: *Parser) lex.Token {
        return self.tokens[self.idx];
    }

    /// Byte offset of `tok` within `source` (spec 119), via its lexeme pointer. 0 when unknown (no
    /// source, a decoded lexeme not pointing into source, or out of range) — a benign "no position".
    pub fn tokenOffset(self: *const Parser, tok: lex.Token) u32 {
        if (self.source.len == 0 or tok.lexeme.len == 0) return 0;
        const base = @intFromPtr(self.source.ptr);
        const p = @intFromPtr(tok.lexeme.ptr);
        if (p < base or (p - base) > self.source.len) return 0;
        return @intCast(p - base);
    }

    pub fn advance(self: *Parser) lex.Token {
        const t = self.tokens[self.idx];
        if (self.idx + 1 < self.tokens.len) self.idx += 1;
        return t;
    }

    pub fn expect(self: *Parser, kind: lex.TokenKind) ParseError!lex.Token {
        if (self.peek().kind != kind) return ParseError.UnexpectedToken;
        return self.advance();
    }

    pub fn alloc(self: *Parser, node: ast.Node) ParseError!*const ast.Node {
        const p = try self.arena.create(ast.Node);
        p.* = node;
        return p;
    }

    pub fn allocStmt(self: *Parser, stmt: ast.Stmt) ParseError!*const ast.Stmt {
        const p = try self.arena.create(ast.Stmt);
        p.* = stmt;
        return p;
    }

    pub fn allocPattern(self: *Parser, pat: ast.Pattern) ParseError!*const ast.Pattern {
        const p = try self.arena.create(ast.Pattern);
        p.* = pat;
        return p;
    }

    /// §14.7.5 `[~In]` reset: any bracketed sub-expression (`( … )`, `[ … ]`, call args, array/object
    /// literal contents, `${ … }`) is `[+In]` — the relational `in` is a normal operator there even
    /// inside a for-header's first clause. These wrappers clear `no_in` for the inner parse and restore
    /// it, so `for ((a in b);;)` / `for (a[b in c];;)` keep `in` while `for (a in b)` is a for-in head.
    pub fn parseAssignmentInBrackets(self: *Parser) ParseError!*const ast.Node {
        const saved = self.no_in;
        self.no_in = false;
        defer self.no_in = saved;
        return self.parseAssignment();
    }

    pub fn parseExpressionInBrackets(self: *Parser) ParseError!*const ast.Node {
        const saved = self.no_in;
        self.no_in = false;
        defer self.no_in = saved;
        return self.parseExpression();
    }

    /// §13.3.3 BindingPattern — a binding identifier, an ArrayBindingPattern `[ … ]`, or an
    /// ObjectBindingPattern `{ … }`. Used by both declarations (§14.3) and parameters (§15.1).
    pub fn parsePattern(self: *Parser) ParseError!*const ast.Pattern {
        switch (self.peek().kind) {
            .lbracket => return self.parseArrayPattern(),
            .lbrace => return self.parseObjectPattern(),
            .identifier => {
                // §12.7.1: an escaped §12.7.2 ReservedWord is not a valid BindingIdentifier.
                if (isEscapedReservedIdent(self.peek())) return ParseError.UnexpectedToken;
                // §15.7.11: `await` is reserved as a BindingIdentifier inside a static block.
                if (self.in_static_block and std.mem.eql(u8, self.peek().lexeme, "await")) return ParseError.UnexpectedToken;
                // §15.8.1: inside an async body `await` may not be a BindingIdentifier (`var await`,
                // `let [await]`, a destructuring target `[await]`). (Params parse `~Await`, so a param
                // `await` is rejected separately via `paramsHaveAwait`; this catches body declarations.)
                if (self.in_async and std.mem.eql(u8, self.peek().lexeme, "await")) return ParseError.UnexpectedToken;
                // §15.5.1: inside a generator body `yield` may not be a BindingIdentifier
                // (`var yield`, `function* g(){ var yield }`, a destructuring target `[yield]`).
                if (self.in_generator and std.mem.eql(u8, self.peek().lexeme, "yield")) return ParseError.UnexpectedToken;
                return self.allocPattern(.{ .identifier = self.advance().lexeme });
            },
            else => return ParseError.UnexpectedToken,
        }
    }

    /// §13.3.3 ArrayBindingPattern `[a, , b = 1, ...rest]` — elisions are holes, each element may
    /// carry a `= default`, and an optional trailing `...rest` (itself a pattern).
    pub fn parseArrayPattern(self: *Parser) ParseError!*const ast.Pattern {
        _ = try self.expect(.lbracket);
        var elements: std.ArrayList(ast.BindingElement) = .empty;
        var rest: ?*const ast.Pattern = null;
        while (self.peek().kind != .rbracket and self.peek().kind != .eof) {
            if (self.peek().kind == .comma) { // elision / hole — no target
                _ = self.advance();
                try elements.append(self.arena, .{ .target = null, .default = null });
                continue;
            }
            if (self.peek().kind == .ellipsis) { // §13.3.3 BindingRestElement (must be last)
                _ = self.advance();
                rest = try self.parsePattern();
                break;
            }
            const target = try self.parsePattern();
            var default: ?*const ast.Node = null;
            if (self.peek().kind == .assign) {
                _ = self.advance();
                default = try self.parseAssignment();
            }
            try elements.append(self.arena, .{ .target = target, .default = default });
            if (self.peek().kind == .comma) {
                _ = self.advance();
                continue;
            }
            break;
        }
        _ = try self.expect(.rbracket);
        return self.allocPattern(.{ .array = .{ .elements = elements.items, .rest = rest } });
    }

    /// §13.3.3 / §14.3.3 ObjectBindingPattern `{x, y: a, z = 1, ...rest}` — shorthand `{x}` binds
    /// `x`, `key: target` renames, `= default` applies when the property is undefined, and an
    /// optional `...rest` (identifier) collects the remaining own enumerable properties.
    pub fn parseObjectPattern(self: *Parser) ParseError!*const ast.Pattern {
        _ = try self.expect(.lbrace);
        var props: std.ArrayList(ast.ObjectBindingProperty) = .empty;
        var rest: ?[]const u8 = null;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            if (self.peek().kind == .ellipsis) { // §14.3.3 BindingRestProperty (must be last)
                _ = self.advance();
                const rt = try self.expect(.identifier);
                // §12.7.1: a BindingRestProperty target is a BindingIdentifier — reject escaped reserved.
                if (isEscapedReservedIdent(rt)) return ParseError.UnexpectedToken;
                rest = rt.lexeme;
                break;
            }
            // §14.3.3 BindingProperty: a PropertyName (identifier / string / numeric / `[computed]`)
            // followed by `: BindingElement`, OR a shorthand SingleNameBinding (a bare
            // BindingIdentifier). A computed / string / numeric name has no shorthand form — it MUST
            // carry a `:`. The shorthand key doubles as the BindingIdentifier.
            const kt = self.peek();
            const pn = try self.parsePropertyName();
            var computed: ?*const ast.Node = null;
            const target: *const ast.Pattern = if (self.peek().kind == .colon) blk: {
                // `key: target` (renaming / nested) — `key` is an IdentifierName (escaped reserved OK)
                // or a ComputedPropertyName evaluated at bind time.
                _ = self.advance();
                computed = pn.computed;
                break :blk try self.parsePattern();
            } else blk: {
                // shorthand `{x}` — only a plain identifier PropertyName has this form; a string /
                // numeric / computed name without `:` is a SyntaxError.
                if (!pn.is_ident) return ParseError.UnexpectedToken;
                // §12.7.1: an escaped §12.7.2 ReservedWord (`{ with }`) is not a valid BindingIdentifier.
                if (isEscapedReservedIdent(kt)) return ParseError.UnexpectedToken;
                break :blk try self.allocPattern(.{ .identifier = pn.key });
            };
            var default: ?*const ast.Node = null;
            if (self.peek().kind == .assign) {
                _ = self.advance();
                default = try self.parseAssignment();
            }
            try props.append(self.arena, .{ .key = pn.key, .target = target, .default = default, .computed = computed });
            if (self.peek().kind == .comma) {
                _ = self.advance();
                continue;
            }
            break;
        }
        _ = try self.expect(.rbrace);
        return self.allocPattern(.{ .object = .{ .properties = props.items, .rest = rest } });
    }

    /// §13.2.8 / §12.9.6 Template literal: split the raw inner text (between the back-ticks, with
    /// `${ … }` substitutions kept raw) into per-segment COOKED (TV) and RAW (TRV) strings plus the
    /// sub-parsed substitution Expressions. `quasis.len == raw.len == exprs.len + 1`.
    ///
    /// A cooked segment is `null` when the segment contains a NotEscapeSequence (illegal escape, e.g.
    /// `\x`/`\u`/legacy-octal). For an UNTAGGED template that is a §12.9.6.1 Early Error (SyntaxError):
    /// `parsePrimary` checks `template_invalid_escape` and rejects. For a TAGGED template the null is
    /// kept and surfaces as `undefined` in the template object (§13.2.8.3). The RAW segment is the
    /// verbatim source with line terminators normalized to <LF> (§12.9.6 TRV: <CR> / <CR><LF> → <LF>).
    pub fn parseTemplate(self: *Parser, raw: []const u8) ParseError!*const ast.Node {
        var quasis: std.ArrayList(?[]const u8) = .empty;
        var raws: std.ArrayList([]const u8) = .empty;
        var exprs: std.ArrayList(*const ast.Node) = .empty;
        var cooked: std.ArrayList(u8) = .empty;
        var raw_seg: std.ArrayList(u8) = .empty;
        var cooked_ok = true; // becomes false once a NotEscapeSequence is seen in THIS segment
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                // §12.9.6 TemplateCharacter escape: shares §12.9.4.1 Character/Hex/Unicode escapes with
                // string literals (UTF-8-encoded), plus `\0` NUL and LineContinuation; templates FORBID
                // legacy octal / `\8` / `\9` (a NotEscapeSequence → cooked = undefined). Find the end of
                // this one escape (up to the next backslash / `${` / end) and decode the slice.
                var j = i + 2;
                while (j < raw.len and raw[j] != '\\' and !(raw[j] == '$' and j + 1 < raw.len and raw[j + 1] == '{')) j += 1;
                // TRV: the raw segment keeps the escape verbatim (line terminators normalized below).
                appendRawNormalized(self, &raw_seg, raw[i..j]) catch return ParseError.OutOfMemory;
                if (cooked_ok) {
                    lex.Lexer.decodeEscapesInto(self.arena, &cooked, raw[i..j], true) catch |e| switch (e) {
                        error.OutOfMemory => return ParseError.OutOfMemory,
                        else => {
                            // §12.9.6.1 NotEscapeSequence → no cooked value for this segment.
                            cooked_ok = false;
                            self.template_invalid_escape = true;
                        },
                    };
                }
                i = j;
                continue;
            }
            if (raw[i] == '$' and i + 1 < raw.len and raw[i + 1] == '{') {
                try quasis.append(self.arena, if (cooked_ok) cooked.items else null);
                try raws.append(self.arena, raw_seg.items);
                cooked = .empty;
                raw_seg = .empty;
                cooked_ok = true;
                i += 2;
                const expr_start = i;
                var depth: usize = 1;
                // The previous significant (non-space) char, to disambiguate a `/` regex from division.
                // Seed with '(' so a leading `/` in the interpolation is read as a RegExp.
                var prev: u8 = '(';
                while (i < raw.len and depth > 0) {
                    const ch = raw[i];
                    // Skip string / template literals so braces/slashes INSIDE them aren't counted (e.g.
                    // `${'(\\d{1,'}`). A naive scan mismatches on an unbalanced brace inside a string.
                    if (ch == '\'' or ch == '"' or ch == '`') {
                        i += 1;
                        while (i < raw.len) : (i += 1) {
                            if (raw[i] == '\\') {
                                i += 1; // skip the escaped char
                                continue;
                            }
                            if (raw[i] == ch) break;
                        }
                        i += 1; // past the closing quote
                        prev = ch;
                        continue;
                    }
                    // Skip comments and RegExp literals so quotes/braces inside them aren't counted
                    // (e.g. `${x.replace(/"/g, '\\"')}` in webpack — a `/.../` whose body holds a quote).
                    if (ch == '/' and i + 1 < raw.len) {
                        const n = raw[i + 1];
                        if (n == '/') { // line comment
                            i += 2;
                            while (i < raw.len and raw[i] != '\n') i += 1;
                            continue;
                        }
                        if (n == '*') { // block comment
                            i += 2;
                            while (i + 1 < raw.len and !(raw[i] == '*' and raw[i + 1] == '/')) i += 1;
                            i += 2;
                            continue;
                        }
                        // RegExp iff the previous significant char does not end a value (else it's division).
                        const ends_value = (prev >= 'a' and prev <= 'z') or (prev >= 'A' and prev <= 'Z') or
                            (prev >= '0' and prev <= '9') or prev == '_' or prev == '$' or
                            prev == ')' or prev == ']' or prev == '}';
                        if (!ends_value) {
                            i += 1;
                            var in_class = false;
                            while (i < raw.len) : (i += 1) {
                                const rc = raw[i];
                                if (rc == '\\') {
                                    i += 1; // escaped char (e.g. `\/`) — never ends the body
                                    continue;
                                }
                                if (rc == '[') in_class = true else if (rc == ']') in_class = false else if (rc == '/' and !in_class) break;
                            }
                            i += 1; // past the closing '/'
                            while (i < raw.len and ((raw[i] >= 'a' and raw[i] <= 'z') or (raw[i] >= 'A' and raw[i] <= 'Z'))) i += 1; // flags
                            prev = '/';
                            continue;
                        }
                    }
                    if (ch == '{') depth += 1 else if (ch == '}') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                    if (ch != ' ' and ch != '\t' and ch != '\n' and ch != '\r') prev = ch;
                    i += 1;
                }
                const node = try self.parseSubstitution(raw[expr_start..i]);
                try exprs.append(self.arena, node);
                i += 1; // skip closing }
                continue;
            }
            // §12.9.6 TRV/TV LineTerminatorSequence normalization: a raw <CR> or <CR><LF> in the
            // source becomes a single <LF> in BOTH the cooked and raw segment.
            if (raw[i] == '\r') {
                try cooked.append(self.arena, '\n');
                try raw_seg.append(self.arena, '\n');
                i += if (i + 1 < raw.len and raw[i + 1] == '\n') 2 else 1;
                continue;
            }
            try cooked.append(self.arena, raw[i]);
            try raw_seg.append(self.arena, raw[i]);
            i += 1;
        }
        try quasis.append(self.arena, if (cooked_ok) cooked.items else null);
        try raws.append(self.arena, raw_seg.items);
        return self.alloc(.{ .template = .{ .quasis = quasis.items, .raw = raws.items, .exprs = exprs.items } });
    }

    /// §12.9.6 append `src` to a TRV raw segment, normalizing a <CR> / <CR><LF> LineTerminatorSequence
    /// to a single <LF> (so a `\`-LineContinuation's raw value is `\\` + `\n`, per the spec).
    fn appendRawNormalized(self: *Parser, out: *std.ArrayList(u8), src: []const u8) std.mem.Allocator.Error!void {
        var k: usize = 0;
        while (k < src.len) {
            if (src[k] == '\r') {
                try out.append(self.arena, '\n');
                k += if (k + 1 < src.len and src[k + 1] == '\n') 2 else 1;
                continue;
            }
            try out.append(self.arena, src[k]);
            k += 1;
        }
    }

    /// §13.2.8 sub-parse the source of a `${ Expression }` substitution. The inner text is an
    /// Expression (NOT a Program / StatementList), so a leading `function`/`class`/`{` is the start of
    /// an expression (`${ function(){}() }`, `${ {a:1} }`), never a declaration / block. The inner
    /// parse inherits the current parser's context (strictness + whether `await`/`yield`/`new.target`/
    /// `super` are in scope) so `` `${ await x }` `` inside an async body parses the operator form.
    fn parseSubstitution(self: *Parser, src: []const u8) ParseError!*const ast.Node {
        var lexer = lex.Lexer.init(self.arena, src);
        var toks: std.ArrayList(lex.Token) = .empty;
        while (true) {
            const t = try lexer.next();
            try toks.append(self.arena, t);
            if (t.kind == .eof) break;
        }
        var sub = Parser{
            .tokens = toks.items,
            .arena = self.arena,
            .strict = self.strict,
            .in_function = self.in_function,
            .in_method = self.in_method,
            .in_class_body = self.in_class_body,
            .in_generator = self.in_generator,
            .in_async = self.in_async,
            .private_names = self.private_names,
        };
        const node = try sub.parseExpression();
        _ = try sub.expect(.eof);
        return node;
    }

    /// §13.3.5 `new Callee(args)`. Callee is a member expression (no call); the argument list
    /// binds to the `new`, so `new a.b.C(x)` constructs `a.b.C`.
    pub fn parseNew(self: *Parser) ParseError!*const ast.Node {
        const new_pos: u32 = self.tokenOffset(self.peek()); // the `new` offset — the stack-trace construction site
        _ = self.advance(); // new
        // §13.3.12 NewTarget MetaProperty `new` `.` `target`. The only MetaProperty in the grammar is
        // `new.target`: after the `.`, the IdentifierName must be exactly `target` (no escapes), else a
        // SyntaxError. A §13.3.12.1 Early Error makes `new.target` a SyntaxError outside a function body
        // (e.g. at Script top level) — gated on `in_function`.
        if (self.peek().kind == .dot) {
            _ = self.advance(); // .
            const m = self.peek();
            if (m.kind != .identifier or m.had_escape or !std.mem.eql(u8, m.lexeme, "target")) return ParseError.UnexpectedToken;
            _ = self.advance(); // target
            if (!self.in_function) return ParseError.UnexpectedToken;
            return self.alloc(.new_target);
        }
        var callee = try self.parsePrimary();
        // §13.3.10: ImportCall is a CallExpression, not a MemberExpression — a BARE ImportCall is
        // NOT a valid NewExpression target (`new import('x')`, `new import('x').prop` are
        // SyntaxErrors). A PARENTHESIZED `new (import(''))` IS valid (the parens make it a
        // CoverParenthesizedExpression → PrimaryExpression → MemberExpression); `last_was_paren`
        // (set by the `.lparen` primary, cleared by the bare-ImportCall primary) distinguishes them.
        if (callee.* == .import_call and !self.last_was_paren) return ParseError.UnexpectedToken;
        while (true) {
            switch (self.peek().kind) {
                .dot => {
                    _ = self.advance();
                    // §13.3.1 MemberExpression `.` IdentifierName — the property name after `.` may be
                    // any IdentifierName, INCLUDING reserved words (`new m.delete`, `new Symbol.for()`). Use
                    // `expectPropertyName` (not `expect(.identifier)`), matching the non-`new` member path.
                    const name = try self.expectPropertyName();
                    callee = try self.alloc(.{ .member = .{ .object = callee, .name = name } });
                },
                .lbracket => {
                    _ = self.advance();
                    const key = try self.parseAssignmentInBrackets();
                    _ = try self.expect(.rbracket);
                    callee = try self.alloc(.{ .index = .{ .object = callee, .key = key } });
                },
                .template => {
                    // §13.2.8: a TaggedTemplate is a MemberExpression, so `new tag\`x\`` constructs the
                    // RESULT of the tagged-template call (application binds tighter than `new`), and a
                    // following `(args)` binds to the `new`. (`new tag\`x\`('a')` ⇒ `new (tag\`x\`)('a')`.)
                    const tok = self.advance();
                    const quasi = try self.parseTemplate(tok.string_value);
                    self.template_invalid_escape = false; // tagged tolerates illegal escapes (cooked → undefined)
                    callee = try self.alloc(.{ .tagged_template = .{ .tag = callee, .quasi = quasi } });
                },
                else => break,
            }
        }
        var args: []const *const ast.Node = &.{};
        if (self.peek().kind == .lparen) {
            _ = self.advance();
            var list: std.ArrayList(*const ast.Node) = .empty;
            while (self.peek().kind != .rparen and self.peek().kind != .eof) {
                try list.append(self.arena, try self.parseSpreadable());
                if (self.peek().kind == .comma) {
                    _ = self.advance();
                    continue;
                }
                break;
            }
            _ = try self.expect(.rparen);
            args = list.items;
        }
        return self.alloc(.{ .new_expr = .{ .callee = callee, .args = args, .pos = new_pos } });
    }

    /// §13.3.10 ImportCall — current token is `import`, next is `(`. Parses
    /// `import ( AssignmentExpression[+In] [ , AssignmentExpression[+In] ] [ , ] )`. The arguments
    /// use `parseAssignment` (NOT the spread-capable element parser): §13.3.10 forbids `...spread`
    /// (a Forbidden Extension), an empty `import()` (AssignmentExpression is not optional), and a
    /// third argument (at most two). A trailing comma after either argument is allowed.
    pub fn parseImportCall(self: *Parser) ParseError!*const ast.Node {
        _ = self.advance(); // import
        _ = try self.expect(.lparen);
        // §13.3.10: no argument is a SyntaxError; a leading spread is a Forbidden Extension.
        if (self.peek().kind == .rparen or self.peek().kind == .ellipsis) return ParseError.UnexpectedToken;
        const specifier = try self.parseAssignment();
        var options: ?*const ast.Node = null;
        if (self.peek().kind == .comma) {
            _ = self.advance(); // first comma
            if (self.peek().kind != .rparen) {
                // A second argument (import options). A spread here is also forbidden.
                if (self.peek().kind == .ellipsis) return ParseError.UnexpectedToken;
                options = try self.parseAssignment();
                // An optional trailing comma after the second argument.
                if (self.peek().kind == .comma) _ = self.advance();
            }
        }
        // At most two arguments: anything other than `)` now (e.g. a third `,`) is a SyntaxError.
        _ = try self.expect(.rparen);
        return self.alloc(.{ .import_call = .{ .specifier = specifier, .options = options } });
    }

    pub fn parseIf(self: *Parser) ParseError!ast.Stmt {
        _ = self.advance(); // if
        _ = try self.expect(.lparen);
        const cond = try self.parseExpression(); // §14.6/14.7: `( Expression )` — comma/sequence allowed
        _ = try self.expect(.rparen);
        const then = try self.allocStmt(try self.parseSubStmt(false));
        var otherwise: ?*const ast.Stmt = null;
        if (self.peek().kind == .kw_else) {
            _ = self.advance();
            otherwise = try self.allocStmt(try self.parseSubStmt(false));
        }
        return .{ .if_stmt = .{ .cond = cond, .then = then, .otherwise = otherwise } };
    }

    /// §14.11 `with ( Expression ) Statement`. §14.11.1 Early Error: a WithStatement in strict
    /// mode code is a SyntaxError.
    pub fn parseWith(self: *Parser) ParseError!ast.Stmt {
        _ = self.advance(); // with
        if (self.strict) return ParseError.UnexpectedToken;
        _ = try self.expect(.lparen);
        const object = try self.parseExpression();
        _ = try self.expect(.rparen);
        // §14.11.1 early error: the `with` body is a Statement, which is NOT a FunctionDeclaration —
        // and unlike `if`/`else` (Annex B B.3.4) there is no legacy carve-out for `with`. So
        // `with ({}) function f(){}` is a SyntaxError even in sloppy mode (`parseSubStmt` accepts a
        // sloppy non-iteration `function` body for `if`, so reject it here before delegating).
        if (self.peek().kind == .kw_function) return ParseError.UnexpectedToken;
        const body = try self.allocStmt(try self.parseSubStmt(false));
        return .{ .with_stmt = .{ .object = object, .body = body } };
    }

    pub fn parseWhile(self: *Parser) ParseError!ast.Stmt {
        _ = self.advance(); // while
        _ = try self.expect(.lparen);
        const cond = try self.parseExpression(); // §14.6/14.7: `( Expression )` — comma/sequence allowed
        _ = try self.expect(.rparen);
        self.iteration_depth += 1;
        defer self.iteration_depth -= 1;
        const body = try self.allocStmt(try self.parseSubStmt(true));
        return .{ .while_stmt = .{ .cond = cond, .body = body } };
    }

    /// §14.7.2 `do Statement while ( Expression ) ;`. The trailing `;` is ASI-optional via the
    /// special rule in §14.7.2 (the `;` is auto-inserted regardless of a line terminator), so we
    /// consume an explicit `;` if present but never require it.
    pub fn parseDoWhile(self: *Parser) ParseError!ast.Stmt {
        _ = self.advance(); // do
        const body = blk: {
            self.iteration_depth += 1;
            defer self.iteration_depth -= 1;
            break :blk try self.allocStmt(try self.parseSubStmt(true));
        };
        _ = try self.expect(.kw_while);
        _ = try self.expect(.lparen);
        const cond = try self.parseExpression(); // §14.6/14.7: `( Expression )` — comma/sequence allowed
        _ = try self.expect(.rparen);
        if (self.peek().kind == .semicolon) _ = self.advance();
        return .{ .do_while_stmt = .{ .cond = cond, .body = body } };
    }

    /// §14.7.5 contextual `of`: lexed as an identifier with lexeme `"of"`. Recognized only in a
    /// for-header (here) as the for-of marker — everywhere else `of` is an ordinary identifier.
    pub fn peekIsOf(self: *Parser) bool {
        const t = self.peek();
        // §12.7.1: a contextual keyword spelled with a Unicode escape is NOT the keyword (`of`
        // is the identifier `of`, never the for-of marker) — terminal symbols must appear verbatim.
        return t.kind == .identifier and !t.had_escape and std.mem.eql(u8, t.lexeme, "of");
    }

    pub fn parseFor(self: *Parser) ParseError!ast.Stmt {
        _ = self.advance(); // for
        // §14.7.5 `for await (LHS of EXPR) BODY` — the optional `await` (contextual identifier, no
        // LineTerminator restriction needed since `for` already consumed) marks an async for-of. It is
        // legal ONLY inside an async function / async generator (`[+Await]`); a `for await` outside an
        // async context is a SyntaxError.
        var is_await = false;
        if (self.peek().kind == .identifier and std.mem.eql(u8, self.peek().lexeme, "await")) {
            if (!self.in_async) return ParseError.UnexpectedToken;
            _ = self.advance(); // await
            is_await = true;
            // §16.2.1.6 [[HasTLA]]: `for await` at module top level evaluates the module asynchronously.
            if (self.is_module and !self.in_function) self.saw_top_level_await = true;
        }
        _ = try self.expect(.lparen);
        // §14.3.1.1: a ForStatement / ForInOfStatement is a UsingDeclaration allow-list context — the
        // head and body may contain `using`/`await using`. Enter it for the whole `for`.
        const saved_using = self.using_allowed;
        self.using_allowed = true;
        defer self.using_allowed = saved_using;
        var init_stmt: ?*const ast.Stmt = null;
        switch (self.peek().kind) {
            // §14.7.5: `for await (; …)` is a SyntaxError — `for await` has no C-style form.
            .semicolon => {
                if (is_await) return ParseError.UnexpectedToken;
                _ = self.advance();
            },
            .kw_var, .kw_let, .kw_const => {
                // §14.7.5 ForBinding vs §14.7.4 ForStatement init: parse the declaration kind + the
                // FIRST binding with the relational `in` suppressed (`[~In]`), then disambiguate.
                const kind: ast.DeclKind = switch (self.advance().kind) {
                    .kw_var => .var_decl,
                    .kw_let => .let_decl,
                    else => .const_decl,
                };
                const saved_no_in = self.no_in;
                self.no_in = true;
                const target = try self.parsePattern();
                self.no_in = saved_no_in;
                if (self.strict and patternHasStrictReserved(target)) return ParseError.UnexpectedToken;
                // `for (var/let/const ForBinding in/of …)` — a for-in / for-of head (no initializer).
                if (self.peek().kind == .kw_in or self.peekIsOf()) {
                    const is_of = self.peekIsOf();
                    // §14.7.5.1 Early Error: a lexical ForDeclaration's BoundNames must contain no
                    // duplicates (e.g. `for (const [x, x] of …)`). `var` permits duplicate bound names.
                    if (kind != .var_decl) {
                        var fb_names: NameSet = .init();
                        if (fb_names.addPatternDup(target)) return ParseError.UnexpectedToken;
                    }
                    // §14.7.5: `for await` requires the `of` form (`for await (… in …)` is a SyntaxError).
                    if (is_await and !is_of) return ParseError.UnexpectedToken;
                    _ = self.advance(); // `in` / `of`
                    return self.finishForInOf(.{ .decl = .{ .kind = kind, .target = target } }, is_of, is_await);
                }
                // §14.7.5: `for await` has no C-style form — the head must be a for-of.
                if (is_await) return ParseError.UnexpectedToken;
                // Otherwise a C-style `for (var x [= init] [, …]; …)` declaration. Finish the first
                // declarator's optional initializer + any remaining comma-separated declarators.
                var decls: std.ArrayList(ast.Declarator) = .empty;
                {
                    var init_expr: ?*const ast.Node = null;
                    if (self.peek().kind == .assign) {
                        _ = self.advance();
                        init_expr = try self.parseAssignment();
                    }
                    // §14.3.1.1 / §14.3.2: a BindingPattern (and any `const`) requires an initializer.
                    if (init_expr == null and (target.* != .identifier or kind == .const_decl)) return ParseError.UnexpectedToken;
                    try decls.append(self.arena, .{ .target = target, .init = init_expr });
                }
                while (self.peek().kind == .comma) {
                    _ = self.advance();
                    const t2 = try self.parsePattern();
                    if (self.strict and patternHasStrictReserved(t2)) return ParseError.UnexpectedToken;
                    var init2: ?*const ast.Node = null;
                    if (self.peek().kind == .assign) {
                        _ = self.advance();
                        init2 = try self.parseAssignment();
                    }
                    if (init2 == null and (t2.* != .identifier or kind == .const_decl)) return ParseError.UnexpectedToken;
                    try decls.append(self.arena, .{ .target = t2, .init = init2 });
                }
                init_stmt = try self.allocStmt(.{ .declaration = .{ .kind = kind, .decls = decls.items } });
                _ = try self.expect(.semicolon);
            },
            else => {
                // §14.7.5 for-head UsingDeclaration: `for (using x of …)` (for-of, no initializer) or
                // `for (using x = … ; … )` (C-style). `using` is contextual — `for (using of …)` is
                // the for-of of the identifier `using` (excluded via `in_for`), so it is NOT a using
                // head. `for (using x in …)` is a Syntax Error (`using` may not head a for-in).
                if (self.atAwaitUsingDeclStart(true) or self.atUsingDeclStart(true)) {
                    const ukind: ast.DeclKind = if (self.peek().kind == .identifier and std.mem.eql(u8, self.peek().lexeme, "await")) .await_using_decl else .using_decl;
                    const saved_no_in2 = self.no_in;
                    self.no_in = true;
                    const ustmt = try self.parseUsingDecl(ukind, true);
                    self.no_in = saved_no_in2;
                    // §14.7.5: `for (using x in …)` is a Syntax Error; the for-of form has no initializer.
                    if (self.peek().kind == .kw_in) return ParseError.UnexpectedToken;
                    if (self.peekIsOf()) {
                        if (ustmt.declaration.decls.len != 1 or ustmt.declaration.decls[0].init != null) return ParseError.UnexpectedToken;
                        _ = self.advance(); // `of`
                        return self.finishForInOf(.{ .decl = .{ .kind = ukind, .target = ustmt.declaration.decls[0].target } }, true, is_await);
                    }
                    // C-style head: `for (using x = … ; cond ; upd )`. Each binding required an
                    // initializer (enforced in parseUsingDecl with for_head=false semantics below).
                    if (is_await) return ParseError.UnexpectedToken; // `for await` has no C-style form
                    for (ustmt.declaration.decls) |d| if (d.init == null) return ParseError.UnexpectedToken;
                    init_stmt = try self.allocStmt(ustmt);
                    _ = try self.expect(.semicolon);
                    var cond2: ?*const ast.Node = null;
                    if (self.peek().kind != .semicolon) cond2 = try self.parseExpression();
                    _ = try self.expect(.semicolon);
                    var update2: ?*const ast.Node = null;
                    if (self.peek().kind != .rparen) update2 = try self.parseExpression();
                    _ = try self.expect(.rparen);
                    self.iteration_depth += 1;
                    defer self.iteration_depth -= 1;
                    const body2 = try self.allocStmt(try self.parseSubStmt(true));
                    return .{ .for_stmt = .{ .init = init_stmt, .cond = cond2, .update = update2, .body = body2 } };
                }
                // §14.7.4/§14.7.5: parse the first clause as an Expression with `in` suppressed
                // (`[~In]`), then disambiguate. `for (LHS in/of …)` is for-in/for-of (LHS must be a
                // simple assignment target); otherwise it is a C-style init Expression.
                const saved_no_in = self.no_in;
                self.no_in = true;
                const first = try self.parseAssignment();
                self.no_in = saved_no_in;
                if (self.peek().kind == .kw_in or self.peekIsOf()) {
                    const is_of = self.peekIsOf();
                    // §14.7.5 ForBinding (assignment form): the LHS is a LeftHandSideExpression refined
                    // by AssignmentTargetType. A simple target (identifier / `a.b` / `a[k]`) is taken as
                    // is; an ArrayLiteral / ObjectLiteral is the §13.15.5 DestructuringAssignment cover
                    // grammar — refine it into an AssignmentPattern (this also discharges any
                    // CoverInitializedName / duplicate-`__proto__` obligations). A parenthesized literal
                    // (`for (({a}) of …)`) is NOT the cover grammar (AssignmentTargetType invalid) and a
                    // call / other expression is not assignable — both are §13.15.1 SyntaxErrors.
                    if (isSimpleAssignTarget(first)) {
                        // ok — simple AssignmentTarget
                    } else if (!self.last_was_paren and (first.* == .array_literal or first.* == .object_literal)) {
                        try self.validateAssignmentPattern(first);
                    } else {
                        return ParseError.UnexpectedToken;
                    }
                    // §14.7.5: `for await` requires the `of` form.
                    if (is_await and !is_of) return ParseError.UnexpectedToken;
                    _ = self.advance(); // `in` / `of`
                    return self.finishForInOf(.{ .target = first }, is_of, is_await);
                }
                // §14.7.5: `for await` has no C-style form — the head must be a for-of.
                if (is_await) return ParseError.UnexpectedToken;
                // §14.7.4 C-style init Expression — the comma / sequence operator is permitted.
                var expr = first;
                while (self.peek().kind == .comma) {
                    _ = self.advance();
                    const right = try self.parseAssignment();
                    expr = try self.alloc(.{ .comma = .{ .left = expr, .right = right } });
                }
                init_stmt = try self.allocStmt(.{ .expr = expr });
                _ = try self.expect(.semicolon);
            },
        }
        var cond: ?*const ast.Node = null;
        if (self.peek().kind != .semicolon) cond = try self.parseExpression();
        _ = try self.expect(.semicolon);
        var update: ?*const ast.Node = null;
        if (self.peek().kind != .rparen) update = try self.parseExpression();
        _ = try self.expect(.rparen);
        self.iteration_depth += 1;
        defer self.iteration_depth -= 1;
        const body = try self.allocStmt(try self.parseSubStmt(true));
        return .{ .for_stmt = .{ .init = init_stmt, .cond = cond, .update = update, .body = body } };
    }

    /// §14.7.5: with the `in`/`of` already consumed, parse the operand, `)`, and body, building the
    /// for-in / for-of statement. for-of's operand is an AssignmentExpression (§14.7.5: `of` takes an
    /// AssignmentExpression — `for (x of a, b)` is a SyntaxError); for-in's operand is a full
    /// Expression (`for (x in a, b)` is legal). The operand is `[+In]` (the suppression was only the head).
    pub fn finishForInOf(self: *Parser, head: ast.ForHead, is_of: bool, is_await: bool) ParseError!ast.Stmt {
        const right = if (is_of) try self.parseAssignment() else try self.parseExpression();
        _ = try self.expect(.rparen);
        self.iteration_depth += 1;
        defer self.iteration_depth -= 1;
        const body = try self.allocStmt(try self.parseSubStmt(true));
        // §14.7.5.1 Early Error: a `using`/`await using` ForDeclaration's BoundName may not also be a
        // VarDeclaredName of the loop body (`for (using x of []) { var x; }`). Enforced for the using
        // forms (the M32 feature); the let/const variants are a separate (unenforced) M-subset cut.
        if (head == .decl and (head.decl.kind == .using_decl or head.decl.kind == .await_using_decl)) {
            if (head.decl.target.* == .identifier and bodyVarDeclaresName(body, head.decl.target.identifier)) {
                return ParseError.UnexpectedToken;
            }
        }
        if (is_of) return .{ .for_of_stmt = .{ .head = head, .right = right, .body = body, .is_await = is_await } };
        return .{ .for_in_stmt = .{ .head = head, .right = right, .body = body } };
    }

    pub fn parseSwitch(self: *Parser) ParseError!ast.Stmt {
        _ = self.advance(); // switch
        _ = try self.expect(.lparen);
        const disc = try self.parseExpression(); // §14.12: `switch ( Expression )` — comma/sequence allowed
        _ = try self.expect(.rparen);
        _ = try self.expect(.lbrace);
        self.switch_depth += 1;
        defer self.switch_depth -= 1;
        // §14.3.1.1: a CaseClause / DefaultClause StatementList is NOT a UsingDeclaration allow-list
        // context — `case 0: using x = …;` is a Syntax Error (a `{}`-wrapped clause body re-allows it
        // via `parseBlock`). The CaseBlock `{ … }` braces are the switch's own, not a Block.
        const saved_using = self.using_allowed;
        self.using_allowed = false;
        defer self.using_allowed = saved_using;
        var cases: std.ArrayList(ast.Case) = .empty;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            var test_expr: ?*const ast.Node = null;
            switch (self.peek().kind) {
                .kw_case => {
                    _ = self.advance();
                    test_expr = try self.parseAssignment();
                },
                .kw_default => _ = self.advance(),
                else => return ParseError.UnexpectedToken,
            }
            _ = try self.expect(.colon);
            var body: std.ArrayList(ast.Stmt) = .empty;
            while (true) {
                switch (self.peek().kind) {
                    .kw_case, .kw_default, .rbrace, .eof => break,
                    else => try body.append(self.arena, try self.parseStmt()),
                }
            }
            try cases.append(self.arena, .{ .test_expr = test_expr, .body = body.items });
        }
        _ = try self.expect(.rbrace);
        return .{ .switch_stmt = .{ .discriminant = disc, .cases = cases.items } };
    }

    pub fn parseTry(self: *Parser) ParseError!ast.Stmt {
        _ = self.advance(); // try
        const block = try self.parseBlock();
        var catch_param: ?*const ast.Pattern = null;
        var catch_block: ?[]const ast.Stmt = null;
        var finally_block: ?[]const ast.Stmt = null;
        if (self.peek().kind == .kw_catch) {
            _ = self.advance();
            if (self.peek().kind == .lparen) {
                _ = self.advance();
                // §14.15 CatchParameter : BindingIdentifier | BindingPattern. `parsePattern` enforces the
                // §12.7.1 escaped-reserved and await/yield-context BindingIdentifier rules for either form.
                const pat = try self.parsePattern();
                // §13.1.1 Early Error: a simple-identifier catch parameter may not be `eval`/`arguments`
                // or a future-reserved word in strict mode.
                if (pat.* == .identifier and self.strict and isStrictReservedBindingName(pat.identifier)) return ParseError.UnexpectedToken;
                // §14.15.1 Early Error: BoundNames of CatchParameter must not contain duplicates
                // (`catch ([x, x])` / `catch ({ a: x, b: x })`).
                var cp_names: NameSet = .init();
                if (cp_names.addPatternDup(pat)) return ParseError.UnexpectedToken;
                catch_param = pat;
                _ = try self.expect(.rparen);
            }
            catch_block = try self.parseBlock();
        }
        if (self.peek().kind == .kw_finally) {
            _ = self.advance();
            finally_block = try self.parseBlock();
        }
        return .{ .try_stmt = .{ .block = block, .catch_param = catch_param, .catch_block = catch_block, .finally_block = finally_block } };
    }

    // ── statements ──────────────────────────────────────────────────────────

    pub fn parseProgram(self: *Parser) ParseError!ast.Program {
        // DIAGNOSTICS: on any parse failure, `self.idx` is at the offending token — record its position
        // + lexeme for the engine's `line:col` SyntaxError message.
        errdefer {
            if (self.idx < self.tokens.len)
                last_error_lexeme = self.tokens[self.idx].lexeme
            else if (self.tokens.len > 0)
                last_error_lexeme = self.tokens[self.tokens.len - 1].lexeme
            else
                last_error_lexeme = "";
        }
        // §11.2.1 / §15.1.1: a Script is strict if it carries a "use strict" directive prologue.
        // Detect it on the token stream before parsing statements so the §13.x Early Errors below
        // fire for the whole Script. (`self.strict` may already be true from a strict `RunMode`.)
        if (directivePrologueIsStrict(self.tokens[self.idx..])) self.strict = true;
        var stmts: std.ArrayList(ast.Stmt) = .empty;
        while (self.peek().kind != .eof) {
            try stmts.append(self.arena, try self.parseStmt());
        }
        // §16.1.1 / §14.2.1 / §14.12.1 / §14.15.1: duplicate-declaration Early Errors. A single
        // post-parse static pass validates the Script scope and recurses into every nested lexical
        // scope (blocks, function/method/arrow bodies, switch CaseBlocks, catch). Parse-time only.
        try validateScope(stmts.items, .script_or_body, self.strict);
        return .{ .statements = stmts.items, .strict = self.strict };
    }

    /// §16.2.1 ModuleBody : ModuleItemList. Parse the module goal: a list of ModuleItems where, in
    /// addition to ordinary StatementListItems, `import` and `export` declarations are permitted at
    /// the top level. Each `export <decl>` emits BOTH the inner declaration statement (so the binding
    /// is created/evaluated normally) AND an ExportEntry; `import`/re-export `from` declarations emit
    /// entries + requested modules but no executable statement.
    pub fn parseModuleProgram(self: *Parser) ParseError!ast.Program {
        var stmts: std.ArrayList(ast.Stmt) = .empty;
        while (self.peek().kind != .eof) {
            switch (self.peek().kind) {
                .kw_import => {
                    // §13.3.10: `import (` / `import .` are the dynamic ImportCall / `import.meta`
                    // MetaProperty — an ExpressionStatement, not an ImportDeclaration. Defer to the
                    // ordinary statement parser for those; only a module-specifier/binding `import`
                    // begins an ImportDeclaration.
                    const next = if (self.idx + 1 < self.tokens.len) self.tokens[self.idx + 1].kind else .eof;
                    if (next == .lparen or next == .dot) {
                        try stmts.append(self.arena, try self.parseStmt());
                    } else {
                        try self.parseImportDeclaration();
                    }
                },
                .kw_export => {
                    if (try self.parseExportDeclaration()) |s| try stmts.append(self.arena, s);
                },
                else => try stmts.append(self.arena, try self.parseStmt()),
            }
        }
        try validateScope(stmts.items, .script_or_body, true);
        try self.validateModuleEarlyErrors(stmts.items);
        return .{
            .statements = stmts.items,
            .strict = true,
            .is_module = true,
            .import_entries = self.import_entries.items,
            .export_entries = self.export_entries.items,
            .requested_modules = self.requested_modules.items,
            .has_top_level_await = self.saw_top_level_await,
        };
    }

    /// Record a RequestedModule specifier (de-duplicated, source order; §16.2.1.6 [[RequestedModules]]).
    pub fn addRequestedModule(self: *Parser, spec: []const u8) ParseError!void {
        for (self.requested_modules.items) |m| if (std.mem.eql(u8, m, spec)) return;
        try self.requested_modules.append(self.arena, spec);
    }

    /// §16.2.2 ImportDeclaration. Forms: `import "m";` (side-effect), `import d from "m";`,
    /// `import * as ns from "m";`, `import { a, b as c } from "m";`, and the default+named/namespace
    /// combinations (`import d, { … } from "m"`, `import d, * as ns from "m"`).
    pub fn parseImportDeclaration(self: *Parser) ParseError!void {
        _ = self.advance(); // import
        // `import "module";` — side-effect import, no bindings.
        if (self.peek().kind == .string) {
            const spec = self.advance().string_value;
            try self.addRequestedModule(spec);
            self.consumeSemicolon();
            return;
        }
        var have_clause = false;
        // ImportedDefaultBinding — a plain BindingIdentifier before `from`.
        if (self.peek().kind == .identifier) {
            const local = try self.importBindingName();
            // module_request is filled once we read the `from` clause below; stage the entry.
            try self.import_entries.append(self.arena, .{ .module_request = "", .import_name = "default", .local_name = local });
            have_clause = true;
            if (self.peek().kind == .comma) _ = self.advance() else {
                const spec = try self.parseFromClause();
                try self.fillPendingImportRequests(spec);
                self.consumeSemicolon();
                return;
            }
        }
        if (self.peek().kind == .star) {
            // NameSpaceImport `* as ns`.
            _ = self.advance();
            try self.expectContextual("as");
            const local = try self.importBindingName();
            try self.import_entries.append(self.arena, .{ .module_request = "", .import_name = "*", .local_name = local });
            have_clause = true;
        } else if (self.peek().kind == .lbrace) {
            try self.parseNamedImports();
            have_clause = true;
        }
        if (!have_clause) return ParseError.UnexpectedToken;
        const spec = try self.parseFromClause();
        try self.fillPendingImportRequests(spec);
        self.consumeSemicolon();
    }

    /// Back-fill the `module_request` of every import entry staged for the current declaration (those
    /// with an empty request) once the `from "spec"` clause is read, and record the requested module.
    pub fn fillPendingImportRequests(self: *Parser, spec: []const u8) ParseError!void {
        for (self.import_entries.items) |*e| {
            if (e.module_request.len == 0) e.module_request = spec;
        }
        try self.addRequestedModule(spec);
    }

    /// §16.2.2 NamedImports `{ a, b as c }` — each ImportSpecifier introduces a local binding for an
    /// imported name (`a` ⇒ import `a` as `a`; `b as c` ⇒ import `b` as `c`). An IdentifierName (not
    /// just IdentifierReference) is a valid imported name; the local is a BindingIdentifier.
    pub fn parseNamedImports(self: *Parser) ParseError!void {
        _ = try self.expect(.lbrace);
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            const imported = try self.moduleExportName(); // IdentifierName or StringLiteral
            var local = imported;
            if (self.isContextual("as")) {
                _ = self.advance();
                local = try self.importBindingName();
            } else {
                // Without `as`, the imported name must be a valid BindingIdentifier (so a string
                // module-export name `{ "x" }` without `as` is a SyntaxError).
                if (!isValidBindingName(imported)) return ParseError.UnexpectedToken;
            }
            try self.import_entries.append(self.arena, .{ .module_request = "", .import_name = imported, .local_name = local });
            if (self.peek().kind == .comma) _ = self.advance() else break;
        }
        _ = try self.expect(.rbrace);
    }

    /// §16.2.3 ExportDeclaration. Returns the inner declaration statement to also emit (for
    /// `export var/let/const/function/class` and `export default <decl/expr>`), or null for the
    /// binding-list / re-export forms (which emit only entries).
    pub fn parseExportDeclaration(self: *Parser) ParseError!?ast.Stmt {
        _ = self.advance(); // export
        switch (self.peek().kind) {
            .star => {
                // `export * from "m";` or `export * as ns from "m";`
                _ = self.advance();
                var export_name: ?[]const u8 = null;
                if (self.isContextual("as")) {
                    _ = self.advance();
                    export_name = try self.moduleExportName();
                }
                const spec = try self.parseFromClause();
                try self.addRequestedModule(spec);
                try self.export_entries.append(self.arena, .{ .export_name = export_name, .module_request = spec, .import_name = "*" });
                self.consumeSemicolon();
                return null;
            },
            .lbrace => {
                // `export { a, b as c };` (local) or `export { a } from "m";` (indirect re-export).
                const specs = try self.parseExportSpecifiers();
                if (self.isContextual("from")) {
                    _ = self.advance();
                    const spec = (try self.expect(.string)).string_value;
                    try self.addRequestedModule(spec);
                    for (specs) |s| try self.export_entries.append(self.arena, .{ .export_name = s.exported, .module_request = spec, .import_name = s.local });
                } else {
                    for (specs) |s| {
                        // §16.2.3.1: a bare `export { a }` clause references a LOCAL binding `a`; a
                        // module-export-name string here without `from` is illegal as a local ref.
                        if (!isValidBindingName(s.local)) return ParseError.UnexpectedToken;
                        try self.export_entries.append(self.arena, .{ .export_name = s.exported, .local_name = s.local });
                    }
                }
                self.consumeSemicolon();
                return null;
            },
            .kw_default => {
                _ = self.advance(); // default
                const dd = try self.parseExportDefault();
                try self.export_entries.append(self.arena, .{ .export_name = "default", .local_name = dd.local });
                return dd.stmt;
            },
            .kw_var, .kw_let, .kw_const => {
                const stmt = try self.parseDecl();
                self.consumeSemicolon();
                for (boundDeclNames(self.arena, stmt) catch &.{}) |n| {
                    try self.export_entries.append(self.arena, .{ .export_name = n, .local_name = n });
                }
                return stmt;
            },
            .kw_function => {
                _ = self.advance();
                const f = try self.parseFunction(false);
                const nm = f.name orelse return ParseError.UnexpectedToken;
                try self.export_entries.append(self.arena, .{ .export_name = nm, .local_name = nm });
                return .{ .func_decl = f };
            },
            .kw_class => {
                const c = try self.parseClass(true, false);
                const nm = c.name orelse return ParseError.UnexpectedToken;
                try self.export_entries.append(self.arena, .{ .export_name = nm, .local_name = nm });
                return .{ .class_decl = c };
            },
            .identifier => {
                // `export async function f(){}` — an AsyncFunctionDeclaration export.
                if (self.atAsyncFunctionStart()) {
                    _ = self.advance(); // async
                    _ = self.advance(); // function
                    const f = try self.parseFunction(true);
                    const nm = f.name orelse return ParseError.UnexpectedToken;
                    try self.export_entries.append(self.arena, .{ .export_name = nm, .local_name = nm });
                    return .{ .func_decl = f };
                }
                return ParseError.UnexpectedToken;
            },
            else => return ParseError.UnexpectedToken,
        }
    }

    const DefaultDecl = struct { stmt: ast.Stmt, local: []const u8 };

    /// §16.2.3 `export default` of a HoistableDeclaration / ClassDeclaration / AssignmentExpression.
    /// A named function/class is hoisted under its own name AND exported as `default` (so its
    /// `local_name` is that name); an anonymous one binds the synthetic `*default*`. An
    /// AssignmentExpression default lowers to `let *default* = <expr>;`. Returns the inner statement
    /// plus the LOCAL binding name the default export entry should reference.
    pub fn parseExportDefault(self: *Parser) ParseError!DefaultDecl {
        switch (self.peek().kind) {
            .kw_function => {
                _ = self.advance();
                const f = try self.namedOrDefault(try self.parseFunction(false));
                return .{ .stmt = .{ .func_decl = f }, .local = f.name.? };
            },
            .kw_class => {
                const c = try self.parseClass(true, true);
                if (c.name != null) return .{ .stmt = .{ .class_decl = c }, .local = c.name.? };
                const named = try self.arena.create(ast.Class);
                named.* = .{ .name = "*default*", .superclass = c.superclass, .elements = c.elements };
                return .{ .stmt = .{ .class_decl = named }, .local = "*default*" };
            },
            .identifier => {
                if (self.atAsyncFunctionStart()) {
                    _ = self.advance(); // async
                    _ = self.advance(); // function
                    const f = try self.namedOrDefault(try self.parseFunction(true));
                    return .{ .stmt = .{ .func_decl = f }, .local = f.name.? };
                }
                return try self.exportDefaultExpr();
            },
            else => return try self.exportDefaultExpr(),
        }
    }

    /// Ensure an exported-default function has a binding name (`*default*` when anonymous).
    pub fn namedOrDefault(self: *Parser, f: *const ast.Function) ParseError!*const ast.Function {
        if (f.name != null) return f;
        const nf = try self.arena.create(ast.Function);
        nf.* = f.*;
        nf.name = "*default*";
        return nf;
    }

    /// `export default <AssignmentExpression>;` → `let *default* = <expr>;`.
    pub fn exportDefaultExpr(self: *Parser) ParseError!DefaultDecl {
        const expr = try self.parseAssignment();
        self.consumeSemicolon();
        const pat = try self.allocPattern(.{ .identifier = "*default*" });
        const decls = try self.arena.alloc(ast.Declarator, 1);
        decls[0] = .{ .target = pat, .init = expr };
        return .{ .stmt = .{ .declaration = .{ .kind = .let_decl, .decls = decls } }, .local = "*default*" };
    }

    const ExportSpec = struct { local: []const u8, exported: []const u8 };

    /// §16.2.3 ExportsList `{ a, b as c }` — each ExportSpecifier maps a local name (or, with
    /// `from`, a source import name) to an exported module name.
    pub fn parseExportSpecifiers(self: *Parser) ParseError![]const ExportSpec {
        _ = try self.expect(.lbrace);
        var out: std.ArrayList(ExportSpec) = .empty;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            const local = try self.moduleExportName();
            var exported = local;
            if (self.isContextual("as")) {
                _ = self.advance();
                exported = try self.moduleExportName();
            }
            try out.append(self.arena, .{ .local = local, .exported = exported });
            if (self.peek().kind == .comma) _ = self.advance() else break;
        }
        _ = try self.expect(.rbrace);
        return out.items;
    }

    /// §16.2.2 `from "ModuleSpecifier"`.
    pub fn parseFromClause(self: *Parser) ParseError![]const u8 {
        try self.expectContextual("from");
        return (try self.expect(.string)).string_value;
    }

    /// §16.2.3 ModuleExportName : IdentifierName | StringLiteral. Returns the name text.
    pub fn moduleExportName(self: *Parser) ParseError![]const u8 {
        const t = self.peek();
        if (t.kind == .string) {
            _ = self.advance();
            return t.string_value;
        }
        if (isIdentifierNameToken(t.kind)) {
            _ = self.advance();
            return t.lexeme;
        }
        return ParseError.UnexpectedToken;
    }

    /// An import-clause BindingIdentifier. §16.2.2 / §16.2.1.5: `eval` / `arguments` are forbidden as
    /// imported binding names, and a reserved word is rejected.
    pub fn importBindingName(self: *Parser) ParseError![]const u8 {
        if (self.peek().kind != .identifier) return ParseError.UnexpectedToken;
        if (isEscapedReservedIdent(self.peek())) return ParseError.UnexpectedToken;
        const nm = self.advance().lexeme;
        // Module code is strict: `eval`/`arguments`/strict-reserved are not valid binding names.
        if (isStrictReservedBindingName(nm)) return ParseError.UnexpectedToken;
        return nm;
    }

    pub fn isContextual(self: *Parser, word: []const u8) bool {
        const t = self.peek();
        return t.kind == .identifier and !t.had_escape and std.mem.eql(u8, t.lexeme, word);
    }

    pub fn expectContextual(self: *Parser, word: []const u8) ParseError!void {
        if (!self.isContextual(word)) return ParseError.UnexpectedToken;
        _ = self.advance();
    }

    pub fn consumeSemicolon(self: *Parser) void {
        if (self.peek().kind == .semicolon) _ = self.advance();
    }

    /// §16.2.1.5 Module Static Semantics: Early Errors.
    ///   • The ExportedNames of the ModuleItemList must contain no duplicate entries.
    ///   • Each ExportedBinding (a LOCAL export's referenced name) must be declared at the module top
    ///     level (a VarDeclaredName or LexicallyDeclaredName) — an `export { x }` / `export default`
    ///     referencing an undeclared name is a SyntaxError.
    pub fn validateModuleEarlyErrors(self: *Parser, stmts: []const ast.Stmt) ParseError!void {
        // Collect the module's top-level declared names (var + lexical + function/class + the
        // synthetic `*default*` for `export default`).
        var declared: std.StringHashMapUnmanaged(void) = .empty;
        for (stmts) |s| {
            for (boundDeclNames(self.arena, s) catch &.{}) |n| try declared.put(self.arena, n, {});
        }
        for (self.import_entries.items) |e| try declared.put(self.arena, e.local_name, {});
        // Duplicate ExportedNames.
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (self.export_entries.items) |e| {
            if (e.export_name) |name| {
                if (seen.contains(name)) return ParseError.UnexpectedToken;
                try seen.put(self.arena, name, {});
            }
            // ExportedBinding must be declared (local exports only; re-exports resolve at link time).
            if (e.module_request == null) {
                if (e.local_name) |ln| {
                    if (!declared.contains(ln)) return ParseError.UnexpectedToken;
                }
            }
        }
    }

    pub fn parseStmt(self: *Parser) ParseError!ast.Stmt {
        // §13.2.5.1: any CoverInitializedName created while parsing this statement must be discharged
        // (refined to an AssignmentPattern) by the time the statement is fully parsed; an undischarged
        // residue means it escaped as a real value (`({x = 1});`) — a SyntaxError. Snapshot the count
        // and verify no net increase. (Nested statements re-check their own slice; refined ones already
        // decremented, so the residue here reflects only THIS statement's leaked defaults.)
        const cover_before = self.cover_init;
        // §B.3.1: an undischarged duplicate-`__proto__` (a real ObjectLiteral value, not refined to an
        // assignment pattern) is likewise a SyntaxError — checked over this statement's slice.
        const proto_before = self.proto_dup;
        const stmt = try self.parseStmtInner();
        if (self.cover_init > cover_before) return ParseError.UnexpectedToken;
        if (self.proto_dup > proto_before) return ParseError.UnexpectedToken;
        return stmt;
    }

    /// §14.5: a single-statement body (the body of `if`/`else`, `while`, `do`, `for`, `for-in`/`for-of`)
    /// is a `Statement`, NOT a `Declaration`. So a lexical declaration (`let`/`const`), a
    /// `ClassDeclaration`, or a `GeneratorDeclaration` (`function*`) in body position is a
    /// SyntaxError (`if (x) class C {}`, `while (x) let y;`, `for (;;) function* g(){}`). A plain
    /// `FunctionDeclaration` is rejected in strict mode always; in sloppy mode Annex B B.3.4 permits it
    /// only as the body of an `if`/`else` — `loop_body` (the body of an iteration statement) forbids it
    /// there too (`do function f(){} while(0)` / `while(0) function f(){}` are SyntaxErrors). The
    /// Annex B B.3.4 `if` positives live under `annexB/`.
    pub fn parseSubStmt(self: *Parser, loop_body: bool) ParseError!ast.Stmt {
        switch (self.peek().kind) {
            .kw_const, .kw_class => return ParseError.UnexpectedToken,
            .kw_let => {
                // §14.5 + the ExpressionStatement lookahead `[lookahead ∉ { let [ }]`: `let` begins a
                // (forbidden) LexicalDeclaration here only when it is followed by `[` (always — that
                // lookahead has no [no LineTerminator here]), or by a BindingIdentifier / `{` on the
                // SAME line. When a LineTerminator follows `let` and the next token is an identifier
                // (`while (0) let \n x = 1`), ASI ends the statement at `let` — `let` is then an
                // IdentifierReference ExpressionStatement, which IS a valid Statement body.
                const next = if (self.idx + 1 < self.tokens.len) self.tokens[self.idx + 1] else return ParseError.UnexpectedToken;
                if (next.kind == .lbracket) return ParseError.UnexpectedToken;
                if (!next.newline_before and (next.kind == .identifier or next.kind == .lbrace)) return ParseError.UnexpectedToken;
            },
            .kw_function => {
                // `function*` (generator declaration) is never a valid substatement; a plain
                // `function` is invalid in strict mode, and (Annex B B.3.4) as an iteration body.
                const next_is_star = self.idx + 1 < self.tokens.len and self.tokens[self.idx + 1].kind == .star;
                if (self.strict or next_is_star or loop_body) return ParseError.UnexpectedToken;
            },
            // §14.13 + Annex B B.3.2: a LabelledStatement is itself a valid sub-statement, but a
            // *labelled FunctionDeclaration* is NOT permitted in any sub-statement position
            // (`if (x) lbl: function f(){}`, `for(;;) lbl: function f(){}` are SyntaxErrors). The
            // label-chain is parsed with `sub_position` set so it rejects a function labelled-item.
            .identifier => {
                // §15.8: an AsyncFunctionDeclaration (`async function …` / `async function* …`) is a
                // Declaration, never a valid sub-statement (like `function*`/`class`) — reject it in
                // `if`/`else`/loop body position (`if (x) async function f(){}`).
                if (self.atAsyncFunctionStart()) return ParseError.UnexpectedToken;
                // §14.3.1: a UsingDeclaration (`using x = …` / `await using x = …`) is likewise a
                // Declaration, not a Statement — forbidden as a single-statement body
                // (`if (true) using x = null;`, `while (0) await using x = null;`).
                if (self.atUsingDeclStart(false) or self.atAwaitUsingDeclStart(false)) return ParseError.UnexpectedToken;
                if (self.idx + 1 < self.tokens.len and self.tokens[self.idx + 1].kind == .colon) {
                    return self.parseLabeled(true);
                }
            },
            else => {},
        }
        return self.parseStmt();
    }

    pub fn parseStmtInner(self: *Parser) ParseError!ast.Stmt {
        switch (self.peek().kind) {
            // §14.4 EmptyStatement : `;` — a no-op. Represented as an empty Block (zero statements),
            // which the interpreter runs as a no-op without allocating a scope (`blockNeedsScope`
            // is false for an empty slice). A bare `;`, doubled `;;`, and a `;` trailing a class or
            // function declaration (e.g. `class C {};`) all reach here.
            .semicolon => {
                _ = self.advance();
                return .{ .block = &.{} };
            },
            .lbrace => return .{ .block = try self.parseBlock() },
            .kw_var, .kw_let, .kw_const => return self.parseDecl(),
            .kw_function => {
                _ = self.advance();
                return .{ .func_decl = try self.parseFunction(false) };
            },
            // §15.7 ClassDeclaration (statement position). Requires a binding name.
            .kw_class => return .{ .class_decl = try self.parseClass(true, false) },
            .kw_return => {
                _ = self.advance();
                var arg: ?*const ast.Node = null;
                const k = self.peek().kind;
                // §12.9.1: `return [no LineTerminator here] Expression` — a LineTerminator before the next
                // token forces ASI (`return;`). Without the `newline_before` check, `if (a) return\n
                // if (b) …` mis-parses the following line as the return argument. The argument is a full
                // Expression (§13.16) — `parseExpression`, NOT `parseAssignment` — so the comma/sequence
                // operator works (`return _typeof = …, _typeof(o)`, ubiquitous in Babel-compiled code).
                if (k != .semicolon and k != .rbrace and k != .eof and !self.peek().newline_before) arg = try self.parseExpression();
                if (self.peek().kind == .semicolon) _ = self.advance();
                return .{ .ret = arg };
            },
            .kw_if => return self.parseIf(),
            .kw_while => return self.parseWhile(),
            .kw_do => return self.parseDoWhile(),
            .kw_for => return self.parseFor(),
            .kw_switch => return self.parseSwitch(),
            .kw_with => return self.parseWith(),
            .kw_try => return self.parseTry(),
            .kw_throw => {
                _ = self.advance();
                // §14.14: `throw Expression ;` — a full Expression (comma/sequence allowed).
                const e = try self.parseExpression();
                if (self.peek().kind == .semicolon) _ = self.advance();
                return .{ .throw_stmt = e };
            },
            .kw_break => {
                _ = self.advance();
                // §14.9 BreakStatement `break [no LineTerminator here] LabelIdentifier? ;`. An
                // identifier on the SAME line is the optional target label; a LineTerminator before it
                // triggers ASI (the `break` is label-less). §14.9.1 Early Error: the label must be in
                // scope, and a label-less `break` requires an enclosing iteration or switch.
                var label: ?[]const u8 = null;
                const t = self.peek();
                if (t.kind == .identifier and !t.newline_before) {
                    label = t.lexeme;
                    _ = self.advance();
                    if (!self.hasLabel(self.labels.items, label.?)) return ParseError.UnexpectedToken;
                } else if (self.iteration_depth == 0 and self.switch_depth == 0) {
                    return ParseError.UnexpectedToken;
                }
                if (self.peek().kind == .semicolon) _ = self.advance();
                return .{ .break_stmt = label };
            },
            .kw_continue => {
                _ = self.advance();
                // §14.8 ContinueStatement `continue [no LineTerminator here] LabelIdentifier? ;`.
                // §14.8.1 Early Error: a `continue` must be inside an iteration; a labelled `continue`
                // targets a label that (transitively) labels an iteration statement.
                var label: ?[]const u8 = null;
                const t = self.peek();
                if (t.kind == .identifier and !t.newline_before) {
                    label = t.lexeme;
                    _ = self.advance();
                    if (!self.hasLabel(self.iteration_labels.items, label.?)) return ParseError.UnexpectedToken;
                } else if (self.iteration_depth == 0) {
                    return ParseError.UnexpectedToken;
                }
                if (self.peek().kind == .semicolon) _ = self.advance();
                return .{ .continue_stmt = label };
            },
            else => {
                // §14.3.1 UsingDeclaration `using [no LineTerminator here] BindingIdentifier …` — a
                // block-scoped Explicit Resource Management declaration. `using` is contextual: it heads
                // a declaration only when a same-line BindingIdentifier follows (else it is an ordinary
                // IdentifierReference ExpressionStatement). Detected before the label / expression
                // fallthrough. `await using …` (the async form) likewise heads off here.
                if (self.atAwaitUsingDeclStart(false)) return self.parseUsingDecl(.await_using_decl, false);
                if (self.atUsingDeclStart(false)) return self.parseUsingDecl(.using_decl, false);
                // §15.8 AsyncFunctionDeclaration `async [no LineTerminator here] function …` in
                // statement position — a Declaration (hoisted), parsed before the label / expression
                // fallthrough. `async` is the contextual modifier ONLY when `function` follows on the
                // SAME line (a LineTerminator triggers ASI: `async \n function f(){}` is the expression
                // statement `async` then a separate `function` declaration). An async generator decl
                // (`async function* g(){}`) also lands here.
                if (self.atAsyncFunctionStart()) {
                    // §12.7.1 Early Error: the `async` keyword of an AsyncFunctionDeclaration must not
                    // contain a Unicode escape (`async function f(){}`).
                    if (self.peek().had_escape) return ParseError.UnexpectedToken;
                    _ = self.advance(); // `async`
                    _ = self.advance(); // `function`
                    return .{ .func_decl = try self.parseFunction(true) };
                }
                // §14.13 LabelledStatement `LabelIdentifier : Statement` — an Identifier immediately
                // followed by `:` at statement start is a label prefix (disambiguated here from an
                // ExpressionStatement / object literal: those never begin `identifier :` in statement
                // position). Anything else is an ExpressionStatement.
                if (self.peek().kind == .identifier and self.idx + 1 < self.tokens.len and self.tokens[self.idx + 1].kind == .colon) {
                    return self.parseLabeled(false); // statement-list position: a sloppy labelled fn is OK (B.3.2)
                }
                // §14.5 ExpressionStatement : Expression `;` — a full Expression, so the comma /
                // sequence operator is permitted here.
                const e = try self.parseExpression();
                if (self.peek().kind == .semicolon) _ = self.advance();
                return .{ .expr = e };
            },
        }
    }

    pub fn hasLabel(self: *Parser, list: []const []const u8, name: []const u8) bool {
        _ = self;
        for (list) |l| if (std.mem.eql(u8, l, name)) return true;
        return false;
    }

    /// Saved label / iteration-nest state for a function-body boundary (§14.13: labels and the
    /// iteration/switch nest do not cross into a nested function body).
    const ControlScope = struct {
        labels: std.ArrayListUnmanaged([]const u8),
        iteration_labels: std.ArrayListUnmanaged([]const u8),
        iteration_depth: usize,
        switch_depth: usize,
    };

    pub fn enterControlScope(self: *Parser) ControlScope {
        const saved = ControlScope{
            .labels = self.labels,
            .iteration_labels = self.iteration_labels,
            .iteration_depth = self.iteration_depth,
            .switch_depth = self.switch_depth,
        };
        self.labels = .empty;
        self.iteration_labels = .empty;
        self.iteration_depth = 0;
        self.switch_depth = 0;
        return saved;
    }

    pub fn exitControlScope(self: *Parser, saved: ControlScope) void {
        self.labels = saved.labels;
        self.iteration_labels = saved.iteration_labels;
        self.iteration_depth = saved.iteration_depth;
        self.switch_depth = saved.switch_depth;
    }

    /// Does `kind` begin an IterationStatement (§14.7)? A label that (transitively) prefixes one of
    /// these is a valid `continue` target; a label prefixing anything else is `break`-only.
    pub fn tokenStartsIterationStmt(kind: lex.TokenKind) bool {
        return switch (kind) {
            .kw_while, .kw_do, .kw_for => true,
            else => false,
        };
    }

    /// §14.13 LabelledStatement `LabelIdentifier : LabelledItem`. The leading `identifier :` was
    /// confirmed by the caller. Collects the full label chain (`a: b: stmt`), enforces §14.13.1
    /// (a label may not be re-declared within its own LabelledStatement — duplicate-label SyntaxError),
    /// records which labels prefix an iteration statement (for `continue label` validity), then parses
    /// the LabelledItem as a substatement and wraps it in nested `labeled_stmt` nodes (outermost first).
    pub fn parseLabeled(self: *Parser, sub_position: bool) ParseError!ast.Stmt {
        const labels_before = self.labels.items.len;
        const iter_labels_before = self.iteration_labels.items.len;
        defer self.labels.shrinkRetainingCapacity(labels_before);
        defer self.iteration_labels.shrinkRetainingCapacity(iter_labels_before);

        // Collect the chain of label identifiers (`a: b: c: …`).
        var chain: std.ArrayListUnmanaged([]const u8) = .empty;
        while (self.peek().kind == .identifier and self.idx + 1 < self.tokens.len and self.tokens[self.idx + 1].kind == .colon) {
            // §12.7.1: an escaped ReservedWord is not a valid LabelIdentifier.
            if (isEscapedReservedIdent(self.peek())) return ParseError.UnexpectedToken;
            const name = self.advance().lexeme; // identifier
            _ = self.advance(); // `:`
            // §13.1.1 LabelIdentifier Early Errors: `yield` is not a valid label in a generator body
            // or in strict mode; any other strict-reserved word (`let`/`static`/…) is invalid in strict
            // mode. (`eval`/`arguments` ARE valid labels — a label is not a binding.) `await` inside a
            // static block is reserved too.
            if (std.mem.eql(u8, name, "yield")) {
                if (self.in_generator or self.strict) return ParseError.UnexpectedToken;
            } else if (std.mem.eql(u8, name, "await")) {
                // §13.1.1 LabelIdentifier `await`: invalid inside an async body (`await` is reserved
                // there) and inside a static block (§15.7.11). Outside async (sloppy script/function)
                // `await` is a valid label.
                if (self.in_async or self.in_static_block) return ParseError.UnexpectedToken;
            } else if (self.strict and !isEvalOrArguments(name) and isStrictReservedBindingName(name)) {
                return ParseError.UnexpectedToken;
            }
            // §14.13.1: a duplicate label nested within the same labelled statement is a SyntaxError.
            if (self.hasLabel(self.labels.items, name)) return ParseError.UnexpectedToken;
            try self.labels.append(self.arena, name);
            try chain.append(self.arena, name);
        }
        // If the labelled item is an iteration statement, every label in this chain can be a
        // `continue` target.
        if (tokenStartsIterationStmt(self.peek().kind)) {
            for (chain.items) |name| try self.iteration_labels.append(self.arena, name);
        }
        // §14.13 LabelledItem : Statement | FunctionDeclaration. A plain `function` labelled-item is a
        // §B.3.2 LabelledFunctionDeclaration — legal only in sloppy mode AND only in a statement-list
        // position (NOT inside an `if`/`else`/loop body, where `sub_position` is set). A `function*`
        // generator is never allowed. Other Declarations (`let`/`const`/`class`) are not `Statement`s.
        const body = if (self.peek().kind == .kw_function) blk: {
            const next_is_star = self.idx + 1 < self.tokens.len and self.tokens[self.idx + 1].kind == .star;
            if (self.strict or next_is_star or sub_position) return ParseError.UnexpectedToken;
            break :blk try self.parseStmt();
        } else try self.parseSubStmt(false);
        // Wrap innermost → outermost so `a: b: stmt` becomes labeled{a, labeled{b, stmt}}.
        var wrapped = try self.allocStmt(body);
        var i = chain.items.len;
        while (i > 0) {
            i -= 1;
            wrapped = try self.allocStmt(.{ .labeled_stmt = .{ .label = chain.items[i], .body = wrapped } });
        }
        return wrapped.*;
    }

    pub fn parseFunction(self: *Parser, is_async: bool) ParseError!*const ast.Function {
        return parse_class.parseFunction(self, is_async);
    }
    pub fn parseClass(self: *Parser, is_declaration: bool, allow_anonymous: bool) ParseError!*const ast.Class {
        return parse_class.parseClass(self, is_declaration, allow_anonymous);
    }
    pub fn collectClassPrivateNames(self: *Parser) ParseError!void {
        return parse_class.collectClassPrivateNames(self);
    }
    pub fn privateNameDeclared(self: *Parser, name: []const u8) bool {
        return parse_class.privateNameDeclared(self, name);
    }
    pub fn parseClassElement(self: *Parser, is_derived: bool) ParseError!ast.ClassElement {
        return parse_class.parseClassElement(self, is_derived);
    }
    pub fn parseStaticBlock(self: *Parser) ParseError!ast.ClassElement {
        return parse_class.parseStaticBlock(self);
    }
    pub fn parseClassAccessor(self: *Parser, is_static: bool, is_get: bool) ParseError!ast.ClassElement {
        return parse_class.parseClassAccessor(self, is_static, is_get);
    }
    pub fn parsePrivateName(self: *Parser) ParseError!PropName {
        return parse_class.parsePrivateName(self);
    }
    pub fn parseParams(self: *Parser) ParseError!ParamList {
        return parse_class.parseParams(self);
    }
    /// Assumes the current token is `(`; consumes through the matching `)`.
    pub fn parseArgs(self: *Parser) ParseError![]const *const ast.Node {
        const saved_no_in = self.no_in; // §14.7.5 `[~In]` reset — arg list is `[+In]`
        self.no_in = false;
        defer self.no_in = saved_no_in;
        _ = try self.expect(.lparen);
        var args: std.ArrayList(*const ast.Node) = .empty;
        while (self.peek().kind != .rparen and self.peek().kind != .eof) {
            try args.append(self.arena, try self.parseSpreadable());
            if (self.peek().kind == .comma) {
                _ = self.advance();
                continue;
            }
            break;
        }
        _ = try self.expect(.rparen);
        return args.items;
    }

    /// §13.3.2 MemberExpression `.` IdentifierName — the name after a `.`/`?.` is an IdentifierName,
    /// so reserved words are valid here (`a.if`, `a?.return`). Returns the name lexeme.
    pub fn expectPropertyName(self: *Parser) ParseError![]const u8 {
        const t = self.peek();
        if (t.kind == .identifier or isKeywordName(t.kind)) {
            _ = self.advance();
            return t.lexeme;
        }
        return ParseError.UnexpectedToken;
    }

    /// An argument or array element that may be a spread `...expr`.
    pub fn parseSpreadable(self: *Parser) ParseError!*const ast.Node {
        const saved_no_in = self.no_in; // §14.7.5 `[~In]` reset — array element / arg is `[+In]`
        self.no_in = false;
        defer self.no_in = saved_no_in;
        if (self.peek().kind == .ellipsis) {
            _ = self.advance();
            return self.alloc(.{ .spread = try self.parseAssignment() });
        }
        return self.parseAssignment();
    }

    pub fn parseBlock(self: *Parser) ParseError![]const ast.Stmt {
        _ = try self.expect(.lbrace);
        // §14.3.1.1: a Block (also a FunctionBody / GeneratorBody / AsyncFunctionBody / try/catch/
        // finally body / ClassStaticBlockBody — all of which parse through here) is a UsingDeclaration
        // allow-list context. Enter it for the duration of this brace pair.
        const saved_using = self.using_allowed;
        self.using_allowed = true;
        defer self.using_allowed = saved_using;
        var stmts: std.ArrayList(ast.Stmt) = .empty;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            try stmts.append(self.arena, try self.parseStmt());
        }
        _ = try self.expect(.rbrace);
        return stmts.items;
    }

    pub fn parseDecl(self: *Parser) ParseError!ast.Stmt {
        const kind: ast.DeclKind = switch (self.advance().kind) {
            .kw_var => .var_decl,
            .kw_let => .let_decl,
            else => .const_decl,
        };
        var decls: std.ArrayList(ast.Declarator) = .empty;
        while (true) {
            // §14.3 LexicalBinding: target is a BindingIdentifier or a BindingPattern.
            const target = try self.parsePattern();
            // §13.1.1 Early Error: in strict, a bound name may not be `eval`/`arguments` or a
            // future-reserved word (applies to every identifier the pattern binds).
            if (self.strict and patternHasStrictReserved(target)) return ParseError.UnexpectedToken;
            var init_expr: ?*const ast.Node = null;
            if (self.peek().kind == .assign) {
                _ = self.advance();
                init_expr = try self.parseAssignment();
            }
            // §14.3.1.1 / §14.3.2: a BindingPattern declaration (and any `const`) requires an
            // initializer — `let {x};`, `const [a];`, `var {y};` are Early SyntaxErrors.
            if (init_expr == null and (target.* != .identifier or kind == .const_decl)) {
                return ParseError.UnexpectedToken;
            }
            try decls.append(self.arena, .{ .target = target, .init = init_expr });
            if (self.peek().kind == .comma) {
                _ = self.advance();
                continue;
            }
            break;
        }
        if (self.peek().kind == .semicolon) _ = self.advance();
        return .{ .declaration = .{ .kind = kind, .decls = decls.items } };
    }

    /// §14.3.1 UsingDeclaration `using BindingList ;` / `await using BindingList ;`. The contextual
    /// `using` (and the leading `await` for the async form) have already been verified by
    /// `atUsingDeclStart` / `atAwaitUsingDeclStart` but NOT consumed. `kind` is `.using_decl` or
    /// `.await_using_decl`. §14.3.1.1 Early Errors enforced here: the Script-top-level prohibition
    /// (`using_allowed`), each LexicalBinding is exactly `BindingIdentifier Initializer` (a
    /// BindingPattern target or a missing Initializer is a SyntaxError), and the bound name may not be
    /// `let`. `for_head` (set by `parseFor`) skips both the trailing `;` and the initializer-required
    /// check (a for-of head has no `= init`, and the for-header's own logic consumes the terminator).
    pub fn parseUsingDecl(self: *Parser, kind: ast.DeclKind, for_head: bool) ParseError!ast.Stmt {
        // §14.3.1.1: a UsingDeclaration is a Syntax Error at the top level of a Script.
        if (!self.using_allowed and !for_head) return ParseError.UnexpectedToken;
        // §16.2.1.6 [[HasTLA]]: an `await using` at module top level awaits at scope disposal, making
        // the module evaluate asynchronously.
        if (kind == .await_using_decl and self.is_module and !self.in_function) self.saw_top_level_await = true;
        if (kind == .await_using_decl) _ = self.advance(); // `await`
        _ = self.advance(); // `using`
        var decls: std.ArrayList(ast.Declarator) = .empty;
        while (true) {
            // §14.3.1: each binding's target is a BindingIdentifier — a BindingPattern is a Syntax Error.
            const target = try self.parsePattern();
            if (target.* != .identifier) return ParseError.UnexpectedToken;
            // §14.3.1.1: the bound name may not be `let` (a lexical binding cannot be named `let`).
            if (std.mem.eql(u8, target.identifier, "let")) return ParseError.UnexpectedToken;
            if (self.strict and patternHasStrictReserved(target)) return ParseError.UnexpectedToken;
            var init_expr: ?*const ast.Node = null;
            if (self.peek().kind == .assign) {
                _ = self.advance();
                init_expr = try self.parseAssignment();
            }
            // §14.3.1.1: every `using`/`await using` LexicalBinding requires an Initializer — EXCEPT in
            // a for head, where a for-of binding has no `= init` (and the C-style-vs-for-of and
            // per-binding-initializer rules are settled by `parseFor` once `of`/`;` is seen).
            if (init_expr == null and !for_head) return ParseError.UnexpectedToken;
            try decls.append(self.arena, .{ .target = target, .init = init_expr });
            if (self.peek().kind == .comma) {
                _ = self.advance();
                continue;
            }
            break;
        }
        if (!for_head and self.peek().kind == .semicolon) _ = self.advance();
        return .{ .declaration = .{ .kind = kind, .decls = decls.items } };
    }

    // ── expressions ─────────────────────────────────────────────────────────

    /// §15.3 ArrowFunction. Builds a `function` node flagged `is_arrow`. An expression body is
    /// normalized to a single `return expr` statement; a `{ … }` body is a normal block.
    /// `params`/`rest` come from the already-parsed (or about-to-parse) formal list.
    pub fn finishArrow(self: *Parser, pl: ParamList) ParseError!*const ast.Node {
        return self.finishArrowAsync(pl, false);
    }

    /// §15.3 / §15.8 ArrowFunction / AsyncArrowFunction. `is_async` flags an async arrow (`async x =>`,
    /// `async (a) =>`), whose body parses with `[+Await]` (and whose `=>` was preceded by `async`).
    pub fn finishArrowAsync(self: *Parser, pl: ParamList, is_async: bool) ParseError!*const ast.Node {
        const enclosing_strict = self.strict;
        const saved_in_async = self.in_async;
        const saved_in_static = self.in_static_block;
        defer self.strict = enclosing_strict; // §11.2.2: never un-strict on the way out
        defer self.in_async = saved_in_async;
        defer self.in_static_block = saved_in_static;
        // §15.7.11: the static-block `Contains await` Early Error does not recurse into an
        // ArrowFunction body, so `await` is an ordinary identifier there (`static { () => { let
        // await; }; }`) — un-reserve it for the body (the params were already parsed by the caller).
        self.in_static_block = false;
        // §15.3.1 Early Error: `ArrowParameters [no LineTerminator here] =>` — a line terminator
        // between the parameters and `=>` is a SyntaxError (ASI must not insert a semicolon here).
        if (self.peek().newline_before) return ParseError.UnexpectedToken;
        // §15.3.1 Early Error: an ArrowFunction's BoundNames must contain no duplicates (unlike a
        // non-strict ordinary function, this holds in every mode).
        if (hasDuplicateBoundNames(pl)) return ParseError.UnexpectedToken;
        // §15.5.1: an arrow appearing inside a generator parses its params with `[+Yield]`, so a
        // YieldExpression in an arrow's parameters (`function* g(){ (x = yield) => {} }`) is a
        // SyntaxError (the params were parsed with `in_generator` set, folding `yield` into a yield node).
        if (self.in_generator and paramsHaveYield(pl)) return ParseError.UnexpectedToken;
        _ = try self.expect(.fat_arrow);
        // §11.2.2 lexical inheritance: a `{ … }` concise body may carry its own "use strict"; an
        // expression body cannot. The arrow's params are subject to strict binding restrictions
        // when the arrow is (itself or by inheritance) strict.
        const body_strict = enclosing_strict or
            (self.peek().kind == .lbrace and directivePrologueIsStrict(self.tokens[self.idx + 1 ..]));
        // §13.1.1: in strict, an arrow's parameter BindingIdentifiers may not be `eval`/`arguments`
        // or a future-reserved word.
        if (body_strict and paramsHaveStrictReserved(pl)) return ParseError.UnexpectedToken;
        self.strict = body_strict;
        // §15.3 ArrowFunction[?Yield, ?Await]: an ordinary arrow's body inherits the enclosing
        // `[?Yield, ?Await]` (an arrow inside a generator/async fn sees `yield`/`await` as operators in
        // its body). An ASYNC arrow forces `[+Await]` for its body regardless. `in_generator` is left
        // untouched (inherited). (The caller set `in_async` true across an `async (…)` param parse; here
        // we keep it true for the async-arrow body too.)
        if (is_async) self.in_async = true;
        const ctrl = self.enterControlScope(); // §14.13: an arrow body starts a fresh label scope
        defer self.exitControlScope(ctrl);
        const body: []const ast.Stmt = if (self.peek().kind == .lbrace)
            // ConciseBody : { FunctionBody }
            try self.parseBlock()
        else blk: {
            // ConciseBody : ExpressionBody  →  implicit `return ExpressionBody`.
            const expr = try self.parseAssignment();
            const stmts = try self.arena.alloc(ast.Stmt, 1);
            stmts[0] = .{ .ret = expr };
            break :blk stmts;
        };
        // §15.1.1 Early Error: a "use strict" directive is forbidden with a non-simple param list.
        if (!isSimpleParameterList(pl) and bodyHasUseStrict(body)) return ParseError.UnexpectedToken;
        // §15.8.1 Early Error: an async arrow's FormalParameters BoundNames may not also occur in the
        // body's LexicallyDeclaredNames (`async (bar) => { let bar; }`).
        if (is_async and paramsConflictWithBodyLexical(pl, body)) return ParseError.UnexpectedToken;
        const f = try self.arena.create(ast.Function);
        f.* = .{ .name = null, .params = pl.params, .rest = pl.rest, .body = body, .is_arrow = true, .is_async = is_async, .strict = body_strict };
        return self.alloc(.{ .function = f });
    }

    /// Bounded lookahead: with `self.idx` on a `(`, scan to its matching `)` (tracking nested
    /// `()`/`[]`/`{}`) and report whether the token after it is `=>`. Used to disambiguate the
    /// arrow cover-grammar `( … ) =>` from a parenthesized expression without backtracking the
    /// real parse. Does not mutate parser state.
    pub fn parenIsArrowHead(self: *Parser) bool {
        return self.parenIsArrowHeadAt(self.idx);
    }

    /// As `parenIsArrowHead`, but the `(` is at the given token index (used for `async ( … ) =>`,
    /// where the `(` sits one past `async`). Returns true iff the token after the matching `)` is `=>`.
    pub fn parenIsArrowHeadAt(self: *Parser, start: usize) bool {
        var i = start; // on the '('
        var depth: usize = 0;
        while (i < self.tokens.len) : (i += 1) {
            switch (self.tokens[i].kind) {
                .lparen, .lbracket, .lbrace => depth += 1,
                .rparen, .rbracket, .rbrace => {
                    depth -= 1;
                    if (depth == 0) {
                        const next = if (i + 1 < self.tokens.len) self.tokens[i + 1].kind else .eof;
                        return next == .fat_arrow;
                    }
                },
                .eof => return false,
                else => {},
            }
        }
        return false;
    }

    /// §14.3.1: is the current token a `using` contextual keyword starting a UsingDeclaration
    /// `using [no LineTerminator here] BindingIdentifier …`? `using` is the declaration head only when
    /// the FOLLOWING token is an identifier (a candidate BindingIdentifier) on the SAME line (no
    /// intervening LineTerminator — else ASI ends an expression statement `using`). `in_for` excludes
    /// `of` (`for (using of …)` is the for-of of an identifier `using`, not a using-decl of `of`).
    /// An escaped `using` is NOT the keyword (§12.7.1 — terminals appear verbatim).
    pub fn atUsingDeclStart(self: *Parser, in_for: bool) bool {
        const t = self.peek();
        if (t.kind != .identifier or t.had_escape or !std.mem.eql(u8, t.lexeme, "using")) return false;
        if (self.idx + 1 >= self.tokens.len) return false;
        const nxt = self.tokens[self.idx + 1];
        if (nxt.newline_before) return false; // §14.3.1 `using [no LineTerminator here]` — ASI splits it
        if (nxt.kind != .identifier) return false; // BindingList must start with a BindingIdentifier
        // §14.7.5 for-head disambiguation: `for (using of …)` is ALWAYS the for-of of the IDENTIFIER
        // `using` (the `of` is the iteration keyword), NOT a using-decl of a binding named `of` — UNLESS
        // an `=` follows the `of`, which is the only C-style reading (`for (using of = …;;)`, a using-
        // decl of binding `of`). So: `using of` heads a decl only when the token after `of` is `=`.
        if (in_for and std.mem.eql(u8, nxt.lexeme, "of") and !nxt.had_escape) {
            const after = if (self.idx + 2 < self.tokens.len) self.tokens[self.idx + 2] else return false;
            if (after.kind != .assign) return false; // `for (using of of …)` / `for (using of [..])` → identifier
        }
        return true;
    }

    /// §14.3.1: is the current token an `await` keyword starting an `await using` declaration
    /// `await [no LineTerminator here] using [no LineTerminator here] BindingIdentifier …`? Only inside
    /// an async context (`in_async`) is `await` a keyword. The `using` must follow on the same line, and
    /// `using` must in turn be followed by a same-line BindingIdentifier.
    pub fn atAwaitUsingDeclStart(self: *Parser, in_for: bool) bool {
        _ = in_for;
        if (!self.in_async) return false;
        const t = self.peek();
        if (t.kind != .identifier or t.had_escape or !std.mem.eql(u8, t.lexeme, "await")) return false;
        if (self.idx + 2 >= self.tokens.len) return false;
        const u = self.tokens[self.idx + 1];
        if (u.newline_before or u.kind != .identifier or u.had_escape or !std.mem.eql(u8, u.lexeme, "using")) return false;
        const nxt = self.tokens[self.idx + 2];
        if (nxt.newline_before or nxt.kind != .identifier) return false;
        // §14.7.5: unlike plain `using`, `await using <ident>` is UNAMBIGUOUSLY a declaration head even
        // when the binding is `of` (`for (await using of of …)` = await-using of binding `of`, then the
        // for-of keyword) — `await` cannot be a for-of loop variable here, so there is no `of` exclusion.
        return true;
    }

    /// §15.8: is the current token an `async` contextual keyword starting an AsyncFunctionDeclaration
    /// `async [no LineTerminator here] function …`? `async` is the modifier only when `function`
    /// follows on the SAME line (no intervening LineTerminator — else ASI splits it). The `function`
    /// keyword must immediately follow `async`.
    pub fn atAsyncFunctionStart(self: *Parser) bool {
        // Structural recognition only — escape-ness is checked by the caller (§12.7.1: `async`
        // [no LT] `function` IS the AsyncFunction production even when escaped; the escape is an
        // Early Error, not a re-parse as an identifier).
        if (self.peek().kind != .identifier or !std.mem.eql(u8, self.peek().lexeme, "async")) return false;
        if (self.idx + 1 >= self.tokens.len) return false;
        const nxt = self.tokens[self.idx + 1];
        return nxt.kind == .kw_function and !nxt.newline_before;
    }

    /// §15.8: classify an `async`-led head in expression (AssignmentExpression) position. Returns the
    /// kind of async construct starting here, or null if `async` is not a modifier (it is then an
    /// ordinary IdentifierReference — `async`, `async()` call, `async + 1`, `async\nx => …`, etc.).
    /// `async` is the modifier ONLY with NO LineTerminator before the following token (§15.8 restricted
    /// production) AND the following form is an arrow head or `function`. A trailing `=>` after the
    /// matching `)` distinguishes `async (a, b) => …` from a call `async(a, b)`.
    const AsyncHead = enum { arrow_ident, arrow_paren, function_expr };
    pub fn atAsyncArrowOrFunction(self: *Parser) ?AsyncHead {
        // Structural recognition only — escape-ness checked by the caller (§12.7.1 Early Error).
        if (self.peek().kind != .identifier or !std.mem.eql(u8, self.peek().lexeme, "async")) return null;
        if (self.idx + 1 >= self.tokens.len) return null;
        const nxt = self.tokens[self.idx + 1];
        // §15.8 restricted production `async [no LineTerminator here] …` — a LineTerminator after
        // `async` makes it a plain IdentifierReference (ASI), never the modifier.
        if (nxt.newline_before) return null;
        // `async function …` / `async function* …` — an AsyncFunctionExpression / AsyncGeneratorExpression.
        if (nxt.kind == .kw_function) return .function_expr;
        // `async Identifier =>` — a single-parameter async arrow. The identifier must be on the same
        // line as `async`, and `=>` must immediately follow (also same line — checked in finishArrow).
        if (nxt.kind == .identifier and self.idx + 2 < self.tokens.len and
            self.tokens[self.idx + 2].kind == .fat_arrow)
        {
            return .arrow_ident;
        }
        // `async ( … ) =>` — a parenthesized async arrow (vs the call `async(...)`, which has no `=>`).
        if (nxt.kind == .lparen and self.parenIsArrowHeadAt(self.idx + 1)) return .arrow_paren;
        return null;
    }

    /// §13.16 Expression — the comma / sequence operator layer that wraps AssignmentExpression.
    /// `a, b, c` left-associates into nested `comma` nodes; each operand is a full
    /// AssignmentExpression. This is ONLY valid where the grammar allows an *Expression* (expression
    /// statements, parenthesized expressions, and the `for(init; test; update)` clauses) — it must
    /// NOT be used for the comma-separated AssignmentExpression *lists* of call args, array elements,
    /// object properties, parameters, or declarators (those keep using `parseAssignment` /
    /// `parseSpreadable`). The arrow cover-grammar is unaffected: `parseAssignment` still fires its
    /// `( … ) =>` lookahead first, so `(a, b) => …` parses as params while `(a, b)` is a sequence.
    pub inline fn parseExpression(self: *Parser) ParseError!*const ast.Node {
        return parse_expr.parseExpression(self);
    }
    pub inline fn parseAssignment(self: *Parser) ParseError!*const ast.Node {
        return parse_expr.parseAssignment(self);
    }
    pub fn parseYield(self: *Parser) ParseError!*const ast.Node {
        return parse_expr.parseYield(self);
    }
    pub fn validateAssignmentPattern(self: *Parser, node: *const ast.Node) ParseError!void {
        return parse_expr.validateAssignmentPattern(self, node);
    }
    pub fn validateAssignmentTarget(self: *Parser, node: *const ast.Node) ParseError!void {
        return parse_expr.validateAssignmentTarget(self, node);
    }
    pub inline fn parseConditional(self: *Parser) ParseError!*const ast.Node {
        return parse_expr.parseConditional(self);
    }
    pub inline fn parseShortCircuit(self: *Parser) ParseError!*const ast.Node {
        return parse_expr.parseShortCircuit(self);
    }
    pub inline fn parseExpr(self: *Parser, min_prec: u8) ParseError!*const ast.Node {
        return parse_expr.parseExpr(self, min_prec);
    }
    pub inline fn parseExprFrom(self: *Parser, left_init: *const ast.Node, min_prec: u8) ParseError!*const ast.Node {
        return parse_expr.parseExprFrom(self, left_init, min_prec);
    }
    pub inline fn parseUnary(self: *Parser) ParseError!*const ast.Node {
        return parse_expr.parseUnary(self);
    }
    pub inline fn parsePostfix(self: *Parser) ParseError!*const ast.Node {
        return parse_expr.parsePostfix(self);
    }
    pub fn parseSuper(self: *Parser) ParseError!*const ast.Node {
        return parse_expr.parseSuper(self);
    }
    pub inline fn continuePostfix(self: *Parser, base: *const ast.Node, started_in_chain: bool, base_off: u32) ParseError!*const ast.Node {
        return parse_expr.continuePostfix(self, base, started_in_chain, base_off);
    }
    pub fn parseMethodBody(self: *Parser, pl: ParamList, strict_out: ?*bool) ParseError![]const ast.Stmt {
        return parse_expr.parseMethodBody(self, pl, strict_out);
    }
    pub fn parseObjectLiteral(self: *Parser) ParseError!*const ast.Node {
        return parse_expr.parseObjectLiteral(self);
    }
    pub fn parsePropertyName(self: *Parser) ParseError!PropName {
        return parse_expr.parsePropertyName(self);
    }
    pub fn parseNumericLiteral(self: *Parser, lexeme: []const u8) ParseError!f64 {
        return parse_expr.parseNumericLiteral(self, lexeme);
    }
    pub fn parseBigIntLiteral(self: *Parser, lexeme: []const u8) ParseError!*const std.math.big.int.Const {
        return parse_expr.parseBigIntLiteral(self, lexeme);
    }
    pub inline fn parsePrimary(self: *Parser) ParseError!*const ast.Node {
        return parse_expr.parsePrimary(self);
    }
};
