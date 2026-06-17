//! Engine unit tests (split from engine_tests.zig to keep files < 1000 lines). All shared symbols
//! (helpers + evaluate/t.Value/...) are referenced via the `t.` prefix off engine_tests.zig.
const t = @import("engine_tests.zig");

test "M11 async: function/arrow/method parse; typeof; runtime stub (§15.8, Cycle 1)" {
    // §15.8 AsyncFunctionExpression — an async function object is still a function.
    try t.expectStr("typeof (async function(){})", "function");
    // §15.8 AsyncFunctionDeclaration parses as a statement and binds its name.
    try t.expectStr("async function f(){} typeof f", "function");
    // §15.6 AsyncGeneratorExpression / Declaration parse.
    try t.expectStr("typeof (async function*(){})", "function");
    try t.expectStr("async function* g(){} typeof g", "function");
    // §15.8 AsyncArrowFunction (single param, parenthesized params, zero params) parse.
    try t.expectNoSyntaxErrorStrict("var f = async x => x;");
    try t.expectNoSyntaxErrorStrict("var f = async (a, b) => a + b;");
    try t.expectNoSyntaxErrorStrict("var f = async () => 1;");
    // §15.8 async methods in object & class bodies, incl. `static async` and computed, parse.
    try t.expectNoSyntaxErrorStrict("var o = { async m(){} };");
    try t.expectNoSyntaxErrorStrict("var o = { async *m(){} };");
    try t.expectNoSyntaxErrorStrict("class C { async m(){} }");
    try t.expectNoSyntaxErrorStrict("class C { static async m(){} }");
    try t.expectNoSyntaxErrorStrict("class C { async ['x'](){} }");
    // §27.7.5.1 (Cycle 2): calling an async function returns a Promise object (not a thrown stub).
    try t.expectStr("async function f(){ return 1; } typeof f()", "object");
    try t.expectBool("async function f(){ return 1; } f() instanceof Promise", true);
}

test "M11 async runtime: async fn returns a fulfilling Promise (§27.7.5)" {
    // §27.7.5.2 a plain `return 42` fulfills the function's promise with 42 (observed via .then).
    try t.expectGlobalNumberAfterDrain("var r; async function f(){ return 42; } f().then(function(v){ r = v; });", "r", 42);
    // §27.7.5.3 a single `await` of a resolved promise yields the value; the body continues.
    try t.expectGlobalNumberAfterDrain("var r; async function f(){ var x = await Promise.resolve(3); return x + 1; } f().then(function(v){ r = v; });", "r", 4);
    // §27.7.5.3 await of a plain (non-promise) value resolves to that value.
    try t.expectGlobalNumberAfterDrain("var r; async function f(){ return (await 7) + 1; } f().then(function(v){ r = v; });", "r", 8);
}

test "M11 async runtime: await of a rejected promise is catchable in the body (§27.7.5.3)" {
    // §27.7.5.3 a rejected await throws into the body at the await point — a try/catch catches it.
    try t.expectGlobalStringAfterDrain(
        "var r; async function f(){ try { await Promise.reject('boom'); return 'no'; } catch (e) { return 'caught:' + e; } } f().then(function(v){ r = v; });",
        "r",
        "caught:boom",
    );
    // §27.7.5.2 an uncaught throw rejects the function's promise (observed via .catch / .then onRejected).
    try t.expectGlobalStringAfterDrain(
        "var r; async function f(){ throw 'oops'; } f().then(function(){ r = 'F'; }, function(e){ r = 'R:' + e; });",
        "r",
        "R:oops",
    );
}

test "M11 Promise: then chaining, resolve adoption, microtask ordering (§27.2)" {
    // §27.2.5.4 then returns a new promise; the chained handler sees the prior result + 1.
    try t.expectGlobalNumberAfterDrain("var r; Promise.resolve(10).then(function(v){ return v + 5; }).then(function(v){ r = v; });", "r", 15);
    // §27.2.1.3.2 resolving with a thenable adopts its eventual value (Promise.resolve(promise) flattens).
    try t.expectGlobalNumberAfterDrain("var r; Promise.resolve(Promise.resolve(99)).then(function(v){ r = v; });", "r", 99);
    // §9.5 microtasks run AFTER synchronous code: the sync assignment wins first, the reaction overwrites.
    try t.expectGlobalStringAfterDrain("var log = ''; Promise.resolve().then(function(){ log = log + 'micro'; }); log = log + 'sync';", "log", "syncmicro");
    // §27.2.5.1 catch handles a rejection; §27.2.5.3 finally passes the value through.
    try t.expectGlobalStringAfterDrain("var r; Promise.reject('e').catch(function(x){ return 'C:' + x; }).then(function(v){ r = v; });", "r", "C:e");
}

test "M11 Promise: new Promise(executor) resolve/reject + executor throw (§27.2.3.1)" {
    // §27.2.3.1 the executor's resolve fulfills the promise.
    try t.expectGlobalNumberAfterDrain("var r; new Promise(function(res){ res(5); }).then(function(v){ r = v; });", "r", 5);
    // §27.2.3.1 step 10: a throwing executor rejects the promise.
    try t.expectGlobalStringAfterDrain("var r; new Promise(function(){ throw 'x'; }).then(function(){ r = 'F'; }, function(e){ r = 'R:' + e; });", "r", "R:x");
    // §27.2.3.1 step 2: a non-callable executor is a TypeError.
    try t.expectThrows("new Promise(42)");
}

