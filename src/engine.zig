//! Engine entry point: source text → observable result. Wires lexer → parser → interpreter
//! and maps outcomes to an EvaluationResult the CLI and the Test262 harness consume.
const std = @import("std");
const Value = @import("value.zig").Value;
const Parser = @import("parser.zig").Parser;
const Interpreter = @import("interpreter.zig").Interpreter;
const Environment = @import("environment.zig").Environment;
const builtins = @import("builtins.zig");

/// ECMA-262 distinguishes strict and sloppy mode. The M0 expression subset has no
/// observable difference yet; the parameter is threaded now so the harness can run both.
pub const RunMode = enum { sloppy, strict };

pub const EvaluationResult = union(enum) {
    normal: Value,
    thrown: Value,
    syntax_error: []const u8,
    step_limit,
};

pub const default_step_limit: u64 = 10_000_000;

pub fn evaluate(arena: std.mem.Allocator, source: []const u8, mode: RunMode) error{OutOfMemory}!EvaluationResult {
    return evaluateWithLimit(arena, source, mode, default_step_limit);
}

/// Like `evaluate`, but with an explicit interpreter step cap (the watchdog, research D8).
/// The Test262 harness uses this to bound runaway tests deterministically.
pub fn evaluateWithLimit(arena: std.mem.Allocator, source: []const u8, mode: RunMode, step_limit: u64) error{OutOfMemory}!EvaluationResult {
    _ = mode; // not yet observable for the M0 subset
    const program = Parser.parse(arena, source) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .syntax_error = @errorName(e) },
    };
    const global = Environment.create(arena, null) catch return error.OutOfMemory;
    builtins.setup(arena, global) catch return error.OutOfMemory;
    var interp = Interpreter{ .arena = arena, .step_limit = step_limit, .globals = global };
    const completion = interp.run(program, global) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StepLimitExceeded => return .step_limit,
    };
    return switch (completion) {
        .normal => |v| .{ .normal = v },
        .throw => |v| .{ .thrown = v },
        .ret => |v| .{ .normal = v }, // stray top-level return → its value
        // TODO(Cycle B/D): top-level return/break/continue should be parse-phase SyntaxErrors.
        .brk, .cont => .{ .normal = .undefined },
    };
}

const testing = std.testing;

fn expectNumber(src: []const u8, want: f64) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try evaluate(arena_state.allocator(), src, .sloppy);
    try testing.expect(r == .normal);
    try testing.expect(r.normal == .number);
    try testing.expectEqual(want, r.normal.number);
}

test "arithmetic" {
    try expectNumber("1 + 2", 3);
    try expectNumber("2 * (3 + 4)", 14);
    try expectNumber("10 - 4 - 3", 3); // left-assoc
    try expectNumber("7 % 3", 1);
    try expectNumber("2 + 3 * 4", 14); // precedence
    try expectNumber("-5 + 8", 3);
}

test "comments are skipped (§12.4)" {
    try expectNumber("/* block */ 1 + 2", 3);
    try expectNumber("1 + 2 // trailing line comment", 3);
    try expectNumber("/*---\ndescription: frontmatter\n---*/\n40 + 2", 42);
}

test "syntax error is reported, not crashed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try evaluate(arena_state.allocator(), "1 +", .sloppy);
    try testing.expect(r == .syntax_error);
}

fn expectThrows(src: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try evaluate(arena_state.allocator(), src, .sloppy);
    try testing.expect(r == .thrown);
}

fn expectStr(src: []const u8, want: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try evaluate(arena_state.allocator(), src, .sloppy);
    try testing.expect(r == .normal and r.normal == .string);
    try testing.expectEqualStrings(want, r.normal.string);
}

fn expectBool(src: []const u8, want: bool) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try evaluate(arena_state.allocator(), src, .sloppy);
    try testing.expect(r == .normal and r.normal == .boolean);
    try testing.expectEqual(want, r.normal.boolean);
}

fn expectSyntaxError(src: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try evaluate(arena_state.allocator(), src, .sloppy);
    try testing.expect(r == .syntax_error);
}

test "bindings: var/let/const, assignment, block scope (US1)" {
    try expectNumber("var x = 40; x + 2", 42);
    try expectNumber("var x = 1; x = x + 5; x", 6);
    try expectNumber("let a = 3; { let a = 10; } a", 3); // inner block shadows, outer unchanged
    try expectNumber("const c = 7; c", 7);
}

