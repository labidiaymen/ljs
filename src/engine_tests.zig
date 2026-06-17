//! Unit tests for the engine (extracted from engine.zig to keep source files under 1000 lines).
//! Imports the engine's public surface + the helpers the `evaluate`-based assertions need. Run by
//! `zig build test` via the `_ = @import("engine_tests.zig")` reference in root.zig.
const std = @import("std");
pub const engine = @import("engine.zig");
pub const Value = @import("value.zig").Value;
pub const Parser = @import("parser.zig").Parser;
pub const Interpreter = @import("interpreter.zig").Interpreter;
pub const Environment = @import("environment.zig").Environment;
pub const builtins = @import("builtins.zig");
pub const evaluate = engine.evaluate;
pub const evaluateWithLimit = engine.evaluateWithLimit;
pub const default_step_limit = engine.default_step_limit;

const testing = std.testing;

pub fn expectNumber(src: []const u8, want: f64) !void {
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

pub fn expectThrows(src: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try evaluate(arena_state.allocator(), src, .sloppy);
    try testing.expect(r == .thrown);
}

pub fn expectStr(src: []const u8, want: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try evaluate(arena_state.allocator(), src, .sloppy);
    try testing.expect(r == .normal and r.normal == .string);
    try testing.expectEqualStrings(want, r.normal.string);
}

pub fn expectBool(src: []const u8, want: bool) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try evaluate(arena_state.allocator(), src, .sloppy);
    try testing.expect(r == .normal and r.normal == .boolean);
    try testing.expectEqual(want, r.normal.boolean);
}

pub fn expectSyntaxError(src: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try evaluate(arena_state.allocator(), src, .sloppy);
    try testing.expect(r == .syntax_error);
}

/// Evaluate in strict `RunMode` (no prepended directive) and assert a parse-phase SyntaxError.
pub fn expectSyntaxErrorStrict(src: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try evaluate(arena_state.allocator(), src, .strict);
    try testing.expect(r == .syntax_error);
}

/// Evaluate in strict `RunMode` and assert it parses + runs without a SyntaxError (it may still
/// throw at runtime — we only assert the absence of a *parse* error).
pub fn expectNoSyntaxErrorStrict(src: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try evaluate(arena_state.allocator(), src, .strict);
    try testing.expect(r != .syntax_error);
}

pub fn expectUndefined(src: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try evaluate(arena_state.allocator(), src, .sloppy);
    try testing.expect(r == .normal and r.normal == .undefined);
}

/// Run `src` in a fresh realm, DRAIN the microtask Job queue (so Promise reactions / async
/// continuations complete), then read the global variable `name`. Used by the async-runtime tests to
/// observe a value a `.then`/async continuation writes AFTER the synchronous script returns (the
/// microtask drain is the only deterministic post-script hook — no real timers). Mirrors
/// `evaluateWithLimit` but keeps the realm env alive so the global is readable post-drain.
pub fn evalGlobalAfterDrain(arena: std.mem.Allocator, src: []const u8, name: []const u8) !Value {
    const program = try Parser.parseMode(arena, src, false);
    const global = try Environment.create(arena, null);
    try builtins.setup(arena, global);
    var gen_registry: std.ArrayListUnmanaged(*@import("object.zig").Generator) = .empty;
    var job_queue: std.ArrayListUnmanaged(@import("object.zig").Job) = .empty;
    var interp = Interpreter{ .arena = arena, .step_limit = default_step_limit, .globals = global, .gen_registry = &gen_registry, .job_queue = &job_queue };
    _ = try interp.run(program, global);
    try interp.drainJobs();
    interp.cleanupGenerators();
    const b = global.lookup(name) orelse return .undefined;
    return b.value;
}

pub fn expectGlobalNumberAfterDrain(src: []const u8, name: []const u8, want: f64) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const v = try evalGlobalAfterDrain(arena_state.allocator(), src, name);
    try testing.expect(v == .number);
    try testing.expectEqual(want, v.number);
}

