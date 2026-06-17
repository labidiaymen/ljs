//! Engine unit tests (split from engine_tests.zig to keep files < 1000 lines). All shared symbols
//! (helpers + evaluate/t.Value/...) are referenced via the `t.` prefix off engine_tests.zig.
const t = @import("engine_tests.zig");
const std = @import("std");
const testing = std.testing;

test "M3 object spread: copy own enumerable props (US6, §13.2.5.4)" {
    try t.expectNumber("var a = {x: 1, y: 2}; var b = {...a}; b.x + b.y", 3);
    // later properties override earlier (spread then explicit)
    try t.expectNumber("var a = {x: 1}; var b = {...a, x: 9}; b.x", 9);
    // explicit then spread (spread wins)
    try t.expectNumber("var a = {x: 9}; var b = {x: 1, ...a}; b.x", 9);
    // null/undefined sources are ignored (no throw)
    try t.expectNumber("var b = {...null, ...undefined, z: 5}; b.z", 5);
    // array spread copies index props
    try t.expectStr("var o = {...[10, 20]}; '' + o[0] + o[1]", "1020");
}

test "M3 accessors: getters & setters (US6, §13.2.5.6 / §10.2.x)" {
    // getter invoked on read
    try t.expectNumber("var o = {get x(){ return 7; }}; o.x", 7);
    // getter sees `this`
    try t.expectNumber("var o = {v: 3, get x(){ return this.v * 2; }}; o.x", 6);
    // setter invoked on write
    try t.expectNumber("var o = {_v: 0, set x(val){ this._v = val; }}; o.x = 41; o._v", 41);
    // get + set pair on the same key
    try t.expectNumber(
        "var o = {_v: 1, get x(){ return this._v; }, set x(val){ this._v = val + 1; }};" ++
            " o.x = 10; o.x",
        11,
    );
    // a getter-only property: writing is a silent no-op (sloppy), read still works
    try t.expectNumber("var o = {get x(){ return 5; }}; o.x = 100; o.x", 5);
}

test "M3 optional chaining: short-circuit (US6, §13.3.9)" {
    // a?.b on a present object
    try t.expectNumber("var o = {b: 8}; o?.b", 8);
    // a?.b on null/undefined → undefined (no throw)
    try t.expectBool("var a = null; a?.b === undefined", true);
    try t.expectBool("var a = undefined; a?.b === undefined", true);
    // whole chain short-circuits: a?.b.c when a is null → undefined (does NOT throw on .c)
    try t.expectBool("var a = null; a?.b.c === undefined", true);
    try t.expectBool("var a = null; (a?.b.c.d.e) === undefined", true);
    // a?.[k] index form
    try t.expectNumber("var o = {x: 4}; o?.['x']", 4);
    try t.expectBool("var a = null; a?.[0] === undefined", true);
    // a?.() call form
    try t.expectNumber("var f = () => 9; f?.()", 9);
    try t.expectBool("var f = null; f?.() === undefined", true);
    // method call through a chain keeps the receiver
    try t.expectNumber("var o = {v: 6, m(){ return this.v; }}; o?.m()", 6);
    // present base, then short-circuit further in: o?.miss?.deep → undefined
    try t.expectBool("var o = {}; o?.miss?.deep === undefined", true);
}

test "M3 nullish coalescing: ?? & mixing early error (US6, §13.13)" {
    // a ?? b → a unless null/undefined
    try t.expectNumber("1 ?? 2", 1);
    try t.expectNumber("null ?? 1", 1);
    try t.expectNumber("undefined ?? 7", 7);
    // 0 and '' are NOT nullish — `??` keeps them (unlike `||`)
    try t.expectNumber("0 ?? 5", 0);
    try t.expectStr("'' ?? 'x'", "");
    try t.expectBool("false ?? true", false);
    // chained ??
    try t.expectNumber("null ?? undefined ?? 3", 3);
    // §13.13.1 Early Error: mixing ?? with || / && without parens is a SyntaxError
    try t.expectSyntaxError("a ?? b || c");
    try t.expectSyntaxError("a || b ?? c");
    try t.expectSyntaxError("a ?? b && c");
    try t.expectSyntaxError("a && b ?? c");
    // …but parentheses make it legal
    try t.expectNumber("null ?? (0 || 4)", 4);
    try t.expectNumber("(null || 2) ?? 9", 2);
}

test "M3 compound assignment: full operator set on identifiers (US7, §13.15)" {
    // The five existing ops still work (regression guard).
    try t.expectNumber("var s = 0; s += 10; s -= 3; s *= 2; s", 14);
    try t.expectNumber("var s = 20; s /= 4; s", 5);
    try t.expectNumber("var s = 20; s %= 7; s", 6);
    // New compound ops: **= and the shifts.
    try t.expectNumber("var s = 3; s **= 4; s", 81);
    try t.expectNumber("var s = 1; s <<= 5; s", 32);
    try t.expectNumber("var s = 64; s >>= 2; s", 16);
    try t.expectNumber("var s = -1; s >>>= 28; s", 15); // logical (unsigned) shift
    // New compound ops: bitwise &= |= ^=.
    try t.expectNumber("var s = 12; s &= 10; s", 8);
    try t.expectNumber("var s = 12; s |= 3; s", 15);
    try t.expectNumber("var s = 12; s ^= 10; s", 6);
    // Result value of a compound assignment is the assigned value.
    try t.expectNumber("var s = 5; (s **= 2)", 25);
}

test "M3 compound assignment: member & index targets (US7, §13.15)" {
    try t.expectNumber("var o = {n: 3}; o.n **= 3; o.n", 27);
    try t.expectNumber("var o = {n: 1}; o.n <<= 4; o.n", 16);
    try t.expectNumber("var o = {n: 13}; o.n &= 6; o.n", 4);
    try t.expectNumber("var o = {n: 8}; o.n |= 1; o.n", 9);
    try t.expectNumber("var o = {n: 8}; o.n ^= 12; o.n", 4);
    // a[k] *= 2 (existing) and the new ops on an index target.
    try t.expectNumber("var a = [1, 2, 3]; a[1] *= 2; a[1]", 4);
    try t.expectNumber("var a = [1, 2, 3]; a[2] **= 3; a[2]", 27);
    try t.expectNumber("var a = [4]; a[0] >>= 1; a[0]", 2);
    try t.expectNumber("var a = [5]; a[0] |= 2; a[0]", 7);
}

