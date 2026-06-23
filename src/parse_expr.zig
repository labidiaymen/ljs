//! Extracted from parser.zig (behavior-preserving split): expression parsing — assignment /
//! conditional / short-circuit / binary precedence climbing / unary / postfix / call chains /
//! primary atoms / object literals / templates / numeric+bigint literals (§13). Free functions
//! taking `self: *Parser`; thin (inline, for the hot recursive descent) wrappers stay in parser.zig.
const std = @import("std");
const ast = @import("ast.zig");
const lex = @import("lexer.zig");
const bigint = @import("bigint.zig");
const regex_engine = @import("builtin_regexp_engine.zig");
const parser = @import("parser.zig");
const Parser = parser.Parser;
const ParseError = parser.ParseError;
const ParamList = Parser.ParamList;
const PropName = Parser.PropName;
const parse_validate = @import("parse_validate.zig");

// Validation/static-semantics helpers used by expression bodies (defined in parse_validate.zig).
const directivePrologueIsStrict = parse_validate.directivePrologueIsStrict;
const paramsHaveStrictReserved = parse_validate.paramsHaveStrictReserved;
const paramsHaveAwait = parse_validate.paramsHaveAwait;
const paramsHaveYield = parse_validate.paramsHaveYield;
const isSimpleParameterList = parse_validate.isSimpleParameterList;
const bodyHasUseStrict = parse_validate.bodyHasUseStrict;
const isEvalOrArguments = parse_validate.isEvalOrArguments;
const isEscapedReservedIdent = parse_validate.isEscapedReservedIdent;
const isStrictReservedBindingName = parse_validate.isStrictReservedBindingName;
const startsYieldArgument = parse_validate.startsYieldArgument;
const startsAccessorName = parse_validate.startsAccessorName;
const isKeywordName = parse_validate.isKeywordName;
const hasDuplicateBoundNames = parse_validate.hasDuplicateBoundNames;
const paramsConflictWithBodyLexical = parse_validate.paramsConflictWithBodyLexical;

pub fn parseExpression(self: *Parser) ParseError!*const ast.Node {
    var left = try self.parseAssignment();
    while (self.peek().kind == .comma) {
        _ = self.advance();
        const right = try self.parseAssignment();
        left = try self.alloc(.{ .comma = .{ .left = left, .right = right } });
    }
    return left;
}