pub fn expectGlobalStringAfterDrain(src: []const u8, name: []const u8, want: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const v = try evalGlobalAfterDrain(arena_state.allocator(), src, name);
    try testing.expect(v == .string);
    try testing.expectEqualStrings(want, v.string);
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

test "M38 Array.prototype methods + sparse length (§23.1.3)" {
    // iteration / search (the M38 green slice; Species/frozen-edge mutators are deferred — see spec).
    try expectNumber("[1,2,3].reduce(function(a,b){return a+b;},0)", 6);
    try expectNumber("[1,2,3,4].reduceRight(function(a,b){return a-b;})", -2); // 4-3-2-1
    try expectNumber("[1,2,3].find(function(x){return x===2;})", 2);
    try expectNumber("[1,2,3].findIndex(function(x){return x===2;})", 1);
    try expectNumber("[1,2,3].findLast(function(x){return x<3;})", 2);
    try expectNumber("[1,2,3].findLastIndex(function(x){return x<3;})", 1);
    try expectBool("[1,2,3].some(function(x){return x===2;})", true);
    try expectBool("[1,2,3].every(function(x){return x>0;})", true);
    try expectNumber("[1,2,2,3].lastIndexOf(2)", 2);
    try expectNumber("[1,2,3].map(function(x){return x*2;})[2]", 6);
    try expectNumber("[1,2,3].at(-1)", 3);
    try expectNumber("[1,2,3].at(0)", 1);
    // mutation (in-place; no result-array creation)
    try expectNumber("[3,1,2].sort()[0]", 1);
    try expectNumber("[3,1,2].sort(function(a,b){return b-a;})[0]", 3);
    try expectNumber("[1,2,3].reverse()[0]", 3);
    try expectNumber("[1,2,3,4].fill(0,1,3)[2]", 0);
    try expectNumber("[1,2,3,4,5].copyWithin(0,3)[0]", 4);
    // search arg coercion: a Symbol fromIndex / relative index throws (ToIntegerOrInfinity)
    try expectBool("var t=false;try{[1].copyWithin(0,Symbol());}catch(e){t=e instanceof TypeError;}t", true);
    // true holes: delete leaves a hole that forEach/reduce skip
    try expectNumber("var a=[1,2,3];delete a[1];var n=0;a.forEach(function(){n++;});n", 2);
    // sparse length — no OOM, lazy
    try expectNumber("var a=[]; a.length=100; a.length", 100);
    try expectNumber("var a=[]; a[1000000]=7; a.length", 1000001);
    try expectNumber("var a=[]; a[1000000]=7; a[1000000]", 7);
    try expectBool("var a=[];a[1000000]=7;!(500 in a)", true); // gap stays a hole
    try expectNumber("var a=[1,2,3]; a.length=2; a.length", 2);
    try expectNumber("new Array(5).length", 5);
    try expectNumber("var a=new Array(3); a[10]=1; a.length", 11);
}

test "M43 deferred Array methods + ArraySpeciesCreate + frozen [[Set]] (§23.1.3)" {
    // result-creating methods (now backed by ArraySpeciesCreate → plain Array by default)
    try expectStr("[1,2,3].filter(function(x){return x>1;}).join()", "2,3");
    try expectNumber("[1,2].concat([3,4]).length", 4);
    try expectStr("[1,2].concat([3,4]).join()", "1,2,3,4");
    try expectStr("[1,2].concat(3,[4,5]).join()", "1,2,3,4,5");
    try expectStr("[1,[2,[3]]].flat(2).join()", "1,2,3");
    try expectStr("[1,[2,[3]]].flat().join()", "1,2,3"); // default depth 1 → [1,2,[3]]
    try expectNumber("[1,2].flatMap(function(x){return [x,x];}).length", 4);
    try expectStr("[1,2].flatMap(function(x){return [x,x];}).join()", "1,1,2,2");
    // in-place mutation
    try expectStr("var a=[1,2,3]; a.splice(1,1); a.join()", "1,3");
    try expectStr("var a=[1,2,3]; var r=a.splice(1,1,9,8); a.join()+'|'+r.join()", "1,9,8,3|2");
    try expectStr("var a=[1,2]; a.unshift(0); a.join()", "0,1,2");
    try expectNumber("var a=[1,2]; a.unshift(0)", 3); // returns new length
    try expectNumber("var a=[1,2,3]; a.shift()", 1);
    try expectStr("var a=[1,2,3]; a.shift(); a.join()", "2,3");
    // statics
    try expectStr("Array.from('ab').join()", "a,b");
    try expectStr("Array.from([1,2,3], function(x){return x*2;}).join()", "2,4,6");
    try expectNumber("Array.of(1,2,3).length", 3);
    try expectStr("Array.of(7).join()", "7"); // unlike Array(7) which is a 7-length sparse array
    // Symbol.species + Array[Symbol.species]
    try expectBool("Array[Symbol.species] === Array", true);
    // ArraySpeciesCreate: a non-constructor @@species → TypeError (callback not invoked)
    try expectBool("var a=[1]; a.constructor={}; a.constructor[Symbol.species]=42; var t=false; try{a.filter(function(){});}catch(e){t=e instanceof TypeError;} t", true);
    // a null @@species → plain Array result
    try expectBool("var a=[1]; a.constructor={}; a.constructor[Symbol.species]=null; Array.isArray(a.filter(function(){return true;}))", true);
    // frozen array: push / splice / unshift throw TypeError; element & length writes rejected
    try expectBool("var a=Object.freeze([1]); var t=false; try{a.push(2);}catch(e){t=e instanceof TypeError;} t", true);
    try expectBool("var a=Object.freeze([1]); var t=false; try{a.splice(0,1);}catch(e){t=e instanceof TypeError;} t", true);
    try expectBool("var a=Object.freeze([1]); var t=false; try{a.unshift(0);}catch(e){t=e instanceof TypeError;} t", true);
    try expectBool("var a=Object.freeze([1]); var t=false; try{a.pop();}catch(e){t=e instanceof TypeError;} t", true);
    // frozen array element write in strict mode → TypeError; sloppy → silent no-op
    try expectBool("'use strict'; var a=Object.freeze([1]); var t=false; try{a[0]=9;}catch(e){t=e instanceof TypeError;} t", true);
    try expectNumber("var a=Object.freeze([1]); a[0]=9; a[0]", 1); // sloppy: silent no-op, value unchanged
    // a frozen array is still readable by the non-mutating methods
    try expectStr("Object.freeze([1,2,3]).filter(function(x){return x>1;}).join()", "2,3");
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

test "M12 string escapes: hex / unicode / octal / line-continuation (§12.9.4.1)" {
    // §12.9.4.1 HexEscapeSequence `\xHH`
    try expectBool("\"\\x41\" === \"A\"", true);
    try expectBool("\"\\x4A\" === \"J\"", true);
    try expectBool("\"B\" === \"B\"", true);
    // §12.9.4.1 UnicodeEscapeSequence `\uHHHH` and braced `\u{H…}`
    try expectBool("\"\\u0041\" === \"A\"", true);
    try expectBool("\"\\u{41}\" === \"A\"", true);
    // A supplementary-plane code point is UTF-8-encoded; ljs `String.length` is the BYTE count
    // (U+1F600 GRINNING FACE = 4 UTF-8 bytes: F0 9F 98 80). Documented byte-length semantics.
    try expectNumber("\"\\u{1F600}\".length", 4);
    // §12.9.4.1 single-char escapes: `\b`=0x08, `\f`=0x0C, `\v`=0x0B, `\0`=NUL
    try expectNumber("\"\\b\".charCodeAt(0)", 8);
    try expectNumber("\"\\f\".charCodeAt(0)", 12);
    try expectNumber("\"\\v\".charCodeAt(0)", 11);
    try expectNumber("\"\\0\".charCodeAt(0)", 0);
    // IdentityEscape: `\q` → `q`
    try expectBool("\"\\q\" === \"q\"", true);
    // §12.9.4.1 LineContinuation: `\` + LineTerminator produces nothing (LF and CRLF)
    try expectBool("\"a\\\nb\" === \"ab\"", true);
    try expectBool("\"a\\\r\nb\" === \"ab\"", true);
    // Annex B.1.2 LegacyOctalEscapeSequence (sloppy): `\101` (octal 101 = 0x41 = 'A'), `\7` = 0x07
    try expectBool("\"\\101\" === \"A\"", true);
    try expectNumber("\"\\7\".charCodeAt(0)", 7);
    // NonOctalDecimalEscape (sloppy): `\8` → `8`
    try expectBool("\"\\8\" === \"8\"", true);
    // computed PropertyName decoded via a hex escape
    try expectNumber("var o = {}; o[\"\\x41\"] = 5; o.A", 5);
    // template literals share the §12.9.4.1 Hex/Unicode escapes
    try expectBool("`\\x41` === \"A\"", true);
    try expectBool("`\\u{41}` === \"A\"", true);
    // §12.9.4.1 invalid hex / unicode escapes → SyntaxError
    try expectSyntaxError("\"\\xZZ\"");
    try expectSyntaxError("\"\\x4\"");
    try expectSyntaxError("\"\\u{110000}\"");
    try expectSyntaxError("\"\\u123\"");
    try expectSyntaxError("\"\\u{}\"");
    // Annex B.1.2 / §12.9.4.1 Early Error: a legacy octal escape in STRICT mode is a SyntaxError;
    // the same string in sloppy mode is fine (verified above).
    try expectSyntaxErrorStrict("\"\\101\"");
    try expectSyntaxErrorStrict("\"\\1\"");
    try expectSyntaxErrorStrict("'\\8'");
    // a NUL escape `\0` (not followed by a digit) is legal in BOTH modes
    try expectNoSyntaxErrorStrict("\"\\0\"");
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

test "M7 destructuring assignment: array targets (§13.15.5)" {
    // basic + the whole expression yields the RHS value
    try expectNumber("var a, b; [a, b] = [1, 2]; a + b", 3);
    try expectNumber("var a, b; var r = ([a, b] = [7, 8]); r.length", 2); // assignment yields RHS
    // swap (RHS evaluated once before any target is written)
    try expectNumber("var a = 1, b = 2; [a, b] = [b, a]; a * 10 + b", 21);
    // elision / hole
    try expectNumber("var a; [, a] = [1, 2]; a", 2);
    try expectNumber("var a, c; [a, , c] = [1, 2, 3]; a + c", 4);
    // rest element collects the leftovers into a fresh Array
    try expectNumber("var a, b; [a, ...b] = [1, 2, 3]; b.length", 2);
    try expectNumber("var a, b; [a, ...b] = [1, 2, 3]; b[1]", 3);
    // defaults (applied only when the source value is undefined)
    try expectNumber("var a; [a = 5] = []; a", 5);
    try expectNumber("var a, b; [a, b = 10] = [1]; a * 100 + b", 110);
    try expectNumber("var a; [a = 5] = [9]; a", 9);
    // a member / index target (PUT into an existing reference)
    try expectNumber("var o = {}; var arr = [0]; [o.p, arr[0]] = [3, 4]; o.p * 10 + arr[0]", 34);
    // a String is iterable
    try expectStr("var a, b; [a, b] = \"hi\"; a + b", "hi");
}

test "M7 destructuring assignment: object targets (§13.15.5)" {
    // shorthand + renaming `key: target`
    try expectNumber("var x, y; ({x, y} = {x: 1, y: 2}); x + y", 3);
    try expectNumber("var a, b; ({x: a, y: b} = {x: 3, y: 4}); a * 10 + b", 34);
    // a member target as a property value: `{x: o.p}`
    try expectNumber("var o = {}; ({x: o.p} = {x: 5}); o.p", 5);
    // CoverInitializedName default `{x = d}` (applied when the property is undefined)
    try expectNumber("var x; ({x = 9} = {}); x", 9);
    try expectNumber("var x; ({x = 9} = {x: 7}); x", 7);
    // rest property copies the remaining own enumerable props into a fresh object
    try expectNumber("var a, r; ({a, ...r} = {a: 1, b: 2, c: 3}); r.b + r.c", 5);
    // object pattern on null/undefined throws
    try expectThrows("var x; ({x} = null);");
    try expectThrows("var x; ({x} = undefined);");
}

test "M7 destructuring assignment: nested patterns (§13.15.5)" {
    try expectNumber("var a, b; [[a], {b}] = [[1], {b: 2}]; a * 10 + b", 12);
    try expectNumber("var a, b; ({p: [a, b]} = {p: [3, 4]}); a + b", 7);
    try expectNumber("var y; ([{x: y = 9}] = [{}]); y", 9);
}

test "M7 destructuring assignment: cover-grammar early errors (§13.2.5.1 / §13.15.1)" {
    // CoverInitializedName that is NOT refined to a pattern → SyntaxError (parse phase)
    try expectSyntaxError("({x = 1});");
    try expectSyntaxError("var o = {x = 1};");
    try expectSyntaxError("f({a = 1});");
    // non-assignable leaves → SyntaxError
    try expectSyntaxError("[1] = x;");
    try expectSyntaxError("({a: 1} = {});");
    try expectSyntaxError("[a()] = [1];");
    // array-literal holes still parse as ordinary literals (no regression)
    try expectNumber("var x = [1, , 3]; x.length", 3);
}

test "M33 duplicate-declaration Early Errors (§14.2.1/§14.12.1/§14.15.1/§16.1.1)" {
    // ── §14.2.1 Block: LexicallyDeclaredNames unique ──
    try expectSyntaxError("{ let x; let x; }");
    try expectSyntaxError("{ let x; const x = 1; }");
    try expectSyntaxError("{ const x = 1; class x {} }");
    try expectSyntaxError("{ let x; class x {} }");
    // ── §14.2.1 Block: LexicallyDeclaredNames ∩ VarDeclaredNames = ∅ ──
    try expectSyntaxError("{ let x; var x; }");
    try expectSyntaxError("{ var x; let x; }");
    try expectSyntaxError("{ { var f; } let f; }"); // nested var bubbles up to the enclosing block
    try expectSyntaxError("function g() { { let f; var f; } }");
    // ── §14.12.1 SwitchStatement CaseBlock merges all clauses into one lexical scope ──
    try expectSyntaxError("switch (0) { case 1: let x; case 2: let x; }");
    try expectSyntaxError("switch (0) { case 1: let x; default: let x; }");
    try expectSyntaxError("switch (0) { case 1: let x; case 2: var x; }");
    // ── §14.15.1 Catch: CatchParameter vs Catch Block lexical names ──
    try expectSyntaxError("try {} catch (e) { let e; }");
    try expectSyntaxError("try {} catch (e) { const e = 1; }");
    try expectSyntaxError("try {} catch ([x, x]) {}"); // dup catch-pattern bound names
    // ── §16.1.1 Script top level ──
    try expectSyntaxError("let x; let x;");
    try expectSyntaxError("let x; var x;");
    try expectSyntaxError("const x = 1; function x() {}");
    // ── Strict-only: two FunctionDeclarations in a Block (Annex B B.3.3 allows it sloppy) ──
    try expectSyntaxErrorStrict("{ function f() {} function f() {} }");
    try expectNoSyntaxErrorStrict("{ function f() {} let g; }"); // sloppy-vs-strict sanity (parses)

    // ── Positives that MUST still parse ──
    try expectNumber("{ var x; var x; } 1", 1); // var redeclaration is legal
    try expectNumber("{ let x; } { let x; } 1", 1); // different blocks
    try expectNumber("let y = 0; { let y = 1; } y", 0); // nested shadow
    try expectNumber("function f() {} function f() {} 1", 1); // top-level fn redeclaration (var-scoped)
    try expectNumber("switch (0) { case 1: let x; case 2: { let x; } } 1", 1); // dup let in NESTED blocks
    try expectNumber("try {} catch (e) { var e; } 1", 1); // Annex B: catch-param vs body var, simple param
    try expectNumber("{ function g() {} function g() {} } 1", 1); // sloppy block fn redeclaration OK
    try expectNumber("for (let i = 0; i < 1; i++) { let i; } 1", 1); // loop head vs body are separate scopes
}

test "M34 sloppy assignment to an unresolved name creates a global (§9.1.1.4.16 / §6.2.5.6 PutValue)" {
    // §6.2.5.6 step 6.a / §9.1.1.4.16: in SLOPPY mode, `x = v` where `x` is unresolved succeeds and
    // creates a property on the global object (and a global binding) — it does NOT throw.
    try expectNumber("x = 5; x", 5);
    try expectNumber("x = 5; globalThis.x", 5); // the reified global object reflects the new global
    try expectNumber("r = 8; globalThis.r", 8); // bare-assignment → globalThis property
    // A sloppy function body that assigns to an unresolved name also creates the global.
    try expectNumber("function f(){ w = 3; } f(); globalThis.w", 3);
    try expectNumber("function f(){ w = 3; } f(); w", 3); // bare read sees the same value
    // §10.1.9.2: the created global property is enumerable/writable/configurable (Set, not var-create).
    try expectBool("aa = 1; Object.getOwnPropertyDescriptor(globalThis, 'aa').enumerable", true);
    // The created global is a normal mutable binding — a subsequent bare read sees the latest value.
    try expectNumber("b = 1; b = 2; b", 2);

    // §13.15.2: STRICT mode keeps throwing ReferenceError for an assignment to an unresolved name.
    // (A `"use strict"` Script body, and a strict function body, both gate this.)
    try expectThrows("'use strict'; y = 5;");
    try expectThrows("'use strict'; (function(){ z = 1; })();");
    try expectBool("'use strict'; try { y2 = 1; false } catch (e) { e instanceof ReferenceError }", true);
    try expectBool(
        "var f = function(){ 'use strict'; z2 = 1; }; try { f(); false } catch (e) { e instanceof ReferenceError }",
        true,
    );
    // A strict function nested in a sloppy script is strict at runtime; a sloppy function nested in a
    // strict script is sloppy at runtime — runtime strictness is per-function (lexical), not per-caller.
    try expectBool("function s(){ 'use strict'; u = 1; } try { s(); false } catch (e) { e instanceof ReferenceError }", true);

    // A class body is always strict — an assignment to an unresolved name in a method throws.
    try expectBool(
        "class C { m(){ cc = 1; } } try { new C().m(); false } catch (e) { e instanceof ReferenceError }",
        true,
    );
    // Reading an unresolved identifier ALWAYS throws ReferenceError (sloppy or strict) — only the
    // assignment target is special; compound/update (`+= `/`++`) read first, so they still throw.
    try expectThrows("missingReadOnly + 1");
    try expectThrows("undeclaredCompound += 1;"); // reads `undeclaredCompound` first → ReferenceError

    // §13.x TDZ: a lexical (`let`/`const`/`class`) name is hoisted into its scope as UNINITIALIZED, so
    // a reference BEFORE the declaration line is a ReferenceError — NOT a stray global / outer binding.
    // This is what gates the sloppy-global change from swallowing a before-init `let` assignment.
    try expectBool(
        "(function(){ function set(){ p = 1; } try { set(); return false } catch (e) { return e instanceof ReferenceError } let p; })()",
        true,
    ); // assign to a block-scoped `let` before its declaration → TDZ, not a global
    try expectBool(
        "(function(){ try { 0, [q] = []; return false } catch (e) { return e instanceof ReferenceError } let q; })()",
        true,
    ); // destructuring-assign to a `let` before its declaration → TDZ
    try expectBool(
        "(function(){ try { return rr } catch (e) { return e instanceof ReferenceError } let rr; })()",
        true,
    ); // READ of a `let` before its declaration → TDZ
    try expectBool(
        "(function(){ try { tt++; return false } catch (e) { return e instanceof ReferenceError } let tt; })()",
        true,
    ); // `++` of a `let` before its declaration → TDZ (the GetValue throws)
    // A normal `let`/`const`/`class`, declared then used, is unaffected by the TDZ hoist.
    try expectNumber("let aok = 3; aok + 1", 4);
    try expectNumber("const cok = 7; cok", 7);
    try expectNumber("let z1 = 1; { let z1 = 2; } z1", 1); // nested-block shadow still works
    // §9.1.1.4.18: `delete x` of a sloppy-created global removes it (configurable), so a later read throws.
    try expectBool("dx = 1; delete dx; try { dx; false } catch (e) { e instanceof ReferenceError }", true);
}

test "M8 Symbol primitive: typeof, description, identity (§20.4)" {
    try expectStr("typeof Symbol()", "symbol");
    try expectStr("typeof Symbol('d')", "symbol");
    try expectStr("typeof Symbol.iterator", "symbol"); // well-known symbol
    // §20.4.3.3 toString / String() are the allowed Symbol→string conversions; both keep the description.
    try expectBool("Symbol('d').toString().indexOf('d') >= 0", true);
    try expectBool("String(Symbol('hi')).indexOf('hi') >= 0", true);
    // §6.1.5: distinct calls yield distinct identities; a symbol equals itself.
    try expectBool("Symbol('x') === Symbol('x')", false);
    try expectBool("var s = Symbol(); s === s", true);
    try expectBool("Symbol.iterator === Symbol.iterator", true);
    // §7.1.17: a bare Symbol→string coercion (template / `+`) throws a TypeError.
    try expectThrows("'' + Symbol()");
    try expectThrows("`${Symbol()}`");
    // §20.4.1: `new Symbol()` is a TypeError (Symbol has no [[Construct]]).
    try expectThrows("new Symbol()");
}

test "M8 Symbol-keyed properties (§6.1.7)" {
    // a symbol key stores/reads via the separate symbol store; ToString is skipped.
    try expectNumber("var s = Symbol(); var o = {}; o[s] = 5; o[s]", 5);
    // symbol keys are NOT enumerated by Object.keys / for-in.
    try expectNumber("var s = Symbol(); var o = {a: 1}; o[s] = 2; Object.keys(o).length", 1);
    try expectStr("var s = Symbol(); var o = {a: 1}; o[s] = 2; var r = ''; for (var k in o) r += k; r", "a");
    // a computed symbol key in an object literal.
    try expectNumber("var s = Symbol(); var o = {[s]: 7}; o[s]", 7);
    // two distinct symbols don't collide.
    try expectNumber("var s1 = Symbol(), s2 = Symbol(); var o = {}; o[s1] = 1; o[s2] = 2; o[s1] + o[s2]", 3);
}

test "M8 iteration protocol: custom iterable (§7.4)" {
    // §7.4.2 GetIterator → §7.4.4 IteratorStep: a hand-written iterable drives for-of.
    const it_src =
        \\var it = { [Symbol.iterator]() { var i = 0; return { next() { return i < 3 ? {value: i++, done: false} : {value: undefined, done: true}; } }; } };
        \\var t = 0; for (var v of it) t += v; t
    ;
    try expectNumber(it_src, 3); // 0 + 1 + 2
    // spread over the same custom iterable.
    const spread_src =
        \\var it = { [Symbol.iterator]() { var i = 0; return { next() { return i < 3 ? {value: i++, done: false} : {value: undefined, done: true}; } }; } };
        \\[...it].length
    ;
    try expectNumber(spread_src, 3);
    // array destructuring over the same custom iterable.
    const dstr_src =
        \\var it = { [Symbol.iterator]() { var i = 0; return { next() { return i < 3 ? {value: i++, done: false} : {value: undefined, done: true}; } }; } };
        \\var a, b; [a, b] = it; a + b
    ;
    try expectNumber(dstr_src, 1); // 0 + 1
}

test "M17 iterator-correct array destructuring: step once + IteratorClose (§8.5.2 / §13.15.5.3)" {
    // §13.15.5.3: a fixed pattern `[x]` over an INFINITE iterator steps EXACTLY ONCE, binds, then calls
    // IteratorClose (the iterator's `return()`) because the iterator is not done. (This is the case that
    // used to drain forever and hang.) `return()` is called exactly once.
    const close_once =
        \\var doneCallCount = 0;
        \\var iter = { [Symbol.iterator]() { return {
        \\  next() { return { value: 42, done: false }; },
        \\  return() { doneCallCount += 1; return {}; }
        \\}; } };
        \\function f([x]) { if (x !== 42) throw 'bad x'; }
        \\f(iter); doneCallCount
    ;
    try expectNumber(close_once, 1); // return() called once; x bound to the single step's value
    // §13.15.5.3 (assignment form): `[a, b]` over a 5-element counting iterator steps EXACTLY twice and
    // then closes (return() once). Assert both the step count and the close count.
    const exact_steps =
        \\var stepCount = 0, closeCount = 0;
        \\var iter = { [Symbol.iterator]() { var n = 0; return {
        \\  next() { stepCount++; return { value: n++, done: n > 5 }; },
        \\  return() { closeCount++; return {}; }
        \\}; } };
        \\var a, b; [a, b] = iter;
        \\if (a !== 0 || b !== 1) throw 'bad values';
        \\stepCount * 10 + closeCount
    ;
    try expectNumber(exact_steps, 21); // 2 steps, 1 close → 2*10 + 1
    // §13.15.5.3 BindingRestElement: `[first, ...rest]` drains the REMAINDER of a finite iterable.
    try expectNumber("var [first, ...rest] = [10, 20, 30, 40]; first + rest.length * 100", 310); // 10 + 3*100
    try expectStr("var [, ...rest] = ['a', 'b', 'c']; rest.join(',')", "b,c"); // elision steps once, rest drains
    // A pattern that EXHAUSTS the iterator does NOT call return() (it is already done, §13.15.5.3). With
    // a 3-slot pattern over a 2-value iterator, the 3rd step returns done → c is undefined, no close.
    const exhaust_no_close =
        \\var closeCount = 0;
        \\var iter = { [Symbol.iterator]() { var n = 0; return {
        \\  next() { return n < 2 ? { value: n++, done: false } : { value: undefined, done: true }; },
        \\  return() { closeCount++; return {}; }
        \\}; } };
        \\var a, b, c; [a, b, c] = iter;
        \\if (a !== 0 || b !== 1 || c !== undefined) throw 'bad values';
        \\closeCount
    ;
    try expectNumber(exhaust_no_close, 0); // iterator naturally done on the 3rd step → no IteratorClose
}

test "M17 reliability: infinite iterator-consuming loops terminate via the step watchdog" {
    // §reliability: even with correct stepping, the rest-drain / for-of over a GENUINELY infinite
    // iterable must FAIL (StepLimitExceeded) rather than hang the process. Use a low step limit so the
    // watchdog fires quickly; assert the run TERMINATES with `.step_limit` (never hangs).
    const inf_iter = // a `next()` that is never done
        \\var iter = { [Symbol.iterator]() { return { next() { return { value: 1, done: false }; } }; } };
    ;
    // for-of over an infinite iterable.
    {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const src = inf_iter ++ "\nfor (var x of iter) {}";
        const r = try evaluateWithLimit(arena_state.allocator(), src, .sloppy, 100_000);
        try testing.expect(r == .step_limit);
    }
    // rest-element destructuring `[...r] = iter` over an infinite iterable.
    {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const src = inf_iter ++ "\nvar r; [...r] = iter;";
        const r = try evaluateWithLimit(arena_state.allocator(), src, .sloppy, 100_000);
        try testing.expect(r == .step_limit);
    }
    // spread over an infinite iterable.
    {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const src = inf_iter ++ "\nvar a = [...iter];";
        const r = try evaluateWithLimit(arena_state.allocator(), src, .sloppy, 100_000);
        try testing.expect(r == .step_limit);
    }
}

test "M8 iteration protocol: Array/String native iterators (§22.1.5 / §23.1.5)" {
    // Array.prototype[Symbol.iterator] resolves and yields the elements.
    try expectBool("typeof [][Symbol.iterator] === 'function'", true);
    try expectNumber("var s = 0; for (var v of [10, 20, 30]) s += v; s", 60);
    // the iterator object's next() yields {value, done}.
    try expectNumber("var it = [9][Symbol.iterator](); it.next().value", 9);
    try expectBool("var it = [][Symbol.iterator](); it.next().done", true);
    // String.prototype[Symbol.iterator] yields characters.
    try expectStr("var r = ''; for (var c of 'abc') r += c; r", "abc");
    // for-of over a non-iterable still throws (§7.4.2 GetIterator).
    try expectThrows("for (var x of 5) {}");
    try expectThrows("for (var x of {}) {}");
}

test "M20 Array.prototype keys/entries + iterator self-iterability (§23.1.3.18/.7 / §27.1.2.1)" {
    // .keys() → indices; .values()/.entries() Array Iterators; each is itself iterable (for-of / spread).
    try expectStr("[...[9, 8, 7].keys()].join(',')", "0,1,2");
    try expectNumber("var s = 0; for (var v of [3, 4, 5].values()) s += v; s", 12);
    try expectStr("var r = []; for (var e of ['a', 'b'].entries()) r.push(e[0] + '=' + e[1]); r.join(',')", "0=a,1=b");
    try expectBool("typeof [].entries === 'function' && typeof [].keys === 'function'", true);
    // the entry pair is a real 2-element Array.
    try expectNumber("[...[7].entries()][0].length", 2);
}

test "M21 with statement: object environment record (§14.11)" {
    try expectNumber("var o = {x: 5}; var r; with (o) { r = x; } r", 5); // read from binding object
    try expectNumber("var o = {x: 1}; with (o) { x = 9; } o.x", 9); // write through to the object
    try expectNumber("var y = 7; var o = {x: 1}; var r; with (o) { r = y; } r", 7); // fall through to outer scope
    try expectNumber("var x = 1; var o = {x: 42}; var r; with (o) { r = x; } r", 42); // object prop shadows outer var
    try expectStr("var o = {x: 5}; with (o) {} typeof x", "undefined"); // with-binding does not leak out
    try expectSyntaxError("\"use strict\"; with ({}) {}"); // §14.11.1 strict-mode SyntaxError
}

test "M22 Number / Boolean constructors + Number statics (§21.1 / §20.3)" {
    try expectNumber("Number('42') + 1", 43); // §21.1.1.1 ToNumber
    try expectNumber("Number()", 0);
    try expectBool("Boolean(0)", false); // §20.3.1.1 ToBoolean
    try expectBool("Boolean('x')", true);
    try expectBool("Number.isNaN(0 / 0)", true); // no coercion
    try expectBool("Number.isNaN('NaN')", false); // a string is not NaN
    try expectBool("Number.isFinite(1 / 0)", false);
    try expectBool("Number.isInteger(4)", true);
    try expectBool("Number.isInteger(4.5)", false);
    try expectBool("Number.isSafeInteger(9007199254740991)", true);
    try expectNumber("Number.MAX_SAFE_INTEGER", 9007199254740991);
    try expectStr("typeof Number + typeof Boolean", "functionfunction");
    try expectBool("Number.prototype.constructor === Number", true); // §21.1.3.1
}

test "M24 numeric literals: radix prefixes, separators, exponents (§12.9.3)" {
    try expectNumber("0xFF", 255);
    try expectNumber("0o17", 15);
    try expectNumber("0b1010", 10);
    try expectNumber("0XfF", 255); // uppercase prefix + mixed-case digits
    try expectNumber("1_000_000", 1000000); // NumericLiteralSeparator
    try expectNumber("0xFF_FF", 65535);
    try expectNumber("1.5e3", 1500); // exponent
    try expectNumber("1.5E-2 * 100", 1.5);
    try expectNumber(".5 + 0.5", 1);
    try expectSyntaxError("var x = 3in1"); // §12.9.3: identifier/digit immediately after a number → SyntaxError
}

test "M9 generators: function* returns a generator; .next drives yield (§15.5 / §27.5, US1-US2)" {
    // §15.5.4: calling a generator returns a generator object (the body does NOT run yet).
    try expectStr("function* g(){} typeof g", "function");
    try expectStr("function* g(){} var it = g(); typeof it", "object");
    // §27.5.1.2: .next() drives the body to each yield; the final {value, done:true} carries return.
    try expectNumber("function* g(){ yield 1; yield 2 } var it = g(); it.next().value", 1);
    try expectNumber("function* g(){ yield 1; yield 2 } var it = g(); it.next(); it.next().value", 2);
    try expectBool("function* g(){ yield 1 } var it = g(); it.next(); it.next().done", true);
    // a generator that returns a value carries it on the final result (done:true).
    try expectNumber("function* g(){ yield 1; return 7 } var it = g(); it.next(); it.next().value", 7);
    try expectBool("function* g(){ yield 1; return 7 } var it = g(); it.next(); it.next().done", true);
    // body does not run before the first .next (a side effect is deferred).
    try expectNumber("var ran = 0; function* g(){ ran = 1; yield } var it = g(); ran", 0);
    try expectNumber("var ran = 0; function* g(){ ran = 1; yield } var it = g(); it.next(); ran", 1);
}

test "M9 generators: yield receives the sent value (§14.4 / §15.5.5, US3)" {
    // §27.5.3.3: yield evaluates to the value passed to the NEXT .next(v).
    try expectNumber("function* g(){ var x = yield; return x } var it = g(); it.next(); it.next(5).value", 5);
    try expectNumber("function* g(){ var a = yield; var b = yield; return a + b } var it = g(); it.next(); it.next(2); it.next(3).value", 5);
    // yield's low precedence: `yield a + b` yields the sum; `x = yield` assigns the sent value.
    try expectNumber("function* g(){ yield 1 + 2 } g().next().value", 3);
}

test "M9 generators: iterable via for-of / spread / destructuring (§27.5.1.1 / §7.4, US4)" {
    // a generator is iterable (%GeneratorPrototype%[Symbol.iterator]() returns this).
    try expectStr("function* g(){ yield 'h'; yield 'i' } var s = ''; for (var c of g()) s += c; s", "hi");
    try expectNumber("function* g(){ yield 1; yield 2; yield 3 } [...g()].length", 3);
    try expectNumber("function* g(){ yield 1; yield 2; yield 3 } var a = [...g()]; a[0] + a[1] + a[2]", 6);
    try expectNumber("function* g(){ yield 10; yield 20 } var [a, b] = g(); a + b", 30);
    // a finite-range generator summed by for-of.
    try expectNumber("function* range(n){ var i = 0; while (i < n) { yield i; i++ } } var t = 0; for (var x of range(5)) t += x; t", 10);
}

test "M9 generators: .return / .throw (§27.5.1.4 / §27.5.1.5, US5)" {
    // §27.5.1.4 .return(v) finishes early → {value:v, done:true}, then the generator is done.
    try expectNumber("function* g(){ yield 1; yield 2 } var it = g(); it.next(); it.return(9).value", 9);
    try expectBool("function* g(){ yield 1; yield 2 } var it = g(); it.next(); it.return(9); it.next().done", true);
    // §27.5.1.5 .throw injects a throw at the suspension point — caught by a body try/catch.
    try expectStr("function* g(){ try { yield 1 } catch (e) { yield 'caught:' + e } } var it = g(); it.next(); it.throw('x').value", "caught:x");
    // an uncaught .throw propagates to the caller and completes the generator.
    try expectThrows("function* g(){ yield 1 } var it = g(); it.next(); it.throw('boom')");
    // .next on a completed generator → {value:undefined, done:true}.
    try expectBool("function* g(){ yield 1 } var it = g(); it.next(); it.next(); it.next().done", true);
}

test "M9 generators: yield parse early errors (§15.5.1, US6)" {
    // §15.5.1: `yield` as an operator outside a generator is a SyntaxError (it stays an identifier
    // in sloppy mode, so a *standalone* `yield expr` is the binary/call interpretation — but a
    // generator's `yield value` form is only legal inside one). A param/binding named `yield` in a
    // generator is a SyntaxError.
    try expectSyntaxError("function* g(yield){}");
    try expectSyntaxError("function* yield(){}");
    // inside a generator, a bare `yield` parses; this generator yields undefined then completes.
    try expectBool("function* g(){ yield } g().next().done", false);
}

test "M9 generators: yield* delegation (§15.5.5, Cycle 2)" {
    // delegate to another generator: the inner's values flow through the outer.
    try expectStr("function* inner(){yield 1; yield 2} function* outer(){yield* inner(); yield 3} [...outer()].join()", "1,2,3");
    // delegate to an array iterator, then a string iterator.
    try expectNumber("function* g(){yield* [1,2]; yield* 'ab'} [...g()].length", 4);
    try expectStr("function* g(){yield* [1,2]; yield* 'ab'} [...g()].join()", "1,2,a,b");
    // §14.4.14 step 7.a.ii: `yield*` evaluates to the inner iterator's final (done) value.
    try expectStr("function* inner(){yield 1; return 9} function* outer(){var r = yield* inner(); yield r} [...outer()].join()", "1,9");
    // a sent value is forwarded into the inner generator's `yield`; the inner's return becomes the
    // yield* value, which the outer then yields back — so the .next(42) that completes the inner sees it.
    try expectNumber("function* inner(){var x = yield; return x} function* outer(){var r = yield* inner(); yield r} var it = outer(); it.next(); it.next(42).value", 42);
    // delegating to an empty iterable yields nothing; the yield* value is the inner return.
    try expectNumber("function* g(){var r = yield* []; yield 5} [...g()].length", 1);
}

test "M9 generators: generator methods in classes & objects (§15.5, Cycle 2)" {
    // class instance generator method.
    try expectNumber("class C{ *g(){yield 5} } [...new C().g()][0]", 5);
    try expectNumber("class C{ *g(){yield 1; yield 2; yield 3} } [...new C().g()].length", 3);
    // static generator method.
    try expectNumber("class C{ static *g(){yield 8} } C.g().next().value", 8);
    // computed-key generator method.
    try expectNumber("class C{ *['g'](){yield 4} } new C().g().next().value", 4);
    // object-literal generator method.
    try expectNumber("var o = {*g(){yield 7}}; o.g().next().value", 7);
    try expectStr("var o = {*g(){yield 'a'; yield 'b'}}; [...o.g()].join()", "a,b");
    // a generator method `this` binds to the receiver.
    try expectNumber("var o = {v: 11, *g(){yield this.v}}; o.g().next().value", 11);
}

test "M9 generators: generator-method early errors stay rejected (§15.5.1, Cycle 2)" {
    // §15.5.1: `yield` as a generator-method param name is a SyntaxError (class + object).
    try expectSyntaxError("class C{ *g(yield){} }");
    try expectSyntaxError("var o = {*g(yield){}};");
    // §15.7.1: a generator method named `constructor` is forbidden.
    try expectSyntaxError("class C{ *constructor(){} }");
    // async generator methods now PARSE (M11 Cycle 1) — covered by the M11 async tests.
    try expectNoSyntaxErrorStrict("class C{ async *g(){} }");
    try expectNoSyntaxErrorStrict("var o = {async *g(){}};");
    // a `*` element with no method body is a SyntaxError.
    try expectSyntaxError("class C{ *x = 1; }");
}
