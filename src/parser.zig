//! Recursive-descent / precedence-climbing parser (ECMA-262 §13–§14). M1 adds statements
//! (declarations, blocks, expression statements) and identifier / assignment expressions.
//! Reports SyntaxError on malformed input (the parse-phase error for negative Test262 cases).
const std = @import("std");
const ast = @import("ast.zig");
const lex = @import("lexer.zig");

pub const ParseError = error{ UnexpectedToken, UnexpectedEof } || lex.LexError;

pub const Parser = struct {
    tokens: []const lex.Token,
    idx: usize = 0,
    arena: std.mem.Allocator,
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
        var p = Parser{ .tokens = toks.items, .arena = arena, .strict = strict };
        return p.parseProgram();
    }

    fn peek(self: *Parser) lex.Token {
        return self.tokens[self.idx];
    }

    fn advance(self: *Parser) lex.Token {
        const t = self.tokens[self.idx];
        if (self.idx + 1 < self.tokens.len) self.idx += 1;
        return t;
    }

    fn expect(self: *Parser, kind: lex.TokenKind) ParseError!lex.Token {
        if (self.peek().kind != kind) return ParseError.UnexpectedToken;
        return self.advance();
    }

    fn alloc(self: *Parser, node: ast.Node) ParseError!*const ast.Node {
        const p = try self.arena.create(ast.Node);
        p.* = node;
        return p;
    }

    fn allocStmt(self: *Parser, stmt: ast.Stmt) ParseError!*const ast.Stmt {
        const p = try self.arena.create(ast.Stmt);
        p.* = stmt;
        return p;
    }

    fn allocPattern(self: *Parser, pat: ast.Pattern) ParseError!*const ast.Pattern {
        const p = try self.arena.create(ast.Pattern);
        p.* = pat;
        return p;
    }

    /// §14.7.5 `[~In]` reset: any bracketed sub-expression (`( … )`, `[ … ]`, call args, array/object
    /// literal contents, `${ … }`) is `[+In]` — the relational `in` is a normal operator there even
    /// inside a for-header's first clause. These wrappers clear `no_in` for the inner parse and restore
    /// it, so `for ((a in b);;)` / `for (a[b in c];;)` keep `in` while `for (a in b)` is a for-in head.
    fn parseAssignmentInBrackets(self: *Parser) ParseError!*const ast.Node {
        const saved = self.no_in;
        self.no_in = false;
        defer self.no_in = saved;
        return self.parseAssignment();
    }

    fn parseExpressionInBrackets(self: *Parser) ParseError!*const ast.Node {
        const saved = self.no_in;
        self.no_in = false;
        defer self.no_in = saved;
        return self.parseExpression();
    }

    /// §13.3.3 BindingPattern — a binding identifier, an ArrayBindingPattern `[ … ]`, or an
    /// ObjectBindingPattern `{ … }`. Used by both declarations (§14.3) and parameters (§15.1).
    fn parsePattern(self: *Parser) ParseError!*const ast.Pattern {
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
    fn parseArrayPattern(self: *Parser) ParseError!*const ast.Pattern {
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
    fn parseObjectPattern(self: *Parser) ParseError!*const ast.Pattern {
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

    /// §13.2.8 Template literal: split raw inner text into cooked quasis + expression sources,
    /// sub-parsing each `${...}`. quasis.len == exprs.len + 1.
    fn parseTemplate(self: *Parser, raw: []const u8) ParseError!*const ast.Node {
        var quasis: std.ArrayList([]const u8) = .empty;
        var exprs: std.ArrayList(*const ast.Node) = .empty;
        var cooked: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                // §12.9.6 TemplateCharacter escape: shares §12.9.4.1 Character/Hex/Unicode escapes with
                // string literals (UTF-8-encoded), plus `\0` NUL and LineContinuation; templates FORBID
                // legacy octal / `\8` / `\9` (handled leniently — see spec). Find the end of this one
                // escape (up to the next backslash / `${` / end) and decode the slice via the lexer.
                var j = i + 2;
                while (j < raw.len and raw[j] != '\\' and !(raw[j] == '$' and j + 1 < raw.len and raw[j + 1] == '{')) j += 1;
                try lex.Lexer.decodeEscapesInto(self.arena, &cooked, raw[i..j], true);
                i = j;
                continue;
            }
            if (raw[i] == '$' and i + 1 < raw.len and raw[i + 1] == '{') {
                try quasis.append(self.arena, cooked.items);
                cooked = .empty;
                i += 2;
                const expr_start = i;
                var depth: usize = 1;
                while (i < raw.len and depth > 0) {
                    if (raw[i] == '{') depth += 1 else if (raw[i] == '}') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                    i += 1;
                }
                const prog = try Parser.parseMode(self.arena, raw[expr_start..i], self.strict);
                const node = if (prog.statements.len > 0 and prog.statements[0] == .expr)
                    prog.statements[0].expr
                else
                    try self.alloc(.{ .string = "" });
                try exprs.append(self.arena, node);
                i += 1; // skip closing }
                continue;
            }
            try cooked.append(self.arena, raw[i]);
            i += 1;
        }
        try quasis.append(self.arena, cooked.items);
        return self.alloc(.{ .template = .{ .quasis = quasis.items, .exprs = exprs.items } });
    }

    /// §13.3.5 `new Callee(args)`. Callee is a member expression (no call); the argument list
    /// binds to the `new`, so `new a.b.C(x)` constructs `a.b.C`.
    fn parseNew(self: *Parser) ParseError!*const ast.Node {
        _ = self.advance(); // new
        var callee = try self.parsePrimary();
        while (true) {
            switch (self.peek().kind) {
                .dot => {
                    _ = self.advance();
                    const name = try self.expect(.identifier);
                    callee = try self.alloc(.{ .member = .{ .object = callee, .name = name.lexeme } });
                },
                .lbracket => {
                    _ = self.advance();
                    const key = try self.parseAssignmentInBrackets();
                    _ = try self.expect(.rbracket);
                    callee = try self.alloc(.{ .index = .{ .object = callee, .key = key } });
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
        return self.alloc(.{ .new_expr = .{ .callee = callee, .args = args } });
    }

    fn parseIf(self: *Parser) ParseError!ast.Stmt {
        _ = self.advance(); // if
        _ = try self.expect(.lparen);
        const cond = try self.parseAssignment();
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
    fn parseWith(self: *Parser) ParseError!ast.Stmt {
        _ = self.advance(); // with
        if (self.strict) return ParseError.UnexpectedToken;
        _ = try self.expect(.lparen);
        const object = try self.parseExpression();
        _ = try self.expect(.rparen);
        const body = try self.allocStmt(try self.parseSubStmt(false));
        return .{ .with_stmt = .{ .object = object, .body = body } };
    }

    fn parseWhile(self: *Parser) ParseError!ast.Stmt {
        _ = self.advance(); // while
        _ = try self.expect(.lparen);
        const cond = try self.parseAssignment();
        _ = try self.expect(.rparen);
        self.iteration_depth += 1;
        defer self.iteration_depth -= 1;
        const body = try self.allocStmt(try self.parseSubStmt(true));
        return .{ .while_stmt = .{ .cond = cond, .body = body } };
    }

    /// §14.7.2 `do Statement while ( Expression ) ;`. The trailing `;` is ASI-optional via the
    /// special rule in §14.7.2 (the `;` is auto-inserted regardless of a line terminator), so we
    /// consume an explicit `;` if present but never require it.
    fn parseDoWhile(self: *Parser) ParseError!ast.Stmt {
        _ = self.advance(); // do
        const body = blk: {
            self.iteration_depth += 1;
            defer self.iteration_depth -= 1;
            break :blk try self.allocStmt(try self.parseSubStmt(true));
        };
        _ = try self.expect(.kw_while);
        _ = try self.expect(.lparen);
        const cond = try self.parseAssignment();
        _ = try self.expect(.rparen);
        if (self.peek().kind == .semicolon) _ = self.advance();
        return .{ .do_while_stmt = .{ .cond = cond, .body = body } };
    }

    /// §14.7.5 contextual `of`: lexed as an identifier with lexeme `"of"`. Recognized only in a
    /// for-header (here) as the for-of marker — everywhere else `of` is an ordinary identifier.
    fn peekIsOf(self: *Parser) bool {
        const t = self.peek();
        // §12.7.1: a contextual keyword spelled with a Unicode escape is NOT the keyword (`of`
        // is the identifier `of`, never the for-of marker) — terminal symbols must appear verbatim.
        return t.kind == .identifier and !t.had_escape and std.mem.eql(u8, t.lexeme, "of");
    }

    fn parseFor(self: *Parser) ParseError!ast.Stmt {
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
    fn finishForInOf(self: *Parser, head: ast.ForHead, is_of: bool, is_await: bool) ParseError!ast.Stmt {
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

    fn parseSwitch(self: *Parser) ParseError!ast.Stmt {
        _ = self.advance(); // switch
        _ = try self.expect(.lparen);
        const disc = try self.parseAssignment();
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

    fn parseTry(self: *Parser) ParseError!ast.Stmt {
        _ = self.advance(); // try
        const block = try self.parseBlock();
        var catch_param: ?[]const u8 = null;
        var catch_block: ?[]const ast.Stmt = null;
        var finally_block: ?[]const ast.Stmt = null;
        if (self.peek().kind == .kw_catch) {
            _ = self.advance();
            if (self.peek().kind == .lparen) {
                _ = self.advance();
                const cp = try self.expect(.identifier);
                // §12.7.1: an escaped ReservedWord is not a valid catch-parameter BindingIdentifier.
                if (isEscapedReservedIdent(cp)) return ParseError.UnexpectedToken;
                // §13.1.1 Early Error: in strict, a catch parameter (a BindingIdentifier) may not be
                // `eval`/`arguments` or a future-reserved word.
                if (self.strict and isStrictReservedBindingName(cp.lexeme)) return ParseError.UnexpectedToken;
                catch_param = cp.lexeme;
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

    fn parseProgram(self: *Parser) ParseError!ast.Program {
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

    fn parseStmt(self: *Parser) ParseError!ast.Stmt {
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
    fn parseSubStmt(self: *Parser, loop_body: bool) ParseError!ast.Stmt {
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

    fn parseStmtInner(self: *Parser) ParseError!ast.Stmt {
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
            .kw_class => return .{ .class_decl = try self.parseClass(true) },
            .kw_return => {
                _ = self.advance();
                var arg: ?*const ast.Node = null;
                const k = self.peek().kind;
                if (k != .semicolon and k != .rbrace and k != .eof) arg = try self.parseAssignment();
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
                const e = try self.parseAssignment();
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

    fn hasLabel(self: *Parser, list: []const []const u8, name: []const u8) bool {
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

    fn enterControlScope(self: *Parser) ControlScope {
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

    fn exitControlScope(self: *Parser, saved: ControlScope) void {
        self.labels = saved.labels;
        self.iteration_labels = saved.iteration_labels;
        self.iteration_depth = saved.iteration_depth;
        self.switch_depth = saved.switch_depth;
    }

    /// Does `kind` begin an IterationStatement (§14.7)? A label that (transitively) prefixes one of
    /// these is a valid `continue` target; a label prefixing anything else is `break`-only.
    fn tokenStartsIterationStmt(kind: lex.TokenKind) bool {
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
    fn parseLabeled(self: *Parser, sub_position: bool) ParseError!ast.Stmt {
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

    /// §15.2 / §15.5 / §15.8: `[async] function [*] [name] (params) { body }` — shared by declarations
    /// and expressions. The current token is the one AFTER `function` (the caller consumed any `async`
    /// and the `function` keyword); a leading `*` (§15.5 Generator / §15.6 AsyncGenerator) is consumed
    /// here and flips the generator context for the body. `is_async` (§15.8) flips the await context.
    fn parseFunction(self: *Parser, is_async: bool) ParseError!*const ast.Function {
        const enclosing_strict = self.strict;
        defer self.strict = enclosing_strict; // §11.2.2: never un-strict an inner scope on the way out
        // §13.3.5/§13.3.7: an ordinary FunctionDeclaration/Expression has its OWN [[HomeObject]] (none)
        // and is not a constructor — `super` does NOT cross into it from an enclosing method. (Arrows
        // DO inherit `super` lexically, like `this`; `finishArrow` deliberately keeps these flags.)
        const saved_in_method = self.in_method;
        const saved_in_derived = self.in_derived_ctor;
        const saved_in_static = self.in_static_block;
        const saved_in_generator = self.in_generator;
        const saved_in_async = self.in_async;
        defer self.in_method = saved_in_method;
        defer self.in_derived_ctor = saved_in_derived;
        defer self.in_static_block = saved_in_static;
        defer self.in_generator = saved_in_generator;
        defer self.in_async = saved_in_async;
        self.in_method = false;
        self.in_derived_ctor = false;
        self.in_static_block = false; // §15.7.11: a nested ordinary function un-reserves `await`
        // §15.5: a leading `*` marks a generator. `yield` is the §14.4 operator only inside ITS body;
        // an ordinary nested function un-sets `in_generator` (yield does not cross into it).
        const is_generator = self.peek().kind == .star;
        if (is_generator) _ = self.advance();
        // §15.5/§15.8: the BODY parses with `[+Yield]`/`[+Await]`, but the FormalParameters are
        // restricted — a `yield`/`await` operator in a default is a §15.5.1/§15.8.1 SyntaxError. We keep
        // `in_generator`/`in_async` false across the name + params (so `yield`/`await` as an operator
        // there does not parse), set them for the body only, and explicitly reject `yield`/`await` as
        // the function's name / a param BindingIdentifier below.
        self.in_generator = false;
        self.in_async = false;
        var name: ?[]const u8 = null;
        if (self.peek().kind == .identifier) {
            // §12.7.1: an escaped ReservedWord is not a valid function-name BindingIdentifier.
            if (isEscapedReservedIdent(self.peek())) return ParseError.UnexpectedToken;
            name = self.advance().lexeme;
        }
        // §13.1.1: a strict function's name (BindingIdentifier) may not be `eval`/`arguments`/a
        // future-reserved word. Checked against the *enclosing* strictness (the name is declared
        // in the outer scope).
        if (enclosing_strict) if (name) |nm| if (isStrictReservedBindingName(nm)) return ParseError.UnexpectedToken;
        // §15.5.1: a generator's BindingIdentifier may not be `yield`, and (in a generator) `yield` may
        // not be a parameter BindingIdentifier (`function* g(yield){}` / `function* yield(){}`).
        if (is_generator) if (name) |nm| if (std.mem.eql(u8, nm, "yield")) return ParseError.UnexpectedToken;
        // §15.8.1: an async function's BindingIdentifier may not be `await`, and `await` may not be an
        // async function's parameter BindingIdentifier (`async function await(){}` / `async function
        // f(await){}`). The name is bound in the enclosing scope; the `[+Await]` of the surrounding
        // context (an async fn nested in another) also forbids it — but the function's own asyncness
        // is sufficient to reject its name/params.
        if (is_async) if (name) |nm| if (std.mem.eql(u8, nm, "await")) return ParseError.UnexpectedToken;
        const pl = try self.parseParams();
        if (is_generator and paramsHaveYield(pl)) return ParseError.UnexpectedToken;
        // §15.8.1: an async function's FormalParameters may not bind `await` (`async function f(await){}`)
        // nor contain an AwaitExpression (the params parse `~Await`, so `await x` there is the identifier
        // `await` applied to `x` — a syntax error on its own — but `await` as a binding name is the case
        // we must reject explicitly).
        if (is_async and paramsHaveAwait(pl)) return ParseError.UnexpectedToken;
        // §15.5.1: a GeneratorDeclaration/Expression has UniqueFormalParameters — no duplicate bound
        // names, in EVERY mode (not only strict), so `function*(x = 0, x){}` is a SyntaxError sloppy too.
        if (is_generator and hasDuplicateBoundNames(pl)) return ParseError.UnexpectedToken;
        // §15.8.1 / §15.6.1: an AsyncFunction/AsyncGenerator also has UniqueFormalParameters.
        if (is_async and hasDuplicateBoundNames(pl)) return ParseError.UnexpectedToken;
        // §11.2.2 lexical inheritance: the body is strict if the enclosing scope is, OR it carries
        // its own "use strict" prologue. Prescan the body tokens (current token is `{`) so the
        // param/body Early Errors below see the function's own strictness.
        const body_strict = enclosing_strict or
            (self.peek().kind == .lbrace and directivePrologueIsStrict(self.tokens[self.idx + 1 ..]));
        // §13.1.1 / §15.1.1: in strict, the parameter BindingIdentifiers may not be reserved and
        // must be unique. (Arrows/methods already enforce uniqueness in every mode.)
        if (body_strict) {
            if (paramsHaveStrictReserved(pl)) return ParseError.UnexpectedToken;
            if (hasDuplicateBoundNames(pl)) return ParseError.UnexpectedToken;
        }
        self.strict = body_strict;
        self.in_generator = is_generator; // §15.5: the GeneratorBody parses with `[+Yield]`
        self.in_async = is_async; // §15.8: the AsyncFunctionBody parses with `[+Await]`
        // §14.13/§14.8/§14.9: labels and the iteration/switch nest do NOT cross a function boundary —
        // the body starts with a fresh, empty label scope (`break`/`continue` can't target an outer
        // loop). Saved/restored around the body parse.
        const ctrl = self.enterControlScope();
        defer self.exitControlScope(ctrl);
        const body = try self.parseBlock();
        // §15.1.1 Early Error: a "use strict" directive is forbidden when the parameter list is
        // non-simple (has defaults, patterns, or a rest element).
        if (!isSimpleParameterList(pl) and bodyHasUseStrict(body)) return ParseError.UnexpectedToken;
        // §15.8.1 / §15.6.1 Early Error: for an AsyncFunction / AsyncGenerator, a BoundName of the
        // FormalParameters may not also occur in the LexicallyDeclaredNames of the body
        // (`async function f(bar){ let bar; }`). (Ordinary/generator functions have the same rule but
        // are tracked separately as pre-existing cuts; methods already enforce it.)
        if (is_async and paramsConflictWithBodyLexical(pl, body)) return ParseError.UnexpectedToken;
        const f = try self.arena.create(ast.Function);
        f.* = .{ .name = name, .params = pl.params, .rest = pl.rest, .body = body, .is_generator = is_generator, .is_async = is_async, .strict = body_strict };
        return f;
    }

    /// §15.7 ClassDeclaration / ClassExpression. The current token is `class`. A declaration requires
    /// a binding name; an expression's name is optional. The ClassBody parses in STRICT context
    /// (§15.7 — classes are always strict), lexically inherited like a function body.
    /// `extends LeftHandSideExpression` is parsed (so heritage syntax doesn't parse-reject); the
    /// superclass link + `super` are wired in Cycle 2.
    fn parseClass(self: *Parser, is_declaration: bool) ParseError!*const ast.Class {
        _ = self.advance(); // class
        var name: ?[]const u8 = null;
        // §15.7: a class name is a BindingIdentifier. `extends`/`{` end the (optional) name.
        if (self.peek().kind == .identifier) {
            // §12.7.1: an escaped ReservedWord is not a valid class-name BindingIdentifier.
            if (isEscapedReservedIdent(self.peek())) return ParseError.UnexpectedToken;
            // §13.1.1: a class name may not be a strict-reserved word — and a class body is always
            // strict, so this holds in every mode.
            if (isStrictReservedBindingName(self.peek().lexeme)) return ParseError.UnexpectedToken;
            // §15.7.11: `await` is reserved inside a static block — `class await {}` there is invalid.
            if (self.in_static_block and std.mem.eql(u8, self.peek().lexeme, "await")) return ParseError.UnexpectedToken;
            name = self.advance().lexeme;
        } else if (is_declaration) {
            // A ClassDeclaration requires a name (the anonymous form is only a ClassExpression /
            // `export default`); reject `class { }` in statement position.
            return ParseError.UnexpectedToken;
        }

        // §15.7 ClassHeritage : `extends` LeftHandSideExpression (optional).
        var superclass: ?*const ast.Node = null;
        if (self.peek().kind == .kw_extends) {
            _ = self.advance();
            // LeftHandSideExpression — `parsePostfix` covers `A`, `a.b`, `f()`, member/call chains.
            superclass = try self.parsePostfix();
        }

        // §15.7 ClassBody parses in strict context; restore on the way out. The ClassBody is also a
        // PrivateName scope (`#x` is parseable here, a SyntaxError outside); inherited by nested bodies.
        const enclosing_strict = self.strict;
        const enclosing_in_class = self.in_class_body;
        defer self.strict = enclosing_strict;
        defer self.in_class_body = enclosing_in_class;
        self.strict = true;
        self.in_class_body = true;

        const is_derived = superclass != null; // §15.7.14: `extends`-bearing class → derived ctors

        _ = try self.expect(.lbrace);
        // §15.7.1 AllPrivateNamesValid: pre-scan this ClassBody's PrivateBoundNames and add them to the
        // in-scope set (so references — including forward references to a name declared later in the
        // body — resolve). Remember the count to truncate on exit (the names leave scope with the body).
        const private_base = self.private_names.items.len;
        defer self.private_names.shrinkRetainingCapacity(private_base);
        try self.collectClassPrivateNames();

        var elements: std.ArrayList(ast.ClassElement) = .empty;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            // §15.7 ClassElement : `;` — an empty element is allowed and ignored.
            if (self.peek().kind == .semicolon) {
                _ = self.advance();
                continue;
            }
            try elements.append(self.arena, try self.parseClassElement(is_derived));
        }
        _ = try self.expect(.rbrace);

        // §15.7.1 Early Error: a ClassBody may declare at most one `constructor` method.
        var seen_ctor = false;
        for (elements.items) |el| {
            if (el.kind == .constructor) {
                if (seen_ctor) return ParseError.UnexpectedToken;
                seen_ctor = true;
            }
        }
        // §15.7.1 Early Error: PrivateBoundIdentifiers of a ClassBody must be unique — EXCEPT a
        // `get`/`set` accessor pair may share a name, and a static + non-static of the same name still
        // clash. A method/field/accessor named `#constructor` is forbidden (`#x` can't be the ctor).
        if (try hasDuplicatePrivateNames(self.arena, elements.items)) return ParseError.UnexpectedToken;

        const c = try self.arena.create(ast.Class);
        c.* = .{ .name = name, .superclass = superclass, .elements = elements.items };
        return c;
    }

    /// §15.7.1 PrivateBoundNames — without consuming input, scan the current ClassBody (from the token
    /// after its `{`, which is where `self.idx` sits) and append each private member NAME to
    /// `self.private_names`. A PrivateIdentifier is a *declaration* (a class-element name) when it
    /// appears at the class-body top level (brace-depth 0 relative to the body, and not inside a `(`
    /// param list or `[` computed key) — i.e. as a `#x`, `static #x`, or `get/set #x` element key.
    /// PrivateIdentifiers inside element bodies / initializers (brace-depth > 0) are references, not
    /// declarations, so they are skipped. A nested class's body (`{ … }` inside this one) is also at
    /// depth > 0, so its own private names are collected when that class is parsed (and shadow-stack via
    /// the recursion). Does not validate — duplicate detection happens after the real parse.
    fn collectClassPrivateNames(self: *Parser) ParseError!void {
        var i = self.idx;
        var depth: usize = 0; // nesting of {} ( ) [ ] relative to the class body
        while (i < self.tokens.len) : (i += 1) {
            const k = self.tokens[i].kind;
            switch (k) {
                .lbrace, .lparen, .lbracket => depth += 1,
                .rbrace, .rparen, .rbracket => {
                    if (depth == 0) return; // hit the class body's closing `}`
                    depth -= 1;
                },
                .private_identifier => {
                    // A declaration is a private name at the class-body top level (depth 0) that is in
                    // element-NAME position — i.e. NOT a member reference `this.#x` (preceded by `.`)
                    // and NOT a brand-check `#x in obj` (followed by `in`). A field initializer like
                    // `f = this.#x` / `f = #x in o` also sits at depth 0, so these guards distinguish a
                    // reference from a declared element name.
                    const prev_is_dot = i > 0 and self.tokens[i - 1].kind == .dot;
                    const next_is_in = i + 1 < self.tokens.len and self.tokens[i + 1].kind == .kw_in;
                    if (depth == 0 and !prev_is_dot and !next_is_in) {
                        try self.private_names.append(self.arena, self.tokens[i].lexeme);
                    }
                },
                .eof => return,
                else => {},
            }
        }
    }

    /// §15.7.1 AllPrivateNamesValid — is the PrivateName `name` (`#` included) declared by some
    /// enclosing ClassBody currently in scope?
    fn privateNameDeclared(self: *Parser, name: []const u8) bool {
        for (self.private_names.items) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }

    /// §15.7 ClassElement — a method `m(){…}`, a `constructor(){…}`, a `static` method, a field
    /// `x = init;` / `x;` (instance or static), a §15.7.11 `static { … }` initialization block, or a
    /// PrivateName member `#x` / `#m(){}` / `get #x(){}` (Cycle 4). Still parse-rejected (preserve the
    /// negatives): generators (`* m`) and `async` methods (a separate future milestone).
    fn parseClassElement(self: *Parser, is_derived: bool) ParseError!ast.ClassElement {
        // §15.7 `static` modifier (contextual): it is a modifier only when followed by something that
        // begins a (non-static) element name. `static(){}`/`static = 1`/`static;`/`static }` use the
        // identifier `static` as the element key instead.
        var is_static = false;
        if (self.peek().kind == .identifier and !self.peek().had_escape and std.mem.eql(u8, self.peek().lexeme, "static")) {
            const next = self.tokens[self.idx + 1].kind;
            switch (next) {
                // `static` as a key, not a modifier.
                .lparen, .assign, .semicolon, .rbrace => {},
                // §15.7.11 ClassStaticBlock `static { … }` — a block that runs once at class
                // definition with `this` = the constructor. Parsed in a method-like context: it has a
                // [[HomeObject]] (so `super.x` is allowed), but `super(...)`/`arguments`/`await`/`yield`
                // restrictions apply (we model the common subset — `super.x` ok, `super()` rejected).
                .lbrace => {
                    _ = self.advance(); // `static`
                    return self.parseStaticBlock();
                },
                else => {
                    is_static = true;
                    _ = self.advance(); // consume `static`
                },
            }
        }

        // §15.7 GeneratorMethod `* m(){…}` / §15.8 AsyncMethod `async m(){…}` / §15.6 AsyncGeneratorMethod
        // `async * m(){…}` — a leading `*` marks a generator method (§15.5); a leading `async` (no
        // LineTerminator before the name) marks an async method, optionally followed by `*` for an
        // async generator. Accessors `get`/`set` (handled just below), computed names `[expr]`, and
        // PrivateName members `#x` (handled below) land too. `get`/`set`/`async` are only a modifier
        // when followed by something that begins a property name (else they are an ordinary element
        // key, e.g. `get(){}` / `get = 1` / `get;` / `async(){}` / `async;`).
        var is_generator_method = false;
        var is_async_method = false;
        // §15.8: `async` is the modifier only when (no LineTerminator before the next token AND) the
        // next token begins a property name or is `*`. `async \n m(){}` is the field `async` then a
        // method `m` (ASI), so a LineTerminator un-sets the modifier.
        if (self.peek().kind == .identifier and !self.peek().had_escape and std.mem.eql(u8, self.peek().lexeme, "async") and
            !self.tokens[self.idx + 1].newline_before and
            (startsAccessorName(self.tokens[self.idx + 1].kind) or self.tokens[self.idx + 1].kind == .star))
        {
            is_async_method = true;
            _ = self.advance(); // consume `async`
        }
        switch (self.peek().kind) {
            .star => {
                is_generator_method = true;
                _ = self.advance(); // consume `*`
            },
            .identifier => {
                const w = self.peek().lexeme;
                // §15.7 `get x(){…}` / `set x(v){…}` accessor (instance or static). A `get`/`set`
                // followed by a PrivateIdentifier is a PRIVATE accessor `get #x(){…}`. (Not reachable
                // when `is_async_method` — `async get(){}` is an async method named `get`.) §12.7.1: an
                // escaped `get`/`set` is the plain identifier, never the accessor modifier.
                if (!is_async_method and !self.peek().had_escape and (std.mem.eql(u8, w, "get") or std.mem.eql(u8, w, "set")) and
                    startsAccessorName(self.tokens[self.idx + 1].kind))
                {
                    return self.parseClassAccessor(is_static, std.mem.eql(u8, w, "get"));
                }
            },
            else => {},
        }

        // §15.7 a PrivateName member: a `#x` field/method/accessor. The leading `get`/`set` accessor
        // case is handled above (it flows through parseClassAccessor, which reads the `#name`).
        const is_private = self.peek().kind == .private_identifier;

        // Parse the element's PropertyName: an identifier/string/number/`[computed]`, OR a `#name`
        // PrivateIdentifier (Cycle 4). A private name is never computed and never `prototype`.
        const pn = if (is_private) try self.parsePrivateName() else try self.parsePropertyName();

        const is_literal = pn.computed == null; // a static (non-computed) PropName we can name-check

        if (self.peek().kind == .lparen) {
            // §15.7 MethodDefinition `m(params){…}` — instance (on `.prototype`) or static method, or
            // a PRIVATE method `#m(){…}` (installed in the private slot). §15.7.1 Early Error: a
            // `static` method may not be named `prototype`. A private method named `#constructor` is a
            // SyntaxError (handled in parsePrivateName) and a private name is never the class ctor.
            if (is_static and is_literal and !is_private and std.mem.eql(u8, pn.key, "prototype")) return ParseError.UnexpectedToken;
            // §15.7: a non-static, non-private method named `constructor` is the class constructor —
            // but a GENERATOR or ASYNC method named `constructor` is a §15.7.1 SyntaxError (a
            // constructor is never a generator/async), and a `static *prototype` was already rejected.
            const is_ctor = !is_generator_method and !is_async_method and !is_static and is_literal and !is_private and std.mem.eql(u8, pn.key, "constructor");
            if ((is_generator_method or is_async_method) and is_literal and !is_private and !is_static and std.mem.eql(u8, pn.key, "constructor")) return ParseError.UnexpectedToken;
            // §13.3.5/§13.3.7: every MethodDefinition body has a [[HomeObject]] (`super.x` allowed);
            // `super(...)` is allowed only in a DERIVED class's `constructor`. Saved/restored so the
            // flags don't leak to the next element (or, via the defers, to anything after the body).
            const saved_in_method = self.in_method;
            const saved_in_derived = self.in_derived_ctor;
            const saved_in_generator = self.in_generator;
            const saved_in_async = self.in_async;
            defer self.in_method = saved_in_method;
            defer self.in_derived_ctor = saved_in_derived;
            defer self.in_generator = saved_in_generator;
            defer self.in_async = saved_in_async;
            self.in_method = true;
            self.in_derived_ctor = is_ctor and is_derived;
            // §15.5/§15.8: a generator/async method's BODY parses with `[+Yield]`/`[+Await]`; its
            // FormalParameters do NOT (a `yield`/`await` operator in a default is a §15.5.1/§15.8.1
            // SyntaxError, and `yield`/`await` may not be a param BindingIdentifier). An ordinary method
            // un-sets both (they are not operators there even inside an enclosing generator/async fn).
            self.in_generator = false;
            self.in_async = false;
            const pl = try self.parseParams();
            if (is_generator_method and paramsHaveYield(pl)) return ParseError.UnexpectedToken;
            if (is_async_method and paramsHaveAwait(pl)) return ParseError.UnexpectedToken;
            self.in_generator = is_generator_method;
            self.in_async = is_async_method;
            var body_strict: bool = false;
            const body = try self.parseMethodBody(pl, &body_strict);
            // §15.7 / §13.2.5.1 UniqueFormalParameters — a method's parameters have no duplicates.
            if (hasDuplicateBoundNames(pl)) return ParseError.UnexpectedToken;
            // §14.3.1 / §15.5.1: a method's params may not collide with its body's LexicallyDeclaredNames.
            if (paramsConflictWithBodyLexical(pl, body)) return ParseError.UnexpectedToken;
            const f = try self.arena.create(ast.Function);
            f.* = .{ .name = null, .params = pl.params, .rest = pl.rest, .body = body, .is_generator = is_generator_method, .is_async = is_async_method, .is_method = true, .strict = body_strict };
            return .{
                .kind = if (is_ctor) .constructor else .method,
                .is_static = is_static,
                .is_private = is_private,
                .key = pn.key,
                .computed_key = pn.computed,
                .value = .{ .func = f },
            };
        }
        // A leading `*` or `async` with no following method body (`* x;` / `async x = 1`) is a
        // SyntaxError — a generator / async element must be a method (have a `(params)` body).
        if (is_generator_method or is_async_method) return ParseError.UnexpectedToken;

        // §15.7 FieldDefinition `x = Initializer ;` or bare `x ;` (ASI). An optional `= expr`.
        // §15.7.1 Early Errors on the field's PropName: it may not be `constructor`; a `static` field
        // may not be named `prototype`. (A private field `#x` skips these — `#constructor` is rejected
        // in parsePrivateName, and `#prototype` is a legal private name.)
        if (is_literal and !is_private) {
            if (std.mem.eql(u8, pn.key, "constructor")) return ParseError.UnexpectedToken;
            if (is_static and std.mem.eql(u8, pn.key, "prototype")) return ParseError.UnexpectedToken;
        }
        var field_init: ?*const ast.Node = null;
        if (self.peek().kind == .assign) {
            _ = self.advance();
            // §13.3.5: a FieldDefinition Initializer has a [[HomeObject]] (so `super.x` is allowed),
            // but it is NOT a constructor (so `super(...)` is a SyntaxError here). Save/restore.
            const saved_in_method = self.in_method;
            const saved_in_derived = self.in_derived_ctor;
            self.in_method = true;
            self.in_derived_ctor = false;
            field_init = try self.parseAssignment();
            self.in_method = saved_in_method;
            self.in_derived_ctor = saved_in_derived;
            // §15.7.1 Early Error: a FieldDefinition Initializer may not contain `arguments`
            // (ContainsArguments) — `x = arguments` / `[k] = f(arguments)` are SyntaxErrors.
            if (containsArguments(field_init.?)) return ParseError.UnexpectedToken;
        }
        // §15.7 ClassElement grammar: a FieldDefinition is terminated by `;` (consumed) or ASI — a
        // `}` or a LineTerminator before the next token. Two fields on one line (`x y`, `x = 1 m(){}`)
        // with no `;` and no newline is a SyntaxError (no ASI here).
        if (self.peek().kind == .semicolon) {
            _ = self.advance();
        } else if (self.peek().kind != .rbrace and !self.peek().newline_before) {
            return ParseError.UnexpectedToken;
        }
        return .{
            .kind = .field,
            .is_static = is_static,
            .is_private = is_private,
            .key = pn.key,
            .computed_key = pn.computed,
            .value = .{ .field_init = field_init },
        };
    }

    /// §15.7.11 ClassStaticBlock `static { … }` — the leading `static` has been consumed; the current
    /// token is `{`. The block body parses in a method-like context: strict (the whole class body is),
    /// with a [[HomeObject]] so `super.x` is allowed but `super(...)` is not (it is not a constructor).
    fn parseStaticBlock(self: *Parser) ParseError!ast.ClassElement {
        const saved_in_method = self.in_method;
        const saved_in_derived = self.in_derived_ctor;
        const saved_in_static = self.in_static_block;
        const saved_in_async = self.in_async;
        const saved_in_generator = self.in_generator;
        defer self.in_method = saved_in_method;
        defer self.in_derived_ctor = saved_in_derived;
        defer self.in_static_block = saved_in_static;
        defer self.in_async = saved_in_async;
        defer self.in_generator = saved_in_generator;
        self.in_method = true;
        self.in_derived_ctor = false;
        // §15.7.11: a ClassStaticBlock is NOT an async/generator context — `await`/`yield` are not
        // operators here. `await` is RESERVED (a binding/reference is a SyntaxError, via `in_static_block`)
        // and `ContainsAwait` of the block is a Syntax Error, so an `await`-led form must not parse as
        // the operator even when the block is nested in an async function. Reset both context flags.
        self.in_async = false;
        self.in_generator = false;
        self.in_static_block = true; // §15.7.11: `await` is reserved inside the block
        const ctrl = self.enterControlScope(); // §14.13: a static block starts a fresh label scope
        defer self.exitControlScope(ctrl);
        const body = try self.parseBlock();
        return .{ .kind = .static_block, .is_static = true, .value = .{ .block = body } };
    }

    /// §15.7 MethodDefinition `get PropName(){…}` / `set PropName(v){…}` in a class body (the leading
    /// `get`/`set` token has NOT yet been consumed; `is_get` selects which). Mirrors the object-literal
    /// accessor path (§13.2.5.6): the accessor arity Early Errors, [[HomeObject]] context for `super`,
    /// and the §15.7.1 name restrictions (`constructor` may not be an accessor; a `static` accessor may
    /// not be named `prototype`). Computed keys `get [expr](){…}` are supported (key in `computed_key`).
    fn parseClassAccessor(self: *Parser, is_static: bool, is_get: bool) ParseError!ast.ClassElement {
        _ = self.advance(); // consume `get` / `set`
        // A PRIVATE accessor `get #x(){…}` (Cycle 4): the name is a PrivateIdentifier (`#constructor`
        // is rejected in parsePrivateName); a private accessor skips the `constructor`/`prototype`
        // name restrictions (those names are legal as private names).
        const is_private = self.peek().kind == .private_identifier;
        const pn = if (is_private) try self.parsePrivateName() else try self.parsePropertyName();
        const is_literal = pn.computed == null;
        // §15.7.1 Early Errors: `constructor` may not be a getter/setter; a `static` accessor named
        // `prototype` is forbidden.
        if (is_literal and !is_private) {
            if (!is_static and std.mem.eql(u8, pn.key, "constructor")) return ParseError.UnexpectedToken;
            if (is_static and std.mem.eql(u8, pn.key, "prototype")) return ParseError.UnexpectedToken;
        }
        // §13.3.5: an accessor body has a [[HomeObject]] (so `super.x` is allowed) but is not a
        // constructor (so `super(...)` is a SyntaxError). Save/restore so the flags don't leak.
        const saved_in_method = self.in_method;
        const saved_in_derived = self.in_derived_ctor;
        defer self.in_method = saved_in_method;
        defer self.in_derived_ctor = saved_in_derived;
        self.in_method = true;
        self.in_derived_ctor = false;
        const pl = try self.parseParams();
        // §13.2.5.1 accessor arity Early Errors: a getter takes no parameters; a setter takes exactly
        // one (a default is allowed, a rest element is not).
        if (is_get) {
            if (pl.params.len != 0 or pl.rest != null) return ParseError.UnexpectedToken;
        } else {
            if (pl.params.len != 1 or pl.rest != null) return ParseError.UnexpectedToken;
        }
        var body_strict: bool = false;
        const body = try self.parseMethodBody(pl, &body_strict);
        if (hasDuplicateBoundNames(pl)) return ParseError.UnexpectedToken;
        const f = try self.arena.create(ast.Function);
        f.* = .{ .name = null, .params = pl.params, .rest = pl.rest, .body = body, .is_method = true, .strict = body_strict };
        return .{
            .kind = if (is_get) .get else .set,
            .is_static = is_static,
            .is_private = is_private,
            .key = pn.key,
            .computed_key = pn.computed,
            .value = .{ .func = f },
        };
    }

    /// §15.7 parse a PrivateIdentifier `#name` as a class-element name. The current token is a
    /// `private_identifier` (lexeme includes the `#`). §15.7.1 Early Error: `#constructor` may not be
    /// used as a private member name. Returns a PropName whose `key` is the `#name` (never computed).
    fn parsePrivateName(self: *Parser) ParseError!PropName {
        const t = self.advance();
        std.debug.assert(t.kind == .private_identifier);
        if (std.mem.eql(u8, t.lexeme, "#constructor")) return ParseError.UnexpectedToken;
        return .{ .key = t.lexeme };
    }

    const ParamList = struct { params: []const ast.Param, rest: ?*const ast.Pattern };

    /// §15.1 FormalParameters — each parameter is a binding pattern with an optional `= default`;
    /// an optional trailing `...rest` (itself a pattern) collects the leftover arguments.
    fn parseParams(self: *Parser) ParseError!ParamList {
        _ = try self.expect(.lparen);
        var params: std.ArrayList(ast.Param) = .empty;
        var rest: ?*const ast.Pattern = null;
        while (self.peek().kind != .rparen and self.peek().kind != .eof) {
            if (self.peek().kind == .ellipsis) { // §15.1 rest parameter (must be last)
                _ = self.advance();
                rest = try self.parsePattern();
                break;
            }
            const pattern = try self.parsePattern();
            var default: ?*const ast.Node = null;
            if (self.peek().kind == .assign) { // §15.1 default value `a = expr`
                _ = self.advance();
                default = try self.parseAssignment();
            }
            try params.append(self.arena, .{ .pattern = pattern, .default = default });
            if (self.peek().kind == .comma) {
                _ = self.advance();
                continue;
            }
            break;
        }
        _ = try self.expect(.rparen);
        return .{ .params = params.items, .rest = rest };
    }

    /// §13.3.6 Arguments `( … )` — a comma-separated list of (possibly spread) AssignmentExpressions.
    /// Assumes the current token is `(`; consumes through the matching `)`.
    fn parseArgs(self: *Parser) ParseError![]const *const ast.Node {
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
    fn expectPropertyName(self: *Parser) ParseError![]const u8 {
        const t = self.peek();
        if (t.kind == .identifier or isKeywordName(t.kind)) {
            _ = self.advance();
            return t.lexeme;
        }
        return ParseError.UnexpectedToken;
    }

    /// An argument or array element that may be a spread `...expr`.
    fn parseSpreadable(self: *Parser) ParseError!*const ast.Node {
        const saved_no_in = self.no_in; // §14.7.5 `[~In]` reset — array element / arg is `[+In]`
        self.no_in = false;
        defer self.no_in = saved_no_in;
        if (self.peek().kind == .ellipsis) {
            _ = self.advance();
            return self.alloc(.{ .spread = try self.parseAssignment() });
        }
        return self.parseAssignment();
    }

    fn parseBlock(self: *Parser) ParseError![]const ast.Stmt {
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

    fn parseDecl(self: *Parser) ParseError!ast.Stmt {
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
    fn parseUsingDecl(self: *Parser, kind: ast.DeclKind, for_head: bool) ParseError!ast.Stmt {
        // §14.3.1.1: a UsingDeclaration is a Syntax Error at the top level of a Script.
        if (!self.using_allowed and !for_head) return ParseError.UnexpectedToken;
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
    fn finishArrow(self: *Parser, pl: ParamList) ParseError!*const ast.Node {
        return self.finishArrowAsync(pl, false);
    }

    /// §15.3 / §15.8 ArrowFunction / AsyncArrowFunction. `is_async` flags an async arrow (`async x =>`,
    /// `async (a) =>`), whose body parses with `[+Await]` (and whose `=>` was preceded by `async`).
    fn finishArrowAsync(self: *Parser, pl: ParamList, is_async: bool) ParseError!*const ast.Node {
        const enclosing_strict = self.strict;
        const saved_in_async = self.in_async;
        defer self.strict = enclosing_strict; // §11.2.2: never un-strict on the way out
        defer self.in_async = saved_in_async;
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
    fn parenIsArrowHead(self: *Parser) bool {
        return self.parenIsArrowHeadAt(self.idx);
    }

    /// As `parenIsArrowHead`, but the `(` is at the given token index (used for `async ( … ) =>`,
    /// where the `(` sits one past `async`). Returns true iff the token after the matching `)` is `=>`.
    fn parenIsArrowHeadAt(self: *Parser, start: usize) bool {
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
    fn atUsingDeclStart(self: *Parser, in_for: bool) bool {
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
    fn atAwaitUsingDeclStart(self: *Parser, in_for: bool) bool {
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
    fn atAsyncFunctionStart(self: *Parser) bool {
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
    fn atAsyncArrowOrFunction(self: *Parser) ?AsyncHead {
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
    fn parseExpression(self: *Parser) ParseError!*const ast.Node {
        var left = try self.parseAssignment();
        while (self.peek().kind == .comma) {
            _ = self.advance();
            const right = try self.parseAssignment();
            left = try self.alloc(.{ .comma = .{ .left = left, .right = right } });
        }
        return left;
    }

    /// §13.15 Assignment (right-associative). Only identifier targets in M1 Cycle A.
    fn parseAssignment(self: *Parser) ParseError!*const ast.Node {
        // §14.4 YieldExpression — `AssignmentExpression : [+Yield] YieldExpression`. Inside a generator
        // body `yield` is always the operator (never an IdentifierReference). Parsed here at the
        // assignment level (its operand is itself an AssignmentExpression, giving `yield` its very low,
        // right-associative precedence: `yield a + b` ≡ `yield (a + b)`, `x = yield y` ≡ `x = (yield y)`).
        if (self.in_generator and self.peek().kind == .identifier and std.mem.eql(u8, self.peek().lexeme, "yield")) {
            return self.parseYield();
        }
        // §15.8 AwaitExpression `await UnaryExpression` — inside an async context `await` is the
        // operator. Parsed via `parseUnary` (UnaryExpression precedence); routed there so it composes
        // with the rest of the precedence climb (`await a + b` ≡ `(await a) + b`). Handled at the
        // assignment level only as a quick gate for the async-arrow / ordinary fallthrough — the actual
        // node is built in `parseUnary`, so we just fall through to the precedence path below.
        // §15.8 async arrow / async function expression (cover grammar, before the ordinary arrow):
        //   • `async [no LT] Identifier =>` — a single-parameter async arrow.
        //   • `async [no LT] ( … ) =>` — a parenthesized async arrow.
        //   • `async [no LT] function …` — an async function expression.
        // `async` is the modifier ONLY with no LineTerminator before the following token (else ASI /
        // `async` is an identifier). Distinguished from a CALL `async(x)` by the trailing `=>`.
        if (self.atAsyncArrowOrFunction()) |kind| {
            // §12.7.1 Early Error: the `async` of an async arrow / async function expression is a
            // terminal symbol and must not contain a Unicode escape (`async function …`).
            if (self.peek().had_escape) return ParseError.UnexpectedToken;
            switch (kind) {
                .arrow_ident => {
                    _ = self.advance(); // `async`
                    // §15.8.1: `async await => …` — `await` may not be an async arrow's param BindingIdentifier.
                    if (std.mem.eql(u8, self.peek().lexeme, "await")) return ParseError.UnexpectedToken;
                    // §12.7.1: an escaped ReservedWord is not a valid arrow-param BindingIdentifier.
                    if (isEscapedReservedIdent(self.peek())) return ParseError.UnexpectedToken;
                    const pat = try self.allocPattern(.{ .identifier = self.advance().lexeme });
                    const params = try self.arena.alloc(ast.Param, 1);
                    params[0] = .{ .pattern = pat, .default = null };
                    return self.finishArrowAsync(.{ .params = params, .rest = null }, true);
                },
                .arrow_paren => {
                    _ = self.advance(); // `async`
                    const saved_in_async = self.in_async;
                    defer self.in_async = saved_in_async;
                    // §15.8: an AsyncArrowFunction's CoverCallExpressionAndAsyncArrowHead parses its
                    // formals with `[+Await]` — so `await` is reserved as a BindingIdentifier inside them
                    // (including in a nested arrow's params, `async(a = (await) => {}) => {}`), and an
                    // `await` operator there becomes an `await_expr`. §15.8.1 then rejects any params that
                    // bind/contain `await` (`paramsHaveAwait`, which catches both the identifier and the node).
                    self.in_async = true;
                    const pl = try self.parseParams();
                    if (paramsHaveAwait(pl)) return ParseError.UnexpectedToken;
                    return self.finishArrowAsync(pl, true);
                },
                .function_expr => {
                    _ = self.advance(); // `async`
                    _ = self.advance(); // `function`
                    return self.alloc(.{ .function = try self.parseFunction(true) });
                },
            }
        }
        // §15.3 ArrowFunction (cover grammar, checked before the precedence climb):
        //   • `Identifier =>` — a single un-parenthesized parameter.
        //   • `( … ) =>` — a parenthesized formal list (lookahead to the matching `)`).
        if (self.peek().kind == .identifier and self.idx + 1 < self.tokens.len and
            self.tokens[self.idx + 1].kind == .fat_arrow)
        {
            // §15.7.11: `await` is reserved as a BindingIdentifier inside a static block (`await => …`).
            if (self.in_static_block and std.mem.eql(u8, self.peek().lexeme, "await")) return ParseError.UnexpectedToken;
            // §15.8.1: inside an async context `await` may not be an arrow's param BindingIdentifier.
            if (self.in_async and std.mem.eql(u8, self.peek().lexeme, "await")) return ParseError.UnexpectedToken;
            // §12.7.1: an escaped ReservedWord is not a valid arrow-param BindingIdentifier.
            if (isEscapedReservedIdent(self.peek())) return ParseError.UnexpectedToken;
            const pat = try self.allocPattern(.{ .identifier = self.advance().lexeme });
            const params = try self.arena.alloc(ast.Param, 1);
            params[0] = .{ .pattern = pat, .default = null };
            return self.finishArrow(.{ .params = params, .rest = null });
        }
        if (self.peek().kind == .lparen and self.parenIsArrowHead()) {
            const pl = try self.parseParams();
            return self.finishArrow(pl);
        }
        const left = try self.parseConditional();
        const op = self.peek().kind;
        // §13.15.2 LogicalAssignment (`&&=`/`||=`/`??=`) — short-circuit, NOT a binary desugar.
        // The target node is kept intact (identifier / member / index) so the interpreter can
        // evaluate the reference exactly once before deciding whether to evaluate the RHS.
        if (logicalAssignOp(op)) |lop| {
            switch (left.*) {
                .identifier => |n| {
                    // §13.15.1 Early Error: in strict, the assignment target may not be `eval`/`arguments`.
                    if (self.strict and isEvalOrArguments(n)) return ParseError.UnexpectedToken;
                },
                .member, .index, .private_member => {},
                else => return ParseError.UnexpectedToken, // §13.15.1 invalid assignment target
            }
            _ = self.advance();
            const value = try self.parseAssignment();
            return self.alloc(.{ .logical_assign = .{ .op = lop, .target = left, .value = value } });
        }
        // §13.15.5 DestructuringAssignment (cover grammar): an ArrayLiteral / ObjectLiteral followed by
        // `=` is REFINED to an AssignmentPattern. Only the plain `=` form (not compound `+=` etc.) takes
        // a pattern target (§13.15.1: a compound assignment requires a simple LeftHandSideExpression).
        // §13.15.1: a PARENTHESIZED literal `({}) = 1` / `([a]) = 1` has AssignmentTargetType *invalid*
        // (the parens make it a ParenthesizedExpression, not the AssignmentPattern cover grammar), so it
        // is NOT refined — it falls through to the ordinary-assignment path, which rejects it.
        if (op == .assign and !self.last_was_paren and (left.* == .array_literal or left.* == .object_literal)) {
            try self.validateAssignmentPattern(left); // §13.15.1 AssignmentTargetType refinement
            _ = self.advance();
            const value = try self.parseAssignment();
            return self.alloc(.{ .assign_pattern = .{ .target = left, .value = value } });
        }
        if (op == .assign or compoundBinOp(op) != null) {
            // §13.15.1 Early Error: in strict, the assignment target may not be `eval`/`arguments`.
            if (self.strict) switch (left.*) {
                .identifier => |n| if (isEvalOrArguments(n)) return ParseError.UnexpectedToken,
                else => {},
            };
            _ = self.advance();
            const rhs = try self.parseAssignment();
            // Compound assignment `x op= v` desugars to `x = x op v` (§13.15).
            const value = if (compoundBinOp(op)) |bop|
                try self.alloc(.{ .binary = .{ .op = bop, .left = left, .right = rhs } })
            else
                rhs;
            switch (left.*) {
                .identifier => |n| return self.alloc(.{ .assign = .{ .name = n, .value = value } }),
                .member => |m| return self.alloc(.{ .assign_member = .{ .object = m.object, .name = m.name, .value = value } }),
                .index => |ix| return self.alloc(.{ .assign_index = .{ .object = ix.object, .key = ix.key, .value = value } }),
                // §13.3.2 `obj.#x = v` — assignment to a private member (TypeError at runtime if `obj`
                // lacks the brand). Compound `obj.#x op= v` desugars with the private member as both
                // sides; the desugared `value` already references `left` (the private_member node).
                .private_member => |pm| return self.alloc(.{ .private_assign = .{ .object = pm.object, .name = pm.name, .value = value } }),
                else => return ParseError.UnexpectedToken, // invalid assignment target
            }
        }
        return left;
    }

    /// §14.4 YieldExpression — the current token is the `yield` identifier (caller verified
    /// `in_generator`). Forms: `yield` (bare → yields undefined), `yield AssignmentExpression`, and
    /// `yield* AssignmentExpression` (delegation, parsed here; full §15.5.5 semantics are Cycle 2).
    /// Restricted production: a LineTerminator after `yield` forces the bare form (ASI), and `yield`
    /// followed by a token that cannot start an expression (`)`, `]`, `}`, `,`, `;`, `:`, eof) is bare.
    fn parseYield(self: *Parser) ParseError!*const ast.Node {
        _ = self.advance(); // yield
        // §14.4 `yield [no LineTerminator here] * AssignmentExpression` — delegation. The `*` IS part of
        // the restricted production: a newline before it forces a bare `yield` (so `yield\n* 1` is NOT
        // `yield*` — the leftover `* 1` then fails to parse, a SyntaxError, matching the spec).
        if (self.peek().kind == .star and !self.peek().newline_before) {
            _ = self.advance();
            const arg = try self.parseAssignment();
            return self.alloc(.{ .yield_expr = .{ .argument = arg, .delegate = true } });
        }
        // §14.4 restricted production: `yield [no LineTerminator here] AssignmentExpression`. A newline,
        // or a token that cannot begin an AssignmentExpression, makes this a bare `yield`.
        const nxt = self.peek();
        if (nxt.newline_before or !startsYieldArgument(nxt.kind)) {
            return self.alloc(.{ .yield_expr = .{ .argument = null, .delegate = false } });
        }
        const arg = try self.parseAssignment();
        return self.alloc(.{ .yield_expr = .{ .argument = arg, .delegate = false } });
    }

    /// §13.15.1 / §13.15.5.1 — refine an ArrayLiteral / ObjectLiteral (the cover grammar) into an
    /// AssignmentPattern: validate that every leaf is a valid destructuring assignment target. A leaf
    /// may be a plain assignment target (identifier / member `a.b` / index `a[k]` / `a.#x`), a nested
    /// array/object literal pattern (recurse), or — carrying a `= default` — an `assign`/`assign_*`
    /// node whose own target the same rules apply to. Holes (elision) and the trailing `...rest` are
    /// allowed in array patterns; object-property *values* and rest are validated likewise. A
    /// non-assignable leaf (`[1] = x`, `[a()] = x`, `({a: 1} = x)`) is a §13.15.1 SyntaxError.
    fn validateAssignmentPattern(self: *Parser, node: *const ast.Node) ParseError!void {
        switch (node.*) {
            .array_literal => |elems| {
                for (elems, 0..) |el, i| {
                    if (el.* == .elision) continue; // hole — no target
                    if (el.* == .spread) {
                        // §13.15.5.1 AssignmentRestElement — it must be the LAST element (a following
                        // element or a trailing comma `[...x,]`, which the parser marks with a trailing
                        // elision, makes it non-last → SyntaxError) and may NOT carry a default
                        // (`[...x = 1]` — the parser folds the `= 1` into an `assign*` node).
                        if (i != elems.len - 1) return ParseError.UnexpectedToken;
                        switch (el.spread.*) {
                            .assign, .assign_member, .assign_index, .private_assign => return ParseError.UnexpectedToken,
                            // §13.15.5.1: AssignmentRestElement is a DestructuringAssignmentTarget — a
                            // nested array/object pattern is allowed (`[...[a, b]] = x`).
                            else => try self.validateAssignmentTarget(el.spread),
                        }
                        continue;
                    }
                    try self.validateAssignmentTarget(el);
                }
            },
            .object_literal => |props| {
                // §13.15.1: a duplicate `__proto__:` is ALLOWED in an ObjectAssignment pattern — this
                // refinement legitimizes it, so discharge the §B.3.1 obligation recorded at parse time
                // (one per `__proto__:` property beyond the first in THIS literal).
                var proto_seen: usize = 0;
                for (props) |p| if (p.is_proto) {
                    proto_seen += 1;
                    if (proto_seen > 1 and self.proto_dup > 0) self.proto_dup -= 1;
                };
                for (props, 0..) |p, i| {
                    // §13.2.5.1: this property's CoverInitializedName (if any) is now legitimized by
                    // the refinement — discharge the obligation recorded at parse time.
                    if (p.default != null and self.cover_init > 0) self.cover_init -= 1;
                    switch (p.kind) {
                        // §13.15.5.1: an object AssignmentPattern admits only `key: target`,
                        // shorthand `{x}`, CoverInitializedName `{x = d}`, and `...rest`. Accessors /
                        // methods are not valid pattern properties.
                        .init => try self.validateAssignmentTarget(p.value),
                        .spread => {
                            // §13.15.5.1 AssignmentRestProperty — must be the LAST property
                            // (`{...rest, b}` is a SyntaxError) and a simple DestructuringAssignmentTarget
                            // (NOT a nested pattern / default — the rest target is an LHS reference).
                            if (i != props.len - 1) return ParseError.UnexpectedToken;
                            switch (p.value.*) {
                                .identifier, .member, .index, .private_member => {},
                                else => return ParseError.UnexpectedToken,
                            }
                        },
                        .get, .set => return ParseError.UnexpectedToken,
                    }
                }
            },
            else => try self.validateAssignmentTarget(node),
        }
    }

    /// Validate one destructuring assignment TARGET (§13.15.5.1 DestructuringAssignmentTarget): a
    /// simple assignment reference (identifier / member / index / private member), a node carrying a
    /// `= default` (`assign`/`assign_member`/`assign_index`/`private_assign`, produced by the literal
    /// parser's right-recursive `=`), or a nested array/object literal pattern (recurse).
    fn validateAssignmentTarget(self: *Parser, node: *const ast.Node) ParseError!void {
        switch (node.*) {
            .identifier => |n| {
                // §13.15.1: in strict, a DestructuringAssignmentTarget IdentifierReference may not be
                // `eval`/`arguments` NOR a strict future-reserved word (`let`/`static`/`implements`/…).
                // Non-escaped reserved words are lexed as keyword tokens and never reach here; this fires
                // for an escaped spelling (`{ let } = o`, §12.7.1) — IdentifierReference ≠ ReservedWord.
                if (self.strict and isStrictReservedBindingName(n)) return ParseError.UnexpectedToken;
            },
            .member, .index, .private_member => {},
            // A `target = default` element/property (the literal parser folded the `=` into an
            // assignment node). The DEFAULT side is an ordinary expression; only the TARGET recurses.
            .assign => |a| {
                if (self.strict and isStrictReservedBindingName(a.name)) return ParseError.UnexpectedToken;
            },
            .assign_member, .assign_index, .private_assign => {},
            // Nested pattern `[{a}, [b]] = …` — the element is itself a literal to refine.
            .array_literal, .object_literal => try self.validateAssignmentPattern(node),
            else => return ParseError.UnexpectedToken, // §13.15.1 invalid assignment target
        }
    }

    /// §13.14 Conditional `cond ? then : otherwise` (above assignment, right-associative branches).
    fn parseConditional(self: *Parser) ParseError!*const ast.Node {
        const cond = try self.parseShortCircuit();
        if (self.peek().kind == .question) {
            _ = self.advance();
            const then = try self.parseAssignment();
            _ = try self.expect(.colon);
            const otherwise = try self.parseAssignment();
            return self.alloc(.{ .conditional = .{ .cond = cond, .then = then, .otherwise = otherwise } });
        }
        return cond;
    }

    /// §13.13 ShortCircuitExpression — the top of the binary tower: either a LogicalORExpression
    /// (`||`/`&&` chain) or a CoalesceExpression (`??` chain). §13.13.1 Early Error: the two may not
    /// be mixed without parentheses (`a ?? b || c`, `a && b ?? c`, … are SyntaxErrors). We parse the
    /// head at the BitwiseOR level (prec ≥ 3, below `&&`/`||`/`??`), then dispatch on the operator.
    fn parseShortCircuit(self: *Parser) ParseError!*const ast.Node {
        const head_paren = blk: {
            const h = try self.parseExpr(3);
            break :blk .{ .node = h, .paren = self.last_was_paren };
        };
        const head = head_paren.node;
        if (self.peek().kind == .question_question) {
            // CoalesceExpression : CoalesceExpressionHead `??` BitwiseORExpression.
            // The head must not be an un-parenthesized `||`/`&&` (it can't be — parseExpr(3) stops
            // below them — but a parenthesized one is fine and already collapsed).
            var left = head;
            while (self.peek().kind == .question_question) {
                _ = self.advance();
                const right = try self.parseExpr(3);
                const right_paren = self.last_was_paren;
                // §13.13.1: a `??` operand may not itself be an un-parenthesized `||`/`&&`.
                if (!right_paren and (self.peek().kind == .pipe_pipe or self.peek().kind == .amp_amp)) {
                    return ParseError.UnexpectedToken;
                }
                left = try self.alloc(.{ .logical = .{ .op = .coalesce, .left = left, .right = right } });
            }
            return left;
        }
        if (self.peek().kind == .pipe_pipe or self.peek().kind == .amp_amp) {
            // LogicalORExpression — continue the climb from the head at the `||` level (prec 1).
            const result = try self.parseExprFrom(head, 1);
            // §13.13.1: a `||`/`&&` chain may not be followed by `??` without parentheses.
            if (self.peek().kind == .question_question) return ParseError.UnexpectedToken;
            return result;
        }
        return head;
    }

    /// Precedence-climbing for binary + logical operators. Higher number binds tighter.
    /// Logical `||`/`&&` build short-circuiting `logical` nodes; everything else is `binary`.
    fn parseExpr(self: *Parser, min_prec: u8) ParseError!*const ast.Node {
        // §13.10.1 RelationalExpression : PrivateIdentifier `in` ShiftExpression — the ergonomic brand
        // check `#x in obj`. A PrivateIdentifier may ONLY appear here as a primary (everywhere else it
        // is a member name `obj.#x`); it must be immediately followed by `in`, inside a class body.
        if (self.peek().kind == .private_identifier) {
            if (!self.in_class_body) return ParseError.UnexpectedToken;
            const name = self.advance().lexeme;
            // §15.7.1 AllPrivateNamesValid: the brand-check name must resolve to a declared private name.
            if (!self.privateNameDeclared(name)) return ParseError.UnexpectedToken;
            if (self.peek().kind != .kw_in) return ParseError.UnexpectedToken;
            _ = self.advance(); // `in`
            // The RHS binds at the shift level (prec 8 — tighter than relational `in` at 7), so the
            // brand check is the relational operator: `#x in a || b` parses as `(#x in a) || b`.
            const rhs = try self.parseExpr(8);
            const node = try self.alloc(.{ .private_in = .{ .name = name, .object = rhs } });
            return self.parseExprFrom(node, min_prec);
        }
        const left = try self.parseUnary();
        return self.parseExprFrom(left, min_prec);
    }

    /// Continue the precedence climb from an already-parsed `left` operand.
    fn parseExprFrom(self: *Parser, left_init: *const ast.Node, min_prec: u8) ParseError!*const ast.Node {
        var left = left_init;
        while (true) {
            const k = self.peek().kind;
            // §14.7.5 `[~In]`: in a for-header's first clause, `in` is not a relational operator — it
            // marks the for-in head. Stop the climb so `parseFor` sees the `kw_in` itself.
            if (self.no_in and k == .kw_in) break;
            const prec = opPrecedence(k) orelse break;
            if (prec < min_prec) break;
            _ = self.advance();
            // `**` is right-associative; everything else left-associative.
            const right = try self.parseExpr(if (k == .star_star) prec else prec + 1);
            left = switch (k) {
                .pipe_pipe => try self.alloc(.{ .logical = .{ .op = .or_, .left = left, .right = right } }),
                .amp_amp => try self.alloc(.{ .logical = .{ .op = .and_, .left = left, .right = right } }),
                else => try self.alloc(.{ .binary = .{ .op = binaryOpFor(k).?, .left = left, .right = right } }),
            };
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!*const ast.Node {
        self.last_was_paren = false; // reset; set by a parenthesized primary (§13.13.1 mix check)
        // §15.8 AwaitExpression : `await` UnaryExpression — inside an async context `await` is the
        // operator (at UnaryExpression precedence, so `await a.b()` awaits the call result and `await
        // -x` awaits `-x`). Outside async, `await` is an ordinary identifier (handled in parsePrimary).
        if (self.in_async and self.peek().kind == .identifier and std.mem.eql(u8, self.peek().lexeme, "await")) {
            _ = self.advance(); // await
            const operand = try self.parseUnary();
            return self.alloc(.{ .await_expr = operand });
        }
        // §13.4.4/5 prefix ++ / --
        if (self.peek().kind == .plus_plus or self.peek().kind == .minus_minus) {
            const op: ast.UpdateOp = if (self.peek().kind == .plus_plus) .inc else .dec;
            _ = self.advance();
            const target = try self.parseUnary();
            // §13.3.9.1 Early Error: `++a?.b` — a prefix-update operand may not be an OptionalChain.
            if (target.* == .optional) return ParseError.UnexpectedToken;
            // §13.4.1.1 Early Error: an UpdateExpression operand must be a simple assignment target; a
            // (parenthesized) YieldExpression / AwaitExpression is not (`++(yield)` in a generator,
            // `++(await x)` in an async function are SyntaxErrors).
            if (target.* == .yield_expr or target.* == .await_expr) return ParseError.UnexpectedToken;
            // §13.4.1.1 Early Error: in strict, the operand of a prefix update may not be the
            // reference `eval`/`arguments`.
            if (self.strict) switch (target.*) {
                .identifier => |n| if (isEvalOrArguments(n)) return ParseError.UnexpectedToken,
                else => {},
            };
            return self.alloc(.{ .update = .{ .op = op, .prefix = true, .target = target } });
        }
        const uop: ?ast.UnaryOp = switch (self.peek().kind) {
            .plus => .plus,
            .minus => .minus,
            .bang => .not,
            .kw_typeof => .typeof_,
            .kw_void => .void_, // §13.5.2
            .kw_delete => .delete_, // §13.5.1
            .bit_not => .bit_not,
            else => null,
        };
        if (uop) |op| {
            _ = self.advance();
            const operand = try self.parseUnary();
            // §13.5.1.1 Early Error: in strict, `delete` of an unqualified reference (a bare
            // identifier — a direct UnresolvableReference / resolvable binding, not a property
            // reference) is a SyntaxError. `delete obj.prop` / `delete obj[k]` stay legal.
            if (op == .delete_ and self.strict and operand.* == .identifier) return ParseError.UnexpectedToken;
            // §13.5.1.1 Early Error: `delete` of a private member reference (`delete this.#x`, even
            // parenthesized `delete (this.#x)`) is ALWAYS a SyntaxError. A parenthesized operand is
            // already collapsed to its inner node, so a direct `private_member` covers both forms.
            if (op == .delete_ and operand.* == .private_member) return ParseError.UnexpectedToken;
            return self.alloc(.{ .unary = .{ .op = op, .operand = operand } });
        }
        return self.parsePostfix();
    }

    /// §13.3 Member/Call postfix: `a.b`, `a[expr]`, `a(args)`, plus §13.3.9 OptionalChain
    /// (`a?.b`, `a?.[k]`, `a?.(args)`). Left-associative, highest precedence. Once a `?.` appears,
    /// the chain is "optional": every following `.`/`[]`/`()` is emitted as an `optional` node so a
    /// nullish short-circuit propagates to the end of the chain (§13.3.9.1).
    fn parsePostfix(self: *Parser) ParseError!*const ast.Node {
        // §13.3 SuperProperty / SuperCall — `super` is never a standalone primary; it must be the
        // base of `super.name`, `super[expr]`, or `super(args)`. Handle it here so the early errors
        // (must be inside a method / derived constructor) fire and the form is captured directly.
        if (self.peek().kind == .kw_super) {
            const sup = try self.parseSuper();
            return self.continuePostfix(sup, false);
        }
        const expr = try self.parsePrimary();
        return self.continuePostfix(expr, false);
    }

    /// §13.3.7 SuperCall / §13.3.5 SuperProperty — current token is `super`. A `super(args)` is only
    /// legal in a derived constructor; a `super.name` / `super[expr]` only inside a method (anything
    /// with a [[HomeObject]]). A bare `super` (no following `(` / `.` / `[`) is a SyntaxError.
    fn parseSuper(self: *Parser) ParseError!*const ast.Node {
        _ = self.advance(); // super
        switch (self.peek().kind) {
            .lparen => {
                // §13.3.7.1 Early Error: a SuperCall must appear within a derived-class constructor.
                if (!self.in_derived_ctor) return ParseError.UnexpectedToken;
                const args = try self.parseArgs();
                return self.alloc(.{ .super_call = args });
            },
            .dot => {
                // §13.3.5.1 Early Error: a SuperProperty must appear within a method ([[HomeObject]]).
                if (!self.in_method) return ParseError.UnexpectedToken;
                _ = self.advance();
                const name = try self.expectPropertyName();
                return self.alloc(.{ .super_member = .{ .name = name } });
            },
            .lbracket => {
                if (!self.in_method) return ParseError.UnexpectedToken;
                _ = self.advance();
                const key = try self.parseAssignment();
                _ = try self.expect(.rbracket);
                return self.alloc(.{ .super_member = .{ .key = key } });
            },
            else => return ParseError.UnexpectedToken, // bare `super` is never a primary
        }
    }

    /// Continue a Member/Call postfix chain from an already-parsed base (`expr`). Shared by the
    /// ordinary-primary path and the `super.x` base. `in_chain` records whether a `?.` has appeared.
    fn continuePostfix(self: *Parser, base: *const ast.Node, started_in_chain: bool) ParseError!*const ast.Node {
        var expr = base;
        var in_chain = started_in_chain; // have we seen a `?.` for the current chain root?
        while (true) {
            switch (self.peek().kind) {
                .question_dot => {
                    _ = self.advance();
                    in_chain = true;
                    switch (self.peek().kind) {
                        .lbracket => { // ?.[ key ]
                            _ = self.advance();
                            const key = try self.parseAssignmentInBrackets();
                            _ = try self.expect(.rbracket);
                            expr = try self.alloc(.{ .optional = .{ .base = expr, .optional = true, .link = .{ .index = key } } });
                        },
                        .lparen => { // ?.( args )
                            const args = try self.parseArgs();
                            expr = try self.alloc(.{ .optional = .{ .base = expr, .optional = true, .link = .{ .call = args } } });
                        },
                        else => { // ?.name  (name is an IdentifierName — keywords allowed)
                            const name = try self.expectPropertyName();
                            expr = try self.alloc(.{ .optional = .{ .base = expr, .optional = true, .link = .{ .member = name } } });
                        },
                    }
                },
                .dot => {
                    _ = self.advance();
                    // §13.3.2 `obj.#x` — a private member access. The `#name` is only legal inside a
                    // class body (§15.7); outside one it is a SyntaxError. A private reference does not
                    // participate in optional chaining short-circuit semantics specially — we model it
                    // as a `private_member` node (chained private access after `?.` is rare; reject it
                    // to keep the brand-check semantics simple rather than mis-handle it).
                    if (self.peek().kind == .private_identifier) {
                        // §15.7.1: a private reference must be inside a class body AND resolve to a
                        // declared private name (AllPrivateNamesValid) — else a SyntaxError.
                        if (!self.in_class_body or in_chain) return ParseError.UnexpectedToken;
                        const pname = self.advance().lexeme;
                        if (!self.privateNameDeclared(pname)) return ParseError.UnexpectedToken;
                        expr = try self.alloc(.{ .private_member = .{ .object = expr, .name = pname } });
                        continue;
                    }
                    const name = try self.expectPropertyName();
                    expr = if (in_chain)
                        try self.alloc(.{ .optional = .{ .base = expr, .optional = false, .link = .{ .member = name } } })
                    else
                        try self.alloc(.{ .member = .{ .object = expr, .name = name } });
                },
                .lbracket => {
                    _ = self.advance();
                    const key = try self.parseAssignmentInBrackets();
                    _ = try self.expect(.rbracket);
                    expr = if (in_chain)
                        try self.alloc(.{ .optional = .{ .base = expr, .optional = false, .link = .{ .index = key } } })
                    else
                        try self.alloc(.{ .index = .{ .object = expr, .key = key } });
                },
                .lparen => { // §13.3.6 call
                    const args = try self.parseArgs();
                    expr = if (in_chain)
                        try self.alloc(.{ .optional = .{ .base = expr, .optional = false, .link = .{ .call = args } } })
                    else
                        try self.alloc(.{ .call = .{ .callee = expr, .args = args } });
                },
                else => break,
            }
        }
        // §13.3.9.1 Early Error: `OptionalChain TemplateLiteral` is a SyntaxError — a tagged
        // template may not be applied to an optional chain (`a?.fn\`x\``).
        if (in_chain and self.peek().kind == .template) return ParseError.UnexpectedToken;
        // §13.4.2/3 postfix ++ / -- . §13.3.9.1 Early Error: the operand of an UpdateExpression may
        // not be an OptionalChain (`a?.b++` is a SyntaxError) — the chain result isn't a Reference.
        // §13.4 restricted production: `LeftHandSideExpression [no LineTerminator here] ++ / --`. A
        // LineTerminator before the operator (incl. the Unicode U+2028/U+2029) means it is NOT a
        // postfix update — ASI ends the statement here and the `++`/`--` begins the next one.
        if ((self.peek().kind == .plus_plus or self.peek().kind == .minus_minus) and !self.peek().newline_before) {
            if (in_chain) return ParseError.UnexpectedToken;
            // §13.4.1.1 Early Error: in strict, a postfix-update operand may not be the reference
            // `eval`/`arguments`.
            if (self.strict) switch (expr.*) {
                .identifier => |n| if (isEvalOrArguments(n)) return ParseError.UnexpectedToken,
                else => {},
            };
            // §13.4.1.1 Early Error: a (parenthesized) YieldExpression / AwaitExpression is not a
            // simple assignment target — `(yield)++` in a generator, `(await x)++` in an async
            // function are SyntaxErrors.
            if (expr.* == .yield_expr or expr.* == .await_expr) return ParseError.UnexpectedToken;
            const op: ast.UpdateOp = if (self.peek().kind == .plus_plus) .inc else .dec;
            _ = self.advance();
            expr = try self.alloc(.{ .update = .{ .op = op, .prefix = false, .target = expr } });
        }
        return expr;
    }

    /// Parse a method / accessor `{ FunctionBody }` (current token is `{`), handling strict-mode
    /// context the same way `parseFunction` does: the body inherits the enclosing strictness OR its
    /// own "use strict" prologue (§11.2.2), strict params may not be reserved/`eval`/`arguments`
    /// (§13.1.1), and a "use strict" directive is forbidden with a non-simple param list (§15.1.1).
    /// `strict_out` (when non-null) receives this method body's §11.2.2 strict-mode flag (inherited
    /// strict, an own `"use strict"`, or — for a class member — the always-strict class body), so the
    /// caller can record it on the `ast.Function` for runtime strict gating. (`self.strict` is restored
    /// to the enclosing value on the way out, so it can't be read back at the creation site.)
    fn parseMethodBody(self: *Parser, pl: ParamList, strict_out: ?*bool) ParseError![]const ast.Stmt {
        const enclosing_strict = self.strict;
        defer self.strict = enclosing_strict;
        const body_strict = enclosing_strict or
            (self.peek().kind == .lbrace and directivePrologueIsStrict(self.tokens[self.idx + 1 ..]));
        if (strict_out) |p| p.* = body_strict;
        if (body_strict and paramsHaveStrictReserved(pl)) return ParseError.UnexpectedToken;
        self.strict = body_strict;
        const ctrl = self.enterControlScope(); // §14.13: a method body starts a fresh label scope
        defer self.exitControlScope(ctrl);
        const body = try self.parseBlock();
        if (!isSimpleParameterList(pl) and bodyHasUseStrict(body)) return ParseError.UnexpectedToken;
        return body;
    }

    /// §13.2.5 Object initializer `{ … }`. Supports every PropertyDefinition form:
    ///   `k: v` · shorthand `{x}` (≡ `x: x`) · computed `[expr]: v` · method `m(){…}` ·
    ///   accessors `get x(){…}` / `set x(v){…}` · spread `...expr`.
    fn parseObjectLiteral(self: *Parser) ParseError!*const ast.Node {
        _ = try self.expect(.lbrace);
        var props: std.ArrayList(ast.Property) = .empty;
        // §B.3.1 Early Error: at most ONE `__proto__:` colon-property (literal name, not computed) per
        // object literal — a second is a SyntaxError. Counted as such proto-setter properties are added.
        var proto_count: usize = 0;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            // §13.2.5 PropertyDefinition : `...AssignmentExpression` (object spread).
            if (self.peek().kind == .ellipsis) {
                _ = self.advance();
                const src = try self.parseAssignmentInBrackets();
                try props.append(self.arena, .{ .kind = .spread, .value = src });
                if (self.peek().kind == .comma) {
                    _ = self.advance();
                    continue;
                }
                break;
            }

            // §13.2.5 GeneratorMethod `* m(){…}` / §15.8 AsyncMethod `async m(){…}` / §15.6
            // AsyncGeneratorMethod `async * m(){…}` in an object literal — a leading `*` marks a
            // generator method; a leading `async` (no LineTerminator before the name/`*`) marks an
            // async method, optionally `*` for an async generator. `async` is the modifier only when
            // followed by something that begins a property name or `*` (else `{async: 1}` / `{async}` /
            // `{async(){}}` use the identifier `async`).
            {
                var om_is_async = false;
                if (self.peek().kind == .identifier and !self.peek().had_escape and std.mem.eql(u8, self.peek().lexeme, "async") and
                    !self.tokens[self.idx + 1].newline_before and
                    (startsAccessorName(self.tokens[self.idx + 1].kind) or self.tokens[self.idx + 1].kind == .star))
                {
                    om_is_async = true;
                    _ = self.advance(); // consume `async`
                }
                var om_is_gen = false;
                if (self.peek().kind == .star) {
                    om_is_gen = true;
                    _ = self.advance(); // consume `*`
                }
                if (om_is_async or om_is_gen) {
                    const name = try self.parsePropertyName();
                    if (self.peek().kind != .lparen) return ParseError.UnexpectedToken; // a `*`/`async` element must be a method
                    const saved_in_generator = self.in_generator;
                    const saved_in_async = self.in_async;
                    defer self.in_generator = saved_in_generator;
                    defer self.in_async = saved_in_async;
                    // §15.5/§15.8: the params parse `~Yield`/`~Await` (a `yield`/`await` operator there
                    // is a §15.5.1/§15.8.1 SyntaxError), the body `+Yield`/`+Await`.
                    self.in_generator = false;
                    self.in_async = false;
                    const pl = try self.parseParams();
                    if (om_is_gen and paramsHaveYield(pl)) return ParseError.UnexpectedToken;
                    if (om_is_async and paramsHaveAwait(pl)) return ParseError.UnexpectedToken;
                    self.in_generator = om_is_gen;
                    self.in_async = om_is_async;
                    var body_strict: bool = false;
                    const body = try self.parseMethodBody(pl, &body_strict);
                    if (hasDuplicateBoundNames(pl)) return ParseError.UnexpectedToken;
                    // §14.3.1 / §15.5.1: params may not collide with the body's LexicallyDeclaredNames.
                    if (paramsConflictWithBodyLexical(pl, body)) return ParseError.UnexpectedToken;
                    const f = try self.arena.create(ast.Function);
                    f.* = .{ .name = null, .params = pl.params, .rest = pl.rest, .body = body, .is_generator = om_is_gen, .is_async = om_is_async, .is_method = true, .strict = body_strict };
                    const fnode = try self.alloc(.{ .function = f });
                    try props.append(self.arena, .{ .key = name.key, .computed_key = name.computed, .value = fnode });
                    if (self.peek().kind == .comma) {
                        _ = self.advance();
                        continue;
                    }
                    break;
                }
            }

            // §13.2.5.6 `get`/`set` accessor — only when the next token starts a property name (so
            // `{get: 1}` and `{get(){}}` and `{get}` stay ordinary uses of the identifier `get`).
            const w = self.peek();
            if (w.kind == .identifier and !w.had_escape and (std.mem.eql(u8, w.lexeme, "get") or std.mem.eql(u8, w.lexeme, "set")) and
                startsAccessorName(self.tokens[self.idx + 1].kind))
            {
                const is_get = std.mem.eql(u8, w.lexeme, "get");
                _ = self.advance(); // get / set
                const name = try self.parsePropertyName();
                const pl = try self.parseParams();
                // §13.2.5.1 accessor arity Early Errors: a getter takes an empty parameter list
                // (`get x()`); a setter takes exactly one PropertySetParameter (`set x(v)`). The
                // setter parameter is a FormalParameter — a default initializer is allowed
                // (`set x(v = 1)`), but a rest element is NOT (`set x(...v)` is a SyntaxError).
                if (is_get) {
                    if (pl.params.len != 0 or pl.rest != null) return ParseError.UnexpectedToken;
                } else {
                    if (pl.params.len != 1 or pl.rest != null) return ParseError.UnexpectedToken;
                }
                var body_strict: bool = false;
                const body = try self.parseMethodBody(pl, &body_strict);
                // §13.2.5.1 UniqueFormalParameters — a method/accessor's params have no duplicates.
                if (hasDuplicateBoundNames(pl)) return ParseError.UnexpectedToken;
                const f = try self.arena.create(ast.Function);
                f.* = .{ .name = null, .params = pl.params, .rest = pl.rest, .body = body, .is_method = true, .strict = body_strict };
                const fnode = try self.alloc(.{ .function = f });
                try props.append(self.arena, .{
                    .kind = if (is_get) .get else .set,
                    .key = name.key,
                    .computed_key = name.computed,
                    .value = fnode,
                });
                if (self.peek().kind == .comma) {
                    _ = self.advance();
                    continue;
                }
                break;
            }

            // Ordinary / shorthand / computed / method. First parse the property name.
            const name = try self.parsePropertyName();

            if (self.peek().kind == .lparen) {
                // §13.2.5 MethodDefinition `m(args){…}` — sugar for `m: function(args){…}`. An ordinary
                // method un-sets `in_generator` (yield is not the operator there, even inside an
                // enclosing generator); restored after the body.
                const saved_in_generator = self.in_generator;
                defer self.in_generator = saved_in_generator;
                self.in_generator = false;
                const pl = try self.parseParams();
                var body_strict: bool = false;
                const body = try self.parseMethodBody(pl, &body_strict);
                // §13.2.5.1 UniqueFormalParameters — a method's parameters have no duplicates.
                if (hasDuplicateBoundNames(pl)) return ParseError.UnexpectedToken;
                // §14.3.1: params may not collide with the body's LexicallyDeclaredNames.
                if (paramsConflictWithBodyLexical(pl, body)) return ParseError.UnexpectedToken;
                const f = try self.arena.create(ast.Function);
                f.* = .{ .name = null, .params = pl.params, .rest = pl.rest, .body = body, .is_method = true, .strict = body_strict };
                const fnode = try self.alloc(.{ .function = f });
                try props.append(self.arena, .{ .key = name.key, .computed_key = name.computed, .value = fnode });
            } else if (self.peek().kind == .colon) {
                // PropertyDefinition : PropertyName `:` AssignmentExpression. A `key: target = init`
                // tail is a legal AssignmentExpression value (`{a: b = 1}` ≡ `{a: (b = 1)}`), so
                // `parseAssignment` already folds the `= init` into an `assign*` node — no separate
                // default is needed here. When refined to an AssignmentPattern, `assignElement` strips
                // that folded `= init` and applies it as the property's destructuring default.
                _ = self.advance();
                const value = try self.parseAssignmentInBrackets();
                // §B.3.1: a colon property with a LITERAL (non-computed) PropertyName `__proto__`
                // — `{__proto__: v}` (identifier) or `{"__proto__": v}` (string) — is the [[Prototype]]
                // setter, not an own property. A computed `{["__proto__"]: v}` (name.computed != null)
                // is excluded. Two such properties is a §B.3.1 Early Error (a SyntaxError).
                const is_proto = name.computed == null and std.mem.eql(u8, name.key, "__proto__");
                if (is_proto) {
                    proto_count += 1;
                    // A SECOND `__proto__:` is recorded as a deferred §B.3.1 Early Error — discharged
                    // only if this literal is later refined to an ObjectAssignment pattern (where
                    // duplicates are allowed); otherwise `parseStmt` reports the residue as a SyntaxError.
                    if (proto_count > 1) self.proto_dup += 1;
                }
                try props.append(self.arena, .{ .key = name.key, .computed_key = name.computed, .value = value, .is_proto = is_proto });
            } else {
                // §13.2.5 IdentifierReference shorthand `{x}` ≡ `{x: x}`. Only valid for a plain
                // (non-computed, non-string-keyed) identifier name; a computed/string key with no
                // `:`/`(` is a SyntaxError.
                if (name.computed != null or !name.is_ident) return ParseError.UnexpectedToken;
                // §12.7.1 / §13.2.5: a shorthand `{x}` is an IdentifierReference (`Identifier ::
                // IdentifierName but not ReservedWord`), so an escaped §12.7.2 ReservedWord shorthand
                // (`({ with })`) is always a SyntaxError — in BOTH modes (the word is reserved
                // unconditionally, unlike the strict-only `let`/`static` handled at refinement).
                if (name.had_escape and lex.isReservedWord(name.key)) return ParseError.UnexpectedToken;
                // §13.1.1 / §15.5.1 / §15.7.11: a shorthand IdentifierReference may not be a reserved
                // word — `yield` in strict OR inside a generator body (`({ yield })` / `({ yield } = o)`
                // in a `function*`), `await` inside a static block.
                if ((self.strict or self.in_generator) and std.mem.eql(u8, name.key, "yield")) return ParseError.UnexpectedToken;
                if (self.in_static_block and std.mem.eql(u8, name.key, "await")) return ParseError.UnexpectedToken;
                // §13.2.5.1 CoverInitializedName `{x = default}`: legal ONLY as the cover grammar for an
                // object AssignmentPattern. We parse it (recording the default) so `({x = 1} = o)` works;
                // a literal that still carries it is a SyntaxError, enforced in `evalObjectLiteral`.
                var default: ?*const ast.Node = null;
                if (self.peek().kind == .assign) {
                    _ = self.advance();
                    default = try self.parseAssignmentInBrackets();
                    self.cover_init += 1; // §13.2.5.1 CoverInitializedName — discharged only if refined
                }
                const ref = try self.alloc(.{ .identifier = name.key });
                try props.append(self.arena, .{ .key = name.key, .value = ref, .default = default });
            }

            if (self.peek().kind == .comma) {
                _ = self.advance();
                continue;
            }
            break;
        }
        _ = try self.expect(.rbrace);
        // §13.15.1: the literal itself is NOT a ParenthesizedExpression — clear any `last_was_paren`
        // set by a parenthesized inner value/default (`{a: (b)}`, `{a = (1)}`), so the `=`/for-head
        // cover-grammar refinement is not mis-rejected as a parenthesized target.
        self.last_was_paren = false;
        return self.alloc(.{ .object_literal = props.items });
    }

    const PropName = struct { key: []const u8, computed: ?*const ast.Node = null, is_ident: bool = false, had_escape: bool = false };

    /// §13.2.5 PropertyName — a literal name (identifier / string / number) or a `[expr]`
    /// ComputedPropertyName. `is_ident` flags a bare identifier (the only shorthand-eligible form).
    fn parsePropertyName(self: *Parser) ParseError!PropName {
        const t = self.peek();
        switch (t.kind) {
            .lbracket => {
                _ = self.advance();
                const expr = try self.parseAssignmentInBrackets();
                _ = try self.expect(.rbracket);
                return .{ .key = "", .computed = expr };
            },
            .identifier => {
                _ = self.advance();
                return .{ .key = t.lexeme, .is_ident = true, .had_escape = t.had_escape };
            },
            .string => {
                // §12.9.4.1 Early Error: a legacy-octal escape in a string PropertyName is a strict-
                // mode SyntaxError too (e.g. `"use strict"; ({"\1": 1})`).
                if (self.strict and t.has_legacy_octal) return ParseError.UnexpectedToken;
                _ = self.advance();
                return .{ .key = t.string_value };
            },
            .number => {
                _ = self.advance();
                // §13.2.5 numeric property names are ToString'd: `{0.5: 1}` → key "0.5".
                const n = self.parseNumericLiteral(t.lexeme) catch return ParseError.UnexpectedToken;
                return .{ .key = try numericKey(self.arena, n) };
            },
            else => {
                // Keywords are valid (non-shorthand) property names: `{if: 1}`, `{return(){}}`.
                if (isKeywordName(t.kind)) {
                    _ = self.advance();
                    return .{ .key = t.lexeme };
                }
                return ParseError.UnexpectedToken;
            },
        }
    }

    /// §12.9.3 — the numeric value of a NumericLiteral lexeme: strip `_` separators, decode
    /// `0x`/`0o`/`0b` by radix (accumulated into f64 to avoid u64 overflow), else parse as a decimal
    /// (integer / fraction / exponent). (Legacy octal `0123` is treated as decimal — a documented
    /// M-subset deviation; it is a strict-mode Early Error anyway.)
    fn parseNumericLiteral(self: *Parser, lexeme: []const u8) ParseError!f64 {
        if (!validNumericSeparators(lexeme)) return ParseError.UnexpectedToken; // §12.9.3 separator placement
        // §12.9.3.1 Early Error: LegacyOctalIntegerLiteral / NonOctalDecimalIntegerLiteral (`0` followed
        // by a decimal digit, e.g. `08`, `010`) is forbidden in strict mode.
        if (self.strict and lexeme.len >= 2 and lexeme[0] == '0' and lexeme[1] >= '0' and lexeme[1] <= '9') {
            return ParseError.UnexpectedToken;
        }
        var buf: std.ArrayList(u8) = .empty;
        for (lexeme) |ch| if (ch != '_') try buf.append(self.arena, ch);
        const s = buf.items;
        if (s.len >= 2 and s[0] == '0') {
            const radix: ?u8 = switch (s[1]) {
                'x', 'X' => 16,
                'o', 'O' => 8,
                'b', 'B' => 2,
                else => null,
            };
            if (radix) |r| {
                if (s.len == 2) return ParseError.UnexpectedToken; // prefix with no digits
                var v: f64 = 0;
                for (s[2..]) |d| {
                    const dv: u8 = switch (d) {
                        '0'...'9' => d - '0',
                        'a'...'f' => d - 'a' + 10,
                        'A'...'F' => d - 'A' + 10,
                        else => return ParseError.UnexpectedToken,
                    };
                    if (dv >= r) return ParseError.UnexpectedToken; // digit out of range for the radix
                    v = v * @as(f64, @floatFromInt(r)) + @as(f64, @floatFromInt(dv));
                }
                return v;
            }
        }
        return std.fmt.parseFloat(f64, s) catch ParseError.UnexpectedToken;
    }

    fn parsePrimary(self: *Parser) ParseError!*const ast.Node {
        const t = self.peek();
        switch (t.kind) {
            .number => {
                _ = self.advance();
                const n = self.parseNumericLiteral(t.lexeme) catch return ParseError.UnexpectedToken;
                return self.alloc(.{ .number = n });
            },
            .string => {
                // §12.9.4.1 / Annex B.1.2 Early Error: a LegacyOctalEscapeSequence /
                // NonOctalDecimalEscape / `\0`-before-a-digit in a StringLiteral is a SyntaxError in
                // strict mode (the lexer flagged the token; strict-ness is only known here).
                if (self.strict and t.has_legacy_octal) return ParseError.UnexpectedToken;
                _ = self.advance();
                return self.alloc(.{ .string = t.string_value });
            },
            .kw_true => {
                _ = self.advance();
                return self.alloc(.{ .boolean = true });
            },
            .kw_false => {
                _ = self.advance();
                return self.alloc(.{ .boolean = false });
            },
            .kw_null => {
                _ = self.advance();
                return self.alloc(.null);
            },
            .identifier => {
                // §12.7.1: an escaped §12.7.2 ReservedWord is not a valid IdentifierReference.
                if (isEscapedReservedIdent(t)) return ParseError.UnexpectedToken;
                // §12.7.1 Early Error: an escaped `async` immediately followed (no LineTerminator) by
                // `function` is the AsyncFunctionExpression production written with an escape — a
                // SyntaxError, never `<identifier async> <function>`. (Caught here because async function
                // expressions in unary-operand position, e.g. `void async function f(){}`, are not
                // recognized at the assignment level.)
                if (t.had_escape and std.mem.eql(u8, t.lexeme, "async") and
                    self.idx + 1 < self.tokens.len and self.tokens[self.idx + 1].kind == .kw_function and
                    !self.tokens[self.idx + 1].newline_before) return ParseError.UnexpectedToken;
                // §13.1.1: `yield` is a reserved word in strict mode — using it as an
                // IdentifierReference (a primary expression, e.g. a `m(x = yield)` param default
                // inside an always-strict class body) is a SyntaxError.
                if (self.strict and std.mem.eql(u8, t.lexeme, "yield")) return ParseError.UnexpectedToken;
                // §14.4 / §15.5.1: inside a generator body `yield` is ALWAYS the yield operator (parsed
                // at the assignment level by `parseYield`), never an IdentifierReference — so a `yield`
                // reaching the primary position (`void yield`, `yield + x`, `(yield)`, the second
                // `yield` in `yield 3 + yield 4`) is a SyntaxError.
                if (self.in_generator and std.mem.eql(u8, t.lexeme, "yield")) return ParseError.UnexpectedToken;
                // §15.8 / §15.8.1: inside an async context `await` is ALWAYS the AwaitExpression
                // operator (parsed at the unary level by `parseUnary`), never an IdentifierReference —
                // a bare `await` reaching primary position is a SyntaxError. Outside async (sloppy
                // scripts/functions) `await` is an ordinary identifier and falls through below.
                if (self.in_async and std.mem.eql(u8, t.lexeme, "await")) return ParseError.UnexpectedToken;
                // §15.7.11: `await` is reserved as an IdentifierReference inside a static block body.
                if (self.in_static_block and std.mem.eql(u8, t.lexeme, "await")) return ParseError.UnexpectedToken;
                // §15.7.11 Early Error: ContainsArguments of a ClassStaticBlock's statement list is a
                // SyntaxError — `arguments` may not appear as an IdentifierReference directly in a static
                // block. `in_static_block` is cleared when entering a nested ordinary function (which
                // rebinds `arguments`), so this only fires for the block's own references.
                if (self.in_static_block and std.mem.eql(u8, t.lexeme, "arguments")) return ParseError.UnexpectedToken;
                _ = self.advance();
                return self.alloc(.{ .identifier = t.lexeme });
            },
            .lbrace => return self.parseObjectLiteral(),
            .lbracket => { // §13.2.4 array literal (also the cover grammar for an ArrayAssignmentPattern)
                _ = self.advance();
                var elems: std.ArrayList(*const ast.Node) = .empty;
                var last_was_spread = false;
                while (self.peek().kind != .rbracket and self.peek().kind != .eof) {
                    // §13.2.4 Elision — a hole `[a, , b]` / `[, x]` (a comma with no preceding element).
                    if (self.peek().kind == .comma) {
                        _ = self.advance();
                        try elems.append(self.arena, try self.alloc(.elision));
                        continue;
                    }
                    // An element may carry a `= AssignmentExpression` tail. In an array LITERAL this is
                    // an ordinary assignment (`[a = 1]` ≡ `[(a = 1)]`); when the literal is refined to an
                    // ArrayAssignmentPattern the `=` becomes the element's default. `parseSpreadable`'s
                    // `parseAssignment` already consumes the `=` (assignment is right-recursive there), so
                    // both readings share the same node shape (an `assign`/`assign_*` element or a spread).
                    const el = try self.parseSpreadable();
                    try elems.append(self.arena, el);
                    last_was_spread = el.* == .spread;
                    if (self.peek().kind == .comma) {
                        _ = self.advance();
                        // §13.15.5.1: a trailing comma AFTER a spread (`[...x,]`) is a valid array LITERAL
                        // (no extra element) but makes the refined AssignmentRestElement non-last — record
                        // a trailing `elision` so `validateAssignmentPattern` sees the spread is not last.
                        // Literal evaluation drops a trailing elision that follows a spread.
                        if (last_was_spread and self.peek().kind == .rbracket) {
                            try elems.append(self.arena, try self.alloc(.elision));
                        }
                        continue;
                    }
                    break;
                }
                _ = try self.expect(.rbracket);
                // §13.15.1: the literal itself is NOT a ParenthesizedExpression — clear any
                // `last_was_paren` set by a parenthesized inner default (`[a = (1)]`), so the
                // `=`/for-head cover-grammar refinement is not mis-rejected as a parenthesized target.
                self.last_was_paren = false;
                return self.alloc(.{ .array_literal = elems.items });
            },
            .kw_function => {
                _ = self.advance();
                return self.alloc(.{ .function = try self.parseFunction(false) });
            },
            .kw_this => {
                _ = self.advance();
                return self.alloc(.this);
            },
            .template => {
                _ = self.advance();
                return self.parseTemplate(t.string_value);
            },
            .kw_new => return self.parseNew(),
            // §13.3.10 ImportCall / §16.2 modules are unsupported — `import` is a reserved word, so
            // any expression form (`import(x)`, `import.meta`, …) is a parse-phase SyntaxError. This
            // also keeps spread support honest: ImportCall forbids `...` (a Forbidden Extension), so
            // `import(...x)` must not parse as an ordinary spread call.
            .kw_import => return ParseError.UnexpectedToken,
            // §15.7 ClassExpression (primary position). The name is optional (`class { … }`).
            .kw_class => return self.alloc(.{ .class_expr = try self.parseClass(false) }),
            // §13.3.5/§13.3.7: `super` is handled in `parsePostfix` (it must be the base of a
            // SuperProperty/SuperCall). Reaching it here means a bare `super` in a non-postfix
            // position (e.g. `super + 1`) — always a SyntaxError.
            .kw_super => return ParseError.UnexpectedToken,
            // §13.10.1: a PrivateIdentifier as a primary is ONLY valid as the LHS of `#x in obj`
            // (handled in parseExpr) — as a member name it is consumed by `continuePostfix`. Reaching
            // it here is a bare `#x` in expression position, always a SyntaxError.
            .private_identifier => return ParseError.UnexpectedToken,
            .lparen => {
                // §13.2.3 ParenthesizedExpression : `(` Expression `)` — a full Expression, so the
                // comma / sequence operator is allowed (`(a, b)` yields `b`). The arrow cover-grammar
                // `( … ) =>` is already handled in `parseAssignment` (its lookahead fires before we
                // reach here), so this path only sees a genuine parenthesized expression.
                _ = self.advance();
                const inner = try self.parseExpressionInBrackets();
                _ = try self.expect(.rparen);
                self.last_was_paren = true; // §13.13.1: a parenthesized operand defuses the mix check
                return inner;
            },
            .eof => return ParseError.UnexpectedEof,
            else => return ParseError.UnexpectedToken,
        }
    }
};

/// §13.1.1: `eval` and `arguments` are not valid as a BindingIdentifier or as an assignment /
/// update target in strict mode.
fn isEvalOrArguments(name: []const u8) bool {
    return std.mem.eql(u8, name, "eval") or std.mem.eql(u8, name, "arguments");
}

/// §12.7.1 / §12.7.2: an `Identifier` is `IdentifierName but not ReservedWord`. A token that is an
/// identifier whose IdentifierName contained a Unicode escape AND whose decoded StringValue is a
/// §12.7.2 ReservedWord is NOT a valid Identifier (binding / reference) — a SyntaxError. (`yield`/
/// `await` are excepted by §12.7.1 and are not in `isReservedWord`.) Non-escaped reserved words are
/// lexed as keyword tokens and never reach an Identifier position as an `.identifier`, so this guard
/// fires only for the escaped spelling. It does NOT apply at IdentifierName positions (property names,
/// member access), where reserved words — escaped or not — are valid.
fn isEscapedReservedIdent(t: lex.Token) bool {
    return t.kind == .identifier and t.had_escape and lex.isReservedWord(t.lexeme);
}

/// §13.1.1 / Table: a name that may not be used as a BindingIdentifier in strict mode — `eval`,
/// `arguments`, and the strict future-reserved words. (`let`/`static`/`yield` are contextual; as a
/// *binding name* they are forbidden in strict. `let` is already lexed as a keyword so it never
/// reaches here as an identifier lexeme, but listing it keeps the set complete.)
/// §14.4: may a token begin a YieldExpression's argument (an AssignmentExpression)? Everything except
/// the tokens that close/separate the enclosing context (`)`, `]`, `}`, `,`, `;`, `:`) and eof. (`:`
/// closes a conditional/case/label; `}` closes a block/object; the rest are list/group separators.)
fn startsYieldArgument(kind: lex.TokenKind) bool {
    return switch (kind) {
        .rparen, .rbracket, .rbrace, .comma, .semicolon, .colon, .eof => false,
        else => true,
    };
}

fn isStrictReservedBindingName(name: []const u8) bool {
    if (isEvalOrArguments(name)) return true;
    const reserved = [_][]const u8{
        "implements", "interface", "let",    "package", "private",
        "protected",  "public",    "static", "yield",
    };
    for (reserved) |r| {
        if (std.mem.eql(u8, name, r)) return true;
    }
    return false;
}

/// Does any identifier bound by `pattern` violate the strict BindingIdentifier restrictions
/// (§13.1.1)? Recurses through array/object binding patterns (and their rest elements).
fn patternHasStrictReserved(pattern: *const ast.Pattern) bool {
    switch (pattern.*) {
        .identifier => |n| return isStrictReservedBindingName(n),
        .array => |ap| {
            for (ap.elements) |el| {
                if (el.target) |t| if (patternHasStrictReserved(t)) return true;
            }
            if (ap.rest) |r| return patternHasStrictReserved(r);
            return false;
        },
        .object => |op| {
            for (op.properties) |prop| {
                if (patternHasStrictReserved(prop.target)) return true;
            }
            if (op.rest) |r| return isStrictReservedBindingName(r);
            return false;
        },
    }
}

/// §13.15.1 / §14.7.5: is `node` a simple AssignmentTarget usable as a for-in/of head? The M-subset
/// accepts a plain identifier, a member `a.b`, or an index `a[k]` (the forms the interpreter's
/// `bindForHead` can write). Destructuring-pattern heads (`for ([a] of …)`) are a later cycle.
fn isSimpleAssignTarget(node: *const ast.Node) bool {
    return switch (node.*) {
        .identifier, .member, .index => true,
        else => false,
    };
}

/// §13.1.1: does any formal parameter (including the rest element) bind a strict-reserved name?
fn paramsHaveStrictReserved(pl: Parser.ParamList) bool {
    for (pl.params) |p| {
        if (patternHasStrictReserved(p.pattern)) return true;
    }
    if (pl.rest) |r| return patternHasStrictReserved(r);
    return false;
}

/// §15.5.1 Early Error: a GeneratorDeclaration/Expression's FormalParameters may neither bind nor
/// reference `yield` (the params are outside the `[+Yield]` body but `yield` is still restricted). A
/// param BindingIdentifier `yield` (`function* g(yield){}`) or a default that references `yield`
/// (`function* g(a = yield){}` — parsed as the identifier `yield` since params are `~Yield`) is invalid.
fn paramsHaveYield(pl: Parser.ParamList) bool {
    for (pl.params) |p| {
        if (patternBindsYield(p.pattern)) return true;
        if (p.default) |d| if (nodeReferencesYield(d)) return true;
    }
    if (pl.rest) |r| return patternBindsYield(r);
    return false;
}

fn patternBindsYield(pattern: *const ast.Pattern) bool {
    switch (pattern.*) {
        .identifier => |n| return std.mem.eql(u8, n, "yield"),
        .array => |ap| {
            for (ap.elements) |el| {
                if (el.target) |t| if (patternBindsYield(t)) return true;
                if (el.default) |d| if (nodeReferencesYield(d)) return true;
            }
            if (ap.rest) |r| return patternBindsYield(r);
            return false;
        },
        .object => |op| {
            for (op.properties) |prop| {
                if (patternBindsYield(prop.target)) return true;
                if (prop.default) |d| if (nodeReferencesYield(d)) return true;
            }
            if (op.rest) |r| return std.mem.eql(u8, r, "yield");
            return false;
        },
    }
}

/// Shallow scan for a `yield` IdentifierReference or a `yield_expr` node in `node` — enough to reject a
/// `yield` in a generator's FormalParameters (§15.5.1). Covers the common default-value expressions; a
/// deeply buried `yield` (e.g. inside a nested function literal default) is not chased (rare; a nested
/// non-generator function un-restricts `yield` anyway).
fn nodeReferencesYield(node: *const ast.Node) bool {
    return switch (node.*) {
        .identifier => |n| std.mem.eql(u8, n, "yield"),
        .yield_expr => true,
        .unary => |u| nodeReferencesYield(u.operand),
        .binary => |b| nodeReferencesYield(b.left) or nodeReferencesYield(b.right),
        .logical => |l| nodeReferencesYield(l.left) or nodeReferencesYield(l.right),
        .conditional => |c| nodeReferencesYield(c.cond) or nodeReferencesYield(c.then) or nodeReferencesYield(c.otherwise),
        .assign => |a| nodeReferencesYield(a.value),
        .comma => |c| nodeReferencesYield(c.left) or nodeReferencesYield(c.right),
        .call => |c| nodeReferencesYield(c.callee),
        else => false,
    };
}

/// §15.8.1 / §15.6.1 Early Error: an AsyncFunction/AsyncArrow/AsyncGenerator's FormalParameters may
/// neither bind `await` (`async function f(await){}`) nor — since params parse `~Await` — contain an
/// AwaitExpression. A param BindingIdentifier `await`, or a default that references `await` as the
/// identifier (`async (a = await) => {}`, parsed as the identifier `await` since params are `~Await`),
/// is invalid. Mirrors `paramsHaveYield`.
fn paramsHaveAwait(pl: Parser.ParamList) bool {
    for (pl.params) |p| {
        if (patternBindsAwait(p.pattern)) return true;
        if (p.default) |d| if (nodeReferencesAwait(d)) return true;
    }
    if (pl.rest) |r| return patternBindsAwait(r);
    return false;
}

fn patternBindsAwait(pattern: *const ast.Pattern) bool {
    switch (pattern.*) {
        .identifier => |n| return std.mem.eql(u8, n, "await"),
        .array => |ap| {
            for (ap.elements) |el| {
                if (el.target) |t| if (patternBindsAwait(t)) return true;
                if (el.default) |d| if (nodeReferencesAwait(d)) return true;
            }
            if (ap.rest) |r| return patternBindsAwait(r);
            return false;
        },
        .object => |op| {
            for (op.properties) |prop| {
                if (patternBindsAwait(prop.target)) return true;
                if (prop.default) |d| if (nodeReferencesAwait(d)) return true;
            }
            if (op.rest) |r| return std.mem.eql(u8, r, "await");
            return false;
        },
    }
}

/// Shallow scan for an `await` IdentifierReference or an `await_expr` node in `node` — enough to
/// reject `await` in an async function's FormalParameters (§15.8.1). Mirrors `nodeReferencesYield`.
fn nodeReferencesAwait(node: *const ast.Node) bool {
    return switch (node.*) {
        .identifier => |n| std.mem.eql(u8, n, "await"),
        .await_expr => true,
        .unary => |u| nodeReferencesAwait(u.operand),
        .binary => |b| nodeReferencesAwait(b.left) or nodeReferencesAwait(b.right),
        .logical => |l| nodeReferencesAwait(l.left) or nodeReferencesAwait(l.right),
        .conditional => |c| nodeReferencesAwait(c.cond) or nodeReferencesAwait(c.then) or nodeReferencesAwait(c.otherwise),
        .assign => |a| nodeReferencesAwait(a.value),
        .comma => |c| nodeReferencesAwait(c.left) or nodeReferencesAwait(c.right),
        .call => |c| nodeReferencesAwait(c.callee),
        else => false,
    };
}

/// §8.2.7 VarDeclaredNames (subset) — does the statement `stmt` (a for-of/for-in body) `var`-declare
/// a binding named `name`? Recurses through the nested Statement productions that share the function's
/// VarScope (blocks, if/else, loops, try/catch/finally, switch, with, labels) but DOES NOT descend
/// into nested function/class bodies (those open a new VarScope). Only the `using` for-head Early
/// Error consumes this, so it runs off the hot path. A `var`'s pattern can bind multiple names; we
/// check each. (let/const declarations are LexicallyDeclaredNames, not VarDeclaredNames — skipped.)
fn bodyVarDeclaresName(stmt: *const ast.Stmt, name: []const u8) bool {
    switch (stmt.*) {
        .declaration => |d| {
            if (d.kind != .var_decl) return false;
            for (d.decls) |dec| if (patternBindsName(dec.target, name)) return true;
            return false;
        },
        .block => |stmts| {
            for (stmts) |*s| if (bodyVarDeclaresName(s, name)) return true;
            return false;
        },
        .if_stmt => |s| {
            if (bodyVarDeclaresName(s.then, name)) return true;
            if (s.otherwise) |e| return bodyVarDeclaresName(e, name);
            return false;
        },
        .while_stmt => |s| return bodyVarDeclaresName(s.body, name),
        .do_while_stmt => |s| return bodyVarDeclaresName(s.body, name),
        .for_stmt => |s| {
            if (s.init) |i| if (bodyVarDeclaresName(i, name)) return true;
            return bodyVarDeclaresName(s.body, name);
        },
        .for_in_stmt => |s| {
            if (s.head == .decl and s.head.decl.kind == .var_decl and patternBindsName(s.head.decl.target, name)) return true;
            return bodyVarDeclaresName(s.body, name);
        },
        .for_of_stmt => |s| {
            if (s.head == .decl and s.head.decl.kind == .var_decl and patternBindsName(s.head.decl.target, name)) return true;
            return bodyVarDeclaresName(s.body, name);
        },
        .try_stmt => |s| {
            for (s.block) |*b| if (bodyVarDeclaresName(b, name)) return true;
            if (s.catch_block) |cb| for (cb) |*b| if (bodyVarDeclaresName(b, name)) return true;
            if (s.finally_block) |fb| for (fb) |*b| if (bodyVarDeclaresName(b, name)) return true;
            return false;
        },
        .switch_stmt => |s| {
            for (s.cases) |c| for (c.body) |*b| if (bodyVarDeclaresName(b, name)) return true;
            return false;
        },
        .with_stmt => |s| return bodyVarDeclaresName(s.body, name),
        .labeled_stmt => |s| return bodyVarDeclaresName(s.body, name),
        else => return false, // func_decl/class_decl open a new VarScope; expr/ret/break/… bind nothing
    }
}

/// Does the binding pattern `pat` bind an identifier named `name`? Walks nested array/object patterns
/// and rest elements (mirrors `patternHasStrictReserved`).
fn patternBindsName(pat: *const ast.Pattern, name: []const u8) bool {
    switch (pat.*) {
        .identifier => |n| return std.mem.eql(u8, n, name),
        .array => |ap| {
            for (ap.elements) |el| if (el.target) |t| if (patternBindsName(t, name)) return true;
            if (ap.rest) |r| return patternBindsName(r, name);
            return false;
        },
        .object => |op| {
            for (op.properties) |prop| if (patternBindsName(prop.target, name)) return true;
            if (op.rest) |r| return std.mem.eql(u8, r, name);
            return false;
        },
    }
}

/// §15.1.3 IsSimpleParameterList — true iff every parameter is a plain BindingIdentifier with no
/// default and there is no rest parameter (the precondition for allowing a "use strict" directive).
fn isSimpleParameterList(pl: Parser.ParamList) bool {
    if (pl.rest != null) return false;
    for (pl.params) |p| {
        if (p.default != null) return false;
        if (p.pattern.* != .identifier) return false;
    }
    return true;
}

/// §15.3.1 Early Error: an ArrowFunction's BoundNames must contain no duplicate entries.
/// Walks every parameter pattern (including nested array/object patterns and the rest element),
/// collecting bound identifiers; returns true on the first repeat. Bounded by the formal list
/// size, so it runs only on the arrow-creation path (never the hot call path).
/// §15.7.1 Early Error: a ClassBody's PrivateBoundIdentifiers must contain no duplicates — EXCEPT a
/// matching `get`/`set` accessor pair (same name, same static-ness) may co-exist. Returns true on a
/// disallowed duplicate. (The allocator is the parse arena; on exhaustion we conservatively report
/// no duplicate — privacy still holds at runtime.)
fn hasDuplicatePrivateNames(arena: std.mem.Allocator, elements: []const ast.ClassElement) std.mem.Allocator.Error!bool {
    // §15.7.1: a class has ONE PrivateEnvironment shared by static and instance members, so private
    // names must be unique across BOTH placements (a `static #m` and an instance `#m()` clash). The
    // only allowed repeat is a matching get/set accessor pair — same name AND same static placement.
    const Seen = struct { name: []const u8, is_static: bool, has_get: bool, has_set: bool, has_other: bool };
    var seen: std.ArrayListUnmanaged(Seen) = .empty;
    for (elements) |el| {
        if (!el.is_private) continue;
        const is_get = el.kind == .get;
        const is_set = el.kind == .set;
        var found = false;
        for (seen.items) |*s| {
            if (!std.mem.eql(u8, s.name, el.key)) continue;
            found = true;
            // The get+set complement (one get, one set, no plain member, SAME placement) is the only
            // legal repeat. A differing placement, or any other overlap, is a duplicate.
            const same_placement = s.is_static == el.is_static;
            if (is_get and same_placement and !s.has_get and !s.has_other) {
                s.has_get = true;
            } else if (is_set and same_placement and !s.has_set and !s.has_other) {
                s.has_set = true;
            } else {
                return true; // any other collision on the same private name
            }
            break;
        }
        if (!found) {
            try seen.append(arena, .{
                .name = el.key,
                .is_static = el.is_static,
                .has_get = is_get,
                .has_set = is_set,
                .has_other = !is_get and !is_set,
            });
        }
    }
    return false;
}

fn hasDuplicateBoundNames(pl: Parser.ParamList) bool {
    var names: std.ArrayList([]const u8) = .empty;
    var buf: [64][]const u8 = undefined; // formal lists are tiny; a small fixed buffer suffices
    var fba = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(buf[0..]));
    const a = fba.allocator();
    for (pl.params) |p| {
        if (collectBoundNames(p.pattern, &names, a)) return true;
    }
    if (pl.rest) |r| {
        if (collectBoundNames(r, &names, a)) return true;
    }
    return false;
}

/// §14.3.1 / §15.5.1 / §13.2.5.1 Early Error: a function/method's FormalParameters BoundNames must be
/// disjoint from its body's LexicallyDeclaredNames (`function f(a){ let a }` / `*m(a){ const a }` are
/// SyntaxErrors). Returns true on a conflict. Walks only the TOP-LEVEL statements of the body — a
/// nested block's `let` is its own lexical scope. Top-level `let`/`const`/`class` are lexical; a
/// top-level `function` declaration is VarDeclared (not Lexical) so it does NOT conflict here.
fn paramsConflictWithBodyLexical(pl: Parser.ParamList, body: []const ast.Stmt) bool {
    // Collect the parameter bound names into a small fixed buffer (formal lists are tiny).
    var names: std.ArrayList([]const u8) = .empty;
    var buf: [128][]const u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(buf[0..]));
    const a = fba.allocator();
    for (pl.params) |p| _ = collectBoundNames(p.pattern, &names, a);
    if (pl.rest) |r| _ = collectBoundNames(r, &names, a);
    if (names.items.len == 0) return false;
    for (body) |stmt| {
        switch (stmt) {
            .declaration => |d| {
                if (d.kind == .var_decl) continue; // var is not a LexicallyDeclaredName
                for (d.decls) |decl| {
                    if (patternBindsAny(decl.target, names.items)) return true;
                }
            },
            .class_decl => |c| {
                if (c.name) |nm| if (nameInList(nm, names.items)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn nameInList(name: []const u8, list: []const []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Does `pattern` bind any identifier present in `list`?
fn patternBindsAny(pattern: *const ast.Pattern, list: []const []const u8) bool {
    switch (pattern.*) {
        .identifier => |n| return nameInList(n, list),
        .array => |ap| {
            for (ap.elements) |el| if (el.target) |t| if (patternBindsAny(t, list)) return true;
            if (ap.rest) |r| return patternBindsAny(r, list);
            return false;
        },
        .object => |op| {
            for (op.properties) |prop| if (patternBindsAny(prop.target, list)) return true;
            if (op.rest) |r| return nameInList(r, list);
            return false;
        },
    }
}

/// Append `pattern`'s bound identifiers to `names`, returning true if any was already present.
/// On allocator exhaustion (a pathologically large pattern) it conservatively returns false —
/// the binding still succeeds at runtime; we just skip the duplicate diagnostic.
fn collectBoundNames(pattern: *const ast.Pattern, names: *std.ArrayList([]const u8), a: std.mem.Allocator) bool {
    switch (pattern.*) {
        .identifier => |n| {
            for (names.items) |existing| {
                if (std.mem.eql(u8, existing, n)) return true;
            }
            names.append(a, n) catch return false;
            return false;
        },
        .array => |ap| {
            for (ap.elements) |el| {
                if (el.target) |t| if (collectBoundNames(t, names, a)) return true;
            }
            if (ap.rest) |r| return collectBoundNames(r, names, a);
            return false;
        },
        .object => |op| {
            for (op.properties) |prop| {
                if (collectBoundNames(prop.target, names, a)) return true;
            }
            if (op.rest) |r| {
                for (names.items) |existing| {
                    if (std.mem.eql(u8, existing, r)) return true;
                }
                names.append(a, r) catch return false;
            }
            return false;
        },
    }
}

/// §15.7.1 Static Semantics: ContainsArguments — true iff the expression references the identifier
/// `arguments` outside any nested ordinary-function (which binds its own `arguments`). Per the spec,
/// recursion continues through ArrowFunction bodies (arrows have no own `arguments`) but stops at an
/// ordinary FunctionExpression. Used to reject `arguments` inside a class FieldDefinition Initializer.
fn containsArguments(node: *const ast.Node) bool {
    switch (node.*) {
        .identifier => |n| return std.mem.eql(u8, n, "arguments"),
        .number, .string, .boolean, .null, .this => return false,
        .unary => |u| return containsArguments(u.operand),
        .update => |u| return containsArguments(u.target),
        .comma => |c| return containsArguments(c.left) or containsArguments(c.right),
        .binary => |b| return containsArguments(b.left) or containsArguments(b.right),
        .logical => |l| return containsArguments(l.left) or containsArguments(l.right),
        .conditional => |c| return containsArguments(c.cond) or containsArguments(c.then) or containsArguments(c.otherwise),
        .assign => |a| return containsArguments(a.value),
        .assign_pattern => |a| return containsArguments(a.target) or containsArguments(a.value),
        .elision => return false,
        .assign_member => |a| return containsArguments(a.object) or containsArguments(a.value),
        .assign_index => |a| return containsArguments(a.object) or containsArguments(a.key) or containsArguments(a.value),
        .logical_assign => |a| return containsArguments(a.target) or containsArguments(a.value),
        .member => |m| return containsArguments(m.object),
        .index => |ix| return containsArguments(ix.object) or containsArguments(ix.key),
        .spread => |s| return containsArguments(s),
        .call => |c| {
            if (containsArguments(c.callee)) return true;
            for (c.args) |a| if (containsArguments(a)) return true;
            return false;
        },
        .new_expr => |n| {
            if (containsArguments(n.callee)) return true;
            for (n.args) |a| if (containsArguments(a)) return true;
            return false;
        },
        .array_literal => |elems| {
            for (elems) |e| if (containsArguments(e)) return true;
            return false;
        },
        .object_literal => |props| {
            for (props) |p| {
                if (p.computed_key) |ck| if (containsArguments(ck)) return true;
                if (containsArguments(p.value)) return true;
                if (p.default) |d| if (containsArguments(d)) return true;
            }
            return false;
        },
        .template => |t| {
            for (t.exprs) |e| if (containsArguments(e)) return true;
            return false;
        },
        .optional => |o| {
            if (containsArguments(o.base)) return true;
            switch (o.link) {
                .member => return false,
                .index => |k| return containsArguments(k),
                .call => |args| {
                    for (args) |a| if (containsArguments(a)) return true;
                    return false;
                },
            }
        },
        .super_call => |args| {
            for (args) |a| if (containsArguments(a)) return true;
            return false;
        },
        .super_member => |sm| return if (sm.key) |k| containsArguments(k) else false,
        .private_member => |pm| return containsArguments(pm.object),
        .private_assign => |pa| return containsArguments(pa.object) or containsArguments(pa.value),
        .private_in => |pi| return containsArguments(pi.object),
        // Recurse into ArrowFunction bodies (no own `arguments`); STOP at an ordinary function /
        // class (they bind/scope their own `arguments`).
        .function => |f| return f.is_arrow and bodyContainsArguments(f.body),
        .class_expr => return false,
        .yield_expr => |y| return if (y.argument) |a| containsArguments(a) else false,
        .await_expr => |operand| return containsArguments(operand),
    }
}

fn bodyContainsArguments(body: []const ast.Stmt) bool {
    for (body) |s| if (stmtContainsArguments(s)) return true;
    return false;
}

fn stmtContainsArguments(stmt: ast.Stmt) bool {
    switch (stmt) {
        .expr => |e| return containsArguments(e),
        .ret => |maybe| return if (maybe) |e| containsArguments(e) else false,
        .throw_stmt => |e| return containsArguments(e),
        .block => |stmts| return bodyContainsArguments(stmts),
        .declaration => |d| {
            for (d.decls) |dec| if (dec.init) |ie| if (containsArguments(ie)) return true;
            return false;
        },
        .if_stmt => |s| {
            if (containsArguments(s.cond)) return true;
            if (stmtContainsArguments(s.then.*)) return true;
            if (s.otherwise) |els| return stmtContainsArguments(els.*);
            return false;
        },
        .while_stmt => |s| return containsArguments(s.cond) or stmtContainsArguments(s.body.*),
        .do_while_stmt => |s| return containsArguments(s.cond) or stmtContainsArguments(s.body.*),
        .labeled_stmt => |s| return stmtContainsArguments(s.body.*),
        .for_stmt => |s| {
            if (s.init) |i| if (stmtContainsArguments(i.*)) return true;
            if (s.cond) |c| if (containsArguments(c)) return true;
            if (s.update) |u| if (containsArguments(u)) return true;
            return stmtContainsArguments(s.body.*);
        },
        .for_in_stmt => |s| {
            if (s.head == .target and containsArguments(s.head.target)) return true;
            if (containsArguments(s.right)) return true;
            return stmtContainsArguments(s.body.*);
        },
        .for_of_stmt => |s| {
            if (s.head == .target and containsArguments(s.head.target)) return true;
            if (containsArguments(s.right)) return true;
            return stmtContainsArguments(s.body.*);
        },
        .switch_stmt => |s| {
            if (containsArguments(s.discriminant)) return true;
            for (s.cases) |case| {
                if (case.test_expr) |te| if (containsArguments(te)) return true;
                if (bodyContainsArguments(case.body)) return true;
            }
            return false;
        },
        .with_stmt => |s| return containsArguments(s.object) or stmtContainsArguments(s.body.*),
        .try_stmt => |s| {
            if (bodyContainsArguments(s.block)) return true;
            if (s.catch_block) |cb| if (bodyContainsArguments(cb)) return true;
            if (s.finally_block) |fb| if (bodyContainsArguments(fb)) return true;
            return false;
        },
        .func_decl, .class_decl, .break_stmt, .continue_stmt => return false,
    }
}

/// Does the function body's directive prologue (§11.2.1) contain a "use strict" directive? The
/// prologue is the leading run of string-literal ExpressionStatements.
fn bodyHasUseStrict(body: []const ast.Stmt) bool {
    for (body) |s| {
        switch (s) {
            .expr => |e| switch (e.*) {
                .string => |str| if (std.mem.eql(u8, str, "use strict")) return true,
                else => return false, // first non-string-literal ends the directive prologue
            },
            else => return false,
        }
    }
    return false;
}

// ── §14.2.1 / §14.12.1 / §14.15.1 / §16.1.1 duplicate-declaration Early Errors ────────────────
// A post-parse static pass over each lexical scope. For every Block, Script/FunctionBody, switch
// CaseBlock, and catch, it checks (1) LexicallyDeclaredNames are unique and (2) they are disjoint
// from the scope's VarDeclaredNames. Parse-time only — no runtime/hot-path impact.

/// The kind of the scope whose StatementList we are validating, which selects how a top-level
/// FunctionDeclaration is classified: in a Block / switch CaseBlock it is a *LexicallyDeclaredName*
/// (so a duplicate is an Early Error, strict-only between two functions per Annex B B.3.3); in a
/// Script / FunctionBody it is a *VarDeclaredName* (so `function f(){} function f(){}` at top level
/// is legal, but it still conflicts with a top-level `let f`).
const ScopeKind = enum { script_or_body, block };

/// A bounded name set backed by a fixed buffer — lexical/var name lists per scope are small. On
/// overflow it stops recording (conservatively under-reporting a duplicate rather than misfiring);
/// real programs never approach the cap.
const NameSet = struct {
    buf: [256][]const u8,
    len: usize = 0,
    fn init() NameSet {
        // SAFETY: `len` starts at 0; `buf` slots are written by `add` before any read (`has`/`addPattern`
        // only ever scan `buf[0..len]`), so the `undefined` backing storage is never observed.
        return .{ .buf = undefined };
    }
    fn has(self: *const NameSet, name: []const u8) bool {
        for (self.buf[0..self.len]) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }
    /// Append `name`; returns true if it was already present (a duplicate).
    fn add(self: *NameSet, name: []const u8) bool {
        if (self.has(name)) return true;
        if (self.len < self.buf.len) {
            self.buf[self.len] = name;
            self.len += 1;
        }
        return false;
    }
    fn addPatternDup(self: *NameSet, pattern: *const ast.Pattern) bool {
        switch (pattern.*) {
            .identifier => |n| return self.add(n),
            .array => |ap| {
                for (ap.elements) |el| if (el.target) |t| if (self.addPatternDup(t)) return true;
                if (ap.rest) |r| return self.addPatternDup(r);
                return false;
            },
            .object => |op| {
                for (op.properties) |prop| if (self.addPatternDup(prop.target)) return true;
                if (op.rest) |r| return self.add(r);
                return false;
            },
        }
    }
    fn addPattern(self: *NameSet, pattern: *const ast.Pattern) void {
        _ = self.addPatternDup(pattern);
    }
};

fn declIsLexical(kind: ast.DeclKind) bool {
    return kind != .var_decl; // let / const / using / await using
}

/// Append the VarDeclaredNames reachable from `stmt` into `set`, bubbling up through nested
/// non-function statements (inner blocks, if/for/while/do/try/with/labeled bodies, switch cases)
/// but STOPPING at any function/class boundary (a nested function body has its own var scope).
/// Only `var` declarations contribute (a FunctionDeclaration is a *Declaration* → empty
/// VarDeclaredNames, §14.2.2). We collect a `for`-head `var` (it hoists out of the loop) but not a
/// `let`/`const` (a `for`'s lexical head is its own per-iteration scope).
fn collectVarNames(stmt: ast.Stmt, set: *NameSet) void {
    switch (stmt) {
        .declaration => |d| {
            if (d.kind == .var_decl) for (d.decls) |dec| set.addPattern(dec.target);
        },
        // §14.2.2 VarDeclaredNames: `StatementListItem : Declaration` → empty. A FunctionDeclaration
        // is a *Declaration*, so it is NOT a VarDeclaredName of a Block (it is a LexicallyDeclaredName
        // there, §14.2.9). It becomes a VarDeclaredName only at a Script/FunctionBody top level
        // (TopLevelVarDeclaredNames) — added separately in `collectScopeVarNames`. So bubbling a
        // FunctionDeclaration contributes nothing to VarDeclaredNames.
        .func_decl => {},
        .block => |stmts| for (stmts) |s| collectVarNames(s, set),
        .if_stmt => |s| {
            collectVarNames(s.then.*, set);
            if (s.otherwise) |e| collectVarNames(e.*, set);
        },
        .while_stmt => |s| collectVarNames(s.body.*, set),
        .do_while_stmt => |s| collectVarNames(s.body.*, set),
        .for_stmt => |s| {
            if (s.init) |i| if (i.* == .declaration and i.declaration.kind == .var_decl)
                for (i.declaration.decls) |dec| set.addPattern(dec.target);
            collectVarNames(s.body.*, set);
        },
        .for_in_stmt => |s| {
            if (s.head == .decl and s.head.decl.kind == .var_decl) set.addPattern(s.head.decl.target);
            collectVarNames(s.body.*, set);
        },
        .for_of_stmt => |s| {
            if (s.head == .decl and s.head.decl.kind == .var_decl) set.addPattern(s.head.decl.target);
            collectVarNames(s.body.*, set);
        },
        .try_stmt => |s| {
            for (s.block) |b| collectVarNames(b, set);
            if (s.catch_block) |cb| for (cb) |b| collectVarNames(b, set);
            if (s.finally_block) |fb| for (fb) |b| collectVarNames(b, set);
        },
        .with_stmt => |s| collectVarNames(s.body.*, set),
        .switch_stmt => |s| for (s.cases) |cs| for (cs.body) |b| collectVarNames(b, set),
        .labeled_stmt => |s| collectVarNames(s.body.*, set),
        else => {},
    }
}

/// Collect, into `lex_set`, the top-level LexicallyDeclaredNames of `stmts` for a scope of `kind`,
/// returning true on a duplicate (rule 1). In a Block / switch CaseBlock, a FunctionDeclaration is a
/// LexicallyDeclaredName. Annex B B.3.3.6 relaxes the duplicate-entries Early Error ONLY for
/// *plain* (non-async, non-generator) FunctionDeclarations in SLOPPY mode: two such functions in one
/// block do not collide with each other. The relaxation does NOT extend to a function colliding with
/// a `let`/`const`/`class`/generator/async-function of the same name, nor to the §14.2.1
/// LexicallyDeclaredNames∩VarDeclaredNames rule (`{ var f; function f(){} }` is still an error) — so
/// the de-duplicated plain-function names are folded into `lex_set` (for those checks) only once. In
/// a Script/FunctionBody, top-level FunctionDeclarations are var-declared, not collected here.
fn collectScopeLexicalNames(stmts: []const ast.Stmt, kind: ScopeKind, strict: bool, lex_set: *NameSet) bool {
    // Plain sloppy block functions: collected once (deduped) so two of them don't collide, but still
    // folded into `lex_set` below so they participate in every other conflict.
    var sloppy_fns: NameSet = .init();
    for (stmts) |stmt| {
        switch (stmt) {
            .declaration => |d| {
                if (declIsLexical(d.kind)) {
                    for (d.decls) |dec| if (lex_set.addPatternDup(dec.target)) return true;
                }
            },
            .class_decl => |c| {
                if (c.name) |nm| if (lex_set.add(nm)) return true;
            },
            .func_decl => |f| {
                if (kind != .block) continue; // Script/FunctionBody: functions are var-declared
                const nm = f.name orelse continue;
                // Annex B applies only to a plain function in sloppy mode; async/generator/strict
                // function declarations are ordinary LexicallyDeclaredNames (a duplicate is an error).
                const annexb = !strict and !f.is_async and !f.is_generator;
                if (annexb) {
                    _ = sloppy_fns.add(nm); // dedupe; folded into lex_set after the loop
                } else {
                    if (lex_set.add(nm)) return true;
                }
            },
            else => {},
        }
    }
    // Fold the deduped plain-function names into the lexical set: a clash with an already-collected
    // lexical name (let/const/class/generator/async/strict-fn) is the §14.2.1 duplicate Early Error;
    // otherwise they join `lex_set` so the ∩-VarDeclaredNames check still sees them.
    for (sloppy_fns.buf[0..sloppy_fns.len]) |nm| if (lex_set.add(nm)) return true;
    return false;
}

/// Validate one scope's StatementList (rules 1 + 2). `catch_param`, when set, is the simple-identifier
/// CatchParameter binding the Block is the body of: §14.15.1 makes it a Syntax Error if the parameter
/// also occurs in the Block's LexicallyDeclaredNames (`catch(e){ let e }` / `catch(e){ function e(){} }`).
/// It does NOT participate in the §14.2.1 LexicallyDeclaredNames∩VarDeclaredNames check — Annex B B.3.4
/// permits a simple-identifier catch param to be re-declared as a `var` in the Block (`catch(e){var e}`).
fn checkScopeNames(stmts: []const ast.Stmt, kind: ScopeKind, strict: bool, catch_param: ?[]const u8) ParseError!void {
    var lex_set: NameSet = .init();
    if (collectScopeLexicalNames(stmts, kind, strict, &lex_set)) return ParseError.UnexpectedToken;
    // §14.15.1: the CatchParameter may not also be a LexicallyDeclaredName of the Catch Block.
    if (catch_param) |cp| if (lex_set.has(cp)) return ParseError.UnexpectedToken;
    if (lex_set.len == 0) return;
    // §14.2.1 rule 2: LexicallyDeclaredNames ∩ VarDeclaredNames = ∅.
    var var_set: NameSet = .init();
    collectScopeVarNames(stmts, kind, &var_set);
    for (lex_set.buf[0..lex_set.len]) |nm| if (var_set.has(nm)) return ParseError.UnexpectedToken;
}

/// VarDeclaredNames of a whole scope: every statement's bubbled-up `var` names (functions never
/// bubble — see `collectVarNames`). At a Script/FunctionBody (`kind == .script_or_body`), a
/// TOP-LEVEL FunctionDeclaration is additionally a VarDeclaredName (TopLevelVarDeclaredNames,
/// §16.1.2 / §15.2.2), so `let f; function f(){}` at script/body level is an Early Error while
/// `function f(){} function f(){}` (var∩var) is legal. In a Block, top-level functions are lexical
/// (handled by `collectScopeLexicalNames`) and contribute nothing here.
fn collectScopeVarNames(stmts: []const ast.Stmt, kind: ScopeKind, set: *NameSet) void {
    if (kind == .script_or_body) {
        for (stmts) |stmt| switch (stmt) {
            .func_decl => |f| {
                if (f.name) |nm| _ = set.add(nm);
            },
            else => {},
        };
    }
    for (stmts) |stmt| collectVarNames(stmt, set);
}

/// Recursively validate `stmts` as a scope of `kind`, then descend into every nested scope
/// (blocks, function/method/arrow bodies, switch CaseBlocks, catch). `strict` is the strictness in
/// effect for `stmts`; it tightens going into a function body carrying its own `"use strict"`.
fn validateScope(stmts: []const ast.Stmt, kind: ScopeKind, strict: bool) ParseError!void {
    try checkScopeNames(stmts, kind, strict, @as(?[]const u8, null));
    for (stmts) |stmt| try descendStmt(stmt, strict);
}

fn validateFunction(f: *const ast.Function, strict: bool) ParseError!void {
    const inner = strict or bodyHasUseStrict(f.body);
    // Parameter default initializers may carry nested function/class expressions (`(a = ()=>{}) =>`).
    for (f.params) |p| if (p.default) |d| try descendNode(d, inner);
    try validateScope(f.body, .script_or_body, inner);
}

fn validateClass(c: *const ast.Class, strict: bool) ParseError!void {
    _ = strict;
    // Class bodies are always strict; each method/getter/setter/field-initializer/static-block is
    // its own FunctionBody-like scope. A ClassHeritage `extends LHS` is an outer expression.
    if (c.superclass) |sc| try descendNode(sc, true);
    for (c.elements) |el| {
        if (el.computed_key) |ck| try descendNode(ck, true);
        switch (el.value) {
            .func => |fn_| try validateFunction(fn_, true),
            .field_init => |maybe| if (maybe) |e| try descendNode(e, true),
            .block => |blk| try validateScope(blk, .script_or_body, true),
        }
    }
}

/// Descend into the nested scopes of a single statement (and any function/class expressions inside
/// its expressions), validating each. Does NOT re-check `stmt`'s own enclosing scope.
fn descendStmt(stmt: ast.Stmt, strict: bool) ParseError!void {
    switch (stmt) {
        .block => |stmts| try validateScope(stmts, .block, strict),
        .func_decl => |f| try validateFunction(f, strict),
        .class_decl => |c| try validateClass(c, strict),
        .declaration => |d| for (d.decls) |dec| if (dec.init) |ie| try descendNode(ie, strict),
        .expr => |e| try descendNode(e, strict),
        .ret => |maybe| if (maybe) |e| try descendNode(e, strict),
        .throw_stmt => |e| try descendNode(e, strict),
        .if_stmt => |s| {
            try descendNode(s.cond, strict);
            try descendStmt(s.then.*, strict);
            if (s.otherwise) |e| try descendStmt(e.*, strict);
        },
        .while_stmt => |s| {
            try descendNode(s.cond, strict);
            try descendStmt(s.body.*, strict);
        },
        .do_while_stmt => |s| {
            try descendNode(s.cond, strict);
            try descendStmt(s.body.*, strict);
        },
        .for_stmt => |s| {
            if (s.init) |i| try descendStmt(i.*, strict);
            if (s.cond) |c| try descendNode(c, strict);
            if (s.update) |u| try descendNode(u, strict);
            try descendStmt(s.body.*, strict);
        },
        .for_in_stmt => |s| {
            try descendNode(s.right, strict);
            try descendStmt(s.body.*, strict);
        },
        .for_of_stmt => |s| {
            try descendNode(s.right, strict);
            try descendStmt(s.body.*, strict);
        },
        .try_stmt => |s| {
            try validateScope(s.block, .block, strict);
            if (s.catch_block) |cb| {
                // §14.15.1: the Catch Block is validated as a Block, with the (simple-identifier)
                // CatchParameter additionally barred from the Block's LexicallyDeclaredNames. A
                // pattern catch param's own dup BoundNames are rejected at parse time (§14.15.1).
                try checkScopeNames(cb, .block, strict, s.catch_param);
                for (cb) |b| try descendStmt(b, strict);
            }
            if (s.finally_block) |fb| try validateScope(fb, .block, strict);
        },
        .with_stmt => |s| {
            try descendNode(s.object, strict);
            try descendStmt(s.body.*, strict);
        },
        .switch_stmt => |s| {
            try descendNode(s.discriminant, strict);
            // §14.12.1: the CaseBlock is ONE lexical scope merging all clause StatementLists.
            var merged: std.ArrayList(ast.Stmt) = .empty;
            var fba_buf: [64 * @sizeOf(ast.Stmt)]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
            const a = fba.allocator();
            var overflow = false;
            for (s.cases) |cs| for (cs.body) |b| {
                merged.append(a, b) catch {
                    overflow = true;
                };
            };
            if (!overflow) try checkScopeNames(merged.items, .block, strict, @as(?[]const u8, null));
            // Descend into each clause's nested scopes regardless.
            for (s.cases) |cs| {
                if (cs.test_expr) |t| try descendNode(t, strict);
                for (cs.body) |b| try descendStmt(b, strict);
            }
        },
        .labeled_stmt => |s| try descendStmt(s.body.*, strict),
        else => {},
    }
}

/// Descend into function/class *expressions* nested in an expression node, validating their bodies.
/// Most expression shapes can carry a function/arrow/class literal; we recurse structurally.
fn descendNode(node: *const ast.Node, strict: bool) ParseError!void {
    switch (node.*) {
        .function => |f| try validateFunction(f, strict),
        .class_expr => |c| try validateClass(c, strict),
        .unary => |u| try descendNode(u.operand, strict),
        .await_expr => |e| try descendNode(e, strict),
        .spread => |e| try descendNode(e, strict),
        .comma => |b| {
            try descendNode(b.left, strict);
            try descendNode(b.right, strict);
        },
        .binary => |b| {
            try descendNode(b.left, strict);
            try descendNode(b.right, strict);
        },
        .logical => |b| {
            try descendNode(b.left, strict);
            try descendNode(b.right, strict);
        },
        .assign => |a| try descendNode(a.value, strict),
        .assign_pattern => |a| {
            try descendNode(a.target, strict);
            try descendNode(a.value, strict);
        },
        .assign_member => |a| {
            try descendNode(a.object, strict);
            try descendNode(a.value, strict);
        },
        .assign_index => |a| {
            try descendNode(a.object, strict);
            try descendNode(a.key, strict);
            try descendNode(a.value, strict);
        },
        .logical_assign => |a| {
            try descendNode(a.target, strict);
            try descendNode(a.value, strict);
        },
        .conditional => |c| {
            try descendNode(c.cond, strict);
            try descendNode(c.then, strict);
            try descendNode(c.otherwise, strict);
        },
        .update => |u| try descendNode(u.target, strict),
        .member => |m| try descendNode(m.object, strict),
        .index => |ix| {
            try descendNode(ix.object, strict);
            try descendNode(ix.key, strict);
        },
        .call => |c| {
            try descendNode(c.callee, strict);
            for (c.args) |arg| try descendNode(arg, strict);
        },
        .new_expr => |c| {
            try descendNode(c.callee, strict);
            for (c.args) |arg| try descendNode(arg, strict);
        },
        .array_literal => |els| for (els) |e| try descendNode(e, strict),
        .object_literal => |props| for (props) |p| {
            if (p.computed_key) |ck| try descendNode(ck, strict);
            if (p.default) |df| try descendNode(df, strict);
            try descendNode(p.value, strict);
        },
        .template => |t| for (t.exprs) |e| try descendNode(e, strict),
        .yield_expr => |y| if (y.argument) |e| try descendNode(e, strict),
        .optional => |o| {
            try descendNode(o.base, strict);
            switch (o.link) {
                .member => {},
                .index => |k| try descendNode(k, strict),
                .call => |args| for (args) |arg| try descendNode(arg, strict),
            }
        },
        .super_call => |args| for (args) |arg| try descendNode(arg, strict),
        .super_member => |sm| if (sm.key) |k| try descendNode(k, strict),
        .private_member => |pm| try descendNode(pm.object, strict),
        .private_assign => |pa| {
            try descendNode(pa.object, strict);
            try descendNode(pa.value, strict);
        },
        .private_in => |pi| try descendNode(pi.object, strict),
        else => {},
    }
}

/// §11.2.1 Directive Prologue → §11.2.2 strict: scan a leading token run (a Script or FunctionBody)
/// for a `"use strict"` (or `'use strict'`) directive. A Directive Prologue is the longest leading
/// sequence of string-literal ExpressionStatements; a directive counts only when its *source text*
/// is exactly `"use strict"` with no escape sequences or line continuations — so we compare the raw
/// lexeme (quotes included), NOT the cooked value (`"use strict"` does NOT trigger strict).
/// `toks` starts at the first token of the body (after the opening `{` for functions). Token-level
/// (not AST-level) so it can run before statement parsing and fire the §13.x Early Errors below.
fn directivePrologueIsStrict(toks: []const lex.Token) bool {
    var i: usize = 0;
    while (i < toks.len and toks[i].kind == .string) {
        // A string is a standalone ExpressionStatement (a Directive) only when the next token
        // terminates the statement: `;`, `}`, EOF, or a line terminator (ASI). If instead the next
        // token continues the expression on the same line (`"x" + 1`, `"x".length`, `"x", y`), the
        // string was an operand of a larger expression — the Directive Prologue has ended.
        const next = if (i + 1 < toks.len) toks[i + 1] else lex.Token{ .kind = .eof, .lexeme = "" };
        const terminated = switch (next.kind) {
            .semicolon, .rbrace, .eof => true,
            else => next.newline_before,
        };
        if (!terminated) return false;
        // §11.2.2: a directive whose *source text* is exactly `"use strict"` (no escapes / line
        // continuations) makes the unit strict — compare the raw lexeme, not the cooked value.
        if (std.mem.eql(u8, toks[i].lexeme, "\"use strict\"") or
            std.mem.eql(u8, toks[i].lexeme, "'use strict'")) return true;
        // Continue the prologue past this directive and an optional explicit `;`.
        i += 1;
        if (i < toks.len and toks[i].kind == .semicolon) i += 1;
    }
    return false;
}

/// Does `kind` begin a PropertyName? Used to distinguish a `get`/`set` accessor (`get x(){}`)
/// from an ordinary use of the identifiers `get`/`set` as a key (`{get: 1}`, `{get}`, `{get(){}}`).
fn startsAccessorName(kind: lex.TokenKind) bool {
    return switch (kind) {
        .identifier, .string, .number, .lbracket, .private_identifier => true,
        else => isKeywordName(kind), // `get if(){}` etc.
    };
}

/// Is `kind` a reserved word usable as a (non-computed) property name? Per §13.2.5 any
/// ReservedWord is a valid IdentifierName key.
fn isKeywordName(kind: lex.TokenKind) bool {
    return switch (kind) {
        .kw_true, .kw_false, .kw_null, .kw_var, .kw_let, .kw_const, .kw_function, .kw_return, .kw_this, .kw_if, .kw_else, .kw_while, .kw_do, .kw_for, .kw_throw, .kw_try, .kw_catch, .kw_finally, .kw_break, .kw_continue, .kw_typeof, .kw_void, .kw_delete, .kw_new, .kw_instanceof, .kw_switch, .kw_case, .kw_default, .kw_import, .kw_class, .kw_extends, .kw_super, .kw_in, .kw_with => true,
        else => false,
    };
}

/// §12.9.3 NumericLiteralSeparator placement: each `_` must sit immediately between two digits of
/// the literal's radix (so no leading/trailing/doubled `_`, none adjacent to `.`/`e`/sign/prefix).
/// Separators are forbidden entirely in a LegacyOctal / NonOctalDecimal literal (`0` followed by a
/// digit, e.g. `0_7`, `08`). Returns false on any violation.
fn validNumericSeparators(s: []const u8) bool {
    if (std.mem.indexOfScalar(u8, s, '_') == null) return true; // no separators → nothing to check
    // Radix + the digit region. A `0` followed by a digit is LegacyOctal/NonOctalDecimal: no separators.
    const hex = s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X');
    const oct = s.len >= 2 and s[0] == '0' and (s[1] == 'o' or s[1] == 'O');
    const bin = s.len >= 2 and s[0] == '0' and (s[1] == 'b' or s[1] == 'B');
    if (s.len >= 2 and s[0] == '0' and !hex and !oct and !bin and ((s[1] >= '0' and s[1] <= '9') or s[1] == '_')) return false;
    const isRadixDigit = struct {
        fn f(c: u8, h: bool) bool {
            return if (h) (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F') else (c >= '0' and c <= '9');
        }
    }.f;
    for (s, 0..) |ch, i| {
        if (ch != '_') continue;
        if (i == 0 or i + 1 >= s.len) return false; // leading / trailing
        if (!isRadixDigit(s[i - 1], hex) or !isRadixDigit(s[i + 1], hex)) return false; // not between two digits
    }
    return true;
}

/// ToString of a numeric PropertyName (§13.2.5 — `{1: x}` has key "1", `{0.5: x}` key "0.5").
fn numericKey(arena: std.mem.Allocator, n: f64) ParseError![]const u8 {
    if (n == @floor(n) and @abs(n) < 1e21) {
        return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))});
    }
    return std.fmt.allocPrint(arena, "{d}", .{n});
}

fn binaryOpFor(kind: lex.TokenKind) ?ast.BinaryOp {
    return switch (kind) {
        .plus => .add,
        .minus => .sub,
        .star => .mul,
        .slash => .div,
        .percent => .mod,
        .star_star => .exp,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        .shl => .shl,
        .shr => .shr,
        .shr_un => .shr_un,
        .lt => .lt,
        .gt => .gt,
        .le => .le,
        .ge => .ge,
        .kw_instanceof => .instanceof_,
        .kw_in => .in_op,
        .eq => .eq,
        .ne => .ne,
        .seq => .seq,
        .sne => .sne,
        else => null,
    };
}

/// The binary operator a compound-assignment token (`+=`, …) desugars to, else null (§13.15).
fn compoundBinOp(kind: lex.TokenKind) ?ast.BinaryOp {
    return switch (kind) {
        .plus_assign => .add,
        .minus_assign => .sub,
        .star_assign => .mul,
        .slash_assign => .div,
        .percent_assign => .mod,
        .star_star_assign => .exp,
        .shl_assign => .shl,
        .shr_assign => .shr,
        .shr_un_assign => .shr_un,
        .amp_assign => .bit_and,
        .pipe_assign => .bit_or,
        .caret_assign => .bit_xor,
        else => null,
    };
}

/// The logical operator a logical-assignment token (`&&=`/`||=`/`??=`) short-circuits on, else null
/// (§13.15.2). Unlike `compoundBinOp` these are NOT a plain `x = x op v` desugar.
fn logicalAssignOp(kind: lex.TokenKind) ?ast.LogicalOp {
    return switch (kind) {
        .amp_amp_assign => .and_,
        .pipe_pipe_assign => .or_,
        .question_question_assign => .coalesce,
        else => null,
    };
}

/// Precedence over token kinds (covers logical, equality, relational, additive,
/// multiplicative). Assignment is handled separately in `parseAssignment`.
fn opPrecedence(kind: lex.TokenKind) ?u8 {
    return switch (kind) {
        .pipe_pipe => 1,
        .amp_amp => 2,
        .bit_or => 3,
        .bit_xor => 4,
        .bit_and => 5,
        .eq, .ne, .seq, .sne => 6,
        .lt, .gt, .le, .ge, .kw_instanceof, .kw_in => 7,
        .shl, .shr, .shr_un => 8,
        .plus, .minus => 9,
        .star, .slash, .percent => 10,
        .star_star => 11, // right-assoc (handled in parseExpr)
        else => null,
    };
}