/// §13.15 Assignment (right-associative). Only identifier targets in M1 Cycle A.
pub fn parseAssignment(self: *Parser) ParseError!*const ast.Node {
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
    // §15.8 the `.function_expr` case (`async [no LT] function …`) is a PrimaryExpression, not an
    // assignment-level production — it is recognized in `parsePrimary` so trailing Member/Call
    // suffixes (`(async function*(){}())`) and the binary/conditional climb attach to it. Only the
    // two ARROW cover-grammars are handled here (arrows are assignment-level productions).
    if (self.atAsyncArrowOrFunction()) |kind| if (kind != .function_expr) {
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
            .function_expr => unreachable, // handled in parsePrimary (see comment above)
        }
    };
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
            .member, .index, .private_member, .super_member => {},
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
        // §13.15.1: the target of a (compound or plain) assignment must be a simple
        // LeftHandSideExpression — identifier / member / index / private member.
        switch (left.*) {
            .identifier, .member, .index, .private_member, .super_member => {},
            else => if (compoundBinOp(op) != null) return ParseError.UnexpectedToken,
        }
        _ = self.advance();
        const rhs = try self.parseAssignment();
        // §13.15.2 compound assignment `target op= v` is kept INTACT as `compound_assign` (the
        // reference is evaluated once at runtime — see ast.compound_assign), NOT desugared to
        // `target = target op v` (which would re-evaluate a side-effecting base/key).
        if (compoundBinOp(op)) |bop| {
            return self.alloc(.{ .compound_assign = .{ .op = bop, .target = left, .value = rhs } });
        }
        switch (left.*) {
            .identifier => |n| return self.alloc(.{ .assign = .{ .name = n, .value = rhs } }),
            .member => |m| return self.alloc(.{ .assign_member = .{ .object = m.object, .name = m.name, .value = rhs } }),
            .index => |ix| return self.alloc(.{ .assign_index = .{ .object = ix.object, .key = ix.key, .value = rhs } }),
            .private_member => |pm| return self.alloc(.{ .private_assign = .{ .object = pm.object, .name = pm.name, .value = rhs } }),
            .super_member => |sm| return self.alloc(.{ .super_assign = .{ .name = sm.name, .key = sm.key, .value = rhs } }),
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
pub fn parseYield(self: *Parser) ParseError!*const ast.Node {
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
pub fn validateAssignmentPattern(self: *Parser, node: *const ast.Node) ParseError!void {
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
pub fn validateAssignmentTarget(self: *Parser, node: *const ast.Node) ParseError!void {
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
        // §13.15.5.5 a nested pattern carrying a default `[ {} = d ]` / `[ [a] = d ]`: the inner
        // `{} = d` was refined to an `assign_pattern` by the cover grammar (a nested literal target
        // followed by `=`). The TARGET side is the pattern to refine; the DEFAULT is any expression.
        .assign_pattern => |ap| try self.validateAssignmentPattern(ap.target),
        else => return ParseError.UnexpectedToken, // §13.15.1 invalid assignment target
    }
}

/// §13.14 Conditional `cond ? then : otherwise` (above assignment, right-associative branches).
pub fn parseConditional(self: *Parser) ParseError!*const ast.Node {
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
pub fn parseShortCircuit(self: *Parser) ParseError!*const ast.Node {
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
pub fn parseExpr(self: *Parser, min_prec: u8) ParseError!*const ast.Node {
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
pub fn parseExprFrom(self: *Parser, left_init: *const ast.Node, min_prec: u8) ParseError!*const ast.Node {
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

pub fn parseUnary(self: *Parser) ParseError!*const ast.Node {
    self.last_was_paren = false; // reset; set by a parenthesized primary (§13.13.1 mix check)
    // §15.8 AwaitExpression : `await` UnaryExpression — inside an async context `await` is the
    // operator (at UnaryExpression precedence, so `await a.b()` awaits the call result and `await
    // -x` awaits `-x`). Outside async, `await` is an ordinary identifier (handled in parsePrimary).
    if (self.in_async and self.peek().kind == .identifier and !self.peek().had_escape and std.mem.eql(u8, self.peek().lexeme, "await")) {
        _ = self.advance(); // await
        // §16.2.1.6 [[HasTLA]]: an `await` at module top level (module goal, not inside a nested
        // function) makes the module evaluate asynchronously.
        if (self.is_module and !self.in_function) self.saw_top_level_await = true;
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
        // §13.3.12.1 / §13.4.1.1: NewTarget has AssignmentTargetType `invalid` — `++new.target`
        // (and the covered `++(new.target)`, parens already collapsed) is a SyntaxError.
        if (target.* == .new_target) return ParseError.UnexpectedToken;
        // §13.3.10 / §13.4.1.1: ImportCall has AssignmentTargetType `invalid` — `++import('')`
        // (and `--import('')`) is a SyntaxError.
        if (target.* == .import_call) return ParseError.UnexpectedToken;
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
pub fn parsePostfix(self: *Parser) ParseError!*const ast.Node {
    // §13.3 SuperProperty / SuperCall — `super` is never a standalone primary; it must be the
    // base of `super.name`, `super[expr]`, or `super(args)`. Handle it here so the early errors
    // (must be inside a method / derived constructor) fire and the form is captured directly.
    const start_off = self.tokenOffset(self.peek()); // callee start — V8 points a call frame here
    if (self.peek().kind == .kw_super) {
        const sup = try self.parseSuper();
        return self.continuePostfix(sup, false, start_off);
    }
    const expr = try self.parsePrimary();
    return self.continuePostfix(expr, false, start_off);
}

/// §13.3.7 SuperCall / §13.3.5 SuperProperty — current token is `super`. A `super(args)` is only
/// legal in a derived constructor; a `super.name` / `super[expr]` only inside a method (anything
/// with a [[HomeObject]]). A bare `super` (no following `(` / `.` / `[`) is a SyntaxError.
pub fn parseSuper(self: *Parser) ParseError!*const ast.Node {
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
pub fn continuePostfix(self: *Parser, base: *const ast.Node, started_in_chain: bool, base_off: u32) ParseError!*const ast.Node {
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
                    try self.alloc(.{ .call = .{ .callee = expr, .args = args, .pos = base_off } }); // V8 call site = callee start
            },
            .template => { // §13.2.8 TaggedTemplate `expr\`…\``
                // §13.3.9.1 Early Error: a tagged template may not be applied to an OptionalChain
                // (`a?.b\`x\``) — the chain result is not a callable Reference. Reject inside a chain.
                if (in_chain) return ParseError.UnexpectedToken;
                const tok = self.advance();
                const quasi = try self.parseTemplate(tok.string_value);
                // §13.2.8.3: a TAGGED template TOLERATES a NotEscapeSequence (cooked → undefined), so
                // clear the flag the untagged `.template` primary would reject on.
                self.template_invalid_escape = false;
                expr = try self.alloc(.{ .tagged_template = .{ .tag = expr, .quasi = quasi } });
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
        // §13.3.12.1 / §13.4.1.1: NewTarget has AssignmentTargetType `invalid` — `new.target++`
        // (and the covered `(new.target)++`) is a SyntaxError.
        if (expr.* == .new_target) return ParseError.UnexpectedToken;
        // §13.3.10 / §13.4.1.1: ImportCall has AssignmentTargetType `invalid` — `import('')++`
        // (and `import('')--`) is a SyntaxError.
        if (expr.* == .import_call) return ParseError.UnexpectedToken;
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
pub fn parseMethodBody(self: *Parser, pl: ParamList, strict_out: ?*bool) ParseError![]const ast.Stmt {
    // §13.3.5 SuperProperty: every MethodDefinition body (class OR object-literal method /
    // accessor / generator / async method) has a [[HomeObject]], so `super.x` / `super[k]` is
    // allowed. Class methods/accessors already set `in_method` at the call site (and the derived
    // constructor sets `in_derived_ctor` for `super(...)`); object-literal methods do not, so set
    // `in_method` here to cover them uniformly. `in_derived_ctor` is left untouched — it is set
    // only by the derived-constructor caller, so `super(...)` stays a SyntaxError in object methods.
    const saved_in_method = self.in_method;
    defer self.in_method = saved_in_method;
    self.in_method = true;
    // §13.3.12: a method body is a NewTarget context (`new.target` is legal; it is `undefined`
    // unless the method was invoked via `new`, which only happens for a class constructor).
    const saved_in_function = self.in_function;
    defer self.in_function = saved_in_function;
    self.in_function = true;
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
pub fn parseObjectLiteral(self: *Parser) ParseError!*const ast.Node {
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
                // §13.3.5: an object-literal generator/async method has a [[HomeObject]], so `super.x`
                // is allowed in BOTH its params (a default `m(x = super.k)`) and body. Set `in_method`
                // before `parseParams` (the body re-asserts it via `parseMethodBody`).
                const saved_om_in_method = self.in_method;
                defer self.in_method = saved_om_in_method;
                self.in_method = true;
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
            // §13.3.5: an object-literal accessor has a [[HomeObject]] — `super.x` is allowed in its
            // params (a setter default `set x(v = super.k)`) and body. Set `in_method` before the
            // params parse (the body re-asserts it in `parseMethodBody`).
            const saved_acc_in_method = self.in_method;
            defer self.in_method = saved_acc_in_method;
            self.in_method = true;
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
            // §13.3.5: an object-literal method has a [[HomeObject]] — `super.x` is allowed in its
            // params (a default `m(x = super.k)`) and body. Set `in_method` before the params parse.
            const saved_m_in_method = self.in_method;
            defer self.in_method = saved_m_in_method;
            self.in_method = true;
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

/// §13.2.5 PropertyName — a literal name (identifier / string / number) or a `[expr]`
/// ComputedPropertyName. `is_ident` flags a bare identifier (the only shorthand-eligible form).
pub fn parsePropertyName(self: *Parser) ParseError!PropName {
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
pub fn parseNumericLiteral(self: *Parser, lexeme: []const u8) ParseError!f64 {
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

/// §12.9.3.2 — the value of a BigIntLiteral lexeme (the digit text, `n` already stripped by the
/// lexer). Strips `_` separators, detects a `0x`/`0o`/`0b` radix prefix (else decimal), and parses
/// the digits into an arena-owned BigInt. Reuses the same separator-placement Early Error.
pub fn parseBigIntLiteral(self: *Parser, lexeme: []const u8) ParseError!*const std.math.big.int.Const {
    if (!validNumericSeparators(lexeme)) return ParseError.UnexpectedToken;
    var buf: std.ArrayList(u8) = .empty;
    for (lexeme) |ch| if (ch != '_') try buf.append(self.arena, ch);
    var s = buf.items;
    var base: u8 = 10;
    if (s.len >= 2 and s[0] == '0') {
        base = switch (s[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => 10,
        };
        if (base != 10) {
            if (s.len == 2) return ParseError.UnexpectedToken; // prefix with no digits
            s = s[2..];
        }
    }
    return bigint.fromDigits(self.arena, s, base, false) catch ParseError.UnexpectedToken;
}

pub fn parsePrimary(self: *Parser) ParseError!*const ast.Node {
    const t = self.peek();
    // §15.8 AsyncFunctionExpression / AsyncGeneratorExpression (`async [no LT] function …`) is a
    // PrimaryExpression. Recognized here (rather than at the assignment level) so the trailing
    // Member/Call suffixes parsed by `continuePostfix` attach to it — e.g. the IIFE
    // `(async function*(){ yield x }())`. The two async ARROW cover-grammars stay at the assignment
    // level (`parseAssignment`); only this `.function_expr` shape reaches here.
    if (self.atAsyncArrowOrFunction()) |kind| if (kind == .function_expr) {
        // §12.7.1 Early Error: the `async` modifier is a terminal symbol — no Unicode escape.
        if (t.had_escape) return ParseError.UnexpectedToken;
        _ = self.advance(); // `async`
        _ = self.advance(); // `function`
        return self.alloc(.{ .function = try self.parseFunction(true) });
    };
    switch (t.kind) {
        .number => {
            _ = self.advance();
            if (t.is_bigint) { // §12.9.3.2 BigIntLiteral
                const b = self.parseBigIntLiteral(t.lexeme) catch return ParseError.UnexpectedToken;
                return self.alloc(.{ .bigint = b });
            }
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
        .regex => { // §13.2.7 RegularExpressionLiteral — lexeme = pattern, string_value = flags
            // §12.9.5 Static Semantics (Early Errors): an invalid pattern or flag set is a
            // parse-phase SyntaxError (Test262 `literals/regexp` negatives use `phase: parse`),
            // not a deferred runtime error — so validate here rather than at RegExp construction.
            regex_engine.validateLiteral(self.arena, t.lexeme, t.string_value) catch |e| switch (e) {
                error.OutOfMemory => return ParseError.OutOfMemory,
                error.SyntaxError => return ParseError.UnexpectedToken,
            };
            _ = self.advance();
            return self.alloc(.{ .regex_literal = .{ .pattern = t.lexeme, .flags = t.string_value } });
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
            // §12.7.2 / §16.2.1.5: in MODULE code `await` is a reserved word — it is NOT a valid
            // IdentifierReference ANYWHERE in the module, including the body of a nested NON-async
            // function (where the Await capability does not propagate, so `await` is also not the
            // operator). `{ await 0; }` in such a body must be a SyntaxError (the `early-does-not-
            // propagate` tests), so reject `await` as a primary in module code regardless of `in_async`.
            if ((self.in_async or self.is_module) and std.mem.eql(u8, t.lexeme, "await")) return ParseError.UnexpectedToken;
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
            const node = try self.parseTemplate(t.string_value);
            // §12.9.6.1 Early Error: an UNTAGGED TemplateLiteral with a NotEscapeSequence (illegal
            // escape) is a SyntaxError. (A TAGGED template tolerates it — but the tagged form consumes
            // the `.template` token in `continuePostfix` before reaching this untagged primary path.)
            if (self.template_invalid_escape) {
                self.template_invalid_escape = false;
                return ParseError.UnexpectedToken;
            }
            return node;
        },
        .kw_new => return self.parseNew(),
        // §13.3.10 ImportCall `import ( AssignmentExpression [, AssignmentExpression] [,] )`.
        // Only the call form is supported: a bare `import`, a static `import`/`export`
        // declaration, and every MetaProperty form (`import.meta`, `import.source`,
        // `import.defer`, `import.UNKNOWN`) remain parse-phase SyntaxErrors (the `else` below).
        .kw_import => {
            if (self.idx + 1 < self.tokens.len and self.tokens[self.idx + 1].kind == .lparen) {
                const ic = try self.parseImportCall();
                // A bare (unparenthesized) ImportCall is not a NewExpression target — clear any
                // stale `last_was_paren` so `parseNew`'s guard reads it correctly (a PARENTHESIZED
                // `new (import(''))` is valid and is handled by the `.lparen` arm, which sets it).
                self.last_was_paren = false;
                return ic;
            }
            // §13.3.12 ImportMeta: `import . meta` — valid only in the Module goal (a SyntaxError in a
            // Script). The member name MUST be exactly `meta` (import.source/defer/etc. stay errors).
            if (self.idx + 2 < self.tokens.len and self.tokens[self.idx + 1].kind == .dot and
                self.tokens[self.idx + 2].kind == .identifier and
                std.mem.eql(u8, self.tokens[self.idx + 2].lexeme, "meta"))
            {
                if (!self.is_module) return ParseError.UnexpectedToken; // import.meta outside a module
                self.idx += 3; // consume `import` `.` `meta`
                self.last_was_paren = false;
                return self.alloc(.{ .import_meta = {} });
            }
            return ParseError.UnexpectedToken;
        },
        // §15.7 ClassExpression (primary position). The name is optional (`class { … }`).
        .kw_class => return self.alloc(.{ .class_expr = try self.parseClass(false, true) }),
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

pub fn validNumericSeparators(s: []const u8) bool {
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
pub fn numericKey(arena: std.mem.Allocator, n: f64) ParseError![]const u8 {
    if (n == @floor(n) and @abs(n) < 1e21) {
        return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))});
    }
    return std.fmt.allocPrint(arena, "{d}", .{n});
}

pub fn binaryOpFor(kind: lex.TokenKind) ?ast.BinaryOp {
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
pub fn compoundBinOp(kind: lex.TokenKind) ?ast.BinaryOp {
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
pub fn logicalAssignOp(kind: lex.TokenKind) ?ast.LogicalOp {
    return switch (kind) {
        .amp_amp_assign => .and_,
        .pipe_pipe_assign => .or_,
        .question_question_assign => .coalesce,
        else => null,
    };
}

/// Precedence over token kinds (covers logical, equality, relational, additive,
/// multiplicative). Assignment is handled separately in `parseAssignment`.
pub fn opPrecedence(kind: lex.TokenKind) ?u8 {
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