test "M11 Cycle 3: globalThis reified global object (§19.3.1 / §9.3.4)" {
    // §19.3.1 globalThis is an object …
    try t.expectStr("typeof globalThis", "object");
    // … carrying the standard globals as own properties (identity-equal to the bindings).
    try t.expectBool("globalThis.Object === Object", true);
    try t.expectBool("globalThis.Promise === Promise", true);
    try t.expectBool("globalThis.Array === Array", true);
    // §19.3.1 globalThis refers to the global object itself (self-referential).
    try t.expectBool("globalThis.globalThis === globalThis", true);
    // A user global is reachable through globalThis (the binding is mirrored at setup; reads observe it).
    try t.expectNumber("globalThis.Math.pow(2, 5)", 32);
}

test "M11 Cycle 3: Promise.all fulfills with the values array; rejects on first reject (§27.2.4.1)" {
    // §27.2.4.1 all inputs fulfill → the result fulfills with an array of their values, in order.
    try t.expectGlobalNumberAfterDrain(
        "var r; async function f(){ var xs = await Promise.all([Promise.resolve(1), Promise.resolve(2)]); return xs[0] + xs[1]; } f().then(function(v){ r = v; });",
        "r",
        3,
    );
    // non-promise members are wrapped (PromiseResolve), preserving order.
    try t.expectGlobalStringAfterDrain("var r; Promise.all([1, Promise.resolve(2), 3]).then(function(xs){ r = xs.join(','); });", "r", "1,2,3");
    // §27.2.4.1 the empty iterable fulfills synchronously-after-loop with an empty array (length 0).
    try t.expectGlobalNumberAfterDrain("var r; Promise.all([]).then(function(xs){ r = xs.length; });", "r", 0);
    // §27.2.4.1 a single rejection rejects the result with that reason.
    try t.expectGlobalStringAfterDrain("var r; Promise.all([Promise.resolve(1), Promise.reject('bad')]).then(function(){ r = 'F'; }, function(e){ r = 'R:' + e; });", "r", "R:bad");
}

test "M11 Cycle 3: Promise.race settles with the first settlement (§27.2.4.6)" {
    // §27.2.4.6 the first already-resolved member wins (both are settled, FIFO microtask order → 'a').
    try t.expectGlobalStringAfterDrain("var r; Promise.race([Promise.resolve('a'), Promise.resolve('b')]).then(function(v){ r = v; });", "r", "a");
    // a rejection that settles first rejects the race.
    try t.expectGlobalStringAfterDrain("var r; Promise.race([Promise.reject('x'), Promise.resolve('y')]).then(function(){ r = 'F'; }, function(e){ r = 'R:' + e; });", "r", "R:x");
}

test "M11 Cycle 3: Promise.allSettled always fulfills with status records (§27.2.4.2)" {
    // §27.2.4.2 a mix of fulfill/reject → an array of {status, value|reason} records, in order.
    try t.expectGlobalStringAfterDrain(
        "var r; Promise.allSettled([Promise.resolve(1), Promise.reject('e')]).then(function(xs){ r = xs[0].status + ':' + xs[0].value + '|' + xs[1].status + ':' + xs[1].reason; });",
        "r",
        "fulfilled:1|rejected:e",
    );
}

test "M11 Cycle 3: Promise.any fulfills with first fulfillment; AggregateError if all reject (§27.2.4.3)" {
    // §27.2.4.3 the first fulfillment wins even when an earlier member rejects.
    try t.expectGlobalStringAfterDrain("var r; Promise.any([Promise.reject('x'), Promise.resolve('ok')]).then(function(v){ r = v; });", "r", "ok");
    // §27.2.4.3 all members reject → reject with an AggregateError whose `.errors` lists the reasons.
    try t.expectGlobalStringAfterDrain(
        "var r; Promise.any([Promise.reject('a'), Promise.reject('b')]).then(function(){ r = 'F'; }, function(e){ r = e.name + ':' + e.errors.join(','); });",
        "r",
        "AggregateError:a,b",
    );
    // §20.5.7 AggregateError is also a directly-constructible global.
    try t.expectStr("var e = new AggregateError([1, 2], 'oops'); e.name + '/' + e.message + '/' + e.errors.length", "AggregateError/oops/2");
}

test "M11 Cycle 3: thenable adoption settles the promise (§27.2.1.3.2 / §27.2.2.2)" {
    // §27.2.2.2 PromiseResolveThenableJob: resolving a promise with a plain (non-Promise) thenable
    // adopts its eventual state — the thenable's `resolve(v)` must settle the derived promise. Earlier
    // the promise's [[AlreadyResolved]] (set when claiming the thenable) wrongly blocked the job's own
    // resolve; the job now uses a fresh [[AlreadyResolved]], so adoption completes.
    try t.expectGlobalStringAfterDrain(
        "var out = 'X'; var thenable = { then: function(res){ res(42); } }; Promise.resolve(thenable).then(function(v){ out = 'got:' + v; });",
        "out",
        "got:42",
    );
    // The same adoption drives `await` of a plain thenable inside an async function.
    try t.expectGlobalStringAfterDrain(
        "var out = 'X'; var thenable = { then: function(res){ res(7); } }; async function f(){ out = 'got:' + (await thenable); } f();",
        "out",
        "got:7",
    );
    // A thenable that rejects propagates the rejection to the adopting promise.
    try t.expectGlobalStringAfterDrain(
        "var out = 'X'; var thenable = { then: function(res, rej){ rej('boom'); } }; Promise.resolve(thenable).then(function(){ out = 'F'; }, function(e){ out = 'R:' + e; });",
        "out",
        "R:boom",
    );
}

