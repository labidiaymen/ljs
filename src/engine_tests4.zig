//! Engine unit tests (split from engine_tests.zig to keep files < 1000 lines). All shared symbols
//! (helpers + evaluate/t.Value/...) are referenced via the `t.` prefix off engine_tests.zig.
const t = @import("engine_tests.zig");
const std = @import("std");

test "M25 raw Unicode private names + property names (§15.7 / §12.7)" {
    // Raw ℘ (U+2118) as a private name.
    try t.expectNumber("class C{ #℘ = 5; get(){ return this.#℘; } } new C().get()", 5);
    // Raw é private name round-trips with the `\u` spelling of the same code point.
    try t.expectNumber("class C{ #café = 9; g(){ return this.#caf\\u{e9}; } } new C().g()", 9);
    // Raw member access `o.℘` resolves the same property as the computed `o[\"℘\"]`.
    try t.expectNumber("var o = {}; o[\"℘\"] = 6; o.℘", 6);
    try t.expectNumber("var o = {}; o.℘ = 7; o[\"℘\"]", 7);
}

test "M25 Unicode WhiteSpace + LineTerminators in skipTrivia (§12.2 / §12.3)" {
    // Raw NBSP (U+00A0) between tokens is WhiteSpace — skipped like a space (`var<NBSP>x=1; x`).
    try t.expectNumber("var\u{00a0}x = 1; x", 1);
    // U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR are LineTerminators: each separates two
    // statements via ASI (no explicit `;`), so all three bindings are in scope for `a + b + c`.
    try t.expectNumber("var a = 1\u{2028}var b = 2\u{2029}var c = 3\na + b + c", 6);
    // IDEOGRAPHIC SPACE (U+3000) and BOM/ZWNBSP (U+FEFF) are also WhiteSpace.
    try t.expectNumber("var\u{3000}y\u{feff}= 2; y", 2);
}

test "M23 escaped contextual keywords are not the keyword (§12.7.1)" {
    // A contextual keyword spelled with an escape is the plain identifier — these grammar positions
    // then become SyntaxErrors (the keyword form is required verbatim).
    try t.expectSyntaxError("for (var x o\\u0066 []) ;"); // escaped `of`
    try t.expectSyntaxError("({ \\u0067\\u0065\\u0074 m() {} });"); // escaped `get`
    try t.expectSyntaxError("\\u0061sync function f(){}"); // escaped `async` function decl
    try t.expectSyntaxError("void \\u0061sync function f(){}"); // escaped `async` function expr
    // §13.15.1: escaped strict-reserved word as an IdentifierReference dstr target (strict) → error.
    try t.expectSyntaxErrorStrict("var x = { l\\u0065t } = { let: 42 };");
    // §12.9.3: a NumericLiteral may not be immediately followed by an IdentifierStart (incl. `\\u`).
    try t.expectSyntaxError("0\\u00620;");
}

test "M26 arguments is iterable (§10.4.4 / §22.1.5)" {
    // §10.4.4.7: the `arguments` object has @@iterator = %Array.prototype.values%, so it spreads
    // and for-of's over its indexed elements.
    try t.expectNumber("function f(){ return [...arguments].length } f(1,2,3)", 3);
    try t.expectNumber("function f(){ var s=0; for (var x of arguments) s+=x; return s } f(1,2,3)", 6);
    // Spread preserves order/values.
    try t.expectNumber("function f(){ return [...arguments][1] } f(10,20,30)", 20);
    // Zero args → empty iteration.
    try t.expectNumber("function f(){ return [...arguments].length } f()", 0);
    // Still an ordinary object, NOT an Array exotic.
    try t.expectBool("function f(){ return Array.isArray(arguments) } f(1)", false);
    // arguments[Symbol.iterator] is the array values native (callable, non-enumerable).
    try t.expectBool("function f(){ return typeof arguments[Symbol.iterator] === 'function' } f()", true);
    // A generator function's `arguments` is iterable too.
    try t.expectNumber("function* g(){ yield [...arguments].length } g(1,2).next().value", 2);
}

test "M26 object-literal __proto__ sets [[Prototype]] (§B.3.1)" {
    // `{__proto__: p}` (literal colon name) sets the prototype, no own `__proto__` property.
    try t.expectNumber("var p={x:1}; var o={__proto__:p}; o.x", 1);
    try t.expectBool("var p={x:1}; var o={__proto__:p}; o.hasOwnProperty('__proto__')", false);
    try t.expectBool("var p={x:1}; var o={__proto__:p}; Object.getPrototypeOf(o)===p", true);
    // `{__proto__: null}` → a null-prototype object.
    try t.expectBool("Object.getPrototypeOf({__proto__:null})===null", true);
    // A primitive value is IGNORED: prototype unchanged, no own `__proto__` property.
    try t.expectBool("var o={__proto__:5}; Object.getPrototypeOf(o)===Object.prototype && !o.hasOwnProperty('__proto__')", true);
    // A string literal name `"__proto__":` is also the proto setter (§B.3.1).
    try t.expectBool("var p={x:1}; var o={\"__proto__\":p}; Object.getPrototypeOf(o)===p", true);
    // A COMPUTED `{['__proto__']: v}` is an ORDINARY own property (proto NOT set).
    try t.expectNumber("({['__proto__']:7}).__proto__", 7);
    try t.expectBool("var o={['__proto__']:7}; o.hasOwnProperty('__proto__')", true);
    // §B.3.1 Early Error: two `__proto__:` colon-properties is a SyntaxError.
    try t.expectSyntaxError("({__proto__:1, __proto__:2})");
    try t.expectSyntaxError("({__proto__:1, \"__proto__\":2})");
    // But mixing a proto setter with a computed `__proto__` is NOT a duplicate (different definitions).
    try t.expectNoSyntaxErrorStrict("var o = ({__proto__:{}, ['__proto__']:2});");
}

