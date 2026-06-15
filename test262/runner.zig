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
    step_limit: u64 = 10_000_000, // accepted; not yet threaded into the interpreter
};

pub const RunError = error{ OpenFailed, OutOfMemory };

pub fn run(io: std.Io, arena: Allocator, opts: Options, report: *rep.Report) RunError!void {
    var dir = std.Io.Dir.cwd().openDir(io, opts.path, .{ .iterate = true }) catch return RunError.OpenFailed;
    defer dir.close(io);

    var walker = dir.walk(arena) catch return RunError.OutOfMemory;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".js")) continue;
        if (std.mem.endsWith(u8, entry.basename, "_FIXTURE.js")) continue;
        if (std.mem.indexOf(u8, entry.path, "harness/") != null) continue; // suite's own helpers

        const source = dir.readFileAlloc(io, entry.path, arena, .limited(8 << 20)) catch continue;
        const path_owned = try arena.dupe(u8, entry.path); // entry.path is invalidated on next()
        try runOne(arena, opts, source, path_owned, report);
    }
}

fn runOne(arena: Allocator, opts: Options, source: []const u8, path: []const u8, report: *rep.Report) RunError!void {
    const meta = md.parse(arena, source) catch return; // not a test (no frontmatter) → skip silently

    // Unsupported execution modes at M0 → skip (not fail).
    if (meta.flags.module or meta.flags.is_async) {
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

    if (run_strict) try execOne(arena, meta, source, path, .strict, report);
    if (run_sloppy) try execOne(arena, meta, source, path, .sloppy, report);
}

fn execOne(arena: Allocator, meta: md.Metadata, source: []const u8, path: []const u8, mode: Mode, report: *rep.Report) RunError!void {
    const full = try buildSource(arena, meta, source, mode);
    const engine_mode: ljs.RunMode = if (mode == .strict) .strict else .sloppy;
    const result = try ljs.evaluate(arena, full, engine_mode);
    try report.add(classify(meta, result, mode, path));
}

/// Assemble the source fed to the engine: a strict-mode prologue for non-raw strict runs, then
/// the test source. NOTE (M0): Test262 harness helpers (sta.js/assert.js + `includes`) are NOT
/// loaded yet — the trivial evaluator can't run them (research D7). `opts.harness_dir` is
/// reserved for when the engine supports functions/objects.
fn buildSource(arena: Allocator, meta: md.Metadata, source: []const u8, mode: Mode) RunError![]const u8 {
    if (meta.flags.raw) return source;
    var buf: std.ArrayList(u8) = .empty;
    if (mode == .strict) try buf.appendSlice(arena, "\"use strict\";\n");
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
                // M0: typed Error objects don't exist, so we can only verify that a throw
                // occurred, not its constructor. Approximate; tightened once Errors land.
                .thrown => r.mk(path, mode, .pass, .none),
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

test "negative runtime: thrown → pass, normal → fail" {
    try testing.expectEqual(Outcome.pass, classify(metaNegRuntime(), .{ .thrown = .undefined }, .sloppy, "p").outcome);
    try testing.expectEqual(Outcome.fail, classify(metaNegRuntime(), .{ .normal = .undefined }, .sloppy, "p").outcome);
}