test "M13 async generators: yield produces values, consumed via for await (§27.6 / §14.7.5)" {
    // An `async function*` returns an AsyncGenerator; consuming it with `for await` inside an async
    // function collects the yielded values in order. `yield await p` exercises await inside the body.
    try t.expectGlobalStringAfterDrain(
        \\var out = '';
        \\async function* g(){ yield 1; yield await Promise.resolve(2); yield 3; }
        \\async function main(){ for await (const x of g()) { out = out + x; } }
        \\main();
    , "out", "123");
    // The async generator's body return value lands on the terminal { done:true } (not iterated by for-await).
    try t.expectGlobalStringAfterDrain(
        \\var out = '';
        \\async function* g(){ yield 'a'; return 'R'; yield 'b'; }
        \\async function main(){ for await (const x of g()) { out = out + x; } out = out + '!'; }
        \\main();
    , "out", "a!");
}

test "M13 for await over a sync iterable of promises (AsyncFromSyncIterator §27.1.4)" {
    // A SYNC iterable with no [Symbol.asyncIterator] is wrapped in an AsyncFromSyncIterator; each sync
    // element (here a mix of a promise and a plain value) is awaited, so `[Promise.resolve(1), 2]`
    // iterates as 1, 2.
    try t.expectGlobalStringAfterDrain(
        \\var out = '';
        \\async function main(){ for await (const x of [Promise.resolve(1), 2, Promise.resolve(3)]) { out = out + x; } }
        \\main();
    , "out", "123");
}

test "M13 async generator method on a class (§15.6 / §27.6)" {
    try t.expectGlobalStringAfterDrain(
        \\var out = '';
        \\class C { async *m(){ yield 10; yield 20; } }
        \\async function main(){ for await (const x of new C().m()) { out = out + x + ','; } }
        \\main();
    , "out", "10,20,");
}

test "M13 async generator .next() returns a promise of {value,done} (§27.6.1.2)" {
    try t.expectGlobalStringAfterDrain(
        \\var out = '';
        \\async function* g(){ yield 7; }
        \\async function main(){ var it = g(); var r = await it.next(); out = r.value + ':' + r.done; }
        \\main();
    , "out", "7:false");
}

test "M13 yield* over an async iterable in an async generator (§27.6.3.8)" {
    try t.expectGlobalStringAfterDrain(
        \\var out = '';
        \\async function* inner(){ yield 1; yield 2; }
        \\async function* outer(){ yield* inner(); yield 3; }
        \\async function main(){ for await (const x of outer()) { out = out + x; } }
        \\main();
    , "out", "123");
}

test "M13 for await is a SyntaxError outside an async context (§14.7.5)" {
    try t.expectSyntaxError("function f(){ for await (const x of []) {} }");
    try t.expectSyntaxError("for await (const x of []) {}");
    // `for await` requires the `of` form (no for-in, no C-style).
    try t.expectSyntaxError("async function f(){ for await (const x in []) {} }");
}

test "M11 async: `await` as identifier outside async; operator only inside async (§15.8)" {
    // §15.8: outside an async function (a sloppy script/function) `await` is an ordinary identifier.
    try t.expectNumber("function f(){var await = 1; return await;} f()", 1);
    try t.expectNumber("var await = 41; await + 1", 42);
    // §15.8.1: inside an async function `await` is the operator — a bare `await` as a binding name is
    // a SyntaxError, and `await` reaching IdentifierReference position is a SyntaxError.
    try t.expectSyntaxError("async function f(){ var await = 1; }");
    try t.expectSyntaxError("async function f(await){}");
    try t.expectSyntaxError("async function await(){}");
    // §15.8.1: an async arrow's param may not be named `await`.
    try t.expectSyntaxError("var f = async await => 1;");
    // §15.8: `await` IS the operator inside an async body (parses; runtime stub at evaluation).
    try t.expectNoSyntaxErrorStrict("async function f(x){ return await x; }");
    try t.expectNoSyntaxErrorStrict("async function f(x){ await x; }");
    // an async method body also has `[+Await]`.
    try t.expectNoSyntaxErrorStrict("var o = { async m(x){ return await x; } };");
}

test "M3 arrow functions: bodies & param forms (US5, §15.3)" {
    // expression body (implicit return), single un-parenthesized param
    try t.expectNumber("var f = x => x + 1; f(41)", 42);
    // block body with explicit return
    try t.expectNumber("var f = x => { return x * 2; }; f(21)", 42);
    // zero params + multi params
    try t.expectNumber("var f = () => 42; f()", 42);
    try t.expectNumber("var add = (a, b) => a + b; add(2, 3)", 5);
    // default param
    try t.expectNumber("var f = (a = 10) => a; f()", 10);
    try t.expectNumber("var f = (a = 10) => a; f(3)", 3);
    // destructuring params (object + array)
    try t.expectNumber("var f = ({x}, [y]) => x + y; f({x: 40}, [2])", 42);
    // rest param
    try t.expectNumber("var f = (...xs) => xs.length; f(1, 2, 3)", 3);
    // immediately-invoked parenthesized arrow (cover-grammar disambiguation)
    try t.expectNumber("((x) => x + 1)(41)", 42);
    // arrows returning closures (curried)
    try t.expectNumber("var mk = a => b => a + b; mk(40)(2)", 42);
}

test "M3 arrow functions: lexical this & not a constructor (US5, §15.3)" {
    // an arrow captures the enclosing `this` at creation, regardless of how it is later called
    try t.expectNumber(
        "var o = { v: 7, get: function() { var f = () => this.v; return f(); } }; o.get()",
        7,
    );
    // calling the arrow as another object's method must NOT rebind `this`
    try t.expectNumber(
        "var outer = { v: 1, make: function(){ return () => this.v; } };" ++
            " var arrow = outer.make(); var other = { v: 99, f: arrow }; other.f()",
        1,
    );
    // §15.3: arrows are not constructors
    try t.expectThrows("new (() => {})");
}