test "M27 NamedEvaluation on destructuring/param defaults (§8.6.2 / §13.15.5.2 / §15.1.3)" {
    // §15.1.3: a SingleNameBinding parameter default that is an anonymous fn/arrow/class
    // takes the parameter name.
    try t.expectStr("function f(cb = function(){}){ return cb.name } f()", "cb");
    try t.expectStr("function f(ar = () => {}){ return ar.name } f()", "ar");
    try t.expectStr("function f(c = class{}){ return c.name } f()", "c");
    // §13.3.3.7 object binding-pattern property default → property-target identifier name.
    try t.expectStr("function f({fn = function(){}}){ return fn.name } f({})", "fn");
    try t.expectStr("function f({af = () => {}}){ return af.name } f({})", "af");
    try t.expectStr("function f({gn = function*(){}}){ return gn.name } f({})", "gn");
    // `key: target = default` form names after the target binding, not the key.
    try t.expectStr("function f({k: t = function(){}}){ return t.name } f({})", "t");
    // §8.6.2 array binding-pattern element default → element-target identifier name.
    try t.expectStr("function f([x = function(){}]){ return x.name } f([])", "x");
    try t.expectStr("function f([y = () => {}]){ return y.name } f([])", "y");
    // var/let binding declarations with destructuring defaults.
    try t.expectStr("var {vn = function(){}} = {}; vn.name", "vn");
    try t.expectStr("var [vy = function(){}] = []; vy.name", "vy");
    // §13.15.5.2 assignment patterns (not declarations) name the same way.
    try t.expectStr("var bn; ({bn = function(){}} = {}); bn.name", "bn");
    try t.expectStr("var by; [by = function(){}] = []; by.name", "by");
    // A NAMED function default keeps its own name (NOT renamed to the binding id).
    try t.expectStr("function f({z = function named(){}}){ return z.name } f({})", "named");
    // When the value IS provided (default not used), the bound value is NOT renamed.
    // (An anonymous fn passed as an array element has name "" and stays "".)
    try t.expectStr("function f({w = function(){}}){ return w.name } var a=[function(){}]; f({w:a[0]})", "");
}

test "M28 for-of/for-in head is a DestructuringAssignment pattern (§14.7.5.6 / §13.15.5)" {
    // §14.7.5.6 ForIn/OfBodyEvaluation, lhsKind = assignment: an ArrayLiteral / ObjectLiteral head is
    // refined to an AssignmentPattern (no `var`/`let`/`const`) and assigned each iteration.
    try t.expectNumber("var a, b; for ([a, b] of [[1, 2]]) {} a * 10 + b", 12);
    try t.expectNumber("var a; for ({a} of [{a: 5}]) {} a", 5);
    try t.expectNumber("var a, b; for ({x: a, y: b} of [{x: 3, y: 4}]) {} a * 10 + b", 34);
    // element default applies when the matched value is undefined.
    try t.expectNumber("var a; for ([a = 9] of [[]]) {} a", 9);
    // member / index targets (PutValue into an existing reference).
    try t.expectNumber("var o = {}; var arr = [0]; for ([o.p, arr[0]] of [[3, 4]]) {} o.p * 10 + arr[0]", 34);
    // nested pattern + rest in the head.
    try t.expectNumber("var a, r; for ([a, ...r] of [[1, 2, 3]]) {} a + r.length", 3);
    // for-in over an object's keys with a pattern head.
    try t.expectStr("var k; var out = ''; for ([k] of [['x'], ['y']]) { out += k; } out", "xy");
    // §13.15.1: a PARENTHESIZED literal head is NOT the cover grammar → SyntaxError.
    try t.expectSyntaxError("var a; for (({a}) of [{a: 1}]) {}");
    // §13.15.5.3 IteratorClose: an abrupt element (a throwing default) closes the not-done iterator.
    const close_on_throw =
        \\var closeCount = 0;
        \\var iter = { [Symbol.iterator]() { return {
        \\  next() { return { value: undefined, done: false }; },
        \\  return() { closeCount++; return {}; }
        \\}; } };
        \\var a;
        \\try { for ([a = (function(){ throw 'boom'; })()] of [iter]) {} } catch (e) {}
        \\closeCount
    ;
    try t.expectNumber(close_on_throw, 1);
}

test "M28 object binding-pattern computed & numeric/string property names (§14.3.3)" {
    // numeric PropertyName → ToString'd key.
    try t.expectNumber("var { 0: v } = [7]; v", 7);
    try t.expectNumber("var { 1: v } = [7, 8]; v", 8);
    // computed PropertyName `{ [expr]: target }` — evaluated (ToPropertyKey) at bind time.
    try t.expectNumber("var k = 'a'; var { [k]: v } = { a: 9 }; v", 9);
    try t.expectStr("var s = Symbol('s'); var o = {}; o[s] = 'hi'; var { [s]: v } = o; v", "hi");
    // a keyword IdentifierName is a valid (colon) PropertyName: `{ if: x }`.
    try t.expectNumber("var { if: v } = { if: 5 }; v", 5);
    // §14.3.3 with a rest: an explicit computed key is excluded from the rest copy.
    try t.expectNumber("var k = 'a'; var { [k]: v, ...r } = { a: 1, b: 2, c: 3 }; v * 100 + r.b + r.c", 105);
    // computed key in a for-of head binding, and a rest-with-nested-object-pattern element.
    try t.expectNumber("var sum = 0; for (var { [String(0)]: x } of [{ 0: 4 }, { 0: 6 }]) { sum += x; } sum", 10);
    try t.expectNumber("var [...{ 0: a, length: n }] = [7, 8, 9]; a * 10 + n", 73);
    // §13.2.5 ComputedPropertyName evaluation order: a throwing key expression propagates.
    try t.expectThrows("var { [(function(){ throw new Error('k'); })()]: x } = {};");
    // a string/numeric/computed PropertyName has NO shorthand form (must carry a `:`).
    try t.expectSyntaxError("var { 0 } = [1];");
    try t.expectSyntaxError("var { [k] } = {};");
}

test "M28 for-of over a custom iterable closes on break/throw (§7.4.11 IteratorClose)" {
    // §14.7.5.6: a `break` from a for-of body is an abrupt completion → IteratorClose (return()).
    const close_on_break =
        \\var closeCount = 0;
        \\var iter = { [Symbol.iterator]() { var n = 0; return {
        \\  next() { return { value: n++, done: false }; },
        \\  return() { closeCount++; return {}; }
        \\}; } };
        \\for (var v of iter) { if (v === 2) break; }
        \\closeCount
    ;
    try t.expectNumber(close_on_break, 1);
    // §7.4.4 IteratorStep: a next() result that is not an Object is a TypeError.
    const bad_result =
        \\var iter = { [Symbol.iterator]() { return { next() { return 42; } }; } };
        \\var ok = false;
        \\try { for (var v of iter) {} } catch (e) { ok = e instanceof TypeError; }
        \\ok
    ;
    try t.expectBool(bad_result, true);
    // §7.4.2: for-of over a String iterates its elements, binding each to the loop variable.
    try t.expectStr("var out = ''; for (var c of 'abc') out = c + out; out", "cba");
}

