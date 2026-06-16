//! Test262 conformance runner: discover test files, parse metadata, execute each in the
//! applicable mode(s) through the ljs engine in a fresh realm, and classify the outcome per
//! INTERPRETING.md. Failures are isolated — one bad test never aborts the run (FR-006); the
//! engine surfaces parse/runtime/step-limit outcomes as result variants, never as host crashes.
const std = @import("std");
const ljs = @import("ljs");
const md = @import("metadata.zig");
const rep = @import("report.zig");

const Allocator = std.mem.Allocator;
const Mode = rep.Mode;
const Outcome = rep.Outcome;
const Reason = rep.Reason;
const TestResult = rep.TestResult;

pub const Options = struct {
    path: []const u8,
    mode_filter: ?Mode = null, // null → run both modes where applicable
    harness_dir: ?[]const u8 = null,
    step_limit: u64 = ljs.default_step_limit, // threaded into the interpreter via evaluateWithLimit (research D8)
};

pub const RunError = error{ OpenFailed, OutOfMemory };

pub fn run(io: std.Io, arena: Allocator, opts: Options, report: *rep.Report) RunError!void {
    // Read the default harness prelude (sta.js + assert.js) once; reused for every non-raw test.
    var prelude: []const u8 = "";
    if (opts.harness_dir) |hdir| {
        const sta = readHarness(io, arena, hdir, "sta.js") catch "";
        const assert_js = readHarness(io, arena, hdir, "assert.js") catch "";
        prelude = std.mem.concat(arena, u8, &.{ sta, "\n", assert_js, "\n" }) catch "";
    }

    var dir = std.Io.Dir.cwd().openDir(io, opts.path, .{ .iterate = true }) catch return RunError.OpenFailed;
    defer dir.close(io);

    var walker = dir.walk(arena) catch return RunError.OutOfMemory;
    defer walker.deinit();

    // Per-test scratch arena: each test's source, parse tree, and engine objects live here and are
    // freed (reset) after the test. Without this, the suite's ~34k executions accumulate in one
    // never-freed arena and exhaust memory. The engine is arena-per-realm so nothing leaks across
    // tests; only the report's `path` must outlive a test, so it is duped on the outer arena.
    var scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_state.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".js")) continue;
        if (std.mem.endsWith(u8, entry.basename, "_FIXTURE.js")) continue;
        if (std.mem.indexOf(u8, entry.path, "harness/") != null) continue; // suite's own helpers

        const path_owned = try arena.dupe(u8, entry.path); // persists in the report; entry.path invalidated on next()
        _ = scratch_state.reset(.{ .retain_with_limit = 8 << 20 }); // free the previous test's allocations; release pathological spikes (keep up to 8 MiB) so a single huge test doesn't hold memory for the whole run
        const scratch = scratch_state.allocator();
        const source = dir.readFileAlloc(io, entry.path, scratch, .limited(8 << 20)) catch continue;
        try runOne(io, scratch, opts, prelude, source, path_owned, report);
    }
}

fn readHarness(io: std.Io, arena: Allocator, hdir: []const u8, name: []const u8) ![]const u8 {
    const path = try std.fs.path.join(arena, &.{ hdir, name });
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 << 20));
}

fn runOne(io: std.Io, arena: Allocator, opts: Options, prelude: []const u8, source: []const u8, path: []const u8, report: *rep.Report) RunError!void {
    const meta = md.parse(arena, source) catch return; // not a test (no frontmatter) → skip silently

    // Module linking is still unsupported at M11 → skip (not fail). `[async]` tests are now RUN
    // (M11 Cycle 2): the engine injects a `$DONE` callback, drains the microtask Job queue, and the
    // outcome is classified below — no longer skipped.
    if (meta.flags.module) {
        try report.add(.{ .path = path, .mode = .strict, .outcome = .skip, .reason = .unsupported_flag });
        return;
    }

    // Determine applicable run modes (INTERPRETING.md flag semantics).
    var run_strict = true;
    var run_sloppy = true;
    if (meta.flags.raw or meta.flags.no_strict) run_strict = false;
    if (meta.flags.only_strict) run_sloppy = false;
    if (opts.mode_filter) |m| {
        run_strict = run_strict and m == .strict;
        run_sloppy = run_sloppy and m == .sloppy;
    }

    if (run_strict) try execOne(io, arena, opts, prelude, meta, source, path, .strict, report);
    if (run_sloppy) try execOne(io, arena, opts, prelude, meta, source, path, .sloppy, report);
}