test "M3 logical assignment: &&= ||= ??= guard semantics (US7, §13.15.2)" {
    // &&= assigns only when the current value is truthy.
    try t.expectNumber("var x = 1; x &&= 5; x", 5); // truthy → assigned
    try t.expectNumber("var x = 0; x &&= 5; x", 0); // falsy → unchanged
    // ||= assigns only when the current value is falsy.
    try t.expectNumber("var x = 0; x ||= 9; x", 9); // falsy → assigned
    try t.expectNumber("var x = 3; x ||= 9; x", 3); // truthy → unchanged
    // ??= assigns only when null/undefined — 0 and '' are NOT nullish.
    try t.expectNumber("var x; x ??= 7; x", 7); // undefined → assigned
    try t.expectNumber("var x = null; x ??= 7; x", 7); // null → assigned
    try t.expectNumber("var x = 0; x ??= 7; x", 0); // 0 is not nullish → unchanged
    try t.expectStr("var x = ''; x ??= 'y'; x", ""); // '' is not nullish → unchanged
    // Yields the final value of the target.
    try t.expectNumber("var x = 0; (x ||= 4)", 4);
    try t.expectNumber("var x = 2; (x &&= 8)", 8);
    // Logical assignment on member / index targets.
    try t.expectNumber("var o = {n: 0}; o.n ||= 5; o.n", 5);
    try t.expectNumber("var o = {}; o.n ??= 9; o.n", 9);
    try t.expectNumber("var a = [0]; a[0] ||= 6; a[0]", 6);
}

test "M3 logical assignment: short-circuit does NOT evaluate RHS (US7, §13.15.2)" {
    // RHS is a call that bumps a counter; assert the counter only moves when the guard passes.
    // &&= on a falsy target must NOT evaluate the RHS.
    try t.expectNumber(
        "var hits = 0; function bump() { hits = hits + 1; return 99; } var x = 0; x &&= bump(); hits",
        0,
    );
    // …but on a truthy target it DOES.
    try t.expectNumber(
        "var hits = 0; function bump() { hits = hits + 1; return 99; } var x = 1; x &&= bump(); hits",
        1,
    );
    // ||= on a truthy target must NOT evaluate the RHS.
    try t.expectNumber(
        "var hits = 0; function bump() { hits = hits + 1; return 99; } var x = 3; x ||= bump(); hits",
        0,
    );
    // ??= on a non-nullish target must NOT evaluate the RHS.
    try t.expectNumber(
        "var hits = 0; function bump() { hits = hits + 1; return 99; } var x = 0; x ??= bump(); hits",
        0,
    );
    // ??= on undefined DOES evaluate the RHS exactly once.
    try t.expectNumber(
        "var hits = 0; function bump() { hits = hits + 1; return 99; } var x; x ??= bump(); hits",
        1,
    );
}

test "M3 logical assignment: member base evaluated exactly once (US7, §13.15.2)" {
    // `obj().p ??= v` must call obj() once whether or not the assignment happens.
    // Non-nullish current value → no write, but base still evaluated once.
    try t.expectNumber(
        "var calls = 0; var o = {p: 1}; function obj() { calls = calls + 1; return o; } obj().p ??= 5; calls",
        1,
    );
    // Nullish current value → write happens, base still evaluated once.
    try t.expectNumber(
        "var calls = 0; var o = {}; function obj() { calls = calls + 1; return o; } obj().p ??= 5; o.p",
        5,
    );
    try t.expectNumber(
        "var calls = 0; var o = {}; function obj() { calls = calls + 1; return o; } obj().p ??= 5; calls",
        1,
    );
}

test "M3 comma / sequence operator (US8, §13.16)" {
    // `(a, b, c)` evaluates each and yields the last.
    try t.expectNumber("(1, 2, 3)", 3);
    // Side effects of the discarded left operand are observable.
    try t.expectNumber("var a = 0; (a = 1, a = 2); a", 2);
    try t.expectNumber("var a = 0; var b = (a = 5, a + 1); b", 6);
    // Comma is allowed as a top-level expression statement.
    try t.expectNumber("var x = 0; x = 1, x = 7; x", 7);
    // Comma in the `for` init/update clauses (full Expression positions).
    try t.expectNumber("var s = 0; for (var i = 0, j = 10; i < 3; i++, j--) { s += j; } s", 27);
}

test "M3 comma does NOT hijack arg/element/declarator commas (US8 regression)" {
    // Call arguments are an AssignmentExpression list — `f(1, 2)` is two args, not a sequence.
    try t.expectNumber("function f(a, b) { return a + b; } f(1, 2)", 3);
    try t.expectNumber("function f(a, b, c) { return c; } f(1, 2, 3)", 3);
    // Array elements likewise — `[1, 2]` has length 2, not a single sequence value.
    try t.expectNumber("[1, 2].length", 2);
    try t.expectNumber("[1, 2, 3][1]", 2);
    // Declarator list — `var a = 1, b = 2;` declares two bindings.
    try t.expectNumber("var a = 1, b = 2; a + b", 3);
    // Object property list.
    try t.expectNumber("var o = {a: 1, b: 2}; o.a + o.b", 3);
    // Arrow cover-grammar still wins over the sequence operator: `(a, b) => …` are params.
    try t.expectNumber("var f = (a, b) => a + b; f(40, 2)", 42);
}

test "M3 void operator (US8, §13.5.2)" {
    try t.expectUndefined("void 0");
    try t.expectUndefined("void \"anything\"");
    // The operand is evaluated for side effects; the result is undefined.
    try t.expectNumber("var a = 0; void (a = 9); a", 9);
}

test "M3 delete operator (US8, §13.5.1)" {
    // delete an own property → property gone, `in` reports false, returns true.
    try t.expectBool("var o = {x: 1}; delete o.x; \"x\" in o", false);
    try t.expectBool("var o = {x: 1}; delete o.x", true);
    try t.expectBool("var o = {x: 1, y: 2}; delete o.x; \"y\" in o", true);
    // computed/index form.
    try t.expectBool("var o = {x: 1}; var k = \"x\"; delete o[k]; \"x\" in o", false);
    // delete of a non-Reference evaluates the operand and returns true.
    try t.expectBool("delete 5", true);
    try t.expectBool("var a = 0; delete (a = 3)", true);
    try t.expectNumber("var a = 0; delete (a = 3); a", 3); // operand side effect observed
    // delete of an unqualified identifier returns true (sloppy M-subset).
    try t.expectBool("var x = 1; delete x", true);
    // accessing a deleted property yields undefined.
    try t.expectUndefined("var o = {x: 1}; delete o.x; o.x");
}

