//! Extracted from parser.zig (behavior-preserving split): early-error / scope validation and
//! related static-semantics helpers (§13.x, §14.x, §15.x, §16.2). Free functions; thin aliases
//! remain in parser.zig for the call sites that reference them from retained code.
const std = @import("std");
const ast = @import("ast.zig");
const lex = @import("lexer.zig");
const parser = @import("parser.zig");
const Parser = parser.Parser;
const ParseError = parser.ParseError;

pub fn isEvalOrArguments(name: []const u8) bool {
    return std.mem.eql(u8, name, "eval") or std.mem.eql(u8, name, "arguments");
}

/// §12.7.1 / §12.7.2: an `Identifier` is `IdentifierName but not ReservedWord`. A token that is an
/// identifier whose IdentifierName contained a Unicode escape AND whose decoded StringValue is a
/// §12.7.2 ReservedWord is NOT a valid Identifier (binding / reference) — a SyntaxError. (`yield`/
/// `await` are excepted by §12.7.1 and are not in `isReservedWord`.) Non-escaped reserved words are
/// lexed as keyword tokens and never reach an Identifier position as an `.identifier`, so this guard
/// fires only for the escaped spelling. It does NOT apply at IdentifierName positions (property names,
/// member access), where reserved words — escaped or not — are valid.
pub fn isEscapedReservedIdent(t: lex.Token) bool {
    return t.kind == .identifier and t.had_escape and lex.isReservedWord(t.lexeme);
}

/// §13.1.1 / Table: a name that may not be used as a BindingIdentifier in strict mode — `eval`,
/// `arguments`, and the strict future-reserved words. (`let`/`static`/`yield` are contextual; as a
/// *binding name* they are forbidden in strict. `let` is already lexed as a keyword so it never
/// reaches here as an identifier lexeme, but listing it keeps the set complete.)
/// §14.4: may a token begin a YieldExpression's argument (an AssignmentExpression)? Everything except
/// the tokens that close/separate the enclosing context (`)`, `]`, `}`, `,`, `;`, `:`) and eof. (`:`
/// closes a conditional/case/label; `}` closes a block/object; the rest are list/group separators.)
pub fn startsYieldArgument(kind: lex.TokenKind) bool {
    return switch (kind) {
        .rparen, .rbracket, .rbrace, .comma, .semicolon, .colon, .eof => false,
        else => true,
    };
}