test "M3 arrow functions: early errors (US5, §15.3.1)" {
    // duplicate BoundNames are a SyntaxError in every mode (unlike a sloppy ordinary function)
    try t.expectSyntaxError("var f = (x, x) => 1;");
    try t.expectSyntaxError("var f = ([x], x) => 1;");
    try t.expectSyntaxError("var f = ({a: x}, x) => 1;");
    try t.expectSyntaxError("var f = (x, ...x) => 1;");
    // ASI restriction: no LineTerminator between ArrowParameters and `=>`
    try t.expectSyntaxError("var f = ()\n=> 1;");
    try t.expectSyntaxError("var f = x\n=> 1;");
    // distinct names + a newline *after* `=>` (before the body) are both fine
    try t.expectNumber("var f = (a, b) =>\n a + b; f(2, 3)", 5);
}

test "M4 classes: declaration, constructor, new (Cycle 1, §15.7.14)" {
    // empty class declaration constructs an instance
    try t.expectStr("class C {} typeof new C()", "object");
    try t.expectStr("class C {} typeof C", "function");
    // constructor binds fields on `this`
    try t.expectNumber("class C { constructor(x) { this.x = x; } } new C(7).x", 7);
    try t.expectNumber("class C { constructor(a, b) { this.s = a + b; } } new C(40, 2).s", 42);
    // a class constructor cannot be called without `new` (§15.7.14)
    try t.expectThrows("class C {} C()");
    // a class is an instanceof itself
    try t.expectBool("class C {} (new C()) instanceof C", true);
}

test "M4 classes: instance methods on the prototype (Cycle 1, §15.7.14)" {
    try t.expectNumber("class C { m() { return 1; } } new C().m()", 1);
    // method `this` is the receiver
    try t.expectNumber("class C { constructor() { this.v = 5; } get() { return this.v; } } new C().get()", 5);
    // method takes params
    try t.expectNumber("class C { add(a, b) { return a + b; } } new C().add(40, 2)", 42);
    // methods live on the prototype (shared), not per-instance
    try t.expectBool("class C { m() {} } var a = new C(); var b = new C(); a.m === b.m", true);
}

test "M4 classes: instance fields (Cycle 1, §15.7.14)" {
    // field with initializer
    try t.expectNumber("class C { x = 5; } new C().x", 5);
    // bare field defaults to undefined
    try t.expectStr("class C { x; } typeof new C().x", "undefined");
    // multiple fields, initialized in order; an initializer may reference `this`
    try t.expectNumber("class C { a = 1; b = 2; } var o = new C(); o.a + o.b", 3);
    // fields initialize BEFORE the constructor body runs
    try t.expectNumber("class C { x = 10; constructor() { this.x = this.x + 1; } } new C().x", 11);
    // a field initializer can reference an outer binding
    try t.expectNumber("var k = 9; class C { x = k; } new C().x", 9);
}

test "M4 classes: static methods and fields (Cycle 1, §15.7.14)" {
    // static method on the constructor object
    try t.expectNumber("class C { static s() { return 9; } } C.s()", 9);
    // static field on the constructor object
    try t.expectNumber("class C { static n = 3; } C.n", 3);
    // static field initializer sees `this` = the constructor
    try t.expectNumber("class C { static a = 2; static b = 40; } C.a + C.b", 42);
    // a static member is NOT on instances
    try t.expectStr("class C { static s() {} } typeof new C().s", "undefined");
}

test "M4 classes: class expression (Cycle 1, §15.7)" {
    // anonymous class expression
    try t.expectNumber("var C = class { m() { return 1; } }; new C().m()", 1);
    // named class expression — the name is bound inside the body for self-reference
    try t.expectBool("var K = class C { who() { return C; } }; new K().who() === K", true);
    // class expression with a field
    try t.expectNumber("var C = class { x = 7; }; new C().x", 7);
    // immediately constructed
    try t.expectNumber("new (class { constructor() { this.v = 42; } })().v", 42);
}

test "M10 EmptyStatement (§14.4): bare/doubled `;` and trailing `;` after declarations" {
    // a bare `;` is a no-op statement (not a SyntaxError)
    try t.expectNumber("; 1", 1);
    // doubled empty statements
    try t.expectNumber(";; 2", 2);
    // §14.4: a `;` (EmptyStatement) after a class declaration — the common Test262 `class C {};` form
    try t.expectNumber("class C { m() { return 9; } }; new C().m()", 9);
    // a `;` after a function declaration
    try t.expectNumber("function f() { return 5; }; f()", 5);
    // an empty loop body (`for (...);`) runs the header but no body statement
    try t.expectNumber("var i = 0; for (; i < 3; i++); i", 3);
    // an empty `if`/`else` body
    try t.expectNumber("if (true) ; else ; 7", 7);
    try t.expectNumber("while (false) ; 8", 8);
}

test "M10 classes: declaration in statement position is block-scoped (§15.7 / §14.3)" {
    // statement-form class declaration: the binding name resolves and methods work
    try t.expectNumber("class C { m() { return 7; } } new C().m()", 7);
    // a derived class declared as a statement; instance is `instanceof` the base
    try t.expectBool("class A {} class B extends A {} (new B()) instanceof A", true);
    // §15.7: a ClassDeclaration creates a block-scoped lexical binding (like `let`), NOT a
    // function-style binding that leaks to the enclosing scope — a class declared in a block
    // is not visible after the block.
    try t.expectStr("{ class Q {} } typeof Q", "undefined");
    try t.expectThrows("{ class Q {} } new Q()");
    // used before its declaration in the same scope → ReferenceError (no function-style hoisting
    // of the initialized binding — matches §14.3 lexical-binding ordering observably).
    try t.expectThrows("new D(); class D {}");
    // anonymous `class {}` is not a ClassDeclaration (statement position requires a name).
    try t.expectSyntaxError("class {}");
    // `class` must still work where it is an expression (parenthesized / assignment RHS).
    try t.expectNumber("var x = (class { m() { return 3; } }); new x().m()", 3);
    // a function* declaration in statement position parses and produces a generator.
    try t.expectNumber("function* g() { yield 5; } g().next().value", 5);
}