test "M3 strict-mode: \"use strict\" directive triggers Early Errors (US9, §11.2.2/§13.1.1)" {
    // A "use strict" directive prologue makes the script strict, so a binding named `eval`/
    // `arguments` is a SyntaxError (§13.1.1).
    try t.expectSyntaxError("\"use strict\"; var eval = 1;");
    try t.expectSyntaxError("\"use strict\"; var arguments = 1;");
    try t.expectSyntaxError("'use strict'; let eval = 2;");
    try t.expectSyntaxError("\"use strict\"; function eval() {}");
    try t.expectSyntaxError("\"use strict\"; function f(eval) {}");
    try t.expectSyntaxError("\"use strict\"; var f = (arguments) => 1;");
    // Future-reserved words as a binding name (§13.1.1).
    try t.expectSyntaxError("\"use strict\"; var public = 1;");
    try t.expectSyntaxError("\"use strict\"; function f(static) {}");
    try t.expectSyntaxError("\"use strict\"; var yield = 1;");
    // §13.15.1 assignment / update target of eval/arguments.
    try t.expectSyntaxError("\"use strict\"; eval = 1;");
    try t.expectSyntaxError("\"use strict\"; arguments++;");
    try t.expectSyntaxError("\"use strict\"; eval += 2;");
    // §13.5.1.1 delete of an unqualified reference.
    try t.expectSyntaxError("\"use strict\"; var y; delete y;");
    // §15.1.1 duplicate parameter names in a strict normal function.
    try t.expectSyntaxError("\"use strict\"; function f(a, a) { return a; }");
}

test "M3 strict-mode: lexical inheritance into nested functions (US9, §11.2.2)" {
    // A nested function inherits strictness even without its own directive.
    try t.expectSyntaxError("\"use strict\"; function outer() { function inner(eval) {} }");
    try t.expectSyntaxError("\"use strict\"; function outer() { var f = () => { var arguments = 1; }; }");
    // A "use strict" only inside the inner function makes the INNER strict (outer stays sloppy).
    try t.expectSyntaxError("function outer() { 'use strict'; function inner() { var eval = 1; } }");
    // …but the outer body, being sloppy, may still bind eval.
    try t.expectNoSyntaxErrorStrict("function outer() { return 1; } var x = 1;"); // sanity: strict mode parses fine
}

test "M3 strict-mode via RunMode: Early Errors fire without a prepended directive (US9)" {
    // The Test262 runner runs each test in strict RunMode (honoring the mode parameter), so the
    // Early Errors must fire even with no explicit directive in the source.
    try t.expectSyntaxErrorStrict("var eval = 1;");
    try t.expectSyntaxErrorStrict("var arguments = 2;");
    try t.expectSyntaxErrorStrict("function f(arguments) {}");
    try t.expectSyntaxErrorStrict("eval = 1;");
    try t.expectSyntaxErrorStrict("var z; delete z;");
    try t.expectSyntaxErrorStrict("function f(a, a) {}");
    try t.expectSyntaxErrorStrict("var f = (x, x) => 1;"); // (also a duplicate-param error in any mode)
    try t.expectSyntaxErrorStrict("var public = 1;");
}

test "M3 strict-mode: NO regression in sloppy mode (US9)" {
    // None of the strict Early Errors apply in sloppy mode.
    try t.expectNumber("var eval = 1; eval", 1);
    try t.expectNumber("var arguments = 2; arguments", 2);
    try t.expectNumber("function f(eval) { return eval; } f(7)", 7);
    try t.expectNumber("var public = 3; public", 3);
    try t.expectNumber("var yield = 4; yield", 4);
    try t.expectBool("var y = 1; delete y", true); // sloppy delete of a binding → true (M-subset)
    try t.expectNumber("var eval = 4; eval = 5; eval", 5); // sloppy assignment to eval is fine
    // A function with its own duplicate params is legal in sloppy mode (no directive).
    try t.expectNumber("function f(a, a) { return a; } f(1, 9)", 9); // last wins
    // `"use strict"` as a non-directive (an operand) does NOT make the script strict.
    try t.expectNumber("(\"use strict\"); var eval = 6; eval", 6);
    try t.expectNumber("\"use strict\" + \"\"; var arguments = 7; arguments", 7);
}

test "M3 strict-mode: member delete & qualified targets stay legal in strict (US9)" {
    // §13.5.1.1 only forbids delete of an *unqualified* reference; property deletes are fine.
    try t.expectNoSyntaxErrorStrict("var o = {x: 1}; delete o.x;");
    try t.expectNoSyntaxErrorStrict("var o = {x: 1}; delete o['x'];");
    // Assignment / update of non-eval/arguments identifiers and members is fine in strict.
    try t.expectNoSyntaxErrorStrict("var x = 1; x = 2; x++; var o = {}; o.p = 3; o.p++;");
    // eval/arguments are usable as property names / member accesses in strict (not bindings).
    try t.expectNoSyntaxErrorStrict("var o = {eval: 1, arguments: 2}; o.eval + o.arguments;");
}

test "deep recursion throws RangeError, not a segfault" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "1");
    var i: usize = 0;
    while (i < 2000) : (i += 1) try buf.appendSlice(a, "+1"); // 2001-deep > max_depth
    const r = try t.evaluate(a, buf.items, .sloppy);
    try testing.expect(r == .thrown);
}

test "M5 for-in: object property-name enumeration (Cycle 1, §14.7.5)" {
    // Single own key → exact name (the M-subset enumerates own string keys; order is the property
    // map's iteration order, so multi-key string assertions below use order-independent checks).
    try t.expectStr("var s=''; for (var k in {a:1}) s+=k; s", "a");
    // Both keys visited (order-independent: concat sorted-insensitive via a membership count).
    try t.expectNumber("var n=0; for (var k in {a:1,b:2}) n++; n", 2);
    try t.expectStr("var got=''; for (var k in {a:1,b:2}) { if (k==='a'||k==='b') got+='x'; } got", "xx");
    // for-in over an array yields the index strings (NOT "length", NOT Array.prototype methods).
    try t.expectStr("var s=''; for (var k in ['x','y','z']) s+=k; s", "012");
    try t.expectNumber("var n=0; for (var k in [10,20]) { if (k==='length') n+=100; n++; } n", 2);
    // Inherited *user* prototype keys are enumerable; built-in prototype methods are not.
    try t.expectNumber("function P(){} P.prototype.z=1; var o=new P(); o.a=2; var n=0; for (var k in o) n++; n", 2);
    try t.expectNumber("var n=0; for (var k in {}) n++; n", 0); // empty object → 0 iterations
    try t.expectNumber("var n=0; for (var k in []) n++; n", 0); // empty array → 0, no proto methods
    // A null/undefined operand runs the body zero times (no throw, §14.7.5.6 step 7.a).
    try t.expectNumber("var n=0; for (var k in null) n++; n", 0);
    try t.expectNumber("var n=0; for (var k in undefined) n++; n", 0);
    // Shadowing: a name owned lower on the chain is visited once (not again from the prototype).
    try t.expectNumber("function P(){} P.prototype.a=1; var o=new P(); o.a=2; var n=0; for (var k in o) n++; n", 1);
}