test "bindings: errors (US1)" {
    try expectThrows("const c = 1; c = 2; c"); // assignment to constant → TypeError
    try expectThrows("missingVar"); // ReferenceError
    try expectThrows("{ let y = 1; } y"); // out of scope → ReferenceError
}

test "objects: literals, member/index access & assignment (US3)" {
    try expectNumber("var o = {x: 41}; o.x = o.x + 1; o.x", 42);
    try expectNumber("var o = {a: 1, b: 2}; o.a + o.b", 3);
    try expectNumber("var o = {}; o[\"k\"] = 7; o[\"k\"]", 7);
    try expectNumber("var o = {nested: {v: 10}}; o.nested.v", 10); // member chain
}

test "objects: access on null/undefined throws TypeError (US3)" {
    try expectThrows("var x = null; x.y");
    try expectThrows("undefined.z");
}

test "functions: declarations, calls, closures, arity (US2)" {
    try expectNumber("function add(a, b) { return a + b; } add(40, 2)", 42);
    try expectNumber("var sq = function (x) { return x * x; }; sq(7)", 49); // function expression
    try expectNumber("function k(a, b) { return a; } k(5, 9)", 5); // extra arg ignored
    try expectNumber("function f() { } f(); 7", 7); // no return → undefined; program continues
    // closure captures the enclosing binding:
    try expectNumber("function mk() { let n = 10; function inner() { return n; } return inner; } mk()()", 10);
}

test "functions: calling a non-function throws; runaway recursion → RangeError (US2)" {
    try expectThrows("var x = 5; x()"); // not a function → TypeError
    try expectThrows("function f() { return f(); } f()"); // unbounded recursion → RangeError (depth guard)
}

test "control flow: if/while/for, break/continue (US4)" {
    try expectNumber("var x = 5; if (x > 3) x = 100; x", 100);
    try expectNumber("var x = 1; if (x > 3) { x = 100; } else { x = 2; } x", 2);
    try expectNumber("var s = 0; var i = 0; while (i < 5) { s = s + i; i = i + 1; } s", 10);
    try expectNumber("var s = 0; for (var i = 0; i < 10; i = i + 1) { s = s + i; } s", 45);
    try expectNumber("var s = 0; for (var i = 0; i < 10; i = i + 1) { if (i > 4) break; s = s + i; } s", 10);
}

test "control flow: terminating recursion now works (fib)" {
    try expectNumber("function fib(n) { if (n < 2) return n; return fib(n - 1) + fib(n - 2); } fib(10)", 55);
}

test "control flow: throw / try / catch / finally (US4)" {
    try expectNumber("var x = 0; try { throw 7; } catch (e) { x = e; } x", 7);
    try expectNumber("var x = 0; try { x = 1; } finally { x = x + 10; } x", 11);
    // finally runs even when catch rethrows is out of scope here; basic ordering:
    try expectNumber("var x = 0; try { throw 1; } catch (e) { x = e; } finally { x = x + 100; } x", 101);
}

test "E1: typeof, logical ops, new + instanceof (US5)" {
    // typeof (incl. unresolved identifier → "undefined", no throw)
    try expectStr("typeof 42", "number");
    try expectStr("typeof \"x\"", "string");
    try expectStr("typeof undefinedGlobalThing", "undefined");
    try expectStr("function f(){} typeof f", "function");
    // logical short-circuit (returns operand values, not coerced booleans)
    try expectNumber("0 || 5", 5);
    try expectNumber("7 && 9", 9);
    try expectNumber("var hit = 0; function side(){ hit = 1; return 1; } true || side(); hit", 0); // short-circuit: side() not called
    // new + constructor + instanceof
    try expectNumber("function P(v){ this.v = v; } var p = new P(42); p.v", 42);
    try expectBool("function P(){} var p = new P(); p instanceof P", true);
    try expectBool("function P(){} function Q(){} (new P()) instanceof Q", false);
}