test "M10 do-while (§14.7.2): body runs, condition re-tests, at least once" {
    // accumulate while i<3
    try t.expectNumber("var i=0,s=0; do { s+=i; i++ } while (i<3); s", 3);
    // body runs at least once even when the condition is false up front
    try t.expectNumber("var n=0; do n++; while(false); n", 1);
    // unlabeled break exits the do-while
    try t.expectNumber("var i=0; do { if (i==2) break; i++ } while (i<10); i", 2);
    // unlabeled continue re-tests the condition (does NOT skip the increment here)
    try t.expectNumber("var i=0,s=0; do { i++; if (i==2) continue; s+=i } while (i<4); s", 8); // 1+3+4
    // trailing `;` is ASI-optional: `do x; while(c)` with no explicit `;` still parses
    try t.expectNumber("var i=0; do i++; while(i<3) i", 3);
}

test "M10 labeled break/continue (§14.13/§14.9/§14.8)" {
    // labeled break exits BOTH loops; the outer i stops at 0 (break fires when j==1, i still 0)
    try t.expectNumber("var i,j,last=-1; outer: for(i=0;i<3;i++){ for(j=0;j<3;j++){ if(j==1) break outer; last=i*10+j } } last", 0);
    // labeled continue restarts the OUTER loop: inner never increments s (continue before s++)
    try t.expectNumber("var s=0; outer: for(var i=0;i<3;i++){ for(var j=0;j<3;j++){ if(j==0) continue outer; s++ } } s", 0);
    // labeled continue that does some work first: inner runs once per outer (j==1 continues outer)
    try t.expectNumber("var s=0; outer: for(var i=0;i<3;i++){ for(var j=0;j<3;j++){ s++; if(j==0) continue outer } } s", 3);
    // labeled break on a do-while loop
    try t.expectNumber("var n=0; L: do { n++; if (n==2) break L; } while (n<10); n", 2);
    // a labeled block: `break label` exits the block, skipping the rest
    try t.expectNumber("var x=1; blk: { x=2; break blk; x=99; } x", 2);
    // label on a while loop, continue label
    try t.expectNumber("var i=0,s=0; L: while(i<5){ i++; if(i%2==0) continue L; s+=i } s", 9); // 1+3+5
    // unlabeled break/continue still work inside a single loop
    try t.expectNumber("var s=0; for(var i=0;i<5;i++){ if(i==3) break; s+=i } s", 3); // 0+1+2
    try t.expectNumber("var s=0; for(var i=0;i<5;i++){ if(i%2==0) continue; s+=i } s", 4); // 1+3
    // a label on a BLOCK only labels the block, NOT a loop nested inside it: an unlabeled break
    // inside that loop exits only the inner loop, and `break L` exits the block.
    try t.expectNumber("var s=0; L: { for(var i=0;i<5;i++){ if(i==2) break; s+=i } s+=100; } s", 101); // 0+1 then +100
    try t.expectNumber("var s=0; L: { for(var i=0;i<5;i++){ s+=i; if(i==1) break L; } s+=100; } s", 1); // 0+1, break L skips +100
    // a chain of labels on one loop: either label is a valid break target
    try t.expectNumber("var c=0; a: b: for(var i=0;i<3;i++){ for(var j=0;j<3;j++){ c++; if(c==2) break a; } } c", 2);
    // labeled break out of a switch wrapped in a label
    try t.expectNumber("var x=0; sw: switch(1){ case 1: x=5; break sw; case 2: x=9; } x", 5);
}

test "M10 labeled statements: parse-phase Early Errors (§14.13.1/§14.8.1/§14.9.1)" {
    // break/continue to an undefined label → SyntaxError
    try t.expectSyntaxError("for(;;){ break nope; }");
    try t.expectSyntaxError("for(;;){ continue nope; }");
    // continue targeting a non-iteration label is a SyntaxError
    try t.expectSyntaxError("blk: { continue blk; }");
    // duplicate nested label is a SyntaxError
    try t.expectSyntaxError("a: a: ;");
    // a label does not cross a function boundary
    try t.expectSyntaxError("L: for(;;){ function f(){ break L; } }");
    // unlabeled break/continue outside any loop/switch is a SyntaxError
    try t.expectSyntaxError("break;");
    try t.expectSyntaxError("continue;");
    // `continue` is illegal inside a switch (no enclosing iteration)
    try t.expectSyntaxError("switch(0){ case 0: continue; }");
}

test "M4 classes: body is strict (Cycle 1, §15.7)" {
    // §15.7: a class body is always strict, so a method binding `eval`/`arguments` as a param is a
    // SyntaxError even with no directive and in sloppy RunMode.
    try t.expectSyntaxError("class C { m(eval) {} }");
    try t.expectSyntaxError("class C { m(arguments) {} }");
    // a duplicate parameter in a method is a SyntaxError (methods enforce this in every mode)
    try t.expectSyntaxError("class C { m(a, a) {} }");
}

test "M4 classes: unsupported element syntax still parse-rejects (Cycle 1 scope)" {
    // generator methods landed in M9 Cycle 2; async methods / async generator methods landed in M11
    // Cycle 1 (§15.8/§15.6 parsing) — they now PARSE (covered by the M11 async tests below).
    try t.expectNoSyntaxErrorStrict("class C { async m() {} }"); // async method (M11)
    try t.expectNoSyntaxErrorStrict("class C { async *m() {} }"); // async generator method (M11)
    // a ClassDeclaration requires a name
    try t.expectSyntaxError("class {}");
}