test "M29 ToPrimitive — valueOf/toString invoked in operator coercion (§7.1.1 / §7.1.1.1)" {
    // §13.15.3 `+` numeric: a `valueOf`-bearing object coerces to its number.
    try t.expectNumber("({valueOf: function(){ return 5; }}) + 1", 6);
    // §13.15.3 `+` string: a `toString`-bearing object concatenates as its string.
    try t.expectStr("({toString: function(){ return \"x\"; }}) + \"y\"", "xy");
    // §7.1.1.1: number hint tries valueOf first (so this is 2, not "01").
    try t.expectNumber("({valueOf: function(){return 1;}, toString: function(){return 0;}}) + 1", 2);
    // §23.1.3.36: an Array's ToPrimitive(string via toString) joins its elements.
    try t.expectStr("[1,2] + \"\"", "1,2");
    // §7.2.15: abstract equality coerces the object operand (toString → "x").
    try t.expectBool("({toString: function(){ return \"x\"; }}) == \"x\"", true);
    // §7.2.13: relational comparison ToPrimitive(number)s the object.
    try t.expectBool("({valueOf: function(){ return 3; }}) < 5", true);
    // §13.5.5 unary minus + §13.4 update run ToNumber (valueOf).
    try t.expectNumber("-({valueOf: function(){ return 4; }})", -4);
    // §7.1.1 step 2: @@toPrimitive takes precedence and receives the hint string.
    try t.expectNumber("({[Symbol.toPrimitive]: function(h){ return h === \"number\" ? 42 : 0; }}) - 0", 42);
    // §7.1.1.1: neither valueOf nor toString yielding a primitive → TypeError.
    try t.expectThrows("({valueOf: function(){return {};}, toString: function(){return {};}}) + 1");
}

test "M30 generator param FunctionDeclarationInstantiation is eager — call-time, not .next (§15.5.2 / §15.6.2)" {
    // A throwing destructuring default in a SYNC generator method throws at the CALL site (param
    // binding runs eagerly in [[Call]], before the generator object is returned / first `.next`).
    try t.expectThrows(
        \\function* g([x = (function(){ throw new Error("boom"); })()]) {}
        \\g([undefined]);
    );
    // A throwing default in an ASYNC GENERATOR throws synchronously at the call site too (V8 parity).
    try t.expectThrows(
        \\async function* ag([x = (function(){ throw new Error("boom"); })()]) {}
        \\ag([undefined]);
    );
    // Binding really happens BEFORE the body runs: a side effect in a default param fires at call
    // time, even though the generator is never resumed (`.next` never called).
    try t.expectBool(
        \\var ran = false;
        \\function* g(x = (function(){ ran = true; return 1; })()) { yield x; }
        \\g(); // create only — do NOT call .next
        \\ran;
    , true);
    // Destructuring a non-iterable as a generator param is a call-time TypeError (eager binding).
    try t.expectThrows(
        \\function* g([x]) {}
        \\g(null);
    );
    // The bound params are still correct once the body runs (no regression): destructuring + default.
    try t.expectNumber(
        \\function* g([a, b = 10]) { yield a + b; }
        \\g([5]).next().value;
    , 15);
    // A plain (non-generator) function with the same throwing default still throws at the call — the
    // refactor must not change ordinary [[Call]] semantics.
    try t.expectThrows(
        \\function f([x = (function(){ throw new Error("boom"); })()]) {}
        \\f([undefined]);
    );
}

test "M29 primitive wrapper objects unbox in coercion (§21.1.4.1 / §22.1.4.1 / §20.3.4.1)" {
    // §21.1.3.3 thisNumberValue: a Number wrapper coerces back to its primitive.
    try t.expectNumber("new Number(5) + 0", 5);
    try t.expectNumber("Number(new Number(7))", 7);
    // §22.1.3.32: a String wrapper coerces / unboxes via valueOf.
    try t.expectStr("new String(\"ab\") + \"\"", "ab");
    try t.expectStr("new String(\"hi\").valueOf()", "hi");
    // §20.3.3.3: a Boolean wrapper unboxes (true → 1 in numeric `+`).
    try t.expectNumber("new Boolean(true) + 0", 1);
    try t.expectBool("new Boolean(false).valueOf()", false);
    // §7.2.15: `new Number(5) == "5"` (number↔string after unboxing).
    try t.expectBool("new Number(5) == \"5\"", true);
}

test "M31: §10.2.5 MethodDefinition functions have no own `.prototype`" {
    // §15.4 / §10.2.5 MakeMethod: a class/object method, getter, setter, or async (non-generator)
    // method is NOT a constructor — it has no own `prototype` property.
    try t.expectBool("class C { m(){} } ('prototype' in C.prototype.m)", false);
    try t.expectBool("class C { static sm(){} } ('prototype' in C.sm)", false);
    try t.expectBool("class C { async m(){} } ('prototype' in C.prototype.m)", false);
    try t.expectBool("class C { get g(){return 1} } ('prototype' in Object.getOwnPropertyDescriptor(C.prototype,'g').get)", false);
    try t.expectBool("var o={m(){}}; ('prototype' in o.m)", false);
    try t.expectBool("var o={get g(){return 1}}; ('prototype' in Object.getOwnPropertyDescriptor(o,'g').get)", false);
    // §15.8: an async function (declaration / expression, non-generator) likewise has no `.prototype`.
    try t.expectBool("async function af(){}; ('prototype' in af)", false);
    try t.expectBool("var ae=async function(){}; ('prototype' in ae)", false);
    // §15.3: an arrow is not a constructor either.
    try t.expectBool("var a=()=>{}; ('prototype' in a)", false);
    // A generator / async-generator method IS a GeneratorFunction → it DOES keep `.prototype`.
    try t.expectBool("class C { *m(){} } ('prototype' in C.prototype.m)", true);
    try t.expectBool("class C { async *m(){} } ('prototype' in C.prototype.m)", true);
    // A plain function / generator / class constructor keeps `.prototype`.
    try t.expectBool("function f(){}; ('prototype' in f) && f.prototype.constructor===f", true);
    try t.expectBool("function* g(){}; ('prototype' in g)", true);
    try t.expectBool("class C{}; ('prototype' in C)", true);
    // `new` still works on plain functions and classes.
    try t.expectBool("function f(){} new f() instanceof f", true);
    try t.expectBool("class C{} new C() instanceof C", true);
}

