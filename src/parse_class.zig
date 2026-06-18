//! Extracted from parser.zig (behavior-preserving split): function / class parsing (§14.1, §15) —
//! parseFunction, parseClass + its elements / accessors / static blocks / private-name collection,
//! parseParams, parsePrivateName. Free functions taking `self: *Parser`; thin wrappers stay in
//! parser.zig.
const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const Parser = parser.Parser;
const ParseError = parser.ParseError;
const ParamList = Parser.ParamList;
const PropName = Parser.PropName;
const parse_validate = @import("parse_validate.zig");

const directivePrologueIsStrict = parse_validate.directivePrologueIsStrict;
const paramsHaveStrictReserved = parse_validate.paramsHaveStrictReserved;
const paramsHaveYield = parse_validate.paramsHaveYield;
const paramsHaveAwait = parse_validate.paramsHaveAwait;
const isSimpleParameterList = parse_validate.isSimpleParameterList;
const bodyHasUseStrict = parse_validate.bodyHasUseStrict;
const isEscapedReservedIdent = parse_validate.isEscapedReservedIdent;
const isStrictReservedBindingName = parse_validate.isStrictReservedBindingName;
const startsAccessorName = parse_validate.startsAccessorName;
const hasDuplicatePrivateNames = parse_validate.hasDuplicatePrivateNames;
const hasDuplicateBoundNames = parse_validate.hasDuplicateBoundNames;
const paramsConflictWithBodyLexical = parse_validate.paramsConflictWithBodyLexical;
const containsArguments = parse_validate.containsArguments;

/// §15.2 / §15.5 / §15.8: `[async] function [*] [name] (params) { body }` — shared by declarations
/// and expressions. The current token is the one AFTER `function` (the caller consumed any `async`
/// and the `function` keyword); a leading `*` (§15.5 Generator / §15.6 AsyncGenerator) is consumed
/// here and flips the generator context for the body. `is_async` (§15.8) flips the await context.
pub fn parseFunction(self: *Parser, is_async: bool) ParseError!*const ast.Function {
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
    const saved_in_function = self.in_function;
    defer self.in_method = saved_in_method;
    defer self.in_derived_ctor = saved_in_derived;
    defer self.in_static_block = saved_in_static;
    defer self.in_generator = saved_in_generator;
    defer self.in_async = saved_in_async;
    defer self.in_function = saved_in_function;
    self.in_method = false;
    self.in_derived_ctor = false;
    self.in_static_block = false; // §15.7.11: a nested ordinary function un-reserves `await`
    self.in_function = true; // §13.3.12: a function body is a NewTarget context (`new.target` legal)
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
pub fn parseClass(self: *Parser, is_declaration: bool, allow_anonymous: bool) ParseError!*const ast.Class {
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
    } else if (is_declaration and !allow_anonymous) {
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
pub fn collectClassPrivateNames(self: *Parser) ParseError!void {
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
pub fn privateNameDeclared(self: *Parser, name: []const u8) bool {
    for (self.private_names.items) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// §15.7 ClassElement — a method `m(){…}`, a `constructor(){…}`, a `static` method, a field
/// `x = init;` / `x;` (instance or static), a §15.7.11 `static { … }` initialization block, or a
/// PrivateName member `#x` / `#m(){}` / `get #x(){}` (Cycle 4). Still parse-rejected (preserve the
/// negatives): generators (`* m`) and `async` methods (a separate future milestone).
pub fn parseClassElement(self: *Parser, is_derived: bool) ParseError!ast.ClassElement {
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
        const saved_in_function = self.in_function;
        self.in_method = true;
        self.in_derived_ctor = false;
        self.in_function = true; // §13.3.12: `new.target` in a field initializer yields `undefined`
        field_init = try self.parseAssignment();
        self.in_method = saved_in_method;
        self.in_derived_ctor = saved_in_derived;
        self.in_function = saved_in_function;
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
pub fn parseStaticBlock(self: *Parser) ParseError!ast.ClassElement {
    const saved_in_method = self.in_method;
    const saved_in_derived = self.in_derived_ctor;
    const saved_in_static = self.in_static_block;
    const saved_in_async = self.in_async;
    const saved_in_generator = self.in_generator;
    const saved_in_function = self.in_function;
    defer self.in_method = saved_in_method;
    defer self.in_derived_ctor = saved_in_derived;
    defer self.in_static_block = saved_in_static;
    defer self.in_async = saved_in_async;
    defer self.in_generator = saved_in_generator;
    defer self.in_function = saved_in_function;
    self.in_method = true;
    self.in_derived_ctor = false;
    self.in_function = true; // §13.3.12: `new.target` is legal in a static block (yields `undefined`)
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
pub fn parseClassAccessor(self: *Parser, is_static: bool, is_get: bool) ParseError!ast.ClassElement {
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
pub fn parsePrivateName(self: *Parser) ParseError!PropName {
    const t = self.advance();
    std.debug.assert(t.kind == .private_identifier);
    if (std.mem.eql(u8, t.lexeme, "#constructor")) return ParseError.UnexpectedToken;
    return .{ .key = t.lexeme };
}

/// §15.1 FormalParameters — each parameter is a binding pattern with an optional `= default`;
/// an optional trailing `...rest` (itself a pattern) collects the leftover arguments.
pub fn parseParams(self: *Parser) ParseError!ParamList {
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