test "M5 for-of: value iteration over arrays & strings (Cycle 1, §14.7.5)" {
    try t.expectNumber("var t=0; for (var v of [1,2,3]) t+=v; t", 6);
    try t.expectStr("var s=''; for (var c of 'abc') s+=c; s", "abc");
    try t.expectNumber("var n=0; for (var v of []) n++; n", 0); // empty array → 0 iterations
    try t.expectNumber("var n=0; for (var v of '') n++; n", 0); // empty string → 0 iterations
    // A non-iterable operand is a TypeError (§14.7.5.6 → GetIterator throws).
    try t.expectThrows("for (var v of 5) {}");
    try t.expectThrows("for (var v of {}) {}");
    try t.expectThrows("for (var v of null) {}");
    try t.expectThrows("for (var v of undefined) {}");
    try t.expectThrows("for (var v of true) {}");
}

test "M5 for-in/of: break, continue, per-iteration binding (Cycle 1, §14.7.5.7)" {
    // break / continue in for-of.
    try t.expectNumber("var t=0; for (var v of [1,2,3,4]) { if (v===3) break; t+=v; } t", 3);
    try t.expectNumber("var t=0; for (var v of [1,2,3,4]) { if (v===2) continue; t+=v; } t", 8);
    // break / continue in for-in (over an array's index strings).
    try t.expectNumber("var n=0; for (var k in [1,2,3,4,5]) { if (k==='2') break; n++; } n", 2);
    try t.expectNumber("var n=0; for (var k in [1,2,3,4]) { if (k==='1') continue; n++; } n", 3);
    // §14.7.5.7 CreatePerIterationEnvironment: a `let` head gives each iteration its own binding,
    // so closures capture distinct values.
    try t.expectStr(
        \\var fns=[]; for (let v of ['a','b','c']) fns.push(function(){ return v; });
        \\fns[0]() + fns[1]() + fns[2]()
    , "abc");
}

test "M5 for-in/of: assignment-target heads + [~In] disambiguation (Cycle 1, §14.7.5)" {
    // An existing identifier / member / index assignment target as the loop head.
    try t.expectStr("var i; var s=''; for (i of [1,2,3]) s+=i; s", "123");
    try t.expectNumber("var o={}; for (o.k of [1,2,3]) {} o.k", 3);
    try t.expectNumber("var a=[0,0,0]; var j=0; for (a[j] of [7,8,9]) j++; a[0]+a[1]+a[2]", 24);
    try t.expectStr("var s=''; var x; for (x in {p:1,q:2}) { if (x==='p'||x==='q') s+='y'; } s", "yy");
    // §14.7.5 `[~In]`: `for (a in b)` is for-in, but a *parenthesized* `in` in a C-style header stays
    // a normal relational operator, and `in` inside a subscript is a normal operator too.
    try t.expectNumber("var b={x:1}; var n=0; for (('x' in b); n<2; n++) {} n", 2);
    try t.expectNumber("var a=[10,20]; var o={t:1}; a['t' in o ? 0 : 1]", 10);
    // A multi-declarator C-style `for` (the non-for-in path) is unaffected.
    try t.expectNumber("var s=0; for (var i=0, j=10; i<3; i++) s += i + j; s", 33);
    try t.expectNumber("var s=0; for (var i=0; i<3; i++) s+=i; s", 3);
}

test "M6 Object.defineProperty + getOwnPropertyDescriptor (Cycle 1, §20.1.2.4/.8)" {
    // A defined data property is readable; omitted attributes default to false (§10.1.6.3).
    try t.expectNumber("var o={}; Object.defineProperty(o,'x',{value:5,enumerable:false}); o.x", 5);
    try t.expectNumber("var o={}; Object.defineProperty(o,'x',{value:5}); Object.getOwnPropertyDescriptor(o,'x').value", 5);
    try t.expectBool("var o={}; Object.defineProperty(o,'x',{value:5}); Object.getOwnPropertyDescriptor(o,'x').enumerable", false);
    try t.expectBool("var o={}; Object.defineProperty(o,'x',{value:5}); Object.getOwnPropertyDescriptor(o,'x').writable", false);
    try t.expectBool("var o={}; Object.defineProperty(o,'x',{value:5}); Object.getOwnPropertyDescriptor(o,'x').configurable", false);
    // A non-enumerable own property is skipped by for-in; an enumerable one is visited.
    try t.expectStr("var o={}; Object.defineProperty(o,'x',{value:5,enumerable:false}); o.y=7; var s=''; for(var k in o)s+=k; s", "y");
    // ordinary assignment → all attributes true (round-trips through the descriptor).
    try t.expectBool("var o={}; o.a=1; Object.getOwnPropertyDescriptor(o,'a').enumerable", true);
    try t.expectBool("var o={}; o.a=1; Object.getOwnPropertyDescriptor(o,'a').writable", true);
    // getOwnPropertyDescriptor of an absent property → undefined.
    try t.expectUndefined("Object.getOwnPropertyDescriptor({},'nope')");
    // A getter installed via defineProperty is invoked on read; the descriptor exposes get/set.
    try t.expectNumber("var g={}; Object.defineProperty(g,'v',{get:function(){return 42;}}); g.v", 42);
    try t.expectBool("var g={}; Object.defineProperty(g,'v',{get:function(){return 1;}}); typeof Object.getOwnPropertyDescriptor(g,'v').get === 'function'", true);
    // defineProperties applies each own enumerable descriptor.
    try t.expectNumber("var o={}; Object.defineProperties(o,{a:{value:1},b:{value:2}}); o.a+o.b", 3);
    // Redefining a non-configurable property incompatibly → TypeError.
    try t.expectThrows("var o={}; Object.defineProperty(o,'x',{value:1}); Object.defineProperty(o,'x',{value:2});");
    // ...but an existing property's omitted attributes are preserved (not reset to false).
    try t.expectBool("var o={a:1}; Object.defineProperty(o,'a',{value:2}); Object.getOwnPropertyDescriptor(o,'a').enumerable", true);
}

test "M6 Object.getOwnPropertyNames (Cycle 1, §20.1.2.10)" {
    // Includes a non-enumerable own name.
    try t.expectNumber("var o={a:1}; Object.defineProperty(o,'h',{value:1,enumerable:false}); Object.getOwnPropertyNames(o).length", 2);
    try t.expectBool("var o={a:1}; Object.defineProperty(o,'h',{value:1,enumerable:false}); Object.getOwnPropertyNames(o).indexOf('h') >= 0", true);
    // Array: indices + "length".
    try t.expectStr("Object.getOwnPropertyNames(['p','q']).join(',')", "0,1,length");
}