test "E2: Error family, String, Object, typed engine errors (US5)" {
    try expectStr("new TypeError(\"boom\").name", "TypeError");
    try expectStr("new RangeError(\"x\").message", "x");
    try expectBool("(new TypeError(\"y\")) instanceof TypeError", true);
    try expectBool("(new RangeError()) instanceof TypeError", false);
    try expectStr("String(42)", "42");
    try expectStr("typeof Object", "function");
    // engine-thrown errors are now real objects, classifiable by `.name`:
    try expectStr("var n = \"\"; try { null.x; } catch (e) { n = e.name; } n", "TypeError");
    try expectStr("var n = \"\"; try { missingThing; } catch (e) { n = e.name; } n", "ReferenceError");
}

test "E4: ternary, switch, compound assignment (US5)" {
    try expectNumber("var x = 5; x > 3 ? 100 : 2", 100);
    try expectNumber("var x = 1; x > 3 ? 100 : 2", 2);
    try expectNumber("var s = 0; s += 10; s -= 3; s *= 2; s", 14);
    try expectNumber("var o = {n: 1}; o.n += 41; o.n", 42);
    // switch with fall-through + break
    try expectNumber("var r = 0; switch (2) { case 1: r = 1; break; case 2: r = 2; break; default: r = 9; } r", 2);
    try expectNumber("var r = 0; switch (7) { case 1: r = 1; break; default: r = 9; } r", 9);
    // ++ / -- (prefix + postfix)
    try expectNumber("var i = 0; i++; i++; i", 2);
    try expectNumber("var i = 5; var j = i++; j", 5); // postfix yields old value
    try expectNumber("var i = 5; var j = ++i; j", 6); // prefix yields new value
    try expectNumber("var s = 0; for (var i = 0; i < 5; i++) { s += i; } s", 10);
}

test "M2 arrays: literals, index, length, methods (US1)" {
    try expectNumber("[10, 20, 30].length", 3);
    try expectNumber("[10, 20, 30][1]", 20);
    try expectNumber("var a = [1, 2]; a.push(3); a[2]", 3);
    try expectNumber("var a = [1, 2, 3]; a.push(4); a.length", 4);
    try expectNumber("[1, 2, 3].indexOf(2)", 1);
    try expectNumber("[5, 6, 7].pop()", 7);
    try expectBool("[1, 2, 3].includes(2)", true);
    try expectBool("Array.isArray([1, 2])", true);
    try expectBool("Array.isArray(5)", false);
    try expectStr("[1, 2, 3].join(\"-\")", "1-2-3");
    try expectNumber("var a = []; a[3] = 9; a.length", 4); // index assignment extends length
    try expectNumber("[1, 2, 3, 4].slice(1, 3).length", 2);
    try expectNumber("[1, 2, 3].map(function (x) { return x * 2; })[2]", 6);
    try expectNumber("var s = 0; [1, 2, 3, 4].forEach(function (x) { s += x; }); s", 10);
}

test "M2 strings: length, index, methods (US2)" {
    try expectNumber("\"hello\".length", 5);
    try expectStr("\"abc\".charAt(1)", "b");
    try expectNumber("\"abc\".charCodeAt(0)", 97);
    try expectNumber("\"hello world\".indexOf(\"world\")", 6);
    try expectBool("\"hello\".includes(\"ell\")", true);
    try expectStr("\"Hello\".toUpperCase()", "HELLO");
    try expectStr("\"Hello\".toLowerCase()", "hello");
    try expectStr("\"hello\".slice(1, 3)", "el");
    try expectStr("\"abc\"[0]", "a");
    try expectNumber("\"a,b,c\".split(\",\").length", 3);
    try expectStr("\"a,b,c\".split(\",\")[2]", "c");
}

test "M3 operators: **, bitwise, shifts, in (US1)" {
    try expectNumber("2 ** 10", 1024);
    try expectNumber("2 ** 3 ** 2", 512); // right-assoc: 2**(3**2)=2**9
    try expectNumber("5 & 3", 1);
    try expectNumber("5 | 2", 7);
    try expectNumber("5 ^ 1", 4);
    try expectNumber("~5", -6);
    try expectNumber("1 << 4", 16);
    try expectNumber("256 >> 2", 64);
    try expectNumber("-1 >>> 28", 15);
    try expectBool("\"x\" in {x: 1}", true);
    try expectBool("\"y\" in {x: 1}", false);
    try expectBool("0 in [9]", true);
}