test "M4 classes: extends + super (Cycle 2, §15.7.14 / §13.3.5 / §13.3.7)" {
    // extends links the chains; super() runs the parent ctor on `this`; own fields after super().
    try t.expectNumber(
        "class A { constructor() { this.x = 1; } } " ++
            "class B extends A { constructor() { super(); this.y = 2; } } " ++
            "var b = new B(); b.x + b.y",
        3,
    );
    // an instance of a derived class is `instanceof` both the derived and the base class
    try t.expectBool(
        "class A {} class B extends A {} (new B()) instanceof A",
        true,
    );
    try t.expectBool(
        "class A {} class B extends A {} (new B()) instanceof B",
        true,
    );
    // super.method() invokes the parent method with `this` = the current instance
    try t.expectNumber(
        "class A { m() { return 10; } } " ++
            "class B extends A { m() { return super.m() + 5; } } " ++
            "new B().m()",
        15,
    );
    // super.method() can read instance state via the current `this`
    try t.expectNumber(
        "class A { who() { return this.v; } } " ++
            "class B extends A { constructor() { super(); this.v = 7; } get() { return super.who(); } } " ++
            "new B().get()",
        7,
    );
    // super.prop reads a parent prototype data property (not the instance's own)
    try t.expectNumber(
        "class A { constructor() { this.label = 99; } } A.prototype.label = 1; " ++
            "class B extends A { read() { return super.label; } } " ++
            "var b = new B(); b.read()",
        1,
    );
    // static inheritance: a static member of the base is reachable through the derived constructor
    try t.expectNumber(
        "class A { static s() { return 42; } } class B extends A {} B.s()",
        42,
    );
    try t.expectNumber(
        "class A { static n = 8; } class B extends A {} B.n",
        8,
    );
    // default derived constructor forwards args to super(...)
    try t.expectNumber(
        "class A { constructor(a, b) { this.s = a + b; } } class B extends A {} new B(40, 2).s",
        42,
    );
    // extends an arbitrary expression (the heritage is a LeftHandSideExpression)
    try t.expectNumber(
        "var box = { Base: class { constructor() { this.v = 5; } } }; " ++
            "class D extends box.Base { constructor() { super(); this.v += 1; } } new D().v",
        6,
    );
    // a three-level chain: C extends B extends A — each super() initializes its level
    try t.expectNumber(
        "class A { constructor() { this.a = 1; } } " ++
            "class B extends A { constructor() { super(); this.b = 2; } } " ++
            "class C extends B { constructor() { super(); this.c = 3; } } " ++
            "var o = new C(); o.a + o.b + o.c",
        6,
    );
    // derived instance fields initialize AFTER super() (so they can see parent-set state)
    try t.expectNumber(
        "class A { constructor() { this.base = 10; } } " ++
            "class B extends A { y = this.base + 1; } " ++
            "new B().y",
        11,
    );
    // extends null: the prototype chain links to null (instance is not instanceof Object via chain)
    try t.expectStr("class A extends null {} typeof A", "function");
}

test "M4 classes: super early errors (Cycle 2, §13.3.5.1 / §13.3.7.1)" {
    // super(...) outside a derived constructor is a SyntaxError
    try t.expectSyntaxError("class A { constructor() { super(); } }"); // non-derived ctor
    try t.expectSyntaxError("class A extends Object { m() { super(); } }"); // non-constructor method
    try t.expectSyntaxError("function f() { super(); }"); // outside any class
    try t.expectSyntaxError("super();"); // top level
    // super.prop outside a method is a SyntaxError
    try t.expectSyntaxError("function f() { return super.x; }");
    try t.expectSyntaxError("super.x;"); // top level
    // a bare `super` (not a SuperProperty/SuperCall) is always a SyntaxError
    try t.expectSyntaxError("class A extends Object { m() { return super; } }");
    // extends a non-constructor, non-null value throws a TypeError at runtime
    try t.expectThrows("class B extends 5 {}");
    try t.expectThrows("class B extends ({}) {}");
}

test "M4 classes: accessors get/set (Cycle 3, §15.7 / §13.2.5.6)" {
    // a getter on the prototype: `.x` invokes it
    try t.expectNumber("class C { get x() { return 5; } } new C().x", 5);
    // a setter stores via the instance; a separate getter reads it back (get+set merge to one prop)
    try t.expectNumber(
        "class C { set x(v) { this._x = v; } get x() { return this._x; } } " ++
            "var c = new C(); c.x = 9; c.x",
        9,
    );
    // a setter-only accessor: assignment runs the setter (here recording into another field)
    try t.expectNumber(
        "class C { set x(v) { this.seen = v + 1; } } var c = new C(); c.x = 41; c.seen",
        42,
    );
    // a getter reading instance state set by the constructor
    try t.expectNumber(
        "class C { constructor() { this.v = 3; } get doubled() { return this.v * 2; } } new C().doubled",
        6,
    );
    // static getter on the constructor
    try t.expectNumber("class C { static get answer() { return 42; } } C.answer", 42);
    // static setter
    try t.expectNumber(
        "class C { static set v(x) { C._v = x; } } C.v = 7; C._v",
        7,
    );
    // an accessor carries [[HomeObject]] — super.x inside a getter resolves to the parent accessor
    try t.expectNumber(
        "class A { get x() { return 100; } } " ++
            "class B extends A { get x() { return super.x + 1; } } " ++
            "new B().x",
        101,
    );
}