pub fn isStrictReservedBindingName(name: []const u8) bool {
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
pub fn patternHasStrictReserved(pattern: *const ast.Pattern) bool {
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
pub fn isSimpleAssignTarget(node: *const ast.Node) bool {
    return switch (node.*) {
        // §13.15.2: a MemberExpression `.` PrivateIdentifier is a valid (simple) AssignmentTarget, so
        // `for (this.#x of …)` / `for (this.#x in …)` are legal. `private_member` is the parsed form
        // of `obj.#x`; the interpreter's for-head binder writes it via setPrivate.
        .identifier, .member, .index, .private_member => true,
        else => false,
    };
}

/// §13.1.1: does any formal parameter (including the rest element) bind a strict-reserved name?
pub fn paramsHaveStrictReserved(pl: Parser.ParamList) bool {
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
pub fn paramsHaveYield(pl: Parser.ParamList) bool {
    for (pl.params) |p| {
        if (patternBindsYield(p.pattern)) return true;
        if (p.default) |d| if (nodeReferencesYield(d)) return true;
    }
    if (pl.rest) |r| return patternBindsYield(r);
    return false;
}

pub fn patternBindsYield(pattern: *const ast.Pattern) bool {
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
pub fn nodeReferencesYield(node: *const ast.Node) bool {
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
        .import_call => |ic| nodeReferencesYield(ic.specifier) or (if (ic.options) |o| nodeReferencesYield(o) else false),
        else => false,
    };
}

/// §15.8.1 / §15.6.1 Early Error: an AsyncFunction/AsyncArrow/AsyncGenerator's FormalParameters may
/// neither bind `await` (`async function f(await){}`) nor — since params parse `~Await` — contain an
/// AwaitExpression. A param BindingIdentifier `await`, or a default that references `await` as the
/// identifier (`async (a = await) => {}`, parsed as the identifier `await` since params are `~Await`),
/// is invalid. Mirrors `paramsHaveYield`.
pub fn paramsHaveAwait(pl: Parser.ParamList) bool {
    for (pl.params) |p| {
        if (patternBindsAwait(p.pattern)) return true;
        if (p.default) |d| if (nodeReferencesAwait(d)) return true;
    }
    if (pl.rest) |r| return patternBindsAwait(r);
    return false;
}

pub fn patternBindsAwait(pattern: *const ast.Pattern) bool {
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
pub fn nodeReferencesAwait(node: *const ast.Node) bool {
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
        .import_call => |ic| nodeReferencesAwait(ic.specifier) or (if (ic.options) |o| nodeReferencesAwait(o) else false),
        else => false,
    };
}

/// §8.2.7 VarDeclaredNames (subset) — does the statement `stmt` (a for-of/for-in body) `var`-declare
/// a binding named `name`? Recurses through the nested Statement productions that share the function's
/// VarScope (blocks, if/else, loops, try/catch/finally, switch, with, labels) but DOES NOT descend
/// into nested function/class bodies (those open a new VarScope). Only the `using` for-head Early
/// Error consumes this, so it runs off the hot path. A `var`'s pattern can bind multiple names; we
/// check each. (let/const declarations are LexicallyDeclaredNames, not VarDeclaredNames — skipped.)
pub fn bodyVarDeclaresName(stmt: *const ast.Stmt, name: []const u8) bool {
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
pub fn patternBindsName(pat: *const ast.Pattern, name: []const u8) bool {
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
pub fn isSimpleParameterList(pl: Parser.ParamList) bool {
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
pub fn hasDuplicatePrivateNames(arena: std.mem.Allocator, elements: []const ast.ClassElement) std.mem.Allocator.Error!bool {
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

pub fn hasDuplicateBoundNames(pl: Parser.ParamList) bool {
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
pub fn paramsConflictWithBodyLexical(pl: Parser.ParamList, body: []const ast.Stmt) bool {
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

pub fn nameInList(name: []const u8, list: []const []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Does `pattern` bind any identifier present in `list`?
pub fn patternBindsAny(pattern: *const ast.Pattern, list: []const []const u8) bool {
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
/// §16.2: may a token kind appear as an IdentifierName (e.g. a NamedImport's imported name or a
/// ModuleExportName)? IdentifierName admits ReservedWords, so any keyword token or `identifier` is
/// accepted. (The lexer maps reserved words to dedicated `kw_*` kinds; a NamedImport like
/// `{ default as d }` needs `default`/`class`/etc. to be valid imported names.)
pub fn isIdentifierNameToken(kind: lex.TokenKind) bool {
    return switch (kind) {
        .identifier => true,
        else => @tagName(kind).len > 3 and std.mem.startsWith(u8, @tagName(kind), "kw_"),
    };
}

/// §16.2.1.5: is `name` usable as a module-level BindingIdentifier (module code is strict)? Rejects
/// reserved words and the strict-reserved set (`eval`, `arguments`, `yield`, …).
pub fn isValidBindingName(name: []const u8) bool {
    if (lex.isReservedWord(name)) return false;
    if (isStrictReservedBindingName(name)) return false;
    return true;
}

/// §16.2.1.5 BoundNames of a module-level Declaration statement (used to collect the module's
/// top-level declared names for the ExportedBinding early error). Returns the names declared by a
/// `var`/`let`/`const`/`using` declaration, a function/class declaration, or `[]` otherwise.
pub fn boundDeclNames(a: std.mem.Allocator, stmt: ast.Stmt) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    switch (stmt) {
        .declaration => |d| {
            for (d.decls) |dec| _ = collectBoundNames(dec.target, &names, a);
        },
        .func_decl => |f| if (f.name) |n| try names.append(a, n),
        .class_decl => |c| if (c.name) |n| try names.append(a, n),
        else => {},
    }
    return names.items;
}

pub fn collectBoundNames(pattern: *const ast.Pattern, names: *std.ArrayList([]const u8), a: std.mem.Allocator) bool {
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
pub fn containsArguments(node: *const ast.Node) bool {
    switch (node.*) {
        .identifier => |n| return std.mem.eql(u8, n, "arguments"),
        .number, .bigint, .string, .boolean, .null, .this, .new_target, .regex_literal, .import_meta => return false,
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
        .compound_assign => |a| return containsArguments(a.target) or containsArguments(a.value),
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
        .import_call => |ic| {
            if (containsArguments(ic.specifier)) return true;
            if (ic.options) |o| if (containsArguments(o)) return true;
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
        .tagged_template => |tt| return containsArguments(tt.tag) or containsArguments(tt.quasi),
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
        .super_assign => |sa| return (if (sa.key) |k| containsArguments(k) else false) or containsArguments(sa.value),
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

pub fn bodyContainsArguments(body: []const ast.Stmt) bool {
    for (body) |s| if (stmtContainsArguments(s)) return true;
    return false;
}

pub fn stmtContainsArguments(stmt: ast.Stmt) bool {
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
pub fn bodyHasUseStrict(body: []const ast.Stmt) bool {
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
pub const ScopeKind = enum { script_or_body, block };

/// A bounded name set backed by a fixed buffer — lexical/var name lists per scope are small. On
/// overflow it stops recording (conservatively under-reporting a duplicate rather than misfiring);
/// real programs never approach the cap.
pub const NameSet = struct {
    buf: [256][]const u8,
    len: usize = 0,
    pub fn init() NameSet {
        // SAFETY: `len` starts at 0; `buf` slots are written by `add` before any read (`has`/`addPattern`
        // only ever scan `buf[0..len]`), so the `undefined` backing storage is never observed.
        return .{ .buf = undefined };
    }
    pub fn has(self: *const NameSet, name: []const u8) bool {
        for (self.buf[0..self.len]) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }
    /// Append `name`; returns true if it was already present (a duplicate).
    pub fn add(self: *NameSet, name: []const u8) bool {
        if (self.has(name)) return true;
        if (self.len < self.buf.len) {
            self.buf[self.len] = name;
            self.len += 1;
        }
        return false;
    }
    pub fn addPatternDup(self: *NameSet, pattern: *const ast.Pattern) bool {
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
    pub fn addPattern(self: *NameSet, pattern: *const ast.Pattern) void {
        _ = self.addPatternDup(pattern);
    }
};

pub fn declIsLexical(kind: ast.DeclKind) bool {
    return kind != .var_decl; // let / const / using / await using
}

/// Append the VarDeclaredNames reachable from `stmt` into `set`, bubbling up through nested
/// non-function statements (inner blocks, if/for/while/do/try/with/labeled bodies, switch cases)
/// but STOPPING at any function/class boundary (a nested function body has its own var scope).
/// Only `var` declarations contribute (a FunctionDeclaration is a *Declaration* → empty
/// VarDeclaredNames, §14.2.2). We collect a `for`-head `var` (it hoists out of the loop) but not a
/// `let`/`const` (a `for`'s lexical head is its own per-iteration scope).
pub fn collectVarNames(stmt: ast.Stmt, set: *NameSet) void {
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
pub fn collectScopeLexicalNames(stmts: []const ast.Stmt, kind: ScopeKind, strict: bool, lex_set: *NameSet) bool {
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

/// Is any BoundName of a CatchParameter pattern present in `set`? (No-alloc recursion over the
/// identifier / array / object pattern forms — used for the §14.15.1 catch-parameter Early Errors.)
pub fn catchBoundNameInSet(pattern: *const ast.Pattern, set: *const NameSet) bool {
    switch (pattern.*) {
        .identifier => |n| return set.has(n),
        .array => |ap| {
            for (ap.elements) |el| if (el.target) |t| {
                if (catchBoundNameInSet(t, set)) return true;
            };
            if (ap.rest) |r| return catchBoundNameInSet(r, set);
            return false;
        },
        .object => |op| {
            for (op.properties) |p| if (catchBoundNameInSet(p.target, set)) return true;
            if (op.rest) |r| return set.has(r);
            return false;
        },
    }
}

/// Validate one scope's StatementList (rules 1 + 2). `catch_param`, when set, is the CatchParameter the
/// Block is the body of: §14.15.1 makes it a Syntax Error if any of its BoundNames also occurs in the
/// Block's LexicallyDeclaredNames (`catch(e){ let e }` / `catch([e]){ let e }`). A SIMPLE-identifier
/// catch param does NOT participate in the §14.2.1 LexicallyDeclaredNames∩VarDeclaredNames check —
/// Annex B B.3.4 permits `catch(e){var e}` — but a destructuring CatchParameter (a BindingPattern) has
/// no such exception, so its BoundNames may not collide with the Block's VarDeclaredNames either.
pub fn checkScopeNames(stmts: []const ast.Stmt, kind: ScopeKind, strict: bool, catch_param: ?*const ast.Pattern) ParseError!void {
    var lex_set: NameSet = .init();
    if (collectScopeLexicalNames(stmts, kind, strict, &lex_set)) return ParseError.UnexpectedToken;
    // §14.15.1: a CatchParameter BoundName may not also be a LexicallyDeclaredName of the Catch Block.
    if (catch_param) |cp| if (catchBoundNameInSet(cp, &lex_set)) return ParseError.UnexpectedToken;
    if (lex_set.len == 0) {
        // §14.15.1 (non-Annex-B): a destructuring CatchParameter's BoundNames also exclude VarDeclaredNames.
        if (catch_param) |cp| if (cp.* != .identifier) {
            var var_set: NameSet = .init();
            collectScopeVarNames(stmts, kind, &var_set);
            if (catchBoundNameInSet(cp, &var_set)) return ParseError.UnexpectedToken;
        };
        return;
    }
    // §14.2.1 rule 2: LexicallyDeclaredNames ∩ VarDeclaredNames = ∅.
    var var_set: NameSet = .init();
    collectScopeVarNames(stmts, kind, &var_set);
    for (lex_set.buf[0..lex_set.len]) |nm| if (var_set.has(nm)) return ParseError.UnexpectedToken;
    // §14.15.1 (non-Annex-B): a destructuring CatchParameter's BoundNames also exclude VarDeclaredNames.
    if (catch_param) |cp| if (cp.* != .identifier) {
        if (catchBoundNameInSet(cp, &var_set)) return ParseError.UnexpectedToken;
    };
}

/// VarDeclaredNames of a whole scope: every statement's bubbled-up `var` names (functions never
/// bubble — see `collectVarNames`). At a Script/FunctionBody (`kind == .script_or_body`), a
/// TOP-LEVEL FunctionDeclaration is additionally a VarDeclaredName (TopLevelVarDeclaredNames,
/// §16.1.2 / §15.2.2), so `let f; function f(){}` at script/body level is an Early Error while
/// `function f(){} function f(){}` (var∩var) is legal. In a Block, top-level functions are lexical
/// (handled by `collectScopeLexicalNames`) and contribute nothing here.
pub fn collectScopeVarNames(stmts: []const ast.Stmt, kind: ScopeKind, set: *NameSet) void {
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
pub fn validateScope(stmts: []const ast.Stmt, kind: ScopeKind, strict: bool) ParseError!void {
    try checkScopeNames(stmts, kind, strict, @as(?*const ast.Pattern, null));
    for (stmts) |stmt| try descendStmt(stmt, strict);
}

pub fn validateFunction(f: *const ast.Function, strict: bool) ParseError!void {
    const inner = strict or bodyHasUseStrict(f.body);
    // Parameter default initializers may carry nested function/class expressions (`(a = ()=>{}) =>`).
    for (f.params) |p| if (p.default) |d| try descendNode(d, inner);
    try validateScope(f.body, .script_or_body, inner);
}

pub fn validateClass(c: *const ast.Class, strict: bool) ParseError!void {
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
pub fn descendStmt(stmt: ast.Stmt, strict: bool) ParseError!void {
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
            if (!overflow) try checkScopeNames(merged.items, .block, strict, @as(?*const ast.Pattern, null));
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
pub fn descendNode(node: *const ast.Node, strict: bool) ParseError!void {
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
        .compound_assign => |a| {
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
        .import_call => |ic| {
            try descendNode(ic.specifier, strict);
            if (ic.options) |o| try descendNode(o, strict);
        },
        .array_literal => |els| for (els) |e| try descendNode(e, strict),
        .object_literal => |props| for (props) |p| {
            if (p.computed_key) |ck| try descendNode(ck, strict);
            if (p.default) |df| try descendNode(df, strict);
            try descendNode(p.value, strict);
        },
        .template => |t| for (t.exprs) |e| try descendNode(e, strict),
        .tagged_template => |tt| {
            try descendNode(tt.tag, strict);
            try descendNode(tt.quasi, strict);
        },
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
pub fn directivePrologueIsStrict(toks: []const lex.Token) bool {
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
pub fn startsAccessorName(kind: lex.TokenKind) bool {
    return switch (kind) {
        .identifier, .string, .number, .lbracket, .private_identifier => true,
        else => isKeywordName(kind), // `get if(){}` etc.
    };
}

/// Is `kind` a reserved word usable as a (non-computed) property name? Per §13.2.5 any
/// ReservedWord is a valid IdentifierName key.
pub fn isKeywordName(kind: lex.TokenKind) bool {
    return switch (kind) {
        .kw_true, .kw_false, .kw_null, .kw_var, .kw_let, .kw_const, .kw_function, .kw_return, .kw_this, .kw_if, .kw_else, .kw_while, .kw_do, .kw_for, .kw_throw, .kw_try, .kw_catch, .kw_finally, .kw_break, .kw_continue, .kw_typeof, .kw_void, .kw_delete, .kw_new, .kw_instanceof, .kw_switch, .kw_case, .kw_default, .kw_import, .kw_export, .kw_class, .kw_extends, .kw_super, .kw_in, .kw_with => true,
        else => false,
    };
}