test "M3 template literals (US2)" {
    try expectStr("`hello`", "hello");
    try expectStr("`a${1 + 1}b`", "a2b");
    try expectStr("var x = 5; `x is ${x}`", "x is 5");
    try expectStr("`${1}${2}${3}`", "123");
    try expectStr("`nested ${`in${\"ner\"}`}`", "nested inner");
    try expectStr("`line\\nbreak`", "line\nbreak");
}

test "M3 spread & rest (US3)" {
    // spread in array literals
    try expectNumber("[...[1, 2, 3]].length", 3);
    try expectNumber("var a = [1, 2]; [0, ...a, 3].length", 4);
    try expectNumber("var a = [1, 2]; [0, ...a, 3][2]", 2);
    try expectNumber("[...[1, 2], ...[3, 4]].length", 4);
    try expectStr("[...\"ab\"].join(\"-\")", "a-b"); // string spreads to chars
    // spread in call args
    try expectNumber("function add(a, b, c) { return a + b + c; } add(...[1, 2, 3])", 6);
    try expectNumber("function f(a, b) { return a + b; } var xs = [10, 20]; f(...xs)", 30);
    // rest parameters
    try expectNumber("function f(...xs) { return xs.length; } f(1, 2, 3, 4)", 4);
    try expectNumber("function f(a, ...xs) { return a + xs.length; } f(9, 1, 2, 3)", 12);
    try expectNumber("function f(...xs) { return xs.length; } f()", 0);
    try expectNumber("function f(a, b, ...xs) { return xs[0]; } f(1, 2, 7, 8)", 7);
    // spread + rest combined
    try expectNumber("function f(...xs) { return xs[1]; } f(...[5, 6, 7])", 6);
}

test "M3 destructuring: array patterns (US4)" {
    // basic + multiple bindings (§13.3.3 ArrayBindingPattern)
    try expectNumber("var [a, b] = [1, 2]; a + b", 3);
    try expectNumber("let [a, b, c] = [10, 20, 30]; a + b + c", 60);
    // elision / hole
    try expectNumber("var [a, , c] = [1, 2, 3]; a + c", 4);
    // default values (applied only when undefined)
    try expectNumber("const [a, b = 5] = [1]; a + b", 6);
    try expectNumber("const [a, b = 5] = [1, 2]; a + b", 3);
    // rest element in pattern
    try expectNumber("var [a, ...rest] = [1, 2, 3, 4]; rest.length", 3);
    try expectNumber("var [a, ...rest] = [1, 2, 3, 4]; rest[1]", 3);
    try expectNumber("var [a, ...rest] = [9]; rest.length", 0);
    // missing values → undefined unless a default is present
    try expectStr("var [a, b] = [1]; typeof b", "undefined");
    // string is iterable
    try expectStr("var [a, b] = \"hi\"; a + b", "hi");
}

test "M3 destructuring: object patterns (US4)" {
    // shorthand (§13.3.3 ObjectBindingPattern)
    try expectNumber("var {x, y} = {x: 1, y: 2}; x + y", 3);
    // renaming `key: target`
    try expectNumber("let {x: a, y: b} = {x: 10, y: 20}; a + b", 30);
    // default value
    try expectNumber("const {x = 1} = {}; x", 1);
    try expectNumber("const {x = 1} = {x: 7}; x", 7);
    // rest property
    try expectNumber("var {x, ...rest} = {x: 1, y: 2, z: 3}; rest.y + rest.z", 5);
    // destructuring null/undefined throws
    try expectThrows("var {x} = null;");
    try expectThrows("var {x} = undefined;");
}

test "M3 destructuring: nested patterns (US4)" {
    try expectNumber("var [{a}, [b]] = [{a: 5}, [7]]; a + b", 12);
    try expectNumber("var {p: [a, b]} = {p: [3, 4]}; a + b", 7);
    try expectNumber("var [{x: y = 9}] = [{}]; y", 9);
    try expectNumber("var {a: {b}} = {a: {b: 42}}; b", 42);
}

test "M3 destructuring: function parameters (US4)" {
    // array pattern param
    try expectNumber("function f([a, b]) { return a + b; } f([3, 4])", 7);
    // object pattern param
    try expectNumber("function f({x, y}) { return x * y; } f({x: 3, y: 4})", 12);
    // default param value
    try expectNumber("function f(a, b = 10) { return a + b; } f(5)", 15);
    try expectNumber("function f(a, b = 10) { return a + b; } f(5, 1)", 6);
    // mixed array + object pattern params
    try expectNumber("function f([a, b], {x}) { return a + b + x; } f([1, 2], {x: 3})", 6);
    // pattern param with default + nested
    try expectNumber("function f({a = 1, b = 2} = {}) { return a + b; } f()", 3);
    try expectNumber("function f({a = 1, b = 2} = {}) { return a + b; } f({a: 10})", 12);
    // rest param destructured
    try expectNumber("function f(...[a, b]) { return a + b; } f(4, 5)", 9);
}