test "M6 Object.prototype.hasOwnProperty / propertyIsEnumerable / isPrototypeOf (Cycle 1, §20.1.3)" {
    try t.expectBool("({a:1}).hasOwnProperty('a')", true);
    try t.expectBool("({}).hasOwnProperty('a')", false);
    // Inherited (a built-in proto method) is NOT an own property.
    try t.expectBool("({}).hasOwnProperty('toString')", false);
    // Array index/length are own.
    try t.expectBool("[10].hasOwnProperty(0)", true);
    try t.expectBool("[10].hasOwnProperty('length')", true);
    // propertyIsEnumerable honors [[Enumerable]].
    try t.expectBool("var o={a:1}; o.propertyIsEnumerable('a')", true);
    try t.expectBool("var o={}; Object.defineProperty(o,'x',{value:1,enumerable:false}); o.propertyIsEnumerable('x')", false);
    try t.expectBool("[1].propertyIsEnumerable('length')", false);
    // isPrototypeOf walks the chain.
    try t.expectBool("var p={}; var c=Object.create?({}):({}); p.isPrototypeOf({})", false);
    try t.expectBool("var a=[]; Array.prototype.isPrototypeOf(a)", true);
}

test "M6 enumerable-awareness: for-in & spread skip non-enumerable / proto methods (Cycle 1, §7.3.25/§14.7.5)" {
    // for-in over a plain object yields only its own enumerable keys (no Object.prototype methods).
    try t.expectStr("var s=''; for(var k in {a:1}) s+=k; s", "a");
    // for-in over an empty object / empty array yields nothing (built-in protos are non-enumerable).
    try t.expectStr("var s='Z'; for(var k in {}) s+=k; s", "Z");
    try t.expectStr("var s='Z'; for(var k in []) s+=k; s", "Z");
    // object spread copies only own enumerable string keys (order is map-iteration; assert membership).
    try t.expectNumber("var c=0; for(var k in {...{a:1,b:2}}) c++; c", 2);
    try t.expectBool("var spread={...{a:1,b:2}}; spread.hasOwnProperty('a') && spread.hasOwnProperty('b')", true);
    try t.expectStr("var o={}; Object.defineProperty(o,'h',{value:1,enumerable:false}); o.v=2; var s=''; for(var k in {...o}) s+=k; s", "v");
}

test "M6 Function.prototype.call (Cycle 2, §20.2.3.3)" {
    // `this` = thisArg, remaining args forwarded.
    try t.expectNumber("function f(a){return this.x+a} f.call({x:1}, 2)", 3);
    try t.expectNumber("function f(a,b){return this.x+a+b} f.call({x:1}, 2, 3)", 6);
    // No thisArg / no args.
    try t.expectNumber("function f(){return 42} f.call()", 42);
    // `.call` resolves on every function (inherited from %Function.prototype%).
    try t.expectBool("typeof Function.prototype.call === 'function'", true);
    // A built-in method works via .call ([].push.call(obj,...) style — array method on an array-like is
    // M-subset, but the resolution + invocation path is what we assert here).
    try t.expectNumber("function id(x){return x} id.call(null, 7)", 7);
    // Calling .call on a non-function throws.
    try t.expectThrows("Function.prototype.call.call(5)");
}

test "M6 Function.prototype.apply (Cycle 2, §20.2.3.1)" {
    try t.expectNumber("function f(a){return this.x+a} f.apply({x:10}, [5])", 15);
    try t.expectNumber("function f(a,b){return a+b} f.apply(null, [2,3])", 5);
    // null/undefined argArray → no args.
    try t.expectNumber("function f(){return 99} f.apply(null)", 99);
    try t.expectNumber("function f(){return 99} f.apply(null, null)", 99);
    try t.expectNumber("function f(){return 99} f.apply(null, undefined)", 99);
    // array-like (has length + indices) is accepted.
    try t.expectNumber("function f(a,b){return a+b} f.apply(null, {0:4, 1:6, length:2})", 10);
    // a non-object, non-nullish argArray → TypeError.
    try t.expectThrows("function f(){} f.apply(null, 5)");
}

test "M6 Function.prototype.bind (Cycle 2, §20.2.3.2)" {
    // Fixes `this`.
    try t.expectNumber("function f(a){return this.x+a} var g=f.bind({x:100}); g(1)", 101);
    // Partial application: bound args prepend, then call args.
    try t.expectNumber("function f(a){return this.x+a} f.bind({x:1},2)()", 3);
    try t.expectNumber("function f(a,b){return a+b} var g=f.bind(null, 10); g(5)", 15);
    try t.expectNumber("function f(a,b,c){return a+b+c} var g=f.bind(null,1,2); g(3)", 6);
    // The bound function is itself callable and is `typeof "function"`.
    try t.expectBool("typeof (function(){}).bind(null) === 'function'", true);
    // Re-binding a bound function chains the bound args (1 then 2,3 then call 4).
    try t.expectNumber("function f(a,b,c,d){return a+b+c+d} var g=f.bind(null,1).bind(null,2,3); g(4)", 10);
    // A method used as a callback via bind keeps its receiver.
    try t.expectNumber("var o={x:5, get:function(){return this.x}}; var cb=o.get.bind(o); cb()", 5);
}

test "M6 bind + new constructs the target, ignoring bound this (Cycle 2, §10.4.1.2)" {
    // `new` on a bound function constructs the target; bound-this is ignored, bound args prepend.
    try t.expectNumber("function C(a,b){this.s=a+b} var B=C.bind(null, 10); var o=new B(5); o.s", 15);
    try t.expectNumber("function C(a){this.v=a} var B=C.bind({ignored:1}, 7); (new B()).v", 7);
}

test "M6 propertyHelper-style call.bind idiom (Cycle 2, §20.2.3)" {
    // The exact propertyHelper.js line-31 pattern: Function.prototype.call.bind(hasOwnProperty)
    // yields a free function `hasOwn(obj, key)`.
    try t.expectBool("var hasOwn=Function.prototype.call.bind(Object.prototype.hasOwnProperty); hasOwn({a:1},'a')", true);
    try t.expectBool("var hasOwn=Function.prototype.call.bind(Object.prototype.hasOwnProperty); hasOwn({a:1},'b')", false);
}

