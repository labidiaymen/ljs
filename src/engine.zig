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

/// The classified result of a Test262 `[async]` test (driven via the runner-injected `$DONE`). The
/// runner maps this to pass/fail. Not part of ECMA-262 — the conformance harness's async contract.
pub const AsyncTestResult = union(enum) {
    /// `$DONE` was called with no/undefined/falsy argument → the async test passed.
    async_pass,
    /// `$DONE` was called with a truthy argument (the failure value, stringified) → async fail.
    async_fail: []const u8,
    /// `$DONE` was NEVER called (after draining all microtasks) → the async test did not report → fail.
    never_done,
    /// The script failed to parse.
    syntax_error: []const u8,
    /// The step watchdog fired (runaway sync code OR microtask loop) → fail.
    step_limit,
    /// The synchronous script threw before reaching/arming the async machinery → fail.
    sync_throw: Value,
};

/// Evaluate a Test262 `[async]` test: inject a native `$DONE(err)` global (the async completion
/// callback) plus its shared sink, run the script, DRAIN the microtask Job queue (so async-function
/// continuations and Promise reactions complete), then classify via whether/how `$DONE` was called.
/// This is the engine surface the conformance runner uses for `[async]` tests (it no longer skips
/// them). Deterministic — no real timers; the drain is step-bounded so a never-settling promise or a
/// runaway microtask loop terminates rather than hangs.
pub fn evaluateAsyncTest(arena: std.mem.Allocator, source: []const u8, mode: RunMode, step_limit: u64) error{OutOfMemory}!AsyncTestResult {
    const interp_mod = @import("interpreter.zig");
    const obj_mod = @import("object.zig");
    const program = Parser.parseMode(arena, source, mode == .strict) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .syntax_error = @errorName(e) },
    };
    const global = Environment.create(arena, null) catch return error.OutOfMemory;
    builtins.setup(arena, global) catch return error.OutOfMemory;
    // Inject the native `$DONE` global (overriding any harness-defined one for the common case where
    // the test references `$DONE` directly). It records completion on the shared sink the runner reads.
    const done_sink = arena.create(interp_mod.AsyncDone) catch return error.OutOfMemory;
    done_sink.* = .{};
    const done_fn = obj_mod.Object.createNative(arena, .test_done, "$DONE") catch return error.OutOfMemory;
    {
        const fp = global.lookup("Function");
        if (fp) |b| if (b.value == .object) {
            if (b.value.object.get("prototype")) |pv| if (pv == .object) {
                done_fn.prototype = pv.object;
            };
        };
    }
    global.declare("$DONE", .{ .object = done_fn }, true, true) catch return error.OutOfMemory;
    // §19.3 also install `$DONE` as an OWN property of the reified global object, so the harness's
    // `asyncTest` — which gates on `Object.prototype.hasOwnProperty.call(globalThis, "$DONE")` — sees it
    // (the async flag is signalled by `$DONE`'s presence on globalThis, per asyncHelpers.js).
    if (global.lookup("%GlobalThis%")) |gb| if (gb.value == .object) {
        gb.value.object.defineData("$DONE", .{ .object = done_fn }, true, false, true) catch return error.OutOfMemory;
    };
    var gen_registry: std.ArrayListUnmanaged(*obj_mod.Generator) = .empty;
    var job_queue: std.ArrayListUnmanaged(obj_mod.Job) = .empty;
    var interp = Interpreter{ .arena = arena, .step_limit = step_limit, .globals = global, .gen_registry = &gen_registry, .job_queue = &job_queue, .async_done = done_sink };
    const completion = interp.run(program, global) catch |e| {
        interp.cleanupGenerators();
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.StepLimitExceeded => .step_limit,
        };
    };
    // A synchronous throw before the async machinery is armed → the test failed synchronously (unless
    // it already reported via $DONE in a prior statement — the sink check below handles that order).
    if (completion == .throw and !done_sink.called) {
        interp.cleanupGenerators();
        return .{ .sync_throw = completion.throw };
    }
    interp.drainJobs() catch |e| {
        interp.cleanupGenerators();
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.StepLimitExceeded => .step_limit,
        };
    };
    interp.cleanupGenerators();
    if (!done_sink.called) return .never_done;
    if (done_sink.failed) return .{ .async_fail = done_sink.message };
    return .async_pass;
}

pub fn evaluate(arena: std.mem.Allocator, source: []const u8, mode: RunMode) error{OutOfMemory}!EvaluationResult {
    return evaluateWithLimit(arena, source, mode, default_step_limit);
}

/// Like `evaluate`, but with an explicit interpreter step cap (the watchdog, research D8).
/// The Test262 harness uses this to bound runaway tests deterministically.
pub fn evaluateWithLimit(arena: std.mem.Allocator, source: []const u8, mode: RunMode, step_limit: u64) error{OutOfMemory}!EvaluationResult {
    // §11.2.2: in strict RunMode the whole Script starts in strict context (the Test262 runner runs
    // each test in both modes and expects the engine to honor this). An explicit `"use strict"`
    // directive prologue is detected independently inside the parser.
    const program = Parser.parseMode(arena, source, mode == .strict) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .syntax_error = @errorName(e) },
    };
    const global = Environment.create(arena, null) catch return error.OutOfMemory;
    builtins.setup(arena, global) catch return error.OutOfMemory;
    // §27.5 generator registry — the main interpreter tracks every generator created in this realm so
    // any never-fully-consumed generator's parked body thread can be unwound + joined at end-of-run.
    var gen_registry: std.ArrayListUnmanaged(*@import("object.zig").Generator) = .empty;
    // §9.5 the realm Job (microtask) queue — drained once the synchronous script completes (Promise
    // reactions / async-function continuations run here). Empty for a script with no promises (no-op).
    var job_queue: std.ArrayListUnmanaged(@import("object.zig").Job) = .empty;
    var interp = Interpreter{ .arena = arena, .step_limit = step_limit, .globals = global, .gen_registry = &gen_registry, .job_queue = &job_queue };
    const completion = interp.run(program, global) catch |e| {
        interp.cleanupGenerators(); // join/abandon any parked generator threads before unwinding
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.StepLimitExceeded => .step_limit,
        };
    };
    // §9.5 RunJobs: drain the microtask queue (Promise reactions + await resumptions) now the stack is
    // empty. Step-bounded — a runaway microtask loop terminates as `step_limit`, never hangs. A script
    // with no promises has an empty queue (no-op; non-async tests classify exactly as before).
    interp.drainJobs() catch |e| {
        interp.cleanupGenerators();
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.StepLimitExceeded => .step_limit,
        };
    };
    interp.cleanupGenerators(); // join/abandon any parked generator/async threads (no lingering OS thread)
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

/// Evaluate in strict `RunMode` (no prepended directive) and assert a parse-phase SyntaxError.
fn expectSyntaxErrorStrict(src: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try evaluate(arena_state.allocator(), src, .strict);
    try testing.expect(r == .syntax_error);
}

/// Evaluate in strict `RunMode` and assert it parses + runs without a SyntaxError (it may still
/// throw at runtime — we only assert the absence of a *parse* error).
fn expectNoSyntaxErrorStrict(src: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try evaluate(arena_state.allocator(), src, .strict);
    try testing.expect(r != .syntax_error);
}