test "M31: §15.7.14 base class `C.prototype.[[Prototype]]` is %Object.prototype%" {
    // §15.7.14 step 6.a: a base class (no `extends`) has protoParent = %Object.prototype%.
    try t.expectBool("class C{}; Object.getPrototypeOf(C.prototype)===Object.prototype", true);
    try t.expectStr("class C{}; typeof C.prototype.hasOwnProperty", "function");
    // A derived class chains to the superclass's `.prototype`.
    try t.expectBool("class C{}; class D extends C{}; Object.getPrototypeOf(D.prototype)===C.prototype", true);
}

test "M32: §14.3.1 `using` disposes at block exit (LIFO, normal + abrupt)" {
    // Dispose runs at block exit, after the body — completion is "body,d".
    try t.expectStr(
        "var log=[]; { using x = { [Symbol.dispose](){ log.push('d'); } }; log.push('body'); } log.join(',')",
        "body,d",
    );
    // Two `using` in one block dispose in REVERSE (LIFO) order: b then a.
    try t.expectStr(
        "var log=[]; { using a = { [Symbol.dispose](){ log.push('a'); } }, b = { [Symbol.dispose](){ log.push('b'); } }; } log.join(',')",
        "b,a",
    );
    // Dispose runs on an early `throw` out of the block (try/catch around the using block).
    try t.expectBool(
        "var d=false; try { { using x = { [Symbol.dispose](){ d=true; } }; throw 1; } } catch(e){} d",
        true,
    );
    // `using y = null` is a no-op (no dispose, no throw) and the block runs normally.
    try t.expectStr("var log=[]; { using y = null; log.push('ok'); } log.join(',')", "ok");
    // The `this` inside the disposer is the resource value.
    try t.expectBool(
        "var ok=false; var r={ [Symbol.dispose](){ ok = (this===r); } }; { using x = r; } ok",
        true,
    );
}

test "M32: §14.3.1 `using` is a const-like immutable binding; values readable in-block" {
    // The binding holds the initialized value within the block.
    try t.expectNumber("var v; { using x = { val: 7, [Symbol.dispose](){} }; v = x.val; } v", 7);
    // `Symbol.dispose` / `Symbol.asyncDispose` are well-known symbols (same identity as a property read).
    try t.expectBool("typeof Symbol.dispose === 'symbol' && typeof Symbol.asyncDispose === 'symbol'", true);
}

test "M32: §ER non-callable / missing `[Symbol.dispose]` is a TypeError" {
    // A non-callable @@dispose property → TypeError.
    try t.expectStr(
        "var n; try { { using x = { [Symbol.dispose]: 1 }; } } catch(e){ n = e.name; } n",
        "TypeError",
    );
    // An object with NO @@dispose method → TypeError.
    try t.expectStr(
        "var n; try { { using x = {}; } } catch(e){ n = e.name; } n",
        "TypeError",
    );
}

test "M32: §20.5.8 SuppressedError aggregation (last disposer error wraps the prior completion)" {
    // A body throw + a disposer throw aggregate into SuppressedError { error: disposerErr, suppressed: bodyErr }.
    try t.expectStr(
        "var n; try { { using a = { [Symbol.dispose](){ throw 'da'; } }; throw 'body'; } } catch(e){ n = (e instanceof SuppressedError) ? e.error+','+e.suppressed : 'plain'; } n",
        "da,body",
    );
    // A single disposer error (no pending completion) rethrows as-is (no SuppressedError wrapper).
    try t.expectBool(
        "var plain=false; try { { using a = { [Symbol.dispose](){ throw new TypeError('x'); } }; } } catch(e){ plain = (e instanceof TypeError); } plain",
        true,
    );
}

test "M32: §14.3.1 `using` is a CONTEXTUAL keyword (identifier elsewhere)" {
    // `var using = 5; using` → 5 — `using` is an ordinary identifier when not heading a declaration.
    try t.expectNumber("var using = 5; using", 5);
    // `using` not followed by a same-line BindingIdentifier is an ordinary identifier reference.
    try t.expectNumber("var using = 3; using + 1", 4);
    // `using` followed by a LineTerminator then an identifier is two statements (ASI), not a decl:
    // `using` is read as the identifier (7), then `r = using` assigns it.
    try t.expectNumber("var using = 7, r; using\nr = using; r", 7);
    // A `using`-headed declaration at the top level of a Script is a SyntaxError (must be in a Block/etc.).
    try t.expectSyntaxError("using x = null;");
    // `using x = …` is allowed inside a block.
    try t.expectStr("var log=[]; { using x = { [Symbol.dispose](){ log.push('d'); } }; } log.join(',')", "d");
}

test "M35: §12.5 HashbangComment — `#!` at source start is a line comment" {
    // A `#!` at the very start of the Script runs to end of line, like `//`.
    try t.expectNumber("#!/usr/bin/env node\n42", 42);
    // The hashbang line is fully ignored; the next line evaluates normally.
    try t.expectNumber("#!shebang ignored 1 + ( garbage\nlet x = 40; x + 2", 42);
    // A bare `#!` with no following newline (whole source is the hashbang) → empty program (undefined).
    try t.expectUndefined("#!only-a-hashbang");
    // §12.5: a `#!` NOT at offset 0 is NOT a hashbang — leading whitespace disqualifies it, and `#`
    // there is a PrivateIdentifier outside any class → SyntaxError.
    try t.expectSyntaxError(" #!/usr/bin/env node\n42");
    // A `#!` after a newline is likewise not a hashbang (offset != 0) → SyntaxError.
    try t.expectSyntaxError("\n#!/usr/bin/env node\n42");
}