test "M3 arrow functions: bodies & param forms (US5, §15.3)" {
    // expression body (implicit return), single un-parenthesized param
    try expectNumber("var f = x => x + 1; f(41)", 42);
    // block body with explicit return
    try expectNumber("var f = x => { return x * 2; }; f(21)", 42);
    // zero params + multi params
    try expectNumber("var f = () => 42; f()", 42);
    try expectNumber("var add = (a, b) => a + b; add(2, 3)", 5);
    // default param
    try expectNumber("var f = (a = 10) => a; f()", 10);
    try expectNumber("var f = (a = 10) => a; f(3)", 3);
    // destructuring params (object + array)
    try expectNumber("var f = ({x}, [y]) => x + y; f({x: 40}, [2])", 42);
    // rest param
    try expectNumber("var f = (...xs) => xs.length; f(1, 2, 3)", 3);
    // immediately-invoked parenthesized arrow (cover-grammar disambiguation)
    try expectNumber("((x) => x + 1)(41)", 42);
    // arrows returning closures (curried)
    try expectNumber("var mk = a => b => a + b; mk(40)(2)", 42);
}

test "M3 arrow functions: lexical this & not a constructor (US5, §15.3)" {
    // an arrow captures the enclosing `this` at creation, regardless of how it is later called
    try expectNumber(
        "var o = { v: 7, get: function() { var f = () => this.v; return f(); } }; o.get()",
        7,
    );
    // calling the arrow as another object's method must NOT rebind `this`
    try expectNumber(
        "var outer = { v: 1, make: function(){ return () => this.v; } };" ++
            " var arrow = outer.make(); var other = { v: 99, f: arrow }; other.f()",
        1,
    );
    // §15.3: arrows are not constructors
    try expectThrows("new (() => {})");
}

test "M3 arrow functions: early errors (US5, §15.3.1)" {
    // duplicate BoundNames are a SyntaxError in every mode (unlike a sloppy ordinary function)
    try expectSyntaxError("var f = (x, x) => 1;");
    try expectSyntaxError("var f = ([x], x) => 1;");
    try expectSyntaxError("var f = ({a: x}, x) => 1;");
    try expectSyntaxError("var f = (x, ...x) => 1;");
    // ASI restriction: no LineTerminator between ArrowParameters and `=>`
    try expectSyntaxError("var f = ()\n=> 1;");
    try expectSyntaxError("var f = x\n=> 1;");
    // distinct names + a newline *after* `=>` (before the body) are both fine
    try expectNumber("var f = (a, b) =>\n a + b; f(2, 3)", 5);
}

test "M3 class definitions rejected at parse (§15.7, unsupported)" {
    // classes are unsupported — `class` is reserved, so any class form is a parse-phase error
    try expectSyntaxError("class C {}");
    try expectSyntaxError("var C = class {};");
    try expectSyntaxError("var C = class { x = () => 1; };");
}

test "M3 object literal sugar: shorthand, computed, method (US6, §13.2.5)" {
    // shorthand `{x}` ≡ `{x: x}`
    try expectNumber("var x = 42; var o = {x}; o.x", 42);
    try expectNumber("var a = 1, b = 2; var o = {a, b}; o.a + o.b", 3);
    // computed key `{[expr]: v}`
    try expectNumber("var k = 'foo'; var o = {[k]: 7}; o.foo", 7);
    try expectStr("var o = {['a' + 'b']: 'hi'}; o.ab", "hi");
    try expectNumber("var i = 1; var o = {[i + 1]: 9}; o[2]", 9); // numeric computed key
    // method shorthand `{m(){…}}`
    try expectNumber("var o = {add(a, b){ return a + b; }}; o.add(40, 2)", 42);
    // method `this` binds to the receiver
    try expectNumber("var o = {v: 5, get5(){ return this.v; }}; o.get5()", 5);
    // mixed forms in one literal
    try expectNumber("var n = 'q'; var o = {a: 1, [n]: 2, m(){ return 3; }}; o.a + o.q + o.m()", 6);
}

