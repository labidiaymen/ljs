//! Engine entry point: source text → observable result. Wires lexer → parser → interpreter
//! and maps outcomes to an EvaluationResult the CLI and the Test262 harness consume.
const std = @import("std");
const Value = @import("value.zig").Value;
const Parser = @import("parser.zig").Parser;
const Interpreter = @import("interpreter.zig").Interpreter;

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
    var interp = Interpreter{ .arena = arena, .step_limit = step_limit };
    const completion = interp.run(program) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StepLimitExceeded => return .step_limit,
    };
    return switch (completion) {
        .normal => |v| .{ .normal = v },
        .throw => |v| .{ .thrown = v },
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