test "M35: §13.3.5 SuperProperty in object-literal methods / accessors" {
    // An object-literal method has a [[HomeObject]] (the object), so `super.x` resolves against its
    // prototype. Here `o`'s proto is %Object.prototype%, so `super.hasOwnProperty` is a function.
    try t.expectBool("var o = { m(){ return typeof super.hasOwnProperty === 'function'; } }; o.m()", true);
    // `super.x` reads the prototype's property, not the object's own shadowing one.
    try t.expectNumber(
        "var proto = { v: 1 }; var o = { v: 99, m(){ return super.v; } }; Object.setPrototypeOf(o, proto); o.m()",
        1,
    );
    // Computed `super[k]` works in an object method too.
    try t.expectNumber(
        "var proto = { v: 7 }; var o = { m(){ return super['v']; } }; Object.setPrototypeOf(o, proto); o.m()",
        7,
    );
    // A getter has a [[HomeObject]] as well — `super.x` is allowed inside it.
    try t.expectNumber(
        "var proto = { v: 5 }; var o = { get g(){ return super.v; } }; Object.setPrototypeOf(o, proto); o.g",
        5,
    );
    // §13.3.7: `super(...)` is NOT allowed in an object method (not a derived constructor) → SyntaxError.
    try t.expectSyntaxError("var o = { m(){ return super(); } };");
}

test "M35: §13.3.12 new.target meta-property" {
    // Called via `new`, `new.target` is the constructor function. (A `new` call discards a primitive
    // body return and yields the instance, so capture the result on the instance / via a global.)
    try t.expectBool("function C(){ this.t = new.target; } (new C()).t === C", true);
    // Called ordinarily, `new.target` is undefined.
    try t.expectBool("function f(){ return new.target === undefined; } f()", true);
    // An arrow inherits the enclosing function's new.target lexically.
    try t.expectBool("function C(){ var g = () => new.target; this.t = g(); } (new C()).t === C", true);
    try t.expectBool("function f(){ var g = () => new.target; return g() === undefined; } f()", true);
    // A nested ordinary call inside a constructed body sees its OWN new.target (undefined), not the
    // enclosing one (no leak through the call boundary).
    try t.expectBool("var inner; function g(){ inner = new.target; } function C(){ g(); } new C(); inner === undefined", true);
    // §13.3.12.1: `new.target` outside any function body (Script top level) is a SyntaxError.
    try t.expectSyntaxError("new.target");
    try t.expectSyntaxErrorStrict("new.target;");
    // `new` `.` followed by anything other than `target` is a SyntaxError.
    try t.expectSyntaxError("function f(){ return new.foo; }");
    // `new.target` propagates down a `super(...)` chain — the base ctor sees the derived target.
    try t.expectBool(
        "var nt; class A { constructor(){ nt = new.target; } } class B extends A {} new B(); nt === B",
        true,
    );
}

test "M36: §6.1.6.2 BigInt — literals, typeof, ToBoolean" {
    try t.expectStr("typeof 1n", "bigint");
    try t.expectStr("typeof BigInt(5)", "bigint");
    // §12.9.3.2 radix literals
    try t.expectBool("0xFFn === 255n", true);
    try t.expectBool("0o17n === 15n", true);
    try t.expectBool("0b1010n === 10n", true);
    try t.expectBool("123_456n === 123456n", true); // separators
    // §7.1.2 ToBoolean
    try t.expectBool("Boolean(0n)", false);
    try t.expectBool("Boolean(1n)", true);
    try t.expectBool("!0n", true);
    // §12.9.3.2: `n` after a fraction / exponent / non-octal-decimal is a SyntaxError.
    try t.expectSyntaxError("1.5n");
    try t.expectSyntaxError("1e2n");
    try t.expectSyntaxError("08n");
}

test "M36: §6.1.6.2 BigInt — arithmetic (both operands BigInt)" {
    try t.expectBool("1n + 2n === 3n", true);
    try t.expectBool("10n * 10n === 100n", true);
    try t.expectBool("7n / 2n === 3n", true); // truncates toward zero
    try t.expectBool("-7n / 2n === -3n", true);
    try t.expectBool("7n % 3n === 1n", true);
    try t.expectBool("-7n % 3n === -1n", true); // remainder follows the dividend's sign
    try t.expectBool("2n ** 10n === 1024n", true);
    try t.expectBool("5n - 8n === -3n", true);
    // bitwise + shifts (two's-complement infinite semantics)
    try t.expectBool("(12n & 10n) === 8n", true);
    try t.expectBool("(12n | 10n) === 14n", true);
    try t.expectBool("(12n ^ 10n) === 6n", true);
    try t.expectBool("(1n << 64n) === 18446744073709551616n", true);
    try t.expectBool("(-1n >> 1n) === -1n", true);
    try t.expectBool("~0n === -1n", true);
    try t.expectBool("-(5n) === -5n", true);
    // huge values stay exact (beyond f64 precision)
    try t.expectBool("9007199254740993n + 1n === 9007199254740994n", true);
}

test "M36: §6.1.6.2 BigInt — errors (mixing, /0n, **-, >>>, unary +)" {
    try t.expectThrows("1n + 1"); // §13.15.3 mixing BigInt + Number → TypeError
    try t.expectThrows("1 - 1n");
    try t.expectThrows("1n & 1");
    try t.expectThrows("1n / 0n"); // RangeError: division by zero
    try t.expectThrows("1n % 0n");
    try t.expectThrows("2n ** -1n"); // RangeError: negative exponent
    try t.expectThrows("1n >>> 1n"); // TypeError: no unsigned right shift for BigInt
    try t.expectThrows("+1n"); // TypeError: unary + on a BigInt
    try t.expectThrows("new BigInt(1)"); // TypeError: BigInt is not a constructor
}

test "M36: §7.2.13/§7.2.15 BigInt comparisons (cross-type)" {
    try t.expectBool("1n == 1", true); // loose == compares numerically
    try t.expectBool("1n === 1", false); // strict === is false across types
    try t.expectBool("1n == 1.0", true);
    try t.expectBool("1n == 1.5", false);
    try t.expectBool("1n == '1'", true); // string side parsed
    try t.expectBool("2n > 1", true); // relational cross-type
    try t.expectBool("1n < 2", true);
    try t.expectBool("2n >= 2", true);
    try t.expectBool("1n == true", true); // Boolean → numeric
    try t.expectBool("0n == false", true);
}