test "M6 Object.keys/values/entries (Cycle 3, §20.1.2.19/.23/.6)" {
    // keys → own enumerable string keys (insertion order); values → the values; entries → [k,v] pairs.
    try t.expectStr("Object.keys({a:1,b:2}).join()", "a,b");
    try t.expectStr("Object.values({a:1,b:2}).join()", "1,2");
    try t.expectStr("Object.entries({a:1,b:2}).map(function(e){return e[0]+':'+e[1]}).join()", "a:1,b:2");
    // Non-enumerable own props are skipped.
    try t.expectStr("var o={a:1}; Object.defineProperty(o,'h',{value:9,enumerable:false}); Object.keys(o).join()", "a");
    try t.expectNumber("Object.keys({a:1,b:2,c:3}).length", 3);
    // Inherited enumerable keys are NOT included (own-only).
    try t.expectStr("var p={x:1}; var o=Object.create(p); o.y=2; Object.keys(o).join()", "y");
    // Array: own enumerable index keys.
    try t.expectStr("Object.keys(['a','b']).join()", "0,1");
}

test "M6 Object.create (Cycle 3, §20.1.2.2)" {
    // Inherited property via the prototype.
    try t.expectNumber("var o=Object.create({x:1}); o.x", 1);
    // null prototype → no inherited Object.prototype methods.
    try t.expectBool("var o=Object.create(null); o.hasOwnProperty===undefined", true);
    // getPrototypeOf round-trips the supplied proto.
    try t.expectBool("var p={}; var o=Object.create(p); Object.getPrototypeOf(o)===p", true);
    // Second arg defines own properties from a descriptor map.
    try t.expectNumber("var o=Object.create(null,{v:{value:7,enumerable:true}}); o.v", 7);
    try t.expectStr("var o=Object.create({},{a:{value:1,enumerable:true},b:{value:2,enumerable:true}}); Object.keys(o).join()", "a,b");
    // A non-object, non-null proto throws.
    try t.expectThrows("Object.create(5)");
}

test "M6 Object.assign (Cycle 3, §20.1.2.1)" {
    try t.expectStr("Object.keys(Object.assign({},{a:1},{b:2})).join()", "a,b");
    try t.expectNumber("Object.assign({a:1},{a:9,b:2}).a", 9); // later source overwrites
    try t.expectNumber("var t={}; Object.assign(t,{a:1}); t.a", 1);
    try t.expectBool("var t={}; Object.assign(t,{a:1})===t", true); // returns target
    try t.expectNumber("Object.assign({x:1},null,undefined,{y:2}).y", 2); // nullish sources skipped
    // Only own enumerable props are copied (inherited / non-enumerable skipped).
    try t.expectStr("var s=Object.create({inh:1}); s.own=2; Object.keys(Object.assign({},s)).join()", "own");
    try t.expectThrows("Object.assign(null,{})"); // nullish target throws
}

test "M6 Object.getPrototypeOf / setPrototypeOf (Cycle 3, §20.1.2.12/.22)" {
    try t.expectBool("var p={}; var o=Object.create(p); Object.getPrototypeOf(o)===p", true);
    try t.expectBool("Object.getPrototypeOf(Object.create(null))===null", true);
    try t.expectNumber("var o={}; Object.setPrototypeOf(o,{z:5}); o.z", 5);
    try t.expectBool("var o={}; Object.setPrototypeOf(o,null); Object.getPrototypeOf(o)===null", true);
    try t.expectBool("var o={}; Object.setPrototypeOf(o,{})===o", true); // returns O
    try t.expectThrows("Object.setPrototypeOf(null,{})");
    try t.expectThrows("Object.setPrototypeOf({},5)");
}

test "M6 Object.is (Cycle 3, §20.1.2.14 SameValue)" {
    try t.expectBool("Object.is(NaN,NaN)", true);
    try t.expectBool("Object.is(0,-0)", false);
    try t.expectBool("Object.is(-0,-0)", true);
    try t.expectBool("Object.is(1,1)", true);
    try t.expectBool("Object.is('a','a')", true);
    try t.expectBool("Object.is({},{})", false); // distinct objects
    try t.expectBool("var o={}; Object.is(o,o)", true);
    try t.expectBool("Object.is(null,undefined)", false);
}

test "M6 Object.freeze/isFrozen/seal/isSealed/preventExtensions/isExtensible (Cycle 3, §20.1.2)" {
    // freeze: isFrozen true; new props rejected; existing data prop write rejected.
    try t.expectBool("var o={a:1}; Object.freeze(o); Object.isFrozen(o)", true);
    try t.expectBool("var o={a:1}; Object.freeze(o)===o", true); // returns O
    try t.expectNumber("var o={a:1}; Object.freeze(o); o.a=99; o.a", 1); // write silently rejected
    try t.expectBool("var o={a:1}; Object.freeze(o); o.b=2; o.b===undefined", true); // new prop rejected
    try t.expectBool("var o={}; Object.isFrozen(o)", false); // an ordinary extensible object is not frozen
    // seal: isSealed true; not frozen (writes still allowed); new props rejected.
    try t.expectBool("var o={a:1}; Object.seal(o); Object.isSealed(o)", true);
    try t.expectBool("var o={a:1}; Object.seal(o); Object.isFrozen(o)", false); // writable → sealed but not frozen
    try t.expectNumber("var o={a:1}; Object.seal(o); o.a=5; o.a", 5); // write allowed
    try t.expectBool("var o={a:1}; Object.seal(o); o.b=2; o.b===undefined", true); // new prop rejected
    // preventExtensions / isExtensible.
    try t.expectBool("Object.isExtensible({})", true);
    try t.expectBool("var o={}; Object.preventExtensions(o); Object.isExtensible(o)", false);
    try t.expectBool("var o={}; Object.preventExtensions(o); o.x=1; o.x===undefined", true);
    try t.expectBool("var o={}; Object.preventExtensions(o); Object.isFrozen(o)", true); // no props + non-ext → frozen
    // freeze makes the props non-configurable (delete returns false / leaves the prop).
    try t.expectBool("var o={a:1}; Object.freeze(o); delete o.a", false);
    try t.expectNumber("var o={a:1}; Object.freeze(o); delete o.a; o.a", 1);
    // a frozen prop's descriptor is non-writable + non-configurable.
    try t.expectBool("var o={a:1}; Object.freeze(o); Object.getOwnPropertyDescriptor(o,'a').writable", false);
    try t.expectBool("var o={a:1}; Object.freeze(o); Object.getOwnPropertyDescriptor(o,'a').configurable", false);
}

test "M6 Object.getOwnPropertyDescriptors (Cycle 3, §20.1.2.9)" {
    try t.expectNumber("var o={a:1,b:2}; Object.getOwnPropertyDescriptors(o).a.value", 1);
    try t.expectBool("var o={a:1}; Object.getOwnPropertyDescriptors(o).a.enumerable", true);
    try t.expectNumber("var o={a:1}; Object.defineProperty(o,'h',{value:9,enumerable:false}); Object.keys(Object.getOwnPropertyDescriptors(o)).length", 2);
}