test "M4 classes: computed names (Cycle 3, §15.7)" {
    // computed method name `[expr]() {}`
    try t.expectNumber("class C { ['a' + 'b']() { return 1; } } new C().ab()", 1);
    // computed instance field name `[expr] = init`
    try t.expectNumber("class C { ['v' + 1] = 7; } new C().v1", 7);
    // a bare computed field `[expr];` is created undefined
    try t.expectStr("var k = 'q'; class C { [k]; } typeof new C().q", "undefined");
    // computed static method name
    try t.expectNumber("class C { static ['s' + 'm']() { return 9; } } C.sm()", 9);
    // computed static field name
    try t.expectNumber("class C { static ['n' + 1] = 4; } C.n1", 4);
    // computed accessor (getter) name
    try t.expectNumber("class C { get ['g' + 'x']() { return 8; } } new C().gx", 8);
    // computed accessor (setter) name round-trips with a matching computed getter
    try t.expectNumber(
        "var k = 'p'; class C { set [k](v) { this._p = v; } get [k]() { return this._p; } } " ++
            "var c = new C(); c.p = 5; c.p",
        5,
    );
    // the key expression is evaluated at class-definition time, in definition order
    try t.expectStr(
        "var log = ''; var a = () => { log += 'a'; return 'm1'; }; " ++
            "var b = () => { log += 'b'; return 'm2'; }; " ++
            "class C { [a()]() {} [b()]() {} } log",
        "ab",
    );
    // a numeric computed key is ToString'd
    try t.expectNumber("class C { [1 + 1]() { return 3; } } new C()[2]()", 3);
}

test "M4 classes: private fields (Cycle 4, §15.7 PrivateName)" {
    // a private field read back through a method (`this.#x`)
    try t.expectNumber("class C { #x = 1; getX() { return this.#x; } } new C().getX()", 1);
    // a bare private field defaults to undefined
    try t.expectStr("class C { #x; peek() { return typeof this.#x; } } new C().peek()", "undefined");
    // private field reassignment via `this.#x = …`
    try t.expectNumber("class C { #x = 1; bump() { this.#x = this.#x + 10; return this.#x; } } new C().bump()", 11);
    // compound assignment to a private field
    try t.expectNumber("class C { #x = 5; go() { this.#x += 3; return this.#x; } } new C().go()", 8);
    // a private field initializer may reference an outer binding + `this`
    try t.expectNumber("var k = 9; class C { #x = k; getX() { return this.#x; } } new C().getX()", 9);
    // private names do NOT collide with same-named public properties
    try t.expectNumber("class C { #x = 1; constructor() { this.x = 100; } both() { return this.x + this.#x; } } new C().both()", 101);
    // a private name is NOT reachable as an ordinary property / not enumerable via `in`
    try t.expectBool("class C { #x = 1; static probe(o) { return 'x' in o; } } C.probe(new C())", false);
}

test "M4 classes: private name brand check — TypeError on a foreign object (Cycle 4, §15.7)" {
    // reading `o.#x` on an object that never got the brand is a TypeError
    try t.expectThrows("class C { #x = 1; static read(o) { return o.#x; } } C.read({})");
    // writing `o.#x` on a foreign object is a TypeError too
    try t.expectThrows("class C { #x = 1; static write(o) { o.#x = 2; } } C.write({})");
    // the thrown error is specifically a TypeError; an instance of the class is fine
    try t.expectStr(
        "class C { #x = 1; static read(o) { return o.#x; } } " ++
            "var n = ''; try { C.read({}); } catch (e) { n = e.name; } n",
        "TypeError",
    );
    try t.expectNumber("class C { #x = 7; static read(o) { return o.#x; } } C.read(new C())", 7);
    // reading a private name on a primitive is a TypeError
    try t.expectThrows("class C { #x = 1; static read(o) { return o.#x; } } C.read(5)");
}

test "M4 classes: private methods and accessors (Cycle 4, §15.7)" {
    // a private method, called via `this.#m()`
    try t.expectNumber("class C { #m() { return 42; } call() { return this.#m(); } } new C().call()", 42);
    // a private method is shared but read-only: assigning to it is a TypeError
    try t.expectThrows("class C { #m() {} go() { this.#m = 1; } } new C().go()");
    // a private getter
    try t.expectNumber("class C { get #v() { return 5; } read() { return this.#v; } } new C().read()", 5);
    // a private get/set pair round-trips
    try t.expectNumber(
        "class C { set #v(x) { this._x = x; } get #v() { return this._x; } go() { this.#v = 9; return this.#v; } } new C().go()",
        9,
    );
    // a private field initializer may call an earlier private method (brand installed in order)
    try t.expectNumber(
        "class C { #m() { return 5; } #x = this.#m() + 1; read() { return this.#x; } } new C().read()",
        6,
    );
    // private members survive inheritance (each class adds its own brand)
    try t.expectStr(
        "class A { #a = 1; ga() { return this.#a; } } " ++
            "class B extends A { #b = 2; gb() { return this.#b; } } " ++
            "var o = new B(); o.ga() + ',' + o.gb()",
        "1,2",
    );
}

test "M4 classes: static private members (Cycle 4, §15.7)" {
    // a static private method, called via the constructor
    try t.expectNumber("class C { static #m() { return 8; } static call() { return C.#m(); } } C.call()", 8);
    // a static private field
    try t.expectNumber("class C { static #n = 3; static read() { return C.#n; } } C.read()", 3);
    // a static private accessor
    try t.expectNumber("class C { static get #v() { return 6; } static read() { return C.#v; } } C.read()", 6);
}

test "M4 classes: static initialization blocks (Cycle 4, §15.7.11)" {
    // a static block runs at class definition with `this` = the constructor
    try t.expectNumber("class C { static y; static { this.y = 7; } } C.y", 7);
    // multiple static blocks run in source order, interleaved with static fields
    try t.expectStr(
        "class C { static a = 1; static { this.b = this.a + 1; } static c = this.b + 1; } " ++
            "C.a + ',' + C.b + ',' + C.c",
        "1,2,3",
    );
    try t.expectStr(
        "class C { static log = ''; static { this.log += '1'; } static { this.log += '2'; } } C.log",
        "12",
    );
    // a static block can use `super.x` (its [[HomeObject]] is the constructor)
    try t.expectNumber(
        "class A { static v() { return 9; } } " ++
            "class B extends A { static r; static { this.r = super.v(); } } B.r",
        9,
    );
}