test "M36: §21.2.1.1 BigInt(x) + §21.2.3 ToString" {
    try t.expectBool("BigInt(5) + 1n === 6n", true);
    try t.expectBool("BigInt(true) === 1n", true);
    try t.expectBool("BigInt(false) === 0n", true);
    try t.expectBool("BigInt('0x1F') === 31n", true);
    try t.expectBool("BigInt('  42  ') === 42n", true); // trimmed
    try t.expectThrows("BigInt(1.5)"); // RangeError: not an integer
    try t.expectThrows("BigInt('xyz')"); // SyntaxError: invalid string
    // §21.2.3 ToString / template / String()
    try t.expectStr("String(123n)", "123");
    try t.expectStr("String(-7n)", "-7");
    try t.expectStr("(255n).toString(16)", "ff");
    try t.expectStr("(10n).toString(2)", "1010");
    try t.expectStr("`${42n}`", "42"); // template substitution
    try t.expectStr("'' + 5n", "5"); // string concat via ToString
    try t.expectBool("(255n).valueOf() === 255n", true);
    // §21.2.2 asIntN / asUintN
    try t.expectBool("BigInt.asUintN(8, 256n) === 0n", true);
    try t.expectBool("BigInt.asIntN(8, 255n) === -1n", true);
}

test "M39: §22.1.3 String.prototype methods — index/search family" {
    // §22.1.3.1 at — relative index (negative from end)
    try t.expectStr("\"abc\".at(-1)", "c");
    try t.expectStr("\"abc\".at(0)", "a");
    try t.expectUndefined("\"abc\".at(3)");
    // §22.1.3.4 codePointAt — ASCII byte
    try t.expectNumber("\"abc\".codePointAt(0)", 97);
    try t.expectUndefined("\"abc\".codePointAt(5)");
    // §22.1.3.24/.7 startsWith / endsWith
    try t.expectBool("\"abc\".startsWith(\"ab\")", true);
    try t.expectBool("\"abc\".startsWith(\"bc\", 1)", true);
    try t.expectBool("\"abc\".endsWith(\"bc\")", true);
    try t.expectBool("\"abc\".endsWith(\"ab\", 2)", true);
    // §22.1.3.9/.11 indexOf(pos) / lastIndexOf
    try t.expectNumber("\"abcabc\".indexOf(\"b\", 2)", 4);
    try t.expectNumber("\"abcabc\".lastIndexOf(\"a\")", 3);
    // §22.1.3.8 includes(pos)
    try t.expectBool("\"abc\".includes(\"a\", 1)", false);
}

test "M39: §22.1.3 String.prototype methods — build/transform family" {
    // §22.1.3.5 concat
    try t.expectStr("\"a\".concat(\"b\", \"c\")", "abc");
    // §22.1.3.18 repeat (+ RangeError on negative / Infinity)
    try t.expectStr("\"ab\".repeat(3)", "ababab");
    try t.expectStr("\"x\".repeat(0)", "");
    try t.expectThrows("\"x\".repeat(-1)");
    try t.expectThrows("\"x\".repeat(Infinity)");
    // §22.1.3.16/.15 padStart / padEnd
    try t.expectStr("\"ab\".padStart(4, \"x\")", "xxab");
    try t.expectStr("\"ab\".padEnd(4, \"x\")", "abxx");
    try t.expectStr("\"ab\".padStart(5)", "   ab");
    // §22.1.3.32/.34/.33 trim / trimStart / trimEnd
    try t.expectStr("\"  x  \".trim()", "x");
    try t.expectStr("\"  x  \".trimStart()", "x  ");
    try t.expectStr("\"  x  \".trimEnd()", "  x");
    // Annex B substr
    try t.expectStr("\"abcde\".substr(1, 2)", "bc");
    try t.expectStr("\"abcde\".substr(-2)", "de");
    // §22.1.3.10 localeCompare (code-unit compare in the M-subset)
    try t.expectNumber("\"a\".localeCompare(\"a\")", 0);
    try t.expectNumber("\"a\".localeCompare(\"b\")", -1);
    // string-arg replace / replaceAll (§22.1.3.20/.21 string path)
    try t.expectStr("\"a-b\".replace(\"-\", \"+\")", "a+b");
    try t.expectStr("\"a-b-c\".replace(\"-\", \"+\")", "a+b-c");
    try t.expectStr("\"a-b-c\".replaceAll(\"-\", \"+\")", "a+b+c");
    try t.expectStr("\"a-b\".replace(\"-\", \"$&$&\")", "a--b");
}

test "M39: §22.1.2 String statics + RequireObjectCoercible" {
    // §22.1.2.1 fromCharCode
    try t.expectStr("String.fromCharCode(97, 98)", "ab");
    // §22.1.2.2 fromCodePoint (+ RangeError on out-of-range)
    try t.expectStr("String.fromCodePoint(97, 98)", "ab");
    try t.expectThrows("String.fromCodePoint(-1)");
    try t.expectThrows("String.fromCodePoint(0x110000)");
    // §22.1.2.4 String.raw — direct call on a template object
    try t.expectStr("String.raw({ raw: [\"a\", \"b\", \"c\"] }, 1, 2)", "a1b2c");
    try t.expectStr("String.raw({ raw: [\"x\"] })", "x");
    // §22.1.3 RequireObjectCoercible — null/undefined this → TypeError
    try t.expectThrows("String.prototype.at.call(undefined, 0)");
    try t.expectThrows("String.prototype.charAt.call(null, 0)");
    // unboxing a String wrapper
    try t.expectStr("new String(\"hi\").at(0)", "h");
}