test "M14 function length: ExpectedArgumentCount (§20.2.4.1)" {
    try t.expectNumber("function f(a,b){} f.length", 2);
    try t.expectNumber("(function(){}).length", 0);
    try t.expectNumber("(()=>{}).length", 0);
    // §15.1.5: stops at the first default / pattern / rest.
    try t.expectNumber("function f(a,b=1,c){} f.length", 1);
    try t.expectNumber("function f(a,[b],c){} f.length", 1);
    try t.expectNumber("function f(a,...rest){} f.length", 1);
    // accessor lengths: getter 0, setter 1.
    try t.expectNumber("class C{get x(){}} Object.getOwnPropertyDescriptor(C.prototype,'x').get.length", 0);
    try t.expectNumber("class C{set x(v){}} Object.getOwnPropertyDescriptor(C.prototype,'x').set.length", 1);
    // constructor length = constructor param count.
    try t.expectNumber("class C{constructor(a,b){}} C.length", 2);
    // §20.2.4.1 length descriptor: writable:false, enumerable:false, configurable:true.
    try t.expectBool("function f(){} Object.getOwnPropertyDescriptor(f,'length').writable", false);
    try t.expectBool("function f(){} Object.getOwnPropertyDescriptor(f,'length').enumerable", false);
    try t.expectBool("function f(){} Object.getOwnPropertyDescriptor(f,'length').configurable", true);
}

test "M14 function name + NamedEvaluation (§20.2.4.2 / §8.4)" {
    try t.expectStr("function f(a,b){} f.name", "f");
    try t.expectStr("var g = function(){}; g.name", "g"); // NamedEvaluation (named-fn-expr is anon here)
    try t.expectStr("var h = () => {}; h.name", "h"); // arrow NamedEvaluation
    try t.expectStr("let k; k = function(){}; k.name", "k"); // identifier-assignment NamedEvaluation
    try t.expectStr("(function(){}).name", ""); // bare anonymous → ""
    try t.expectStr("(class C{}).name", "C");
    try t.expectStr("var C = class{}; C.name", "C"); // anon class NamedEvaluation
    try t.expectStr("function* gen(){} gen.name", "gen");
    try t.expectStr("async function af(){} af.name", "af");
    // object-literal property value + method.
    try t.expectStr("var o = {f: function(){}}; o.f.name", "f");
    try t.expectStr("var o = {m(){}}; o.m.name", "m");
    // class method / accessor names.
    try t.expectStr("class C{m(a){}} C.prototype.m.name", "m");
    try t.expectStr("class C{get x(){}} Object.getOwnPropertyDescriptor(C.prototype,'x').get.name", "get x");
    try t.expectStr("class C{set x(v){}} Object.getOwnPropertyDescriptor(C.prototype,'x').set.name", "set x");
    // §20.2.4.2 name descriptor: writable:false, enumerable:false, configurable:true.
    try t.expectBool("function f(){} Object.getOwnPropertyDescriptor(f,'name').writable", false);
    try t.expectBool("function f(){} Object.getOwnPropertyDescriptor(f,'name').configurable", true);
    // bound function name (§20.2.3.2).
    try t.expectStr("function f(){} f.bind(null).name", "bound f");
    try t.expectNumber("function f(a,b,c){} f.bind(null,1).length", 2);
}

test "M14 class member attributes: methods non-enumerable, fields enumerable (§15.7.x)" {
    // class methods are NON-enumerable...
    try t.expectBool("class C{m(){}} Object.getOwnPropertyDescriptor(C.prototype,'m').enumerable", false);
    try t.expectBool("class C{static m(){}} Object.getOwnPropertyDescriptor(C,'m').enumerable", false);
    try t.expectBool("class C{get x(){}} Object.getOwnPropertyDescriptor(C.prototype,'x').enumerable", false);
    // ...but OBJECT-literal methods stay ENUMERABLE (ordinary properties).
    try t.expectBool("Object.getOwnPropertyDescriptor({m(){}},'m').enumerable", true);
    try t.expectBool("Object.getOwnPropertyDescriptor({get x(){}},'x').enumerable", true);
    // class fields are enumerable data; the `constructor` slot is non-enumerable.
    try t.expectBool("class C{f=1} Object.getOwnPropertyDescriptor(new C(),'f').enumerable", true);
    try t.expectBool("class C{} Object.getOwnPropertyDescriptor(C.prototype,'constructor').enumerable", false);
}

test "M15 eval: core + direct + indirect (§19.2.1 / §19.2.1.1)" {
    // §19.2.1: the completion value of the parsed Script is eval's result.
    try t.expectNumber("eval(\"1+2\")", 3);
    try t.expectNumber("eval(\"var x=10; x*2\")", 20);
    try t.expectNumber("eval(\"1;2;3\")", 3);
    try t.expectNumber("eval(\"if(true) 7\")", 7);
    try t.expectUndefined("eval(\"var x=5\")"); // a `var` declaration completes with undefined
    try t.expectNumber("eval(\"({x:1}).x\")", 1); // object-literal parse (a leading `{` is an expr here)
    // §19.2.1 step 2: a non-string argument is returned unchanged.
    try t.expectNumber("eval(42)", 42);
    // §19.2.1.1 DIRECT eval reads + writes the caller's locals.
    try t.expectNumber("function f(){ var a=5; return eval(\"a+1\") } f()", 6);
    try t.expectNumber("function f(){ var a=1; eval(\"a=9\"); return a } f()", 9);
    // §19.2.1.1 INDIRECT eval runs in the global env — it cannot see a caller's local `a`.
    try t.expectStr("var e=eval; function f(){ var a=1; try{ e(\"a\"); return \"no\" }catch(x){ return \"ref\" } } f()", "ref");
    // §19.2.1 step 7: a parse error throws a real, catchable SyntaxError.
    try t.expectStr("try{ eval(\"var\") }catch(e){ e.name }", "SyntaxError");
    // globalThis.eval is the same intrinsic (indirect when called off globalThis).
    try t.expectNumber("globalThis.eval(\"2+3\")", 5);
}