test "M3 object spread: copy own enumerable props (US6, §13.2.5.4)" {
    try expectNumber("var a = {x: 1, y: 2}; var b = {...a}; b.x + b.y", 3);
    // later properties override earlier (spread then explicit)
    try expectNumber("var a = {x: 1}; var b = {...a, x: 9}; b.x", 9);
    // explicit then spread (spread wins)
    try expectNumber("var a = {x: 9}; var b = {x: 1, ...a}; b.x", 9);
    // null/undefined sources are ignored (no throw)
    try expectNumber("var b = {...null, ...undefined, z: 5}; b.z", 5);
    // array spread copies index props
    try expectStr("var o = {...[10, 20]}; '' + o[0] + o[1]", "1020");
}

test "M3 accessors: getters & setters (US6, §13.2.5.6 / §10.2.x)" {
    // getter invoked on read
    try expectNumber("var o = {get x(){ return 7; }}; o.x", 7);
    // getter sees `this`
    try expectNumber("var o = {v: 3, get x(){ return this.v * 2; }}; o.x", 6);
    // setter invoked on write
    try expectNumber("var o = {_v: 0, set x(val){ this._v = val; }}; o.x = 41; o._v", 41);
    // get + set pair on the same key
    try expectNumber(
        "var o = {_v: 1, get x(){ return this._v; }, set x(val){ this._v = val + 1; }};" ++
            " o.x = 10; o.x",
        11,
    );
    // a getter-only property: writing is a silent no-op (sloppy), read still works
    try expectNumber("var o = {get x(){ return 5; }}; o.x = 100; o.x", 5);
}

test "M3 optional chaining: short-circuit (US6, §13.3.9)" {
    // a?.b on a present object
    try expectNumber("var o = {b: 8}; o?.b", 8);
    // a?.b on null/undefined → undefined (no throw)
    try expectBool("var a = null; a?.b === undefined", true);
    try expectBool("var a = undefined; a?.b === undefined", true);
    // whole chain short-circuits: a?.b.c when a is null → undefined (does NOT throw on .c)
    try expectBool("var a = null; a?.b.c === undefined", true);
    try expectBool("var a = null; (a?.b.c.d.e) === undefined", true);
    // a?.[k] index form
    try expectNumber("var o = {x: 4}; o?.['x']", 4);
    try expectBool("var a = null; a?.[0] === undefined", true);
    // a?.() call form
    try expectNumber("var f = () => 9; f?.()", 9);
    try expectBool("var f = null; f?.() === undefined", true);
    // method call through a chain keeps the receiver
    try expectNumber("var o = {v: 6, m(){ return this.v; }}; o?.m()", 6);
    // present base, then short-circuit further in: o?.miss?.deep → undefined
    try expectBool("var o = {}; o?.miss?.deep === undefined", true);
}

test "M3 nullish coalescing: ?? & mixing early error (US6, §13.13)" {
    // a ?? b → a unless null/undefined
    try expectNumber("1 ?? 2", 1);
    try expectNumber("null ?? 1", 1);
    try expectNumber("undefined ?? 7", 7);
    // 0 and '' are NOT nullish — `??` keeps them (unlike `||`)
    try expectNumber("0 ?? 5", 0);
    try expectStr("'' ?? 'x'", "");
    try expectBool("false ?? true", false);
    // chained ??
    try expectNumber("null ?? undefined ?? 3", 3);
    // §13.13.1 Early Error: mixing ?? with || / && without parens is a SyntaxError
    try expectSyntaxError("a ?? b || c");
    try expectSyntaxError("a || b ?? c");
    try expectSyntaxError("a ?? b && c");
    try expectSyntaxError("a && b ?? c");
    // …but parentheses make it legal
    try expectNumber("null ?? (0 || 4)", 4);
    try expectNumber("(null || 2) ?? 9", 2);
}

test "deep recursion throws RangeError, not a segfault" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "1");
    var i: usize = 0;
    while (i < 2000) : (i += 1) try buf.appendSlice(a, "+1"); // 2001-deep > max_depth
    const r = try evaluate(a, buf.items, .sloppy);
    try testing.expect(r == .thrown);
}