test "M40: §21.3 Math — full method surface + value properties" {
    // §21.3.2 newly added methods
    try t.expectNumber("Math.sign(-3)", -1);
    try t.expectNumber("Math.sign(3)", 1);
    try t.expectNumber("Math.trunc(4.7)", 4);
    try t.expectNumber("Math.trunc(-4.7)", -4);
    try t.expectNumber("Math.hypot(3,4)", 5);
    try t.expectNumber("Math.hypot(3,4,12)", 13);
    try t.expectNumber("Math.log2(8)", 3);
    try t.expectNumber("Math.log10(1000)", 3);
    try t.expectNumber("Math.cbrt(27)", 3);
    try t.expectNumber("Math.clz32(1)", 31);
    try t.expectNumber("Math.clz32(0)", 32);
    try t.expectNumber("Math.imul(3, 4)", 12);
    try t.expectNumber("Math.imul(0xffffffff, 5)", -5);
    try t.expectNumber("Math.fround(1.5)", 1.5);
    try t.expectNumber("Math.expm1(0)", 0);
    try t.expectNumber("Math.atan2(0, 1)", 0);
    try t.expectNumber("Math.cosh(0)", 1);
    // §21.3.2.24/.25 NaN propagation + ToNumber-coerced args
    try t.expectBool("Number.isNaN(Math.max(1, NaN))", true);
    try t.expectBool("Number.isNaN(Math.min(NaN, 2))", true);
    try t.expectNumber("Math.max(1, 2, 3)", 3);
    try t.expectNumber("Math.min(-1, -2, -3)", -3);
    try t.expectNumber("Math.max('5', 3)", 5); // ToNumber coercion of a string arg
    // §21.3.2.28 round half-up toward +Inf, including the -0 edge for x in (-0.5, 0]
    try t.expectNumber("Math.round(2.5)", 3);
    try t.expectNumber("Math.round(-2.5)", -2);
    try t.expectBool("1 / Math.round(-0.5) === -Infinity", true); // Math.round(-0.5) is -0
    // §21.3.2.27 random in [0,1)
    try t.expectBool("var r = Math.random(); r >= 0 && r < 1", true);
    // §21.3.1 value properties (read-only; assignment is a silent no-op)
    try t.expectNumber("Math.PI > 3.14 && Math.PI < 3.15 ? 1 : 0", 1);
    try t.expectBool("Math.SQRT2 * Math.SQRT2 > 1.9999 && Math.SQRT2 * Math.SQRT2 < 2.0001", true);
    try t.expectBool("Math.E > 2.71 && Math.E < 2.72", true);
    // non-writable: a write is rejected (value unchanged)
    try t.expectBool("Math.PI = 0; Math.PI > 3.14", true);
}

test "M40: §28.1 Reflect namespace object" {
    // §28.1.9 has → the `in` operation (own + inherited)
    try t.expectBool("Reflect.has({a:1}, 'a')", true);
    try t.expectBool("Reflect.has({a:1}, 'b')", false);
    try t.expectBool("Reflect.has({}, 'toString')", true); // inherited
    // §28.1.6 get / §28.1.13 set
    try t.expectNumber("Reflect.get({a:5}, 'a')", 5);
    try t.expectNumber("var o={}; Reflect.set(o,'x',9); o.x", 9);
    try t.expectBool("Reflect.set({}, 'x', 1)", true);
    // §28.1.11 ownKeys
    try t.expectNumber("Reflect.ownKeys({a:1, b:2}).length", 2);
    try t.expectStr("Reflect.ownKeys({a:1, b:2})[0]", "a");
    // §28.1.1 apply
    try t.expectNumber("Reflect.apply(function(a,b){return a+b}, null, [2,3])", 5);
    try t.expectNumber("Reflect.apply(function(){return this.v}, {v:7}, [])", 7);
    // §28.1.2 construct (with + without explicit newTarget)
    try t.expectNumber("Reflect.construct(function(x){this.x=x}, [7]).x", 7);
    // §28.1.3 defineProperty → boolean (no throw on failure)
    try t.expectBool("Reflect.defineProperty({}, 'k', {value:1})", true);
    try t.expectBool("var o={}; Reflect.defineProperty(o,'k',{value:1,configurable:false}); Reflect.defineProperty(o,'k',{value:2})", false);
    try t.expectNumber("var o={}; Reflect.defineProperty(o,'k',{value:42,enumerable:true}); o.k", 42);
    // §28.1.4 deleteProperty → boolean
    try t.expectBool("var o={a:1}; Reflect.deleteProperty(o,'a')", true);
    try t.expectBool("var o={a:1}; Reflect.deleteProperty(o,'a'); 'a' in o", false);
    // §28.1.7 getOwnPropertyDescriptor
    try t.expectNumber("Reflect.getOwnPropertyDescriptor({a:5}, 'a').value", 5);
    try t.expectBool("Reflect.getOwnPropertyDescriptor({}, 'a') === undefined", true);
    // §28.1.8/.14 getPrototypeOf / setPrototypeOf
    try t.expectBool("Reflect.getPrototypeOf(Object.create(null)) === null", true);
    try t.expectBool("var o={}; var p={}; Reflect.setPrototypeOf(o,p); Reflect.getPrototypeOf(o)===p", true);
    // §28.1.10/.12 isExtensible / preventExtensions
    try t.expectBool("Reflect.isExtensible({})", true);
    try t.expectBool("var o={}; Reflect.preventExtensions(o); Reflect.isExtensible(o)", false);
    // §28.1.x: a non-object target → TypeError
    try t.expectThrows("Reflect.get(5, 'x')");
    try t.expectThrows("Reflect.ownKeys(5)");
    try t.expectThrows("Reflect.apply(5, null, [])"); // non-callable target
    // §28.1.14 Reflect[Symbol.toStringTag] = "Reflect" (own non-enumerable data property)
    try t.expectStr("Reflect[Symbol.toStringTag]", "Reflect");
    try t.expectBool("Reflect.getOwnPropertyDescriptor(Reflect, Symbol.toStringTag).enumerable", false);
}