fn expectUndefined(src: []const u8) !void {
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
fn evalGlobalAfterDrain(arena: std.mem.Allocator, src: []const u8, name: []const u8) !Value {
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

fn expectGlobalNumberAfterDrain(src: []const u8, name: []const u8, want: f64) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const v = try evalGlobalAfterDrain(arena_state.allocator(), src, name);
    try testing.expect(v == .number);
    try testing.expectEqual(want, v.number);
}

fn expectGlobalStringAfterDrain(src: []const u8, name: []const u8, want: []const u8) !void {
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

test "M11 async: function/arrow/method parse; typeof; runtime stub (§15.8, Cycle 1)" {
    // §15.8 AsyncFunctionExpression — an async function object is still a function.
    try expectStr("typeof (async function(){})", "function");
    // §15.8 AsyncFunctionDeclaration parses as a statement and binds its name.
    try expectStr("async function f(){} typeof f", "function");
    // §15.6 AsyncGeneratorExpression / Declaration parse.
    try expectStr("typeof (async function*(){})", "function");
    try expectStr("async function* g(){} typeof g", "function");
    // §15.8 AsyncArrowFunction (single param, parenthesized params, zero params) parse.
    try expectNoSyntaxErrorStrict("var f = async x => x;");
    try expectNoSyntaxErrorStrict("var f = async (a, b) => a + b;");
    try expectNoSyntaxErrorStrict("var f = async () => 1;");
    // §15.8 async methods in object & class bodies, incl. `static async` and computed, parse.
    try expectNoSyntaxErrorStrict("var o = { async m(){} };");
    try expectNoSyntaxErrorStrict("var o = { async *m(){} };");
    try expectNoSyntaxErrorStrict("class C { async m(){} }");
    try expectNoSyntaxErrorStrict("class C { static async m(){} }");
    try expectNoSyntaxErrorStrict("class C { async ['x'](){} }");
    // §27.7.5.1 (Cycle 2): calling an async function returns a Promise object (not a thrown stub).
    try expectStr("async function f(){ return 1; } typeof f()", "object");
    try expectBool("async function f(){ return 1; } f() instanceof Promise", true);
}

test "M11 async runtime: async fn returns a fulfilling Promise (§27.7.5)" {
    // §27.7.5.2 a plain `return 42` fulfills the function's promise with 42 (observed via .then).
    try expectGlobalNumberAfterDrain("var r; async function f(){ return 42; } f().then(function(v){ r = v; });", "r", 42);
    // §27.7.5.3 a single `await` of a resolved promise yields the value; the body continues.
    try expectGlobalNumberAfterDrain("var r; async function f(){ var x = await Promise.resolve(3); return x + 1; } f().then(function(v){ r = v; });", "r", 4);
    // §27.7.5.3 await of a plain (non-promise) value resolves to that value.
    try expectGlobalNumberAfterDrain("var r; async function f(){ return (await 7) + 1; } f().then(function(v){ r = v; });", "r", 8);
}

test "M11 async runtime: await of a rejected promise is catchable in the body (§27.7.5.3)" {
    // §27.7.5.3 a rejected await throws into the body at the await point — a try/catch catches it.
    try expectGlobalStringAfterDrain(
        "var r; async function f(){ try { await Promise.reject('boom'); return 'no'; } catch (e) { return 'caught:' + e; } } f().then(function(v){ r = v; });",
        "r",
        "caught:boom",
    );
    // §27.7.5.2 an uncaught throw rejects the function's promise (observed via .catch / .then onRejected).
    try expectGlobalStringAfterDrain(
        "var r; async function f(){ throw 'oops'; } f().then(function(){ r = 'F'; }, function(e){ r = 'R:' + e; });",
        "r",
        "R:oops",
    );
}

test "M11 Promise: then chaining, resolve adoption, microtask ordering (§27.2)" {
    // §27.2.5.4 then returns a new promise; the chained handler sees the prior result + 1.
    try expectGlobalNumberAfterDrain("var r; Promise.resolve(10).then(function(v){ return v + 5; }).then(function(v){ r = v; });", "r", 15);
    // §27.2.1.3.2 resolving with a thenable adopts its eventual value (Promise.resolve(promise) flattens).
    try expectGlobalNumberAfterDrain("var r; Promise.resolve(Promise.resolve(99)).then(function(v){ r = v; });", "r", 99);
    // §9.5 microtasks run AFTER synchronous code: the sync assignment wins first, the reaction overwrites.
    try expectGlobalStringAfterDrain("var log = ''; Promise.resolve().then(function(){ log = log + 'micro'; }); log = log + 'sync';", "log", "syncmicro");
    // §27.2.5.1 catch handles a rejection; §27.2.5.3 finally passes the value through.
    try expectGlobalStringAfterDrain("var r; Promise.reject('e').catch(function(x){ return 'C:' + x; }).then(function(v){ r = v; });", "r", "C:e");
}

test "M11 Promise: new Promise(executor) resolve/reject + executor throw (§27.2.3.1)" {
    // §27.2.3.1 the executor's resolve fulfills the promise.
    try expectGlobalNumberAfterDrain("var r; new Promise(function(res){ res(5); }).then(function(v){ r = v; });", "r", 5);
    // §27.2.3.1 step 10: a throwing executor rejects the promise.
    try expectGlobalStringAfterDrain("var r; new Promise(function(){ throw 'x'; }).then(function(){ r = 'F'; }, function(e){ r = 'R:' + e; });", "r", "R:x");
    // §27.2.3.1 step 2: a non-callable executor is a TypeError.
    try expectThrows("new Promise(42)");
}

test "M11 Cycle 3: globalThis reified global object (§19.3.1 / §9.3.4)" {
    // §19.3.1 globalThis is an object …
    try expectStr("typeof globalThis", "object");
    // … carrying the standard globals as own properties (identity-equal to the bindings).
    try expectBool("globalThis.Object === Object", true);
    try expectBool("globalThis.Promise === Promise", true);
    try expectBool("globalThis.Array === Array", true);
    // §19.3.1 globalThis refers to the global object itself (self-referential).
    try expectBool("globalThis.globalThis === globalThis", true);
    // A user global is reachable through globalThis (the binding is mirrored at setup; reads observe it).
    try expectNumber("globalThis.Math.pow(2, 5)", 32);
}

test "M11 Cycle 3: Promise.all fulfills with the values array; rejects on first reject (§27.2.4.1)" {
    // §27.2.4.1 all inputs fulfill → the result fulfills with an array of their values, in order.
    try expectGlobalNumberAfterDrain(
        "var r; async function f(){ var xs = await Promise.all([Promise.resolve(1), Promise.resolve(2)]); return xs[0] + xs[1]; } f().then(function(v){ r = v; });",
        "r",
        3,
    );
    // non-promise members are wrapped (PromiseResolve), preserving order.
    try expectGlobalStringAfterDrain("var r; Promise.all([1, Promise.resolve(2), 3]).then(function(xs){ r = xs.join(','); });", "r", "1,2,3");
    // §27.2.4.1 the empty iterable fulfills synchronously-after-loop with an empty array (length 0).
    try expectGlobalNumberAfterDrain("var r; Promise.all([]).then(function(xs){ r = xs.length; });", "r", 0);
    // §27.2.4.1 a single rejection rejects the result with that reason.
    try expectGlobalStringAfterDrain("var r; Promise.all([Promise.resolve(1), Promise.reject('bad')]).then(function(){ r = 'F'; }, function(e){ r = 'R:' + e; });", "r", "R:bad");
}

test "M11 Cycle 3: Promise.race settles with the first settlement (§27.2.4.6)" {
    // §27.2.4.6 the first already-resolved member wins (both are settled, FIFO microtask order → 'a').
    try expectGlobalStringAfterDrain("var r; Promise.race([Promise.resolve('a'), Promise.resolve('b')]).then(function(v){ r = v; });", "r", "a");
    // a rejection that settles first rejects the race.
    try expectGlobalStringAfterDrain("var r; Promise.race([Promise.reject('x'), Promise.resolve('y')]).then(function(){ r = 'F'; }, function(e){ r = 'R:' + e; });", "r", "R:x");
}

test "M11 Cycle 3: Promise.allSettled always fulfills with status records (§27.2.4.2)" {
    // §27.2.4.2 a mix of fulfill/reject → an array of {status, value|reason} records, in order.
    try expectGlobalStringAfterDrain(
        "var r; Promise.allSettled([Promise.resolve(1), Promise.reject('e')]).then(function(xs){ r = xs[0].status + ':' + xs[0].value + '|' + xs[1].status + ':' + xs[1].reason; });",
        "r",
        "fulfilled:1|rejected:e",
    );
}

test "M11 Cycle 3: Promise.any fulfills with first fulfillment; AggregateError if all reject (§27.2.4.3)" {
    // §27.2.4.3 the first fulfillment wins even when an earlier member rejects.
    try expectGlobalStringAfterDrain("var r; Promise.any([Promise.reject('x'), Promise.resolve('ok')]).then(function(v){ r = v; });", "r", "ok");
    // §27.2.4.3 all members reject → reject with an AggregateError whose `.errors` lists the reasons.
    try expectGlobalStringAfterDrain(
        "var r; Promise.any([Promise.reject('a'), Promise.reject('b')]).then(function(){ r = 'F'; }, function(e){ r = e.name + ':' + e.errors.join(','); });",
        "r",
        "AggregateError:a,b",
    );
    // §20.5.7 AggregateError is also a directly-constructible global.
    try expectStr("var e = new AggregateError([1, 2], 'oops'); e.name + '/' + e.message + '/' + e.errors.length", "AggregateError/oops/2");
}

test "M11 Cycle 3: thenable adoption settles the promise (§27.2.1.3.2 / §27.2.2.2)" {
    // §27.2.2.2 PromiseResolveThenableJob: resolving a promise with a plain (non-Promise) thenable
    // adopts its eventual state — the thenable's `resolve(v)` must settle the derived promise. Earlier
    // the promise's [[AlreadyResolved]] (set when claiming the thenable) wrongly blocked the job's own
    // resolve; the job now uses a fresh [[AlreadyResolved]], so adoption completes.
    try expectGlobalStringAfterDrain(
        "var out = 'X'; var thenable = { then: function(res){ res(42); } }; Promise.resolve(thenable).then(function(v){ out = 'got:' + v; });",
        "out",
        "got:42",
    );
    // The same adoption drives `await` of a plain thenable inside an async function.
    try expectGlobalStringAfterDrain(
        "var out = 'X'; var thenable = { then: function(res){ res(7); } }; async function f(){ out = 'got:' + (await thenable); } f();",
        "out",
        "got:7",
    );
    // A thenable that rejects propagates the rejection to the adopting promise.
    try expectGlobalStringAfterDrain(
        "var out = 'X'; var thenable = { then: function(res, rej){ rej('boom'); } }; Promise.resolve(thenable).then(function(){ out = 'F'; }, function(e){ out = 'R:' + e; });",
        "out",
        "R:boom",
    );
}

test "M13 async generators: yield produces values, consumed via for await (§27.6 / §14.7.5)" {
    // An `async function*` returns an AsyncGenerator; consuming it with `for await` inside an async
    // function collects the yielded values in order. `yield await p` exercises await inside the body.
    try expectGlobalStringAfterDrain(
        \\var out = '';
        \\async function* g(){ yield 1; yield await Promise.resolve(2); yield 3; }
        \\async function main(){ for await (const x of g()) { out = out + x; } }
        \\main();
    , "out", "123");
    // The async generator's body return value lands on the terminal { done:true } (not iterated by for-await).
    try expectGlobalStringAfterDrain(
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
    try expectGlobalStringAfterDrain(
        \\var out = '';
        \\async function main(){ for await (const x of [Promise.resolve(1), 2, Promise.resolve(3)]) { out = out + x; } }
        \\main();
    , "out", "123");
}

test "M13 async generator method on a class (§15.6 / §27.6)" {
    try expectGlobalStringAfterDrain(
        \\var out = '';
        \\class C { async *m(){ yield 10; yield 20; } }
        \\async function main(){ for await (const x of new C().m()) { out = out + x + ','; } }
        \\main();
    , "out", "10,20,");
}

test "M13 async generator .next() returns a promise of {value,done} (§27.6.1.2)" {
    try expectGlobalStringAfterDrain(
        \\var out = '';
        \\async function* g(){ yield 7; }
        \\async function main(){ var it = g(); var r = await it.next(); out = r.value + ':' + r.done; }
        \\main();
    , "out", "7:false");
}

test "M13 yield* over an async iterable in an async generator (§27.6.3.8)" {
    try expectGlobalStringAfterDrain(
        \\var out = '';
        \\async function* inner(){ yield 1; yield 2; }
        \\async function* outer(){ yield* inner(); yield 3; }
        \\async function main(){ for await (const x of outer()) { out = out + x; } }
        \\main();
    , "out", "123");
}

test "M13 for await is a SyntaxError outside an async context (§14.7.5)" {
    try expectSyntaxError("function f(){ for await (const x of []) {} }");
    try expectSyntaxError("for await (const x of []) {}");
    // `for await` requires the `of` form (no for-in, no C-style).
    try expectSyntaxError("async function f(){ for await (const x in []) {} }");
}

test "M11 async: `await` as identifier outside async; operator only inside async (§15.8)" {
    // §15.8: outside an async function (a sloppy script/function) `await` is an ordinary identifier.
    try expectNumber("function f(){var await = 1; return await;} f()", 1);
    try expectNumber("var await = 41; await + 1", 42);
    // §15.8.1: inside an async function `await` is the operator — a bare `await` as a binding name is
    // a SyntaxError, and `await` reaching IdentifierReference position is a SyntaxError.
    try expectSyntaxError("async function f(){ var await = 1; }");
    try expectSyntaxError("async function f(await){}");
    try expectSyntaxError("async function await(){}");
    // §15.8.1: an async arrow's param may not be named `await`.
    try expectSyntaxError("var f = async await => 1;");
    // §15.8: `await` IS the operator inside an async body (parses; runtime stub at evaluation).
    try expectNoSyntaxErrorStrict("async function f(x){ return await x; }");
    try expectNoSyntaxErrorStrict("async function f(x){ await x; }");
    // an async method body also has `[+Await]`.
    try expectNoSyntaxErrorStrict("var o = { async m(x){ return await x; } };");
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

test "M4 classes: declaration, constructor, new (Cycle 1, §15.7.14)" {
    // empty class declaration constructs an instance
    try expectStr("class C {} typeof new C()", "object");
    try expectStr("class C {} typeof C", "function");
    // constructor binds fields on `this`
    try expectNumber("class C { constructor(x) { this.x = x; } } new C(7).x", 7);
    try expectNumber("class C { constructor(a, b) { this.s = a + b; } } new C(40, 2).s", 42);
    // a class constructor cannot be called without `new` (§15.7.14)
    try expectThrows("class C {} C()");
    // a class is an instanceof itself
    try expectBool("class C {} (new C()) instanceof C", true);
}

test "M4 classes: instance methods on the prototype (Cycle 1, §15.7.14)" {
    try expectNumber("class C { m() { return 1; } } new C().m()", 1);
    // method `this` is the receiver
    try expectNumber("class C { constructor() { this.v = 5; } get() { return this.v; } } new C().get()", 5);
    // method takes params
    try expectNumber("class C { add(a, b) { return a + b; } } new C().add(40, 2)", 42);
    // methods live on the prototype (shared), not per-instance
    try expectBool("class C { m() {} } var a = new C(); var b = new C(); a.m === b.m", true);
}

test "M4 classes: instance fields (Cycle 1, §15.7.14)" {
    // field with initializer
    try expectNumber("class C { x = 5; } new C().x", 5);
    // bare field defaults to undefined
    try expectStr("class C { x; } typeof new C().x", "undefined");
    // multiple fields, initialized in order; an initializer may reference `this`
    try expectNumber("class C { a = 1; b = 2; } var o = new C(); o.a + o.b", 3);
    // fields initialize BEFORE the constructor body runs
    try expectNumber("class C { x = 10; constructor() { this.x = this.x + 1; } } new C().x", 11);
    // a field initializer can reference an outer binding
    try expectNumber("var k = 9; class C { x = k; } new C().x", 9);
}

test "M4 classes: static methods and fields (Cycle 1, §15.7.14)" {
    // static method on the constructor object
    try expectNumber("class C { static s() { return 9; } } C.s()", 9);
    // static field on the constructor object
    try expectNumber("class C { static n = 3; } C.n", 3);
    // static field initializer sees `this` = the constructor
    try expectNumber("class C { static a = 2; static b = 40; } C.a + C.b", 42);
    // a static member is NOT on instances
    try expectStr("class C { static s() {} } typeof new C().s", "undefined");
}

test "M4 classes: class expression (Cycle 1, §15.7)" {
    // anonymous class expression
    try expectNumber("var C = class { m() { return 1; } }; new C().m()", 1);
    // named class expression — the name is bound inside the body for self-reference
    try expectBool("var K = class C { who() { return C; } }; new K().who() === K", true);
    // class expression with a field
    try expectNumber("var C = class { x = 7; }; new C().x", 7);
    // immediately constructed
    try expectNumber("new (class { constructor() { this.v = 42; } })().v", 42);
}

test "M10 EmptyStatement (§14.4): bare/doubled `;` and trailing `;` after declarations" {
    // a bare `;` is a no-op statement (not a SyntaxError)
    try expectNumber("; 1", 1);
    // doubled empty statements
    try expectNumber(";; 2", 2);
    // §14.4: a `;` (EmptyStatement) after a class declaration — the common Test262 `class C {};` form
    try expectNumber("class C { m() { return 9; } }; new C().m()", 9);
    // a `;` after a function declaration
    try expectNumber("function f() { return 5; }; f()", 5);
    // an empty loop body (`for (...);`) runs the header but no body statement
    try expectNumber("var i = 0; for (; i < 3; i++); i", 3);
    // an empty `if`/`else` body
    try expectNumber("if (true) ; else ; 7", 7);
    try expectNumber("while (false) ; 8", 8);
}

test "M10 classes: declaration in statement position is block-scoped (§15.7 / §14.3)" {
    // statement-form class declaration: the binding name resolves and methods work
    try expectNumber("class C { m() { return 7; } } new C().m()", 7);
    // a derived class declared as a statement; instance is `instanceof` the base
    try expectBool("class A {} class B extends A {} (new B()) instanceof A", true);
    // §15.7: a ClassDeclaration creates a block-scoped lexical binding (like `let`), NOT a
    // function-style binding that leaks to the enclosing scope — a class declared in a block
    // is not visible after the block.
    try expectStr("{ class Q {} } typeof Q", "undefined");
    try expectThrows("{ class Q {} } new Q()");
    // used before its declaration in the same scope → ReferenceError (no function-style hoisting
    // of the initialized binding — matches §14.3 lexical-binding ordering observably).
    try expectThrows("new D(); class D {}");
    // anonymous `class {}` is not a ClassDeclaration (statement position requires a name).
    try expectSyntaxError("class {}");
    // `class` must still work where it is an expression (parenthesized / assignment RHS).
    try expectNumber("var x = (class { m() { return 3; } }); new x().m()", 3);
    // a function* declaration in statement position parses and produces a generator.
    try expectNumber("function* g() { yield 5; } g().next().value", 5);
}

test "M10 do-while (§14.7.2): body runs, condition re-tests, at least once" {
    // accumulate while i<3
    try expectNumber("var i=0,s=0; do { s+=i; i++ } while (i<3); s", 3);
    // body runs at least once even when the condition is false up front
    try expectNumber("var n=0; do n++; while(false); n", 1);
    // unlabeled break exits the do-while
    try expectNumber("var i=0; do { if (i==2) break; i++ } while (i<10); i", 2);
    // unlabeled continue re-tests the condition (does NOT skip the increment here)
    try expectNumber("var i=0,s=0; do { i++; if (i==2) continue; s+=i } while (i<4); s", 8); // 1+3+4
    // trailing `;` is ASI-optional: `do x; while(c)` with no explicit `;` still parses
    try expectNumber("var i=0; do i++; while(i<3) i", 3);
}

test "M10 labeled break/continue (§14.13/§14.9/§14.8)" {
    // labeled break exits BOTH loops; the outer i stops at 0 (break fires when j==1, i still 0)
    try expectNumber("var i,j,last=-1; outer: for(i=0;i<3;i++){ for(j=0;j<3;j++){ if(j==1) break outer; last=i*10+j } } last", 0);
    // labeled continue restarts the OUTER loop: inner never increments s (continue before s++)
    try expectNumber("var s=0; outer: for(var i=0;i<3;i++){ for(var j=0;j<3;j++){ if(j==0) continue outer; s++ } } s", 0);
    // labeled continue that does some work first: inner runs once per outer (j==1 continues outer)
    try expectNumber("var s=0; outer: for(var i=0;i<3;i++){ for(var j=0;j<3;j++){ s++; if(j==0) continue outer } } s", 3);
    // labeled break on a do-while loop
    try expectNumber("var n=0; L: do { n++; if (n==2) break L; } while (n<10); n", 2);
    // a labeled block: `break label` exits the block, skipping the rest
    try expectNumber("var x=1; blk: { x=2; break blk; x=99; } x", 2);
    // label on a while loop, continue label
    try expectNumber("var i=0,s=0; L: while(i<5){ i++; if(i%2==0) continue L; s+=i } s", 9); // 1+3+5
    // unlabeled break/continue still work inside a single loop
    try expectNumber("var s=0; for(var i=0;i<5;i++){ if(i==3) break; s+=i } s", 3); // 0+1+2
    try expectNumber("var s=0; for(var i=0;i<5;i++){ if(i%2==0) continue; s+=i } s", 4); // 1+3
    // a label on a BLOCK only labels the block, NOT a loop nested inside it: an unlabeled break
    // inside that loop exits only the inner loop, and `break L` exits the block.
    try expectNumber("var s=0; L: { for(var i=0;i<5;i++){ if(i==2) break; s+=i } s+=100; } s", 101); // 0+1 then +100
    try expectNumber("var s=0; L: { for(var i=0;i<5;i++){ s+=i; if(i==1) break L; } s+=100; } s", 1); // 0+1, break L skips +100
    // a chain of labels on one loop: either label is a valid break target
    try expectNumber("var c=0; a: b: for(var i=0;i<3;i++){ for(var j=0;j<3;j++){ c++; if(c==2) break a; } } c", 2);
    // labeled break out of a switch wrapped in a label
    try expectNumber("var x=0; sw: switch(1){ case 1: x=5; break sw; case 2: x=9; } x", 5);
}

test "M10 labeled statements: parse-phase Early Errors (§14.13.1/§14.8.1/§14.9.1)" {
    // break/continue to an undefined label → SyntaxError
    try expectSyntaxError("for(;;){ break nope; }");
    try expectSyntaxError("for(;;){ continue nope; }");
    // continue targeting a non-iteration label is a SyntaxError
    try expectSyntaxError("blk: { continue blk; }");
    // duplicate nested label is a SyntaxError
    try expectSyntaxError("a: a: ;");
    // a label does not cross a function boundary
    try expectSyntaxError("L: for(;;){ function f(){ break L; } }");
    // unlabeled break/continue outside any loop/switch is a SyntaxError
    try expectSyntaxError("break;");
    try expectSyntaxError("continue;");
    // `continue` is illegal inside a switch (no enclosing iteration)
    try expectSyntaxError("switch(0){ case 0: continue; }");
}

test "M4 classes: body is strict (Cycle 1, §15.7)" {
    // §15.7: a class body is always strict, so a method binding `eval`/`arguments` as a param is a
    // SyntaxError even with no directive and in sloppy RunMode.
    try expectSyntaxError("class C { m(eval) {} }");
    try expectSyntaxError("class C { m(arguments) {} }");
    // a duplicate parameter in a method is a SyntaxError (methods enforce this in every mode)
    try expectSyntaxError("class C { m(a, a) {} }");
}

test "M4 classes: unsupported element syntax still parse-rejects (Cycle 1 scope)" {
    // generator methods landed in M9 Cycle 2; async methods / async generator methods landed in M11
    // Cycle 1 (§15.8/§15.6 parsing) — they now PARSE (covered by the M11 async tests below).
    try expectNoSyntaxErrorStrict("class C { async m() {} }"); // async method (M11)
    try expectNoSyntaxErrorStrict("class C { async *m() {} }"); // async generator method (M11)
    // a ClassDeclaration requires a name
    try expectSyntaxError("class {}");
}

test "M4 classes: extends + super (Cycle 2, §15.7.14 / §13.3.5 / §13.3.7)" {
    // extends links the chains; super() runs the parent ctor on `this`; own fields after super().
    try expectNumber(
        "class A { constructor() { this.x = 1; } } " ++
            "class B extends A { constructor() { super(); this.y = 2; } } " ++
            "var b = new B(); b.x + b.y",
        3,
    );
    // an instance of a derived class is `instanceof` both the derived and the base class
    try expectBool(
        "class A {} class B extends A {} (new B()) instanceof A",
        true,
    );
    try expectBool(
        "class A {} class B extends A {} (new B()) instanceof B",
        true,
    );
    // super.method() invokes the parent method with `this` = the current instance
    try expectNumber(
        "class A { m() { return 10; } } " ++
            "class B extends A { m() { return super.m() + 5; } } " ++
            "new B().m()",
        15,
    );
    // super.method() can read instance state via the current `this`
    try expectNumber(
        "class A { who() { return this.v; } } " ++
            "class B extends A { constructor() { super(); this.v = 7; } get() { return super.who(); } } " ++
            "new B().get()",
        7,
    );
    // super.prop reads a parent prototype data property (not the instance's own)
    try expectNumber(
        "class A { constructor() { this.label = 99; } } A.prototype.label = 1; " ++
            "class B extends A { read() { return super.label; } } " ++
            "var b = new B(); b.read()",
        1,
    );
    // static inheritance: a static member of the base is reachable through the derived constructor
    try expectNumber(
        "class A { static s() { return 42; } } class B extends A {} B.s()",
        42,
    );
    try expectNumber(
        "class A { static n = 8; } class B extends A {} B.n",
        8,
    );
    // default derived constructor forwards args to super(...)
    try expectNumber(
        "class A { constructor(a, b) { this.s = a + b; } } class B extends A {} new B(40, 2).s",
        42,
    );
    // extends an arbitrary expression (the heritage is a LeftHandSideExpression)
    try expectNumber(
        "var box = { Base: class { constructor() { this.v = 5; } } }; " ++
            "class D extends box.Base { constructor() { super(); this.v += 1; } } new D().v",
        6,
    );
    // a three-level chain: C extends B extends A — each super() initializes its level
    try expectNumber(
        "class A { constructor() { this.a = 1; } } " ++
            "class B extends A { constructor() { super(); this.b = 2; } } " ++
            "class C extends B { constructor() { super(); this.c = 3; } } " ++
            "var o = new C(); o.a + o.b + o.c",
        6,
    );
    // derived instance fields initialize AFTER super() (so they can see parent-set state)
    try expectNumber(
        "class A { constructor() { this.base = 10; } } " ++
            "class B extends A { y = this.base + 1; } " ++
            "new B().y",
        11,
    );
    // extends null: the prototype chain links to null (instance is not instanceof Object via chain)
    try expectStr("class A extends null {} typeof A", "function");
}

test "M4 classes: super early errors (Cycle 2, §13.3.5.1 / §13.3.7.1)" {
    // super(...) outside a derived constructor is a SyntaxError
    try expectSyntaxError("class A { constructor() { super(); } }"); // non-derived ctor
    try expectSyntaxError("class A extends Object { m() { super(); } }"); // non-constructor method
    try expectSyntaxError("function f() { super(); }"); // outside any class
    try expectSyntaxError("super();"); // top level
    // super.prop outside a method is a SyntaxError
    try expectSyntaxError("function f() { return super.x; }");
    try expectSyntaxError("super.x;"); // top level
    // a bare `super` (not a SuperProperty/SuperCall) is always a SyntaxError
    try expectSyntaxError("class A extends Object { m() { return super; } }");
    // extends a non-constructor, non-null value throws a TypeError at runtime
    try expectThrows("class B extends 5 {}");
    try expectThrows("class B extends ({}) {}");
}

test "M4 classes: accessors get/set (Cycle 3, §15.7 / §13.2.5.6)" {
    // a getter on the prototype: `.x` invokes it
    try expectNumber("class C { get x() { return 5; } } new C().x", 5);
    // a setter stores via the instance; a separate getter reads it back (get+set merge to one prop)
    try expectNumber(
        "class C { set x(v) { this._x = v; } get x() { return this._x; } } " ++
            "var c = new C(); c.x = 9; c.x",
        9,
    );
    // a setter-only accessor: assignment runs the setter (here recording into another field)
    try expectNumber(
        "class C { set x(v) { this.seen = v + 1; } } var c = new C(); c.x = 41; c.seen",
        42,
    );
    // a getter reading instance state set by the constructor
    try expectNumber(
        "class C { constructor() { this.v = 3; } get doubled() { return this.v * 2; } } new C().doubled",
        6,
    );
    // static getter on the constructor
    try expectNumber("class C { static get answer() { return 42; } } C.answer", 42);
    // static setter
    try expectNumber(
        "class C { static set v(x) { C._v = x; } } C.v = 7; C._v",
        7,
    );
    // an accessor carries [[HomeObject]] — super.x inside a getter resolves to the parent accessor
    try expectNumber(
        "class A { get x() { return 100; } } " ++
            "class B extends A { get x() { return super.x + 1; } } " ++
            "new B().x",
        101,
    );
}

test "M4 classes: computed names (Cycle 3, §15.7)" {
    // computed method name `[expr]() {}`
    try expectNumber("class C { ['a' + 'b']() { return 1; } } new C().ab()", 1);
    // computed instance field name `[expr] = init`
    try expectNumber("class C { ['v' + 1] = 7; } new C().v1", 7);
    // a bare computed field `[expr];` is created undefined
    try expectStr("var k = 'q'; class C { [k]; } typeof new C().q", "undefined");
    // computed static method name
    try expectNumber("class C { static ['s' + 'm']() { return 9; } } C.sm()", 9);
    // computed static field name
    try expectNumber("class C { static ['n' + 1] = 4; } C.n1", 4);
    // computed accessor (getter) name
    try expectNumber("class C { get ['g' + 'x']() { return 8; } } new C().gx", 8);
    // computed accessor (setter) name round-trips with a matching computed getter
    try expectNumber(
        "var k = 'p'; class C { set [k](v) { this._p = v; } get [k]() { return this._p; } } " ++
            "var c = new C(); c.p = 5; c.p",
        5,
    );
    // the key expression is evaluated at class-definition time, in definition order
    try expectStr(
        "var log = ''; var a = () => { log += 'a'; return 'm1'; }; " ++
            "var b = () => { log += 'b'; return 'm2'; }; " ++
            "class C { [a()]() {} [b()]() {} } log",
        "ab",
    );
    // a numeric computed key is ToString'd
    try expectNumber("class C { [1 + 1]() { return 3; } } new C()[2]()", 3);
}

test "M4 classes: private fields (Cycle 4, §15.7 PrivateName)" {
    // a private field read back through a method (`this.#x`)
    try expectNumber("class C { #x = 1; getX() { return this.#x; } } new C().getX()", 1);
    // a bare private field defaults to undefined
    try expectStr("class C { #x; peek() { return typeof this.#x; } } new C().peek()", "undefined");
    // private field reassignment via `this.#x = …`
    try expectNumber("class C { #x = 1; bump() { this.#x = this.#x + 10; return this.#x; } } new C().bump()", 11);
    // compound assignment to a private field
    try expectNumber("class C { #x = 5; go() { this.#x += 3; return this.#x; } } new C().go()", 8);
    // a private field initializer may reference an outer binding + `this`
    try expectNumber("var k = 9; class C { #x = k; getX() { return this.#x; } } new C().getX()", 9);
    // private names do NOT collide with same-named public properties
    try expectNumber("class C { #x = 1; constructor() { this.x = 100; } both() { return this.x + this.#x; } } new C().both()", 101);
    // a private name is NOT reachable as an ordinary property / not enumerable via `in`
    try expectBool("class C { #x = 1; static probe(o) { return 'x' in o; } } C.probe(new C())", false);
}

test "M4 classes: private name brand check — TypeError on a foreign object (Cycle 4, §15.7)" {
    // reading `o.#x` on an object that never got the brand is a TypeError
    try expectThrows("class C { #x = 1; static read(o) { return o.#x; } } C.read({})");
    // writing `o.#x` on a foreign object is a TypeError too
    try expectThrows("class C { #x = 1; static write(o) { o.#x = 2; } } C.write({})");
    // the thrown error is specifically a TypeError; an instance of the class is fine
    try expectStr(
        "class C { #x = 1; static read(o) { return o.#x; } } " ++
            "var n = ''; try { C.read({}); } catch (e) { n = e.name; } n",
        "TypeError",
    );
    try expectNumber("class C { #x = 7; static read(o) { return o.#x; } } C.read(new C())", 7);
    // reading a private name on a primitive is a TypeError
    try expectThrows("class C { #x = 1; static read(o) { return o.#x; } } C.read(5)");
}

test "M4 classes: private methods and accessors (Cycle 4, §15.7)" {
    // a private method, called via `this.#m()`
    try expectNumber("class C { #m() { return 42; } call() { return this.#m(); } } new C().call()", 42);
    // a private method is shared but read-only: assigning to it is a TypeError
    try expectThrows("class C { #m() {} go() { this.#m = 1; } } new C().go()");
    // a private getter
    try expectNumber("class C { get #v() { return 5; } read() { return this.#v; } } new C().read()", 5);
    // a private get/set pair round-trips
    try expectNumber(
        "class C { set #v(x) { this._x = x; } get #v() { return this._x; } go() { this.#v = 9; return this.#v; } } new C().go()",
        9,
    );
    // a private field initializer may call an earlier private method (brand installed in order)
    try expectNumber(
        "class C { #m() { return 5; } #x = this.#m() + 1; read() { return this.#x; } } new C().read()",
        6,
    );
    // private members survive inheritance (each class adds its own brand)
    try expectStr(
        "class A { #a = 1; ga() { return this.#a; } } " ++
            "class B extends A { #b = 2; gb() { return this.#b; } } " ++
            "var o = new B(); o.ga() + ',' + o.gb()",
        "1,2",
    );
}

test "M4 classes: static private members (Cycle 4, §15.7)" {
    // a static private method, called via the constructor
    try expectNumber("class C { static #m() { return 8; } static call() { return C.#m(); } } C.call()", 8);
    // a static private field
    try expectNumber("class C { static #n = 3; static read() { return C.#n; } } C.read()", 3);
    // a static private accessor
    try expectNumber("class C { static get #v() { return 6; } static read() { return C.#v; } } C.read()", 6);
}

test "M4 classes: static initialization blocks (Cycle 4, §15.7.11)" {
    // a static block runs at class definition with `this` = the constructor
    try expectNumber("class C { static y; static { this.y = 7; } } C.y", 7);
    // multiple static blocks run in source order, interleaved with static fields
    try expectStr(
        "class C { static a = 1; static { this.b = this.a + 1; } static c = this.b + 1; } " ++
            "C.a + ',' + C.b + ',' + C.c",
        "1,2,3",
    );
    try expectStr(
        "class C { static log = ''; static { this.log += '1'; } static { this.log += '2'; } } C.log",
        "12",
    );
    // a static block can use `super.x` (its [[HomeObject]] is the constructor)
    try expectNumber(
        "class A { static v() { return 9; } } " ++
            "class B extends A { static r; static { this.r = super.v(); } } B.r",
        9,
    );
}

test "M4 classes: `#x in obj` ergonomic brand check (Cycle 4, §13.10.1)" {
    // true for an instance carrying the brand, false for a foreign object (no throw)
    try expectBool("class C { #x = 1; static has(o) { return #x in o; } } C.has(new C())", true);
    try expectBool("class C { #x = 1; static has(o) { return #x in o; } } C.has({})", false);
    // false for a non-object (no throw, unlike ordinary `in`)
    try expectBool("class C { #x = 1; static has(o) { return #x in o; } } C.has(5)", false);
    // the brand check works for a private method's name too
    try expectBool("class C { #m() {} static has(o) { return #m in o; } } C.has(new C())", true);
}

test "M4 classes: private-name early errors (Cycle 4, §15.7.1)" {
    // a PrivateIdentifier outside any class body is a SyntaxError
    try expectSyntaxError("var o = {}; o.#x");
    try expectSyntaxError("#x");
    try expectSyntaxError("#x in {}");
    // a bare `#` (not a private identifier) is a lexer error → SyntaxError
    try expectSyntaxError("var x = # 1;");
    // `#constructor` is not a legal private name
    try expectSyntaxError("class C { #constructor() {} }");
    try expectSyntaxError("class C { #constructor = 1; }");
    // a duplicate private name is a SyntaxError (but a get/set pair may share a name)
    try expectSyntaxError("class C { #x = 1; #x = 2; }");
    try expectSyntaxError("class C { #m() {} #m() {} }");
    try expectNoSyntaxErrorStrict("class C { get #v() {} set #v(x) {} }");
    // a private name in an object literal is a SyntaxError
    try expectSyntaxError("var o = { #x: 1 };");
    try expectSyntaxError("var o = { get #x() {} };");
}

test "M4 classes: §15.7.1 class early errors + legal positives (Cycle 5, close)" {
    // ----- Early Errors (parse-phase SyntaxError) — these MUST keep rejecting -----
    // §15.7.1 ClassBody may declare at most one (non-static) `constructor`.
    try expectSyntaxError("class C { constructor() {} constructor() {} }");
    // `constructor` may not be a getter/setter/field (only an ordinary method).
    try expectSyntaxError("class C { get constructor() {} }");
    try expectSyntaxError("class C { set constructor(v) {} }");
    try expectSyntaxError("class C { constructor = 1; }");
    try expectSyntaxError("class C { \"constructor\" = 1; }"); // string-named field `constructor`
    // a `static` member named `prototype` is forbidden (method/accessor/field).
    try expectSyntaxError("class C { static prototype() {} }");
    try expectSyntaxError("class C { static get prototype() {} }");
    try expectSyntaxError("class C { static prototype = 1; }");

    // ----- Legal positives — these MUST NOT be rejected (over-rejection guard) -----
    // §15.7 ClassBody `;` empty elements are legal and ignored.
    try expectNumber("var C = class { ; ; m() { return 5; } ; }; new C().m()", 5);
    // `static constructor` is a legal STATIC method (the §15.7.1 ctor restriction is non-static only).
    try expectNumber("var C = class { static constructor() { return 9; } }; C.constructor()", 9);
    // one non-static `constructor` PLUS a `static constructor` is legal (only one non-static counts).
    try expectNoSyntaxErrorStrict("var C = class { constructor() {} static constructor() {} }");
    // a STATIC accessor named `constructor` is legal (only `prototype` is forbidden when static).
    try expectNumber("var C = class { static get constructor() { return 3; } }; C.constructor", 3);
    // a non-static method/accessor named `prototype` is legal (only `static prototype` is barred).
    try expectNumber("var C = class { prototype() { return 8; } }; new C().prototype()", 8);
    try expectNumber("var C = class { get prototype() { return 6; } }; new C().prototype", 6);
    // a computed `[\"constructor\"]` method is NOT the constructor (§15.7.1 keys off the *static*
    // StringValue), so it does not clash with the real `constructor` — legal.
    try expectNoSyntaxErrorStrict("var C = class { constructor() {} [\"constructor\"]() {} }");
    // `extends` an invalid target is a RUNTIME TypeError, not a parse Early Error.
    try expectNoSyntaxErrorStrict("var C = class extends 5 {}");
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

test "M3 compound assignment: full operator set on identifiers (US7, §13.15)" {
    // The five existing ops still work (regression guard).
    try expectNumber("var s = 0; s += 10; s -= 3; s *= 2; s", 14);
    try expectNumber("var s = 20; s /= 4; s", 5);
    try expectNumber("var s = 20; s %= 7; s", 6);
    // New compound ops: **= and the shifts.
    try expectNumber("var s = 3; s **= 4; s", 81);
    try expectNumber("var s = 1; s <<= 5; s", 32);
    try expectNumber("var s = 64; s >>= 2; s", 16);
    try expectNumber("var s = -1; s >>>= 28; s", 15); // logical (unsigned) shift
    // New compound ops: bitwise &= |= ^=.
    try expectNumber("var s = 12; s &= 10; s", 8);
    try expectNumber("var s = 12; s |= 3; s", 15);
    try expectNumber("var s = 12; s ^= 10; s", 6);
    // Result value of a compound assignment is the assigned value.
    try expectNumber("var s = 5; (s **= 2)", 25);
}

test "M3 compound assignment: member & index targets (US7, §13.15)" {
    try expectNumber("var o = {n: 3}; o.n **= 3; o.n", 27);
    try expectNumber("var o = {n: 1}; o.n <<= 4; o.n", 16);
    try expectNumber("var o = {n: 13}; o.n &= 6; o.n", 4);
    try expectNumber("var o = {n: 8}; o.n |= 1; o.n", 9);
    try expectNumber("var o = {n: 8}; o.n ^= 12; o.n", 4);
    // a[k] *= 2 (existing) and the new ops on an index target.
    try expectNumber("var a = [1, 2, 3]; a[1] *= 2; a[1]", 4);
    try expectNumber("var a = [1, 2, 3]; a[2] **= 3; a[2]", 27);
    try expectNumber("var a = [4]; a[0] >>= 1; a[0]", 2);
    try expectNumber("var a = [5]; a[0] |= 2; a[0]", 7);
}

test "M3 logical assignment: &&= ||= ??= guard semantics (US7, §13.15.2)" {
    // &&= assigns only when the current value is truthy.
    try expectNumber("var x = 1; x &&= 5; x", 5); // truthy → assigned
    try expectNumber("var x = 0; x &&= 5; x", 0); // falsy → unchanged
    // ||= assigns only when the current value is falsy.
    try expectNumber("var x = 0; x ||= 9; x", 9); // falsy → assigned
    try expectNumber("var x = 3; x ||= 9; x", 3); // truthy → unchanged
    // ??= assigns only when null/undefined — 0 and '' are NOT nullish.
    try expectNumber("var x; x ??= 7; x", 7); // undefined → assigned
    try expectNumber("var x = null; x ??= 7; x", 7); // null → assigned
    try expectNumber("var x = 0; x ??= 7; x", 0); // 0 is not nullish → unchanged
    try expectStr("var x = ''; x ??= 'y'; x", ""); // '' is not nullish → unchanged
    // Yields the final value of the target.
    try expectNumber("var x = 0; (x ||= 4)", 4);
    try expectNumber("var x = 2; (x &&= 8)", 8);
    // Logical assignment on member / index targets.
    try expectNumber("var o = {n: 0}; o.n ||= 5; o.n", 5);
    try expectNumber("var o = {}; o.n ??= 9; o.n", 9);
    try expectNumber("var a = [0]; a[0] ||= 6; a[0]", 6);
}

test "M3 logical assignment: short-circuit does NOT evaluate RHS (US7, §13.15.2)" {
    // RHS is a call that bumps a counter; assert the counter only moves when the guard passes.
    // &&= on a falsy target must NOT evaluate the RHS.
    try expectNumber(
        "var hits = 0; function bump() { hits = hits + 1; return 99; } var x = 0; x &&= bump(); hits",
        0,
    );
    // …but on a truthy target it DOES.
    try expectNumber(
        "var hits = 0; function bump() { hits = hits + 1; return 99; } var x = 1; x &&= bump(); hits",
        1,
    );
    // ||= on a truthy target must NOT evaluate the RHS.
    try expectNumber(
        "var hits = 0; function bump() { hits = hits + 1; return 99; } var x = 3; x ||= bump(); hits",
        0,
    );
    // ??= on a non-nullish target must NOT evaluate the RHS.
    try expectNumber(
        "var hits = 0; function bump() { hits = hits + 1; return 99; } var x = 0; x ??= bump(); hits",
        0,
    );
    // ??= on undefined DOES evaluate the RHS exactly once.
    try expectNumber(
        "var hits = 0; function bump() { hits = hits + 1; return 99; } var x; x ??= bump(); hits",
        1,
    );
}

test "M3 logical assignment: member base evaluated exactly once (US7, §13.15.2)" {
    // `obj().p ??= v` must call obj() once whether or not the assignment happens.
    // Non-nullish current value → no write, but base still evaluated once.
    try expectNumber(
        "var calls = 0; var o = {p: 1}; function obj() { calls = calls + 1; return o; } obj().p ??= 5; calls",
        1,
    );
    // Nullish current value → write happens, base still evaluated once.
    try expectNumber(
        "var calls = 0; var o = {}; function obj() { calls = calls + 1; return o; } obj().p ??= 5; o.p",
        5,
    );
    try expectNumber(
        "var calls = 0; var o = {}; function obj() { calls = calls + 1; return o; } obj().p ??= 5; calls",
        1,
    );
}

test "M3 comma / sequence operator (US8, §13.16)" {
    // `(a, b, c)` evaluates each and yields the last.
    try expectNumber("(1, 2, 3)", 3);
    // Side effects of the discarded left operand are observable.
    try expectNumber("var a = 0; (a = 1, a = 2); a", 2);
    try expectNumber("var a = 0; var b = (a = 5, a + 1); b", 6);
    // Comma is allowed as a top-level expression statement.
    try expectNumber("var x = 0; x = 1, x = 7; x", 7);
    // Comma in the `for` init/update clauses (full Expression positions).
    try expectNumber("var s = 0; for (var i = 0, j = 10; i < 3; i++, j--) { s += j; } s", 27);
}

test "M3 comma does NOT hijack arg/element/declarator commas (US8 regression)" {
    // Call arguments are an AssignmentExpression list — `f(1, 2)` is two args, not a sequence.
    try expectNumber("function f(a, b) { return a + b; } f(1, 2)", 3);
    try expectNumber("function f(a, b, c) { return c; } f(1, 2, 3)", 3);
    // Array elements likewise — `[1, 2]` has length 2, not a single sequence value.
    try expectNumber("[1, 2].length", 2);
    try expectNumber("[1, 2, 3][1]", 2);
    // Declarator list — `var a = 1, b = 2;` declares two bindings.
    try expectNumber("var a = 1, b = 2; a + b", 3);
    // Object property list.
    try expectNumber("var o = {a: 1, b: 2}; o.a + o.b", 3);
    // Arrow cover-grammar still wins over the sequence operator: `(a, b) => …` are params.
    try expectNumber("var f = (a, b) => a + b; f(40, 2)", 42);
}

test "M3 void operator (US8, §13.5.2)" {
    try expectUndefined("void 0");
    try expectUndefined("void \"anything\"");
    // The operand is evaluated for side effects; the result is undefined.
    try expectNumber("var a = 0; void (a = 9); a", 9);
}

test "M3 delete operator (US8, §13.5.1)" {
    // delete an own property → property gone, `in` reports false, returns true.
    try expectBool("var o = {x: 1}; delete o.x; \"x\" in o", false);
    try expectBool("var o = {x: 1}; delete o.x", true);
    try expectBool("var o = {x: 1, y: 2}; delete o.x; \"y\" in o", true);
    // computed/index form.
    try expectBool("var o = {x: 1}; var k = \"x\"; delete o[k]; \"x\" in o", false);
    // delete of a non-Reference evaluates the operand and returns true.
    try expectBool("delete 5", true);
    try expectBool("var a = 0; delete (a = 3)", true);
    try expectNumber("var a = 0; delete (a = 3); a", 3); // operand side effect observed
    // delete of an unqualified identifier returns true (sloppy M-subset).
    try expectBool("var x = 1; delete x", true);
    // accessing a deleted property yields undefined.
    try expectUndefined("var o = {x: 1}; delete o.x; o.x");
}

test "M3 strict-mode: \"use strict\" directive triggers Early Errors (US9, §11.2.2/§13.1.1)" {
    // A "use strict" directive prologue makes the script strict, so a binding named `eval`/
    // `arguments` is a SyntaxError (§13.1.1).
    try expectSyntaxError("\"use strict\"; var eval = 1;");
    try expectSyntaxError("\"use strict\"; var arguments = 1;");
    try expectSyntaxError("'use strict'; let eval = 2;");
    try expectSyntaxError("\"use strict\"; function eval() {}");
    try expectSyntaxError("\"use strict\"; function f(eval) {}");
    try expectSyntaxError("\"use strict\"; var f = (arguments) => 1;");
    // Future-reserved words as a binding name (§13.1.1).
    try expectSyntaxError("\"use strict\"; var public = 1;");
    try expectSyntaxError("\"use strict\"; function f(static) {}");
    try expectSyntaxError("\"use strict\"; var yield = 1;");
    // §13.15.1 assignment / update target of eval/arguments.
    try expectSyntaxError("\"use strict\"; eval = 1;");
    try expectSyntaxError("\"use strict\"; arguments++;");
    try expectSyntaxError("\"use strict\"; eval += 2;");
    // §13.5.1.1 delete of an unqualified reference.
    try expectSyntaxError("\"use strict\"; var y; delete y;");
    // §15.1.1 duplicate parameter names in a strict normal function.
    try expectSyntaxError("\"use strict\"; function f(a, a) { return a; }");
}

test "M3 strict-mode: lexical inheritance into nested functions (US9, §11.2.2)" {
    // A nested function inherits strictness even without its own directive.
    try expectSyntaxError("\"use strict\"; function outer() { function inner(eval) {} }");
    try expectSyntaxError("\"use strict\"; function outer() { var f = () => { var arguments = 1; }; }");
    // A "use strict" only inside the inner function makes the INNER strict (outer stays sloppy).
    try expectSyntaxError("function outer() { 'use strict'; function inner() { var eval = 1; } }");
    // …but the outer body, being sloppy, may still bind eval.
    try expectNoSyntaxErrorStrict("function outer() { return 1; } var x = 1;"); // sanity: strict mode parses fine
}

test "M3 strict-mode via RunMode: Early Errors fire without a prepended directive (US9)" {
    // The Test262 runner runs each test in strict RunMode (honoring the mode parameter), so the
    // Early Errors must fire even with no explicit directive in the source.
    try expectSyntaxErrorStrict("var eval = 1;");
    try expectSyntaxErrorStrict("var arguments = 2;");
    try expectSyntaxErrorStrict("function f(arguments) {}");
    try expectSyntaxErrorStrict("eval = 1;");
    try expectSyntaxErrorStrict("var z; delete z;");
    try expectSyntaxErrorStrict("function f(a, a) {}");
    try expectSyntaxErrorStrict("var f = (x, x) => 1;"); // (also a duplicate-param error in any mode)
    try expectSyntaxErrorStrict("var public = 1;");
}

test "M3 strict-mode: NO regression in sloppy mode (US9)" {
    // None of the strict Early Errors apply in sloppy mode.
    try expectNumber("var eval = 1; eval", 1);
    try expectNumber("var arguments = 2; arguments", 2);
    try expectNumber("function f(eval) { return eval; } f(7)", 7);
    try expectNumber("var public = 3; public", 3);
    try expectNumber("var yield = 4; yield", 4);
    try expectBool("var y = 1; delete y", true); // sloppy delete of a binding → true (M-subset)
    try expectNumber("var eval = 4; eval = 5; eval", 5); // sloppy assignment to eval is fine
    // A function with its own duplicate params is legal in sloppy mode (no directive).
    try expectNumber("function f(a, a) { return a; } f(1, 9)", 9); // last wins
    // `"use strict"` as a non-directive (an operand) does NOT make the script strict.
    try expectNumber("(\"use strict\"); var eval = 6; eval", 6);
    try expectNumber("\"use strict\" + \"\"; var arguments = 7; arguments", 7);
}

test "M3 strict-mode: member delete & qualified targets stay legal in strict (US9)" {
    // §13.5.1.1 only forbids delete of an *unqualified* reference; property deletes are fine.
    try expectNoSyntaxErrorStrict("var o = {x: 1}; delete o.x;");
    try expectNoSyntaxErrorStrict("var o = {x: 1}; delete o['x'];");
    // Assignment / update of non-eval/arguments identifiers and members is fine in strict.
    try expectNoSyntaxErrorStrict("var x = 1; x = 2; x++; var o = {}; o.p = 3; o.p++;");
    // eval/arguments are usable as property names / member accesses in strict (not bindings).
    try expectNoSyntaxErrorStrict("var o = {eval: 1, arguments: 2}; o.eval + o.arguments;");
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

test "M5 for-in: object property-name enumeration (Cycle 1, §14.7.5)" {
    // Single own key → exact name (the M-subset enumerates own string keys; order is the property
    // map's iteration order, so multi-key string assertions below use order-independent checks).
    try expectStr("var s=''; for (var k in {a:1}) s+=k; s", "a");
    // Both keys visited (order-independent: concat sorted-insensitive via a membership count).
    try expectNumber("var n=0; for (var k in {a:1,b:2}) n++; n", 2);
    try expectStr("var got=''; for (var k in {a:1,b:2}) { if (k==='a'||k==='b') got+='x'; } got", "xx");
    // for-in over an array yields the index strings (NOT "length", NOT Array.prototype methods).
    try expectStr("var s=''; for (var k in ['x','y','z']) s+=k; s", "012");
    try expectNumber("var n=0; for (var k in [10,20]) { if (k==='length') n+=100; n++; } n", 2);
    // Inherited *user* prototype keys are enumerable; built-in prototype methods are not.
    try expectNumber("function P(){} P.prototype.z=1; var o=new P(); o.a=2; var n=0; for (var k in o) n++; n", 2);
    try expectNumber("var n=0; for (var k in {}) n++; n", 0); // empty object → 0 iterations
    try expectNumber("var n=0; for (var k in []) n++; n", 0); // empty array → 0, no proto methods
    // A null/undefined operand runs the body zero times (no throw, §14.7.5.6 step 7.a).
    try expectNumber("var n=0; for (var k in null) n++; n", 0);
    try expectNumber("var n=0; for (var k in undefined) n++; n", 0);
    // Shadowing: a name owned lower on the chain is visited once (not again from the prototype).
    try expectNumber("function P(){} P.prototype.a=1; var o=new P(); o.a=2; var n=0; for (var k in o) n++; n", 1);
}

test "M5 for-of: value iteration over arrays & strings (Cycle 1, §14.7.5)" {
    try expectNumber("var t=0; for (var v of [1,2,3]) t+=v; t", 6);
    try expectStr("var s=''; for (var c of 'abc') s+=c; s", "abc");
    try expectNumber("var n=0; for (var v of []) n++; n", 0); // empty array → 0 iterations
    try expectNumber("var n=0; for (var v of '') n++; n", 0); // empty string → 0 iterations
    // A non-iterable operand is a TypeError (§14.7.5.6 → GetIterator throws).
    try expectThrows("for (var v of 5) {}");
    try expectThrows("for (var v of {}) {}");
    try expectThrows("for (var v of null) {}");
    try expectThrows("for (var v of undefined) {}");
    try expectThrows("for (var v of true) {}");
}

test "M5 for-in/of: break, continue, per-iteration binding (Cycle 1, §14.7.5.7)" {
    // break / continue in for-of.
    try expectNumber("var t=0; for (var v of [1,2,3,4]) { if (v===3) break; t+=v; } t", 3);
    try expectNumber("var t=0; for (var v of [1,2,3,4]) { if (v===2) continue; t+=v; } t", 8);
    // break / continue in for-in (over an array's index strings).
    try expectNumber("var n=0; for (var k in [1,2,3,4,5]) { if (k==='2') break; n++; } n", 2);
    try expectNumber("var n=0; for (var k in [1,2,3,4]) { if (k==='1') continue; n++; } n", 3);
    // §14.7.5.7 CreatePerIterationEnvironment: a `let` head gives each iteration its own binding,
    // so closures capture distinct values.
    try expectStr(
        \\var fns=[]; for (let v of ['a','b','c']) fns.push(function(){ return v; });
        \\fns[0]() + fns[1]() + fns[2]()
    , "abc");
}

test "M5 for-in/of: assignment-target heads + [~In] disambiguation (Cycle 1, §14.7.5)" {
    // An existing identifier / member / index assignment target as the loop head.
    try expectStr("var i; var s=''; for (i of [1,2,3]) s+=i; s", "123");
    try expectNumber("var o={}; for (o.k of [1,2,3]) {} o.k", 3);
    try expectNumber("var a=[0,0,0]; var j=0; for (a[j] of [7,8,9]) j++; a[0]+a[1]+a[2]", 24);
    try expectStr("var s=''; var x; for (x in {p:1,q:2}) { if (x==='p'||x==='q') s+='y'; } s", "yy");
    // §14.7.5 `[~In]`: `for (a in b)` is for-in, but a *parenthesized* `in` in a C-style header stays
    // a normal relational operator, and `in` inside a subscript is a normal operator too.
    try expectNumber("var b={x:1}; var n=0; for (('x' in b); n<2; n++) {} n", 2);
    try expectNumber("var a=[10,20]; var o={t:1}; a['t' in o ? 0 : 1]", 10);
    // A multi-declarator C-style `for` (the non-for-in path) is unaffected.
    try expectNumber("var s=0; for (var i=0, j=10; i<3; i++) s += i + j; s", 33);
    try expectNumber("var s=0; for (var i=0; i<3; i++) s+=i; s", 3);
}

test "M6 Object.defineProperty + getOwnPropertyDescriptor (Cycle 1, §20.1.2.4/.8)" {
    // A defined data property is readable; omitted attributes default to false (§10.1.6.3).
    try expectNumber("var o={}; Object.defineProperty(o,'x',{value:5,enumerable:false}); o.x", 5);
    try expectNumber("var o={}; Object.defineProperty(o,'x',{value:5}); Object.getOwnPropertyDescriptor(o,'x').value", 5);
    try expectBool("var o={}; Object.defineProperty(o,'x',{value:5}); Object.getOwnPropertyDescriptor(o,'x').enumerable", false);
    try expectBool("var o={}; Object.defineProperty(o,'x',{value:5}); Object.getOwnPropertyDescriptor(o,'x').writable", false);
    try expectBool("var o={}; Object.defineProperty(o,'x',{value:5}); Object.getOwnPropertyDescriptor(o,'x').configurable", false);
    // A non-enumerable own property is skipped by for-in; an enumerable one is visited.
    try expectStr("var o={}; Object.defineProperty(o,'x',{value:5,enumerable:false}); o.y=7; var s=''; for(var k in o)s+=k; s", "y");
    // ordinary assignment → all attributes true (round-trips through the descriptor).
    try expectBool("var o={}; o.a=1; Object.getOwnPropertyDescriptor(o,'a').enumerable", true);
    try expectBool("var o={}; o.a=1; Object.getOwnPropertyDescriptor(o,'a').writable", true);
    // getOwnPropertyDescriptor of an absent property → undefined.
    try expectUndefined("Object.getOwnPropertyDescriptor({},'nope')");
    // A getter installed via defineProperty is invoked on read; the descriptor exposes get/set.
    try expectNumber("var g={}; Object.defineProperty(g,'v',{get:function(){return 42;}}); g.v", 42);
    try expectBool("var g={}; Object.defineProperty(g,'v',{get:function(){return 1;}}); typeof Object.getOwnPropertyDescriptor(g,'v').get === 'function'", true);
    // defineProperties applies each own enumerable descriptor.
    try expectNumber("var o={}; Object.defineProperties(o,{a:{value:1},b:{value:2}}); o.a+o.b", 3);
    // Redefining a non-configurable property incompatibly → TypeError.
    try expectThrows("var o={}; Object.defineProperty(o,'x',{value:1}); Object.defineProperty(o,'x',{value:2});");
    // ...but an existing property's omitted attributes are preserved (not reset to false).
    try expectBool("var o={a:1}; Object.defineProperty(o,'a',{value:2}); Object.getOwnPropertyDescriptor(o,'a').enumerable", true);
}

test "M6 Object.getOwnPropertyNames (Cycle 1, §20.1.2.10)" {
    // Includes a non-enumerable own name.
    try expectNumber("var o={a:1}; Object.defineProperty(o,'h',{value:1,enumerable:false}); Object.getOwnPropertyNames(o).length", 2);
    try expectBool("var o={a:1}; Object.defineProperty(o,'h',{value:1,enumerable:false}); Object.getOwnPropertyNames(o).indexOf('h') >= 0", true);
    // Array: indices + "length".
    try expectStr("Object.getOwnPropertyNames(['p','q']).join(',')", "0,1,length");
}

test "M6 Object.prototype.hasOwnProperty / propertyIsEnumerable / isPrototypeOf (Cycle 1, §20.1.3)" {
    try expectBool("({a:1}).hasOwnProperty('a')", true);
    try expectBool("({}).hasOwnProperty('a')", false);
    // Inherited (a built-in proto method) is NOT an own property.
    try expectBool("({}).hasOwnProperty('toString')", false);
    // Array index/length are own.
    try expectBool("[10].hasOwnProperty(0)", true);
    try expectBool("[10].hasOwnProperty('length')", true);
    // propertyIsEnumerable honors [[Enumerable]].
    try expectBool("var o={a:1}; o.propertyIsEnumerable('a')", true);
    try expectBool("var o={}; Object.defineProperty(o,'x',{value:1,enumerable:false}); o.propertyIsEnumerable('x')", false);
    try expectBool("[1].propertyIsEnumerable('length')", false);
    // isPrototypeOf walks the chain.
    try expectBool("var p={}; var c=Object.create?({}):({}); p.isPrototypeOf({})", false);
    try expectBool("var a=[]; Array.prototype.isPrototypeOf(a)", true);
}

test "M6 enumerable-awareness: for-in & spread skip non-enumerable / proto methods (Cycle 1, §7.3.25/§14.7.5)" {
    // for-in over a plain object yields only its own enumerable keys (no Object.prototype methods).
    try expectStr("var s=''; for(var k in {a:1}) s+=k; s", "a");
    // for-in over an empty object / empty array yields nothing (built-in protos are non-enumerable).
    try expectStr("var s='Z'; for(var k in {}) s+=k; s", "Z");
    try expectStr("var s='Z'; for(var k in []) s+=k; s", "Z");
    // object spread copies only own enumerable string keys (order is map-iteration; assert membership).
    try expectNumber("var c=0; for(var k in {...{a:1,b:2}}) c++; c", 2);
    try expectBool("var spread={...{a:1,b:2}}; spread.hasOwnProperty('a') && spread.hasOwnProperty('b')", true);
    try expectStr("var o={}; Object.defineProperty(o,'h',{value:1,enumerable:false}); o.v=2; var s=''; for(var k in {...o}) s+=k; s", "v");
}

test "M6 Function.prototype.call (Cycle 2, §20.2.3.3)" {
    // `this` = thisArg, remaining args forwarded.
    try expectNumber("function f(a){return this.x+a} f.call({x:1}, 2)", 3);
    try expectNumber("function f(a,b){return this.x+a+b} f.call({x:1}, 2, 3)", 6);
    // No thisArg / no args.
    try expectNumber("function f(){return 42} f.call()", 42);
    // `.call` resolves on every function (inherited from %Function.prototype%).
    try expectBool("typeof Function.prototype.call === 'function'", true);
    // A built-in method works via .call ([].push.call(obj,...) style — array method on an array-like is
    // M-subset, but the resolution + invocation path is what we assert here).
    try expectNumber("function id(x){return x} id.call(null, 7)", 7);
    // Calling .call on a non-function throws.
    try expectThrows("Function.prototype.call.call(5)");
}

test "M6 Function.prototype.apply (Cycle 2, §20.2.3.1)" {
    try expectNumber("function f(a){return this.x+a} f.apply({x:10}, [5])", 15);
    try expectNumber("function f(a,b){return a+b} f.apply(null, [2,3])", 5);
    // null/undefined argArray → no args.
    try expectNumber("function f(){return 99} f.apply(null)", 99);
    try expectNumber("function f(){return 99} f.apply(null, null)", 99);
    try expectNumber("function f(){return 99} f.apply(null, undefined)", 99);
    // array-like (has length + indices) is accepted.
    try expectNumber("function f(a,b){return a+b} f.apply(null, {0:4, 1:6, length:2})", 10);
    // a non-object, non-nullish argArray → TypeError.
    try expectThrows("function f(){} f.apply(null, 5)");
}

test "M6 Function.prototype.bind (Cycle 2, §20.2.3.2)" {
    // Fixes `this`.
    try expectNumber("function f(a){return this.x+a} var g=f.bind({x:100}); g(1)", 101);
    // Partial application: bound args prepend, then call args.
    try expectNumber("function f(a){return this.x+a} f.bind({x:1},2)()", 3);
    try expectNumber("function f(a,b){return a+b} var g=f.bind(null, 10); g(5)", 15);
    try expectNumber("function f(a,b,c){return a+b+c} var g=f.bind(null,1,2); g(3)", 6);
    // The bound function is itself callable and is `typeof "function"`.
    try expectBool("typeof (function(){}).bind(null) === 'function'", true);
    // Re-binding a bound function chains the bound args (1 then 2,3 then call 4).
    try expectNumber("function f(a,b,c,d){return a+b+c+d} var g=f.bind(null,1).bind(null,2,3); g(4)", 10);
    // A method used as a callback via bind keeps its receiver.
    try expectNumber("var o={x:5, get:function(){return this.x}}; var cb=o.get.bind(o); cb()", 5);
}

test "M6 bind + new constructs the target, ignoring bound this (Cycle 2, §10.4.1.2)" {
    // `new` on a bound function constructs the target; bound-this is ignored, bound args prepend.
    try expectNumber("function C(a,b){this.s=a+b} var B=C.bind(null, 10); var o=new B(5); o.s", 15);
    try expectNumber("function C(a){this.v=a} var B=C.bind({ignored:1}, 7); (new B()).v", 7);
}

test "M6 propertyHelper-style call.bind idiom (Cycle 2, §20.2.3)" {
    // The exact propertyHelper.js line-31 pattern: Function.prototype.call.bind(hasOwnProperty)
    // yields a free function `hasOwn(obj, key)`.
    try expectBool("var hasOwn=Function.prototype.call.bind(Object.prototype.hasOwnProperty); hasOwn({a:1},'a')", true);
    try expectBool("var hasOwn=Function.prototype.call.bind(Object.prototype.hasOwnProperty); hasOwn({a:1},'b')", false);
}

test "M6 Object.keys/values/entries (Cycle 3, §20.1.2.19/.23/.6)" {
    // keys → own enumerable string keys (insertion order); values → the values; entries → [k,v] pairs.
    try expectStr("Object.keys({a:1,b:2}).join()", "a,b");
    try expectStr("Object.values({a:1,b:2}).join()", "1,2");
    try expectStr("Object.entries({a:1,b:2}).map(function(e){return e[0]+':'+e[1]}).join()", "a:1,b:2");
    // Non-enumerable own props are skipped.
    try expectStr("var o={a:1}; Object.defineProperty(o,'h',{value:9,enumerable:false}); Object.keys(o).join()", "a");
    try expectNumber("Object.keys({a:1,b:2,c:3}).length", 3);
    // Inherited enumerable keys are NOT included (own-only).
    try expectStr("var p={x:1}; var o=Object.create(p); o.y=2; Object.keys(o).join()", "y");
    // Array: own enumerable index keys.
    try expectStr("Object.keys(['a','b']).join()", "0,1");
}

test "M6 Object.create (Cycle 3, §20.1.2.2)" {
    // Inherited property via the prototype.
    try expectNumber("var o=Object.create({x:1}); o.x", 1);
    // null prototype → no inherited Object.prototype methods.
    try expectBool("var o=Object.create(null); o.hasOwnProperty===undefined", true);
    // getPrototypeOf round-trips the supplied proto.
    try expectBool("var p={}; var o=Object.create(p); Object.getPrototypeOf(o)===p", true);
    // Second arg defines own properties from a descriptor map.
    try expectNumber("var o=Object.create(null,{v:{value:7,enumerable:true}}); o.v", 7);
    try expectStr("var o=Object.create({},{a:{value:1,enumerable:true},b:{value:2,enumerable:true}}); Object.keys(o).join()", "a,b");
    // A non-object, non-null proto throws.
    try expectThrows("Object.create(5)");
}

test "M6 Object.assign (Cycle 3, §20.1.2.1)" {
    try expectStr("Object.keys(Object.assign({},{a:1},{b:2})).join()", "a,b");
    try expectNumber("Object.assign({a:1},{a:9,b:2}).a", 9); // later source overwrites
    try expectNumber("var t={}; Object.assign(t,{a:1}); t.a", 1);
    try expectBool("var t={}; Object.assign(t,{a:1})===t", true); // returns target
    try expectNumber("Object.assign({x:1},null,undefined,{y:2}).y", 2); // nullish sources skipped
    // Only own enumerable props are copied (inherited / non-enumerable skipped).
    try expectStr("var s=Object.create({inh:1}); s.own=2; Object.keys(Object.assign({},s)).join()", "own");
    try expectThrows("Object.assign(null,{})"); // nullish target throws
}

test "M6 Object.getPrototypeOf / setPrototypeOf (Cycle 3, §20.1.2.12/.22)" {
    try expectBool("var p={}; var o=Object.create(p); Object.getPrototypeOf(o)===p", true);
    try expectBool("Object.getPrototypeOf(Object.create(null))===null", true);
    try expectNumber("var o={}; Object.setPrototypeOf(o,{z:5}); o.z", 5);
    try expectBool("var o={}; Object.setPrototypeOf(o,null); Object.getPrototypeOf(o)===null", true);
    try expectBool("var o={}; Object.setPrototypeOf(o,{})===o", true); // returns O
    try expectThrows("Object.setPrototypeOf(null,{})");
    try expectThrows("Object.setPrototypeOf({},5)");
}

test "M6 Object.is (Cycle 3, §20.1.2.14 SameValue)" {
    try expectBool("Object.is(NaN,NaN)", true);
    try expectBool("Object.is(0,-0)", false);
    try expectBool("Object.is(-0,-0)", true);
    try expectBool("Object.is(1,1)", true);
    try expectBool("Object.is('a','a')", true);
    try expectBool("Object.is({},{})", false); // distinct objects
    try expectBool("var o={}; Object.is(o,o)", true);
    try expectBool("Object.is(null,undefined)", false);
}

test "M6 Object.freeze/isFrozen/seal/isSealed/preventExtensions/isExtensible (Cycle 3, §20.1.2)" {
    // freeze: isFrozen true; new props rejected; existing data prop write rejected.
    try expectBool("var o={a:1}; Object.freeze(o); Object.isFrozen(o)", true);
    try expectBool("var o={a:1}; Object.freeze(o)===o", true); // returns O
    try expectNumber("var o={a:1}; Object.freeze(o); o.a=99; o.a", 1); // write silently rejected
    try expectBool("var o={a:1}; Object.freeze(o); o.b=2; o.b===undefined", true); // new prop rejected
    try expectBool("var o={}; Object.isFrozen(o)", false); // an ordinary extensible object is not frozen
    // seal: isSealed true; not frozen (writes still allowed); new props rejected.
    try expectBool("var o={a:1}; Object.seal(o); Object.isSealed(o)", true);
    try expectBool("var o={a:1}; Object.seal(o); Object.isFrozen(o)", false); // writable → sealed but not frozen
    try expectNumber("var o={a:1}; Object.seal(o); o.a=5; o.a", 5); // write allowed
    try expectBool("var o={a:1}; Object.seal(o); o.b=2; o.b===undefined", true); // new prop rejected
    // preventExtensions / isExtensible.
    try expectBool("Object.isExtensible({})", true);
    try expectBool("var o={}; Object.preventExtensions(o); Object.isExtensible(o)", false);
    try expectBool("var o={}; Object.preventExtensions(o); o.x=1; o.x===undefined", true);
    try expectBool("var o={}; Object.preventExtensions(o); Object.isFrozen(o)", true); // no props + non-ext → frozen
    // freeze makes the props non-configurable (delete returns false / leaves the prop).
    try expectBool("var o={a:1}; Object.freeze(o); delete o.a", false);
    try expectNumber("var o={a:1}; Object.freeze(o); delete o.a; o.a", 1);
    // a frozen prop's descriptor is non-writable + non-configurable.
    try expectBool("var o={a:1}; Object.freeze(o); Object.getOwnPropertyDescriptor(o,'a').writable", false);
    try expectBool("var o={a:1}; Object.freeze(o); Object.getOwnPropertyDescriptor(o,'a').configurable", false);
}

test "M6 Object.getOwnPropertyDescriptors (Cycle 3, §20.1.2.9)" {
    try expectNumber("var o={a:1,b:2}; Object.getOwnPropertyDescriptors(o).a.value", 1);
    try expectBool("var o={a:1}; Object.getOwnPropertyDescriptors(o).a.enumerable", true);
    try expectNumber("var o={a:1}; Object.defineProperty(o,'h',{value:9,enumerable:false}); Object.keys(Object.getOwnPropertyDescriptors(o)).length", 2);
}

test "M14 function length: ExpectedArgumentCount (§20.2.4.1)" {
    try expectNumber("function f(a,b){} f.length", 2);
    try expectNumber("(function(){}).length", 0);
    try expectNumber("(()=>{}).length", 0);
    // §15.1.5: stops at the first default / pattern / rest.
    try expectNumber("function f(a,b=1,c){} f.length", 1);
    try expectNumber("function f(a,[b],c){} f.length", 1);
    try expectNumber("function f(a,...rest){} f.length", 1);
    // accessor lengths: getter 0, setter 1.
    try expectNumber("class C{get x(){}} Object.getOwnPropertyDescriptor(C.prototype,'x').get.length", 0);
    try expectNumber("class C{set x(v){}} Object.getOwnPropertyDescriptor(C.prototype,'x').set.length", 1);
    // constructor length = constructor param count.
    try expectNumber("class C{constructor(a,b){}} C.length", 2);
    // §20.2.4.1 length descriptor: writable:false, enumerable:false, configurable:true.
    try expectBool("function f(){} Object.getOwnPropertyDescriptor(f,'length').writable", false);
    try expectBool("function f(){} Object.getOwnPropertyDescriptor(f,'length').enumerable", false);
    try expectBool("function f(){} Object.getOwnPropertyDescriptor(f,'length').configurable", true);
}

test "M14 function name + NamedEvaluation (§20.2.4.2 / §8.4)" {
    try expectStr("function f(a,b){} f.name", "f");
    try expectStr("var g = function(){}; g.name", "g"); // NamedEvaluation (named-fn-expr is anon here)
    try expectStr("var h = () => {}; h.name", "h"); // arrow NamedEvaluation
    try expectStr("let k; k = function(){}; k.name", "k"); // identifier-assignment NamedEvaluation
    try expectStr("(function(){}).name", ""); // bare anonymous → ""
    try expectStr("(class C{}).name", "C");
    try expectStr("var C = class{}; C.name", "C"); // anon class NamedEvaluation
    try expectStr("function* gen(){} gen.name", "gen");
    try expectStr("async function af(){} af.name", "af");
    // object-literal property value + method.
    try expectStr("var o = {f: function(){}}; o.f.name", "f");
    try expectStr("var o = {m(){}}; o.m.name", "m");
    // class method / accessor names.
    try expectStr("class C{m(a){}} C.prototype.m.name", "m");
    try expectStr("class C{get x(){}} Object.getOwnPropertyDescriptor(C.prototype,'x').get.name", "get x");
    try expectStr("class C{set x(v){}} Object.getOwnPropertyDescriptor(C.prototype,'x').set.name", "set x");
    // §20.2.4.2 name descriptor: writable:false, enumerable:false, configurable:true.
    try expectBool("function f(){} Object.getOwnPropertyDescriptor(f,'name').writable", false);
    try expectBool("function f(){} Object.getOwnPropertyDescriptor(f,'name').configurable", true);
    // bound function name (§20.2.3.2).
    try expectStr("function f(){} f.bind(null).name", "bound f");
    try expectNumber("function f(a,b,c){} f.bind(null,1).length", 2);
}

test "M14 class member attributes: methods non-enumerable, fields enumerable (§15.7.x)" {
    // class methods are NON-enumerable...
    try expectBool("class C{m(){}} Object.getOwnPropertyDescriptor(C.prototype,'m').enumerable", false);
    try expectBool("class C{static m(){}} Object.getOwnPropertyDescriptor(C,'m').enumerable", false);
    try expectBool("class C{get x(){}} Object.getOwnPropertyDescriptor(C.prototype,'x').enumerable", false);
    // ...but OBJECT-literal methods stay ENUMERABLE (ordinary properties).
    try expectBool("Object.getOwnPropertyDescriptor({m(){}},'m').enumerable", true);
    try expectBool("Object.getOwnPropertyDescriptor({get x(){}},'x').enumerable", true);
    // class fields are enumerable data; the `constructor` slot is non-enumerable.
    try expectBool("class C{f=1} Object.getOwnPropertyDescriptor(new C(),'f').enumerable", true);
    try expectBool("class C{} Object.getOwnPropertyDescriptor(C.prototype,'constructor').enumerable", false);
}

test "M15 eval: core + direct + indirect (§19.2.1 / §19.2.1.1)" {
    // §19.2.1: the completion value of the parsed Script is eval's result.
    try expectNumber("eval(\"1+2\")", 3);
    try expectNumber("eval(\"var x=10; x*2\")", 20);
    try expectNumber("eval(\"1;2;3\")", 3);
    try expectNumber("eval(\"if(true) 7\")", 7);
    try expectUndefined("eval(\"var x=5\")"); // a `var` declaration completes with undefined
    try expectNumber("eval(\"({x:1}).x\")", 1); // object-literal parse (a leading `{` is an expr here)
    // §19.2.1 step 2: a non-string argument is returned unchanged.
    try expectNumber("eval(42)", 42);
    // §19.2.1.1 DIRECT eval reads + writes the caller's locals.
    try expectNumber("function f(){ var a=5; return eval(\"a+1\") } f()", 6);
    try expectNumber("function f(){ var a=1; eval(\"a=9\"); return a } f()", 9);
    // §19.2.1.1 INDIRECT eval runs in the global env — it cannot see a caller's local `a`.
    try expectStr("var e=eval; function f(){ var a=1; try{ e(\"a\"); return \"no\" }catch(x){ return \"ref\" } } f()", "ref");
    // §19.2.1 step 7: a parse error throws a real, catchable SyntaxError.
    try expectStr("try{ eval(\"var\") }catch(e){ e.name }", "SyntaxError");
    // globalThis.eval is the same intrinsic (indirect when called off globalThis).
    try expectNumber("globalThis.eval(\"2+3\")", 5);
}

test "M16 prototype.constructor back-reference (§19/§20/§22/§23)" {
    // Built-in constructors: <Ctor>.prototype.constructor === <Ctor>, resolved through the chain.
    try expectBool("[].constructor === Array", true);
    try expectBool("({}).constructor === Object", true);
    try expectBool("(function(){}).constructor === Function", true);
    try expectBool("\"x\".constructor === String", true);
    try expectBool("Array.prototype.constructor === Array", true);
    try expectBool("Object.prototype.constructor === Object", true);
    try expectBool("Error.prototype.constructor === Error", true);
    try expectBool("TypeError.prototype.constructor === TypeError", true);
    // User functions: §10.2.4 MakeConstructor — F.prototype.constructor === F; instances inherit it.
    try expectBool("function F(){}; F.prototype.constructor === F", true);
    try expectBool("function F(){}; new F().constructor === F", true);
    // Classes: §15.7.14 — C.prototype.constructor === C; instances inherit; derived too.
    try expectBool("class C{}; new C().constructor === C", true);
    try expectBool("class C{}; C.prototype.constructor === C", true);
    try expectBool("class B{}; class D extends B{}; new D().constructor === D", true);
    // A thrown engine error resolves `.constructor` through its prototype (the assert.throws unblock).
    try expectBool("(()=>{try{null.x}catch(e){return e.constructor===TypeError}})()", true);
    try expectBool("(()=>{try{undefinedVar}catch(e){return e.constructor===ReferenceError}})()", true);
    // The back-reference MUST be non-enumerable (else for-in / Object.keys would surface it).
    try expectBool("Object.getOwnPropertyDescriptor(Array.prototype,\"constructor\").enumerable === false", true);
    try expectBool("Object.getOwnPropertyDescriptor(Array.prototype,\"constructor\").writable === true", true);
    try expectBool("Object.getOwnPropertyDescriptor(Array.prototype,\"constructor\").configurable === true", true);
    try expectBool("Object.getOwnPropertyDescriptor((function F(){}).prototype,\"constructor\").enumerable === false", true);
    // A Test262-style assert.throws mini-harness: it checks `thrown.constructor === expected`.
    try expectBool(
        \\function throwsRightCtor(Ctor, fn){
        \\  try { fn(); } catch(e){ return e.constructor === Ctor; }
        \\  return false;
        \\}
        \\throwsRightCtor(TypeError, function(){ null.x })
    , true);
}

test "M23 IdentifierName unicode escapes — basic decode + binding (§12.7.1)" {
    // `\uHHHH` / `\u{H…}` at identifier start and parts; decoded StringValue is the name.
    try expectNumber("var \\u{62}=9; b", 9);
    try expectNumber("var \\u0062 = 7; b", 7);
    try expectNumber("var b = 7; \\u{62}", 7); // an escaped USE resolves to the same binding
    try expectNumber("var a\\u{62}c = 4; abc", 4); // escape in a PART
    try expectNumber("var $\\u{30} = 8; $0", 8); // §12.7 ID_Continue digit via escape (`$0`)
    // Member access with an escaped IdentifierName (`a.if` — reserved words OK as property names).
    try expectNumber("var o = { a: 5 }; o.\\u{61}", 5);
    try expectNumber("var o = { if: 3 }; o.\\u{69}f", 3);
}

test "M23 IdentifierName escapes in class fields + private names (§12.7.1 / §15.7)" {
    try expectNumber("class C { \\u{6F} = 5; m(){ return this.o; } } new C().m()", 5);
    try expectNumber("class C { #\\u{78} = 6; g(){ return this.#x; } } new C().g()", 6);
}

test "M23 escaped ReservedWord → SyntaxError (§12.7.1 / §12.7.2)" {
    // §12.7.2 ReservedWord spelled with an escape is a SyntaxError (keyword-table + dedicated set).
    try expectSyntaxError("var \\u{69}f = 1;"); // if
    try expectSyntaxError("var \\u{76}ar = 1;"); // var
    try expectSyntaxError("\\u0066or (;;) {}"); // for
    try expectSyntaxError("var \\u0065xport = 1;"); // export (absent from the keyword table)
    try expectSyntaxError("var \\u{65}num = 1;"); // enum
    try expectSyntaxError("\\u0077ith (o) {}"); // with
    try expectSyntaxError("d\\u0065bugger;"); // debugger
}

test "M23 escaped yield/await are identifiers in sloppy (§12.7.1 exception)" {
    // §12.7.1: `yield`/`await` are NOT ReservedWords for this rule — an escaped spelling is OK as an
    // identifier in sloppy mode.
    try expectNumber("var \\u{79}ield = 5; yield", 5);
    try expectNumber("var \\u{61}wait = 4; await", 4);
}

test "M23 ID_Start / ID_Continue validation of escaped code points (§12.7)" {
    // Invalid IdentifierStart / IdentifierPart code points reached via escape → SyntaxError.
    try expectSyntaxError("var \\u2E2F;"); // VERTICAL TILDE (U+2E2F): Lm but Pattern_Syntax — not ID_Start
    try expectSyntaxError("var a\\u2E2F;"); // …nor ID_Continue
    try expectSyntaxError("var \\u200C;"); // ZWNJ (U+200C): not ID_Start
    try expectSyntaxError("var \\u200D;"); // ZWJ (U+200D): not ID_Start
    // Accepted: grandfathered Other_ID_Start, Kelvin, ZWNJ/ZWJ as PARTS, astral letter.
    try expectNumber("var \\u2118 = 3; \\u2118", 3); // SCRIPT CAPITAL P
    try expectNumber("var \\u212A = 1; \\u212A", 1); // KELVIN SIGN
    try expectNumber("var a\\u200C = 2; a\\u200C", 2); // ZWNJ valid as ID_Continue
    try expectNoSyntaxErrorStrict("var \\u{10840};"); // astral IMPERIAL ARAMAIC ALEPH
}

test "M25 raw non-ASCII Unicode identifiers — binding + use (§12.7)" {
    // Raw `é` (U+00E9) as an IdentifierPart.
    try expectNumber("var café = 1; café", 1);
    // Raw é and `\u{e9}` escape decode to the same StringValue → same binding.
    try expectNumber("var café = 5; caf\\u{e9}", 5);
    try expectNumber("var caf\\u{e9} = 7; café", 7);
    // A raw-Unicode identifier whose ASCII look-alike is not declared is `undefined` (distinct name).
    try expectBool("var café = 1; typeof cafe === 'undefined'", true);
    // Raw ID_Start letters: Greek Ω (U+03A9), SCRIPT CAPITAL P ℘ (U+2118, Other_ID_Start).
    try expectNumber("var Ω = 3; Ω", 3);
    try expectNumber("var ℘ = 4; ℘", 4);
    // ZWNJ (U+200C) / ZWJ (U+200D) are valid raw ID_Continue (must NOT be eaten as whitespace).
    try expectNumber("var a\u{200c}b = 8; a\u{200c}b", 8);
}

test "M25 raw Unicode private names + property names (§15.7 / §12.7)" {
    // Raw ℘ (U+2118) as a private name.
    try expectNumber("class C{ #℘ = 5; get(){ return this.#℘; } } new C().get()", 5);
    // Raw é private name round-trips with the `\u` spelling of the same code point.
    try expectNumber("class C{ #café = 9; g(){ return this.#caf\\u{e9}; } } new C().g()", 9);
    // Raw member access `o.℘` resolves the same property as the computed `o[\"℘\"]`.
    try expectNumber("var o = {}; o[\"℘\"] = 6; o.℘", 6);
    try expectNumber("var o = {}; o.℘ = 7; o[\"℘\"]", 7);
}

test "M25 Unicode WhiteSpace + LineTerminators in skipTrivia (§12.2 / §12.3)" {
    // Raw NBSP (U+00A0) between tokens is WhiteSpace — skipped like a space (`var<NBSP>x=1; x`).
    try expectNumber("var\u{00a0}x = 1; x", 1);
    // U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR are LineTerminators: each separates two
    // statements via ASI (no explicit `;`), so all three bindings are in scope for `a + b + c`.
    try expectNumber("var a = 1\u{2028}var b = 2\u{2029}var c = 3\na + b + c", 6);
    // IDEOGRAPHIC SPACE (U+3000) and BOM/ZWNBSP (U+FEFF) are also WhiteSpace.
    try expectNumber("var\u{3000}y\u{feff}= 2; y", 2);
}

test "M23 escaped contextual keywords are not the keyword (§12.7.1)" {
    // A contextual keyword spelled with an escape is the plain identifier — these grammar positions
    // then become SyntaxErrors (the keyword form is required verbatim).
    try expectSyntaxError("for (var x o\\u0066 []) ;"); // escaped `of`
    try expectSyntaxError("({ \\u0067\\u0065\\u0074 m() {} });"); // escaped `get`
    try expectSyntaxError("\\u0061sync function f(){}"); // escaped `async` function decl
    try expectSyntaxError("void \\u0061sync function f(){}"); // escaped `async` function expr
    // §13.15.1: escaped strict-reserved word as an IdentifierReference dstr target (strict) → error.
    try expectSyntaxErrorStrict("var x = { l\\u0065t } = { let: 42 };");
    // §12.9.3: a NumericLiteral may not be immediately followed by an IdentifierStart (incl. `\\u`).
    try expectSyntaxError("0\\u00620;");
}

test "M26 arguments is iterable (§10.4.4 / §22.1.5)" {
    // §10.4.4.7: the `arguments` object has @@iterator = %Array.prototype.values%, so it spreads
    // and for-of's over its indexed elements.
    try expectNumber("function f(){ return [...arguments].length } f(1,2,3)", 3);
    try expectNumber("function f(){ var s=0; for (var x of arguments) s+=x; return s } f(1,2,3)", 6);
    // Spread preserves order/values.
    try expectNumber("function f(){ return [...arguments][1] } f(10,20,30)", 20);
    // Zero args → empty iteration.
    try expectNumber("function f(){ return [...arguments].length } f()", 0);
    // Still an ordinary object, NOT an Array exotic.
    try expectBool("function f(){ return Array.isArray(arguments) } f(1)", false);
    // arguments[Symbol.iterator] is the array values native (callable, non-enumerable).
    try expectBool("function f(){ return typeof arguments[Symbol.iterator] === 'function' } f()", true);
    // A generator function's `arguments` is iterable too.
    try expectNumber("function* g(){ yield [...arguments].length } g(1,2).next().value", 2);
}

test "M26 object-literal __proto__ sets [[Prototype]] (§B.3.1)" {
    // `{__proto__: p}` (literal colon name) sets the prototype, no own `__proto__` property.
    try expectNumber("var p={x:1}; var o={__proto__:p}; o.x", 1);
    try expectBool("var p={x:1}; var o={__proto__:p}; o.hasOwnProperty('__proto__')", false);
    try expectBool("var p={x:1}; var o={__proto__:p}; Object.getPrototypeOf(o)===p", true);
    // `{__proto__: null}` → a null-prototype object.
    try expectBool("Object.getPrototypeOf({__proto__:null})===null", true);
    // A primitive value is IGNORED: prototype unchanged, no own `__proto__` property.
    try expectBool("var o={__proto__:5}; Object.getPrototypeOf(o)===Object.prototype && !o.hasOwnProperty('__proto__')", true);
    // A string literal name `"__proto__":` is also the proto setter (§B.3.1).
    try expectBool("var p={x:1}; var o={\"__proto__\":p}; Object.getPrototypeOf(o)===p", true);
    // A COMPUTED `{['__proto__']: v}` is an ORDINARY own property (proto NOT set).
    try expectNumber("({['__proto__']:7}).__proto__", 7);
    try expectBool("var o={['__proto__']:7}; o.hasOwnProperty('__proto__')", true);
    // §B.3.1 Early Error: two `__proto__:` colon-properties is a SyntaxError.
    try expectSyntaxError("({__proto__:1, __proto__:2})");
    try expectSyntaxError("({__proto__:1, \"__proto__\":2})");
    // But mixing a proto setter with a computed `__proto__` is NOT a duplicate (different definitions).
    try expectNoSyntaxErrorStrict("var o = ({__proto__:{}, ['__proto__']:2});");
}

test "M27 NamedEvaluation on destructuring/param defaults (§8.6.2 / §13.15.5.2 / §15.1.3)" {
    // §15.1.3: a SingleNameBinding parameter default that is an anonymous fn/arrow/class
    // takes the parameter name.
    try expectStr("function f(cb = function(){}){ return cb.name } f()", "cb");
    try expectStr("function f(ar = () => {}){ return ar.name } f()", "ar");
    try expectStr("function f(c = class{}){ return c.name } f()", "c");
    // §13.3.3.7 object binding-pattern property default → property-target identifier name.
    try expectStr("function f({fn = function(){}}){ return fn.name } f({})", "fn");
    try expectStr("function f({af = () => {}}){ return af.name } f({})", "af");
    try expectStr("function f({gn = function*(){}}){ return gn.name } f({})", "gn");
    // `key: target = default` form names after the target binding, not the key.
    try expectStr("function f({k: t = function(){}}){ return t.name } f({})", "t");
    // §8.6.2 array binding-pattern element default → element-target identifier name.
    try expectStr("function f([x = function(){}]){ return x.name } f([])", "x");
    try expectStr("function f([y = () => {}]){ return y.name } f([])", "y");
    // var/let binding declarations with destructuring defaults.
    try expectStr("var {vn = function(){}} = {}; vn.name", "vn");
    try expectStr("var [vy = function(){}] = []; vy.name", "vy");
    // §13.15.5.2 assignment patterns (not declarations) name the same way.
    try expectStr("var bn; ({bn = function(){}} = {}); bn.name", "bn");
    try expectStr("var by; [by = function(){}] = []; by.name", "by");
    // A NAMED function default keeps its own name (NOT renamed to the binding id).
    try expectStr("function f({z = function named(){}}){ return z.name } f({})", "named");
    // When the value IS provided (default not used), the bound value is NOT renamed.
    // (An anonymous fn passed as an array element has name "" and stays "".)
    try expectStr("function f({w = function(){}}){ return w.name } var a=[function(){}]; f({w:a[0]})", "");
}

test "M28 for-of/for-in head is a DestructuringAssignment pattern (§14.7.5.6 / §13.15.5)" {
    // §14.7.5.6 ForIn/OfBodyEvaluation, lhsKind = assignment: an ArrayLiteral / ObjectLiteral head is
    // refined to an AssignmentPattern (no `var`/`let`/`const`) and assigned each iteration.
    try expectNumber("var a, b; for ([a, b] of [[1, 2]]) {} a * 10 + b", 12);
    try expectNumber("var a; for ({a} of [{a: 5}]) {} a", 5);
    try expectNumber("var a, b; for ({x: a, y: b} of [{x: 3, y: 4}]) {} a * 10 + b", 34);
    // element default applies when the matched value is undefined.
    try expectNumber("var a; for ([a = 9] of [[]]) {} a", 9);
    // member / index targets (PutValue into an existing reference).
    try expectNumber("var o = {}; var arr = [0]; for ([o.p, arr[0]] of [[3, 4]]) {} o.p * 10 + arr[0]", 34);
    // nested pattern + rest in the head.
    try expectNumber("var a, r; for ([a, ...r] of [[1, 2, 3]]) {} a + r.length", 3);
    // for-in over an object's keys with a pattern head.
    try expectStr("var k; var out = ''; for ([k] of [['x'], ['y']]) { out += k; } out", "xy");
    // §13.15.1: a PARENTHESIZED literal head is NOT the cover grammar → SyntaxError.
    try expectSyntaxError("var a; for (({a}) of [{a: 1}]) {}");
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
    try expectNumber(close_on_throw, 1);
}

test "M28 object binding-pattern computed & numeric/string property names (§14.3.3)" {
    // numeric PropertyName → ToString'd key.
    try expectNumber("var { 0: v } = [7]; v", 7);
    try expectNumber("var { 1: v } = [7, 8]; v", 8);
    // computed PropertyName `{ [expr]: target }` — evaluated (ToPropertyKey) at bind time.
    try expectNumber("var k = 'a'; var { [k]: v } = { a: 9 }; v", 9);
    try expectStr("var s = Symbol('s'); var o = {}; o[s] = 'hi'; var { [s]: v } = o; v", "hi");
    // a keyword IdentifierName is a valid (colon) PropertyName: `{ if: x }`.
    try expectNumber("var { if: v } = { if: 5 }; v", 5);
    // §14.3.3 with a rest: an explicit computed key is excluded from the rest copy.
    try expectNumber("var k = 'a'; var { [k]: v, ...r } = { a: 1, b: 2, c: 3 }; v * 100 + r.b + r.c", 105);
    // computed key in a for-of head binding, and a rest-with-nested-object-pattern element.
    try expectNumber("var sum = 0; for (var { [String(0)]: x } of [{ 0: 4 }, { 0: 6 }]) { sum += x; } sum", 10);
    try expectNumber("var [...{ 0: a, length: n }] = [7, 8, 9]; a * 10 + n", 73);
    // §13.2.5 ComputedPropertyName evaluation order: a throwing key expression propagates.
    try expectThrows("var { [(function(){ throw new Error('k'); })()]: x } = {};");
    // a string/numeric/computed PropertyName has NO shorthand form (must carry a `:`).
    try expectSyntaxError("var { 0 } = [1];");
    try expectSyntaxError("var { [k] } = {};");
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
    try expectNumber(close_on_break, 1);
    // §7.4.4 IteratorStep: a next() result that is not an Object is a TypeError.
    const bad_result =
        \\var iter = { [Symbol.iterator]() { return { next() { return 42; } }; } };
        \\var ok = false;
        \\try { for (var v of iter) {} } catch (e) { ok = e instanceof TypeError; }
        \\ok
    ;
    try expectBool(bad_result, true);
    // §7.4.2: for-of over a String iterates its elements, binding each to the loop variable.
    try expectStr("var out = ''; for (var c of 'abc') out = c + out; out", "cba");
}

test "M29 ToPrimitive — valueOf/toString invoked in operator coercion (§7.1.1 / §7.1.1.1)" {
    // §13.15.3 `+` numeric: a `valueOf`-bearing object coerces to its number.
    try expectNumber("({valueOf: function(){ return 5; }}) + 1", 6);
    // §13.15.3 `+` string: a `toString`-bearing object concatenates as its string.
    try expectStr("({toString: function(){ return \"x\"; }}) + \"y\"", "xy");
    // §7.1.1.1: number hint tries valueOf first (so this is 2, not "01").
    try expectNumber("({valueOf: function(){return 1;}, toString: function(){return 0;}}) + 1", 2);
    // §23.1.3.36: an Array's ToPrimitive(string via toString) joins its elements.
    try expectStr("[1,2] + \"\"", "1,2");
    // §7.2.15: abstract equality coerces the object operand (toString → "x").
    try expectBool("({toString: function(){ return \"x\"; }}) == \"x\"", true);
    // §7.2.13: relational comparison ToPrimitive(number)s the object.
    try expectBool("({valueOf: function(){ return 3; }}) < 5", true);
    // §13.5.5 unary minus + §13.4 update run ToNumber (valueOf).
    try expectNumber("-({valueOf: function(){ return 4; }})", -4);
    // §7.1.1 step 2: @@toPrimitive takes precedence and receives the hint string.
    try expectNumber("({[Symbol.toPrimitive]: function(h){ return h === \"number\" ? 42 : 0; }}) - 0", 42);
    // §7.1.1.1: neither valueOf nor toString yielding a primitive → TypeError.
    try expectThrows("({valueOf: function(){return {};}, toString: function(){return {};}}) + 1");
}

test "M30 generator param FunctionDeclarationInstantiation is eager — call-time, not .next (§15.5.2 / §15.6.2)" {
    // A throwing destructuring default in a SYNC generator method throws at the CALL site (param
    // binding runs eagerly in [[Call]], before the generator object is returned / first `.next`).
    try expectThrows(
        \\function* g([x = (function(){ throw new Error("boom"); })()]) {}
        \\g([undefined]);
    );
    // A throwing default in an ASYNC GENERATOR throws synchronously at the call site too (V8 parity).
    try expectThrows(
        \\async function* ag([x = (function(){ throw new Error("boom"); })()]) {}
        \\ag([undefined]);
    );
    // Binding really happens BEFORE the body runs: a side effect in a default param fires at call
    // time, even though the generator is never resumed (`.next` never called).
    try expectBool(
        \\var ran = false;
        \\function* g(x = (function(){ ran = true; return 1; })()) { yield x; }
        \\g(); // create only — do NOT call .next
        \\ran;
    , true);
    // Destructuring a non-iterable as a generator param is a call-time TypeError (eager binding).
    try expectThrows(
        \\function* g([x]) {}
        \\g(null);
    );
    // The bound params are still correct once the body runs (no regression): destructuring + default.
    try expectNumber(
        \\function* g([a, b = 10]) { yield a + b; }
        \\g([5]).next().value;
    , 15);
    // A plain (non-generator) function with the same throwing default still throws at the call — the
    // refactor must not change ordinary [[Call]] semantics.
    try expectThrows(
        \\function f([x = (function(){ throw new Error("boom"); })()]) {}
        \\f([undefined]);
    );
}

test "M29 primitive wrapper objects unbox in coercion (§21.1.4.1 / §22.1.4.1 / §20.3.4.1)" {
    // §21.1.3.3 thisNumberValue: a Number wrapper coerces back to its primitive.
    try expectNumber("new Number(5) + 0", 5);
    try expectNumber("Number(new Number(7))", 7);
    // §22.1.3.32: a String wrapper coerces / unboxes via valueOf.
    try expectStr("new String(\"ab\") + \"\"", "ab");
    try expectStr("new String(\"hi\").valueOf()", "hi");
    // §20.3.3.3: a Boolean wrapper unboxes (true → 1 in numeric `+`).
    try expectNumber("new Boolean(true) + 0", 1);
    try expectBool("new Boolean(false).valueOf()", false);
    // §7.2.15: `new Number(5) == "5"` (number↔string after unboxing).
    try expectBool("new Number(5) == \"5\"", true);
}

test "M31: §10.2.5 MethodDefinition functions have no own `.prototype`" {
    // §15.4 / §10.2.5 MakeMethod: a class/object method, getter, setter, or async (non-generator)
    // method is NOT a constructor — it has no own `prototype` property.
    try expectBool("class C { m(){} } ('prototype' in C.prototype.m)", false);
    try expectBool("class C { static sm(){} } ('prototype' in C.sm)", false);
    try expectBool("class C { async m(){} } ('prototype' in C.prototype.m)", false);
    try expectBool("class C { get g(){return 1} } ('prototype' in Object.getOwnPropertyDescriptor(C.prototype,'g').get)", false);
    try expectBool("var o={m(){}}; ('prototype' in o.m)", false);
    try expectBool("var o={get g(){return 1}}; ('prototype' in Object.getOwnPropertyDescriptor(o,'g').get)", false);
    // §15.8: an async function (declaration / expression, non-generator) likewise has no `.prototype`.
    try expectBool("async function af(){}; ('prototype' in af)", false);
    try expectBool("var ae=async function(){}; ('prototype' in ae)", false);
    // §15.3: an arrow is not a constructor either.
    try expectBool("var a=()=>{}; ('prototype' in a)", false);
    // A generator / async-generator method IS a GeneratorFunction → it DOES keep `.prototype`.
    try expectBool("class C { *m(){} } ('prototype' in C.prototype.m)", true);
    try expectBool("class C { async *m(){} } ('prototype' in C.prototype.m)", true);
    // A plain function / generator / class constructor keeps `.prototype`.
    try expectBool("function f(){}; ('prototype' in f) && f.prototype.constructor===f", true);
    try expectBool("function* g(){}; ('prototype' in g)", true);
    try expectBool("class C{}; ('prototype' in C)", true);
    // `new` still works on plain functions and classes.
    try expectBool("function f(){} new f() instanceof f", true);
    try expectBool("class C{} new C() instanceof C", true);
}

test "M31: §15.7.14 base class `C.prototype.[[Prototype]]` is %Object.prototype%" {
    // §15.7.14 step 6.a: a base class (no `extends`) has protoParent = %Object.prototype%.
    try expectBool("class C{}; Object.getPrototypeOf(C.prototype)===Object.prototype", true);
    try expectStr("class C{}; typeof C.prototype.hasOwnProperty", "function");
    // A derived class chains to the superclass's `.prototype`.
    try expectBool("class C{}; class D extends C{}; Object.getPrototypeOf(D.prototype)===C.prototype", true);
}

test "M32: §14.3.1 `using` disposes at block exit (LIFO, normal + abrupt)" {
    // Dispose runs at block exit, after the body — completion is "body,d".
    try expectStr(
        "var log=[]; { using x = { [Symbol.dispose](){ log.push('d'); } }; log.push('body'); } log.join(',')",
        "body,d",
    );
    // Two `using` in one block dispose in REVERSE (LIFO) order: b then a.
    try expectStr(
        "var log=[]; { using a = { [Symbol.dispose](){ log.push('a'); } }, b = { [Symbol.dispose](){ log.push('b'); } }; } log.join(',')",
        "b,a",
    );
    // Dispose runs on an early `throw` out of the block (try/catch around the using block).
    try expectBool(
        "var d=false; try { { using x = { [Symbol.dispose](){ d=true; } }; throw 1; } } catch(e){} d",
        true,
    );
    // `using y = null` is a no-op (no dispose, no throw) and the block runs normally.
    try expectStr("var log=[]; { using y = null; log.push('ok'); } log.join(',')", "ok");
    // The `this` inside the disposer is the resource value.
    try expectBool(
        "var ok=false; var r={ [Symbol.dispose](){ ok = (this===r); } }; { using x = r; } ok",
        true,
    );
}

test "M32: §14.3.1 `using` is a const-like immutable binding; values readable in-block" {
    // The binding holds the initialized value within the block.
    try expectNumber("var v; { using x = { val: 7, [Symbol.dispose](){} }; v = x.val; } v", 7);
    // `Symbol.dispose` / `Symbol.asyncDispose` are well-known symbols (same identity as a property read).
    try expectBool("typeof Symbol.dispose === 'symbol' && typeof Symbol.asyncDispose === 'symbol'", true);
}

test "M32: §ER non-callable / missing `[Symbol.dispose]` is a TypeError" {
    // A non-callable @@dispose property → TypeError.
    try expectStr(
        "var n; try { { using x = { [Symbol.dispose]: 1 }; } } catch(e){ n = e.name; } n",
        "TypeError",
    );
    // An object with NO @@dispose method → TypeError.
    try expectStr(
        "var n; try { { using x = {}; } } catch(e){ n = e.name; } n",
        "TypeError",
    );
}

test "M32: §20.5.8 SuppressedError aggregation (last disposer error wraps the prior completion)" {
    // A body throw + a disposer throw aggregate into SuppressedError { error: disposerErr, suppressed: bodyErr }.
    try expectStr(
        "var n; try { { using a = { [Symbol.dispose](){ throw 'da'; } }; throw 'body'; } } catch(e){ n = (e instanceof SuppressedError) ? e.error+','+e.suppressed : 'plain'; } n",
        "da,body",
    );
    // A single disposer error (no pending completion) rethrows as-is (no SuppressedError wrapper).
    try expectBool(
        "var plain=false; try { { using a = { [Symbol.dispose](){ throw new TypeError('x'); } }; } } catch(e){ plain = (e instanceof TypeError); } plain",
        true,
    );
}

test "M32: §14.3.1 `using` is a CONTEXTUAL keyword (identifier elsewhere)" {
    // `var using = 5; using` → 5 — `using` is an ordinary identifier when not heading a declaration.
    try expectNumber("var using = 5; using", 5);
    // `using` not followed by a same-line BindingIdentifier is an ordinary identifier reference.
    try expectNumber("var using = 3; using + 1", 4);
    // `using` followed by a LineTerminator then an identifier is two statements (ASI), not a decl:
    // `using` is read as the identifier (7), then `r = using` assigns it.
    try expectNumber("var using = 7, r; using\nr = using; r", 7);
    // A `using`-headed declaration at the top level of a Script is a SyntaxError (must be in a Block/etc.).
    try expectSyntaxError("using x = null;");
    // `using x = …` is allowed inside a block.
    try expectStr("var log=[]; { using x = { [Symbol.dispose](){ log.push('d'); } }; } log.join(',')", "d");
}