test "M16 prototype.constructor back-reference (§19/§20/§22/§23)" {
    // Built-in constructors: <Ctor>.prototype.constructor === <Ctor>, resolved through the chain.
    try t.expectBool("[].constructor === Array", true);
    try t.expectBool("({}).constructor === Object", true);
    try t.expectBool("(function(){}).constructor === Function", true);
    try t.expectBool("\"x\".constructor === String", true);
    try t.expectBool("Array.prototype.constructor === Array", true);
    try t.expectBool("Object.prototype.constructor === Object", true);
    try t.expectBool("Error.prototype.constructor === Error", true);
    try t.expectBool("TypeError.prototype.constructor === TypeError", true);
    // User functions: §10.2.4 MakeConstructor — F.prototype.constructor === F; instances inherit it.
    try t.expectBool("function F(){}; F.prototype.constructor === F", true);
    try t.expectBool("function F(){}; new F().constructor === F", true);
    // Classes: §15.7.14 — C.prototype.constructor === C; instances inherit; derived too.
    try t.expectBool("class C{}; new C().constructor === C", true);
    try t.expectBool("class C{}; C.prototype.constructor === C", true);
    try t.expectBool("class B{}; class D extends B{}; new D().constructor === D", true);
    // A thrown engine error resolves `.constructor` through its prototype (the assert.throws unblock).
    try t.expectBool("(()=>{try{null.x}catch(e){return e.constructor===TypeError}})()", true);
    try t.expectBool("(()=>{try{undefinedVar}catch(e){return e.constructor===ReferenceError}})()", true);
    // The back-reference MUST be non-enumerable (else for-in / Object.keys would surface it).
    try t.expectBool("Object.getOwnPropertyDescriptor(Array.prototype,\"constructor\").enumerable === false", true);
    try t.expectBool("Object.getOwnPropertyDescriptor(Array.prototype,\"constructor\").writable === true", true);
    try t.expectBool("Object.getOwnPropertyDescriptor(Array.prototype,\"constructor\").configurable === true", true);
    try t.expectBool("Object.getOwnPropertyDescriptor((function F(){}).prototype,\"constructor\").enumerable === false", true);
    // A Test262-style assert.throws mini-harness: it checks `thrown.constructor === expected`.
    try t.expectBool(
        \\function throwsRightCtor(Ctor, fn){
        \\  try { fn(); } catch(e){ return e.constructor === Ctor; }
        \\  return false;
        \\}
        \\throwsRightCtor(TypeError, function(){ null.x })
    , true);
}

test "M23 IdentifierName unicode escapes — basic decode + binding (§12.7.1)" {
    // `\uHHHH` / `\u{H…}` at identifier start and parts; decoded StringValue is the name.
    try t.expectNumber("var \\u{62}=9; b", 9);
    try t.expectNumber("var \\u0062 = 7; b", 7);
    try t.expectNumber("var b = 7; \\u{62}", 7); // an escaped USE resolves to the same binding
    try t.expectNumber("var a\\u{62}c = 4; abc", 4); // escape in a PART
    try t.expectNumber("var $\\u{30} = 8; $0", 8); // §12.7 ID_Continue digit via escape (`$0`)
    // Member access with an escaped IdentifierName (`a.if` — reserved words OK as property names).
    try t.expectNumber("var o = { a: 5 }; o.\\u{61}", 5);
    try t.expectNumber("var o = { if: 3 }; o.\\u{69}f", 3);
}

test "M23 IdentifierName escapes in class fields + private names (§12.7.1 / §15.7)" {
    try t.expectNumber("class C { \\u{6F} = 5; m(){ return this.o; } } new C().m()", 5);
    try t.expectNumber("class C { #\\u{78} = 6; g(){ return this.#x; } } new C().g()", 6);
}

test "M23 escaped ReservedWord → SyntaxError (§12.7.1 / §12.7.2)" {
    // §12.7.2 ReservedWord spelled with an escape is a SyntaxError (keyword-table + dedicated set).
    try t.expectSyntaxError("var \\u{69}f = 1;"); // if
    try t.expectSyntaxError("var \\u{76}ar = 1;"); // var
    try t.expectSyntaxError("\\u0066or (;;) {}"); // for
    try t.expectSyntaxError("var \\u0065xport = 1;"); // export (absent from the keyword table)
    try t.expectSyntaxError("var \\u{65}num = 1;"); // enum
    try t.expectSyntaxError("\\u0077ith (o) {}"); // with
    try t.expectSyntaxError("d\\u0065bugger;"); // debugger
}

test "M23 escaped yield/await are identifiers in sloppy (§12.7.1 exception)" {
    // §12.7.1: `yield`/`await` are NOT ReservedWords for this rule — an escaped spelling is OK as an
    // identifier in sloppy mode.
    try t.expectNumber("var \\u{79}ield = 5; yield", 5);
    try t.expectNumber("var \\u{61}wait = 4; await", 4);
}

test "M23 ID_Start / ID_Continue validation of escaped code points (§12.7)" {
    // Invalid IdentifierStart / IdentifierPart code points reached via escape → SyntaxError.
    try t.expectSyntaxError("var \\u2E2F;"); // VERTICAL TILDE (U+2E2F): Lm but Pattern_Syntax — not ID_Start
    try t.expectSyntaxError("var a\\u2E2F;"); // …nor ID_Continue
    try t.expectSyntaxError("var \\u200C;"); // ZWNJ (U+200C): not ID_Start
    try t.expectSyntaxError("var \\u200D;"); // ZWJ (U+200D): not ID_Start
    // Accepted: grandfathered Other_ID_Start, Kelvin, ZWNJ/ZWJ as PARTS, astral letter.
    try t.expectNumber("var \\u2118 = 3; \\u2118", 3); // SCRIPT CAPITAL P
    try t.expectNumber("var \\u212A = 1; \\u212A", 1); // KELVIN SIGN
    try t.expectNumber("var a\\u200C = 2; a\\u200C", 2); // ZWNJ valid as ID_Continue
    try t.expectNoSyntaxErrorStrict("var \\u{10840};"); // astral IMPERIAL ARAMAIC ALEPH
}

test "M25 raw non-ASCII Unicode identifiers — binding + use (§12.7)" {
    // Raw `é` (U+00E9) as an IdentifierPart.
    try t.expectNumber("var café = 1; café", 1);
    // Raw é and `\u{e9}` escape decode to the same StringValue → same binding.
    try t.expectNumber("var café = 5; caf\\u{e9}", 5);
    try t.expectNumber("var caf\\u{e9} = 7; café", 7);
    // A raw-Unicode identifier whose ASCII look-alike is not declared is `undefined` (distinct name).
    try t.expectBool("var café = 1; typeof cafe === 'undefined'", true);
    // Raw ID_Start letters: Greek Ω (U+03A9), SCRIPT CAPITAL P ℘ (U+2118, Other_ID_Start).
    try t.expectNumber("var Ω = 3; Ω", 3);
    try t.expectNumber("var ℘ = 4; ℘", 4);
    // ZWNJ (U+200C) / ZWJ (U+200D) are valid raw ID_Continue (must NOT be eaten as whitespace).
    try t.expectNumber("var a\u{200c}b = 8; a\u{200c}b", 8);
}