fn execOne(io: std.Io, arena: Allocator, opts: Options, prelude: []const u8, meta: md.Metadata, source: []const u8, path: []const u8, mode: Mode, report: *rep.Report) RunError!void {
    const full = try buildSource(io, arena, opts, prelude, meta, source, mode);
    const engine_mode: ljs.RunMode = if (mode == .strict) .strict else .sloppy;
    // §[async]: drive the test through the $DONE / microtask-drain path; a parse-negative async test
    // still classifies on the parse error (handled in classifyAsync).
    if (meta.flags.is_async) {
        const ar = try ljs.evaluateAsyncTest(arena, full, engine_mode, opts.step_limit);
        try report.add(classifyAsync(meta, ar, mode, path));
        return;
    }
    const result = try ljs.evaluateWithLimit(arena, full, engine_mode, opts.step_limit);
    try report.add(classify(meta, result, mode, path));
}

/// Classify an `[async]` test result (§ Test262 async contract): PASS iff `$DONE` was called with no
/// error; FAIL if called with an error, never called, threw synchronously, parse-errored, or hit the
/// step watchdog. A `negative: parse` async test passes on a syntax_error (some async tests are
/// parse-negatives that still carry the flag).
fn classifyAsync(meta: md.Metadata, ar: ljs.AsyncTestResult, mode: Mode, path: []const u8) TestResult {
    const r = struct {
        fn mk(p: []const u8, m: Mode, o: Outcome, reason: Reason) TestResult {
            return .{ .path = p, .mode = m, .outcome = o, .reason = reason };
        }
    };
    // A parse-phase negative async test passes precisely when the source fails to parse.
    if (meta.negative) |neg| {
        if (neg.phase == .parse) {
            return switch (ar) {
                .syntax_error => r.mk(path, mode, .pass, .none),
                else => r.mk(path, mode, .fail, .no_error_expected_throw),
            };
        }
    }
    return switch (ar) {
        .async_pass => r.mk(path, mode, .pass, .none),
        .async_fail => r.mk(path, mode, .fail, .unexpected_error),
        .never_done => r.mk(path, mode, .fail, .no_error_expected_throw),
        .sync_throw => r.mk(path, mode, .fail, .unexpected_error),
        .syntax_error => r.mk(path, mode, .fail, .parse_error),
        .step_limit => r.mk(path, mode, .fail, .step_limit),
    };
}

/// Assemble the source fed to the engine (INTERPRETING.md): strict prologue (non-raw strict),
/// then the harness prelude (sta.js+assert.js) and each `includes` file, then the test source.
/// `raw` tests run alone.
fn buildSource(io: std.Io, arena: Allocator, opts: Options, prelude: []const u8, meta: md.Metadata, source: []const u8, mode: Mode) RunError![]const u8 {
    if (meta.flags.raw) return source;
    var buf: std.ArrayList(u8) = .empty;
    if (mode == .strict) try buf.appendSlice(arena, "\"use strict\";\n");
    try buf.appendSlice(arena, prelude);
    if (opts.harness_dir) |hdir| {
        for (meta.includes) |inc| {
            const c = readHarness(io, arena, hdir, inc) catch "";
            try buf.appendSlice(arena, c);
            try buf.appendSlice(arena, "\n");
        }
    }
    try buf.appendSlice(arena, source);
    return buf.items;
}