test "M4 classes: `#x in obj` ergonomic brand check (Cycle 4, §13.10.1)" {
    // true for an instance carrying the brand, false for a foreign object (no throw)
    try t.expectBool("class C { #x = 1; static has(o) { return #x in o; } } C.has(new C())", true);
    try t.expectBool("class C { #x = 1; static has(o) { return #x in o; } } C.has({})", false);
    // false for a non-object (no throw, unlike ordinary `in`)
    try t.expectBool("class C { #x = 1; static has(o) { return #x in o; } } C.has(5)", false);
    // the brand check works for a private method's name too
    try t.expectBool("class C { #m() {} static has(o) { return #m in o; } } C.has(new C())", true);
}

test "M4 classes: private-name early errors (Cycle 4, §15.7.1)" {
    // a PrivateIdentifier outside any class body is a SyntaxError
    try t.expectSyntaxError("var o = {}; o.#x");
    try t.expectSyntaxError("#x");
    try t.expectSyntaxError("#x in {}");
    // a bare `#` (not a private identifier) is a lexer error → SyntaxError
    try t.expectSyntaxError("var x = # 1;");
    // `#constructor` is not a legal private name
    try t.expectSyntaxError("class C { #constructor() {} }");
    try t.expectSyntaxError("class C { #constructor = 1; }");
    // a duplicate private name is a SyntaxError (but a get/set pair may share a name)
    try t.expectSyntaxError("class C { #x = 1; #x = 2; }");
    try t.expectSyntaxError("class C { #m() {} #m() {} }");
    try t.expectNoSyntaxErrorStrict("class C { get #v() {} set #v(x) {} }");
    // a private name in an object literal is a SyntaxError
    try t.expectSyntaxError("var o = { #x: 1 };");
    try t.expectSyntaxError("var o = { get #x() {} };");
}

test "M4 classes: §15.7.1 class early errors + legal positives (Cycle 5, close)" {
    // ----- Early Errors (parse-phase SyntaxError) — these MUST keep rejecting -----
    // §15.7.1 ClassBody may declare at most one (non-static) `constructor`.
    try t.expectSyntaxError("class C { constructor() {} constructor() {} }");
    // `constructor` may not be a getter/setter/field (only an ordinary method).
    try t.expectSyntaxError("class C { get constructor() {} }");
    try t.expectSyntaxError("class C { set constructor(v) {} }");
    try t.expectSyntaxError("class C { constructor = 1; }");
    try t.expectSyntaxError("class C { \"constructor\" = 1; }"); // string-named field `constructor`
    // a `static` member named `prototype` is forbidden (method/accessor/field).
    try t.expectSyntaxError("class C { static prototype() {} }");
    try t.expectSyntaxError("class C { static get prototype() {} }");
    try t.expectSyntaxError("class C { static prototype = 1; }");

    // ----- Legal positives — these MUST NOT be rejected (over-rejection guard) -----
    // §15.7 ClassBody `;` empty elements are legal and ignored.
    try t.expectNumber("var C = class { ; ; m() { return 5; } ; }; new C().m()", 5);
    // `static constructor` is a legal STATIC method (the §15.7.1 ctor restriction is non-static only).
    try t.expectNumber("var C = class { static constructor() { return 9; } }; C.constructor()", 9);
    // one non-static `constructor` PLUS a `static constructor` is legal (only one non-static counts).
    try t.expectNoSyntaxErrorStrict("var C = class { constructor() {} static constructor() {} }");
    // a STATIC accessor named `constructor` is legal (only `prototype` is forbidden when static).
    try t.expectNumber("var C = class { static get constructor() { return 3; } }; C.constructor", 3);
    // a non-static method/accessor named `prototype` is legal (only `static prototype` is barred).
    try t.expectNumber("var C = class { prototype() { return 8; } }; new C().prototype()", 8);
    try t.expectNumber("var C = class { get prototype() { return 6; } }; new C().prototype", 6);
    // a computed `[\"constructor\"]` method is NOT the constructor (§15.7.1 keys off the *static*
    // StringValue), so it does not clash with the real `constructor` — legal.
    try t.expectNoSyntaxErrorStrict("var C = class { constructor() {} [\"constructor\"]() {} }");
    // `extends` an invalid target is a RUNTIME TypeError, not a parse Early Error.
    try t.expectNoSyntaxErrorStrict("var C = class extends 5 {}");
}

test "M3 object literal sugar: shorthand, computed, method (US6, §13.2.5)" {
    // shorthand `{x}` ≡ `{x: x}`
    try t.expectNumber("var x = 42; var o = {x}; o.x", 42);
    try t.expectNumber("var a = 1, b = 2; var o = {a, b}; o.a + o.b", 3);
    // computed key `{[expr]: v}`
    try t.expectNumber("var k = 'foo'; var o = {[k]: 7}; o.foo", 7);
    try t.expectStr("var o = {['a' + 'b']: 'hi'}; o.ab", "hi");
    try t.expectNumber("var i = 1; var o = {[i + 1]: 9}; o[2]", 9); // numeric computed key
    // method shorthand `{m(){…}}`
    try t.expectNumber("var o = {add(a, b){ return a + b; }}; o.add(40, 2)", 42);
    // method `this` binds to the receiver
    try t.expectNumber("var o = {v: 5, get5(){ return this.v; }}; o.get5()", 5);
    // mixed forms in one literal
    try t.expectNumber("var n = 'q'; var o = {a: 1, [n]: 2, m(){ return 3; }}; o.a + o.q + o.m()", 6);
}