test "M41: §19.2 global functions (isNaN/isFinite/parseInt/parseFloat/URI)" {
    // §19.2.3 isNaN / §19.2.2 isFinite — COERCING (unlike Number.isNaN/isFinite).
    try t.expectBool("isNaN('x')", true);
    try t.expectBool("isNaN('3')", false);
    try t.expectBool("isNaN(NaN)", true);
    try t.expectBool("isFinite('3')", true);
    try t.expectBool("isFinite(Infinity)", false);
    try t.expectBool("isFinite('foo')", false);
    // §19.2.5 parseInt — radix handling, 0x prefix, trim, stop at first invalid char.
    try t.expectNumber("parseInt('0x1F')", 31);
    try t.expectNumber("parseInt('11', 2)", 3);
    try t.expectNumber("parseInt('  42px')", 42);
    try t.expectNumber("parseInt('-10', 16)", -16);
    try t.expectNumber("parseInt('z', 36)", 35);
    try t.expectBool("isNaN(parseInt('xyz'))", true);
    // §19.2.4 parseFloat — longest StrDecimalLiteral prefix, Infinity, NaN on no prefix.
    try t.expectNumber("parseFloat('3.14abc')", 3.14);
    try t.expectNumber("parseFloat('Infinity')", std.math.inf(f64));
    try t.expectNumber("parseFloat('  6.022e23 ')", 6.022e23);
    try t.expectBool("isNaN(parseFloat('abc'))", true);
    // §19.2.6 URI handlers.
    try t.expectStr("encodeURIComponent('a b&c')", "a%20b%26c");
    try t.expectStr("decodeURIComponent('a%20b')", "a b");
    try t.expectStr("encodeURI('a b/c?d')", "a%20b/c?d"); // reserved `/ ?` preserved
    try t.expectStr("decodeURIComponent('%E2%82%AC')", "\u{20AC}"); // euro sign round-trip
    try t.expectThrows("decodeURIComponent('%')"); // malformed → URIError
    try t.expectThrows("decodeURIComponent('%ZZ')");
    // globalThis mirror — non-enumerable own properties.
    try t.expectBool("globalThis.parseInt === parseInt", true);
    try t.expectBool("Object.getOwnPropertyDescriptor(globalThis,'parseInt').enumerable", false);
}

test "M41: §21.1.3 Number.prototype methods" {
    // §21.1.3.6 toString([radix]).
    try t.expectStr("(255).toString(16)", "ff");
    try t.expectStr("(255).toString()", "255");
    try t.expectStr("(10).toString(2)", "1010");
    try t.expectStr("(0.5).toString(2)", "0.1");
    try t.expectThrows("(5).toString(1)"); // radix < 2 → RangeError
    try t.expectThrows("(5).toString(37)");
    // §21.1.3.26 valueOf — unbox a Number wrapper too.
    try t.expectNumber("new Number(7).valueOf()", 7);
    try t.expectNumber("(42).valueOf()", 42);
    // §21.1.3.3 toFixed.
    try t.expectStr("(3.14159).toFixed(2)", "3.14");
    try t.expectStr("(0).toFixed(0)", "0");
    try t.expectStr("(1.005).toFixed(0)", "1");
    try t.expectThrows("(1).toFixed(101)"); // > 100 → RangeError
    // §21.1.3.5 toPrecision.
    try t.expectStr("(123.456).toPrecision(4)", "123.5");
    try t.expectStr("(0.0001234).toPrecision(2)", "0.00012");
    try t.expectThrows("(1).toPrecision(0)"); // < 1 → RangeError
    // §21.1.3.2 toExponential.
    try t.expectStr("(123456).toExponential(2)", "1.23e+5");
    // §21.1.3.5 toLocaleString ≈ toString for the M-subset.
    try t.expectStr("(255).toLocaleString()", "255");
}

test "M42: §20.1.3.6 Object.prototype.toString — builtin tags + @@toStringTag" {
    try t.expectStr("Object.prototype.toString.call([])", "[object Array]");
    try t.expectStr("Object.prototype.toString.call(null)", "[object Null]");
    try t.expectStr("Object.prototype.toString.call(undefined)", "[object Undefined]");
    try t.expectStr("Object.prototype.toString.call(function(){})", "[object Function]");
    try t.expectStr("Object.prototype.toString.call(new Error('x'))", "[object Error]");
    try t.expectStr("Object.prototype.toString.call(new Number(5))", "[object Number]");
    try t.expectStr("Object.prototype.toString.call(new String('s'))", "[object String]");
    try t.expectStr("Object.prototype.toString.call(new Boolean(true))", "[object Boolean]");
    try t.expectStr("Object.prototype.toString.call({})", "[object Object]");
    try t.expectStr("(function(){return Object.prototype.toString.call(arguments);})()", "[object Arguments]");
    // §20.1.3.6 step 15: a String @@toStringTag overrides the builtin tag.
    try t.expectStr("Object.prototype.toString.call({[Symbol.toStringTag]:'Foo'})", "[object Foo]");
    // A non-String @@toStringTag is ignored → the builtin tag is used.
    try t.expectStr("Object.prototype.toString.call({[Symbol.toStringTag]:42})", "[object Object]");
    // Primitive receivers via .call box to their wrapper brand.
    try t.expectStr("Object.prototype.toString.call(5)", "[object Number]");
    try t.expectStr("Object.prototype.toString.call('s')", "[object String]");
}

test "M42: §20.1.2 new statics — fromEntries / hasOwn / getOwnPropertySymbols / groupBy" {
    // §20.1.2.7 Object.fromEntries.
    try t.expectNumber("Object.fromEntries([['a',1],['b',2]]).b", 2);
    try t.expectBool("Object.getPrototypeOf(Object.fromEntries([])) === Object.prototype", true);
    // §20.1.2.13 Object.hasOwn — own string + symbol, regardless of enumerability; no chain walk.
    try t.expectBool("Object.hasOwn({a:1},'a')", true);
    try t.expectBool("Object.hasOwn({},'toString')", false); // inherited, not own
    try t.expectBool("(function(){var s=Symbol(); var o={}; o[s]=1; return Object.hasOwn(o,s);})()", true);
    // §20.1.2.10 Object.getOwnPropertySymbols.
    try t.expectNumber("Object.getOwnPropertySymbols({[Symbol.iterator]:1}).length", 1);
    try t.expectNumber("Object.getOwnPropertySymbols({a:1}).length", 0);
    // §20.1.2.11 Object.groupBy — null-proto result, per-key arrays.
    try t.expectStr("Object.groupBy([1,2,3,4],function(n){return n%2?'odd':'even';}).odd.join(',')", "1,3");
    try t.expectBool("Object.getPrototypeOf(Object.groupBy([1],function(){return 'k';})) === null", true);
}

test "M42: §B.2.2.1 Object.prototype.__proto__ accessor" {
    try t.expectBool("({}).__proto__ === Object.prototype", true);
    try t.expectNumber("(function(){var o={}; o.__proto__={x:5}; return o.x;})()", 5);
    // Setting __proto__ to a non-object/non-null value is a silent no-op (proto unchanged).
    try t.expectBool("(function(){var o={}; o.__proto__=5; return o.__proto__===Object.prototype;})()", true);
    // get on a null-proto object returns null.
    try t.expectBool("Object.create(null).__proto__ === undefined", true);
}