/// Pure classification: (metadata, engine result, mode) → TestResult. Unit-tested below.
pub fn classify(meta: md.Metadata, result: ljs.EvaluationResult, mode: Mode, path: []const u8) TestResult {
    const r = struct {
        fn mk(p: []const u8, m: Mode, o: Outcome, reason: Reason) TestResult {
            return .{ .path = p, .mode = m, .outcome = o, .reason = reason };
        }
    };

    if (meta.negative) |neg| {
        switch (neg.phase) {
            .resolution => return r.mk(path, mode, .skip, .unsupported_flag), // module linking
            .parse => return switch (result) {
                .syntax_error => r.mk(path, mode, .pass, .none),
                else => r.mk(path, mode, .fail, .no_error_expected_throw),
            },
            .runtime => return switch (result) {
                // §14.15: a runtime-negative test passes only if the thrown error's name matches
                // the expected type (FR-008; tightened now that errors are real objects).
                .thrown => |tv| blk: {
                    const got = errorName(tv) orelse break :blk r.mk(path, mode, .fail, .wrong_error);
                    break :blk if (std.mem.eql(u8, got, neg.type_name))
                        r.mk(path, mode, .pass, .none)
                    else
                        r.mk(path, mode, .fail, .wrong_error);
                },
                .syntax_error => r.mk(path, mode, .fail, .parse_error),
                .step_limit => r.mk(path, mode, .fail, .step_limit),
                .normal => r.mk(path, mode, .fail, .no_error_expected_throw),
            },
        }
    }

    // Positive test: passes only on normal completion.
    return switch (result) {
        .normal => r.mk(path, mode, .pass, .none),
        .thrown => r.mk(path, mode, .fail, .unexpected_error),
        .syntax_error => r.mk(path, mode, .fail, .parse_error),
        .step_limit => r.mk(path, mode, .fail, .step_limit),
    };
}

/// The `name` of a thrown Error object, if any (for negative-runtime classification).
fn errorName(v: ljs.Value) ?[]const u8 {
    if (v != .object) return null;
    const nv = v.object.get("name") orelse return null;
    return if (nv == .string) nv.string else null;
}

// ── classification unit tests (T016 / SC-001 logic) ─────────────────────────
const testing = std.testing;

fn metaPositive() md.Metadata {
    return .{};
}
fn metaNegParse() md.Metadata {
    return .{ .negative = .{ .phase = .parse, .type_name = "SyntaxError" } };
}
fn metaNegRuntime() md.Metadata {
    return .{ .negative = .{ .phase = .runtime, .type_name = "TypeError" } };
}

test "positive: normal → pass, syntax_error → fail" {
    try testing.expectEqual(Outcome.pass, classify(metaPositive(), .{ .normal = .undefined }, .sloppy, "p").outcome);
    try testing.expectEqual(Outcome.fail, classify(metaPositive(), .{ .syntax_error = "x" }, .sloppy, "p").outcome);
    try testing.expectEqual(Outcome.fail, classify(metaPositive(), .step_limit, .sloppy, "p").outcome);
}

test "negative parse: syntax_error → pass, normal → fail" {
    try testing.expectEqual(Outcome.pass, classify(metaNegParse(), .{ .syntax_error = "x" }, .strict, "p").outcome);
    try testing.expectEqual(Outcome.fail, classify(metaNegParse(), .{ .normal = .undefined }, .strict, "p").outcome);
}

test "negative runtime: matching error name → pass, wrong/none → fail" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const want = try ljs.Object.create(a, null); // metaNegRuntime expects "TypeError"
    try want.set("name", .{ .string = "TypeError" });
    try testing.expectEqual(Outcome.pass, classify(metaNegRuntime(), .{ .thrown = .{ .object = want } }, .sloppy, "p").outcome);
    const wrong = try ljs.Object.create(a, null);
    try wrong.set("name", .{ .string = "RangeError" });
    try testing.expectEqual(Outcome.fail, classify(metaNegRuntime(), .{ .thrown = .{ .object = wrong } }, .sloppy, "p").outcome);
    try testing.expectEqual(Outcome.fail, classify(metaNegRuntime(), .{ .normal = .undefined }, .sloppy, "p").outcome);
}
