//! Test262 result types and the conformance report (counts, percentage, per-test list,
//! human summary, JSON). See contracts/report-schema.json.
const std = @import("std");

pub const Mode = enum { strict, sloppy };

pub const Outcome = enum { pass, fail, skip };

pub const Reason = enum {
    none,
    wrong_error, // negative test threw, but wrong type/phase
    unexpected_error, // positive test threw/failed
    no_error_expected_throw, // negative test did NOT produce the expected error
    parse_error, // unexpected syntax error
    step_limit, // watchdog tripped
    unsupported_flag, // module/async etc. not supported at M0
    unsupported_feature,

    pub fn label(self: Reason) []const u8 {
        return switch (self) {
            .none => "",
            .wrong_error => "wrong_error",
            .unexpected_error => "unexpected_error",
            .no_error_expected_throw => "no_error_expected_throw",
            .parse_error => "parse_error",
            .step_limit => "step_limit",
            .unsupported_flag => "unsupported_flag",
            .unsupported_feature => "unsupported_feature",
        };
    }
};

pub const TestResult = struct {
    path: []const u8,
    mode: Mode,
    outcome: Outcome,
    reason: Reason = .none,
};

pub const Counts = struct {
    total: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,

    pub fn conformancePct(self: Counts) f64 {
        const denom = self.passed + self.failed; // skips excluded
        if (denom == 0) return 0;
        return @as(f64, @floatFromInt(self.passed)) / @as(f64, @floatFromInt(denom)) * 100.0;
    }
};

pub const Report = struct {
    arena: std.mem.Allocator,
    results: std.ArrayList(TestResult) = .empty,

    pub fn add(self: *Report, r: TestResult) error{OutOfMemory}!void {
        try self.results.append(self.arena, r);
    }

    pub fn counts(self: Report) Counts {
        var c: Counts = .{};
        for (self.results.items) |r| {
            c.total += 1;
            switch (r.outcome) {
                .pass => c.passed += 1,
                .fail => c.failed += 1,
                .skip => c.skipped += 1,
            }
        }
        return c;
    }

    pub fn writeSummary(self: Report, w: *std.Io.Writer, subset: []const u8) std.Io.Writer.Error!void {
        const c = self.counts();
        try w.print("Test262  subset={s}\n", .{subset});
        try w.print("  total={d}  passed={d}  failed={d}  skipped={d}  conformance={d:.1}%\n", .{
            c.total, c.passed, c.failed, c.skipped, c.conformancePct(),
        });
    }

    /// Per-test detail (fails and skips only, to keep output readable).
    pub fn writeDetail(self: Report, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.results.items) |r| {
            if (r.outcome == .pass) continue;
            try w.print("  {s:<5} {s:<7} {s}  {s}\n", .{
                @tagName(r.outcome), @tagName(r.mode), r.path, r.reason.label(),
            });
        }
    }

    // ── baseline / regression detection (US3, FR-009) ────────────────────────

    /// The set of currently-passing test ids ("path#mode"), as a string hash set. Built once and
    /// reused so regression detection is O(results + baseline) instead of O(baseline × results) —
    /// the quadratic form OOMs at the full-`language/` corpus size (allocPrint per comparison).
    fn passingIdSet(self: Report, arena: std.mem.Allocator) std.mem.Allocator.Error!std.StringHashMap(void) {
        var set = std.StringHashMap(void).init(arena);
        for (self.results.items) |r| {
            if (r.outcome != .pass) continue;
            try set.put(try idFor(arena, r), {});
        }
        return set;
    }

    /// Serialize the set of currently-passing test ids ("path#mode") as a JSON string array.
    pub fn baselineBytes(self: Report, arena: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(arena, "[\n");
        var first = true;
        for (self.results.items) |r| {
            if (r.outcome != .pass) continue;
            if (!first) try buf.appendSlice(arena, ",\n");
            first = false;
            const line = try std.fmt.allocPrint(arena, "  \"{s}\"", .{try idFor(arena, r)});
            try buf.appendSlice(arena, line);
        }
        try buf.appendSlice(arena, "\n]\n");
        return buf.items;
    }

    /// Baseline ids that are no longer passing in this run (regressions). A baseline id that
    /// now fails OR is skipped/absent counts as a regression (strict "a baseline pass must
    /// still pass" definition, FR-009). O(results + baseline) via a one-shot passing-id hash set
    /// (the corpus has grown past the point where the old O(baseline × results) form is viable).
    pub fn regressionsVs(self: Report, arena: std.mem.Allocator, baseline_ids: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
        var passing = try self.passingIdSet(arena);
        var regressed: std.ArrayList([]const u8) = .empty;
        for (baseline_ids) |bid| {
            if (!passing.contains(bid)) try regressed.append(arena, bid);
        }
        return regressed.toOwnedSlice(arena);
    }
};

fn idFor(arena: std.mem.Allocator, r: TestResult) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}#{s}", .{ r.path, @tagName(r.mode) });
}

/// Extract every JSON quoted string from `bytes` — the baseline is a flat string array,
/// so each quoted token is a passing-test id. M0 assumption: ids are quote-free (`path#mode`)
/// and the file is exactly what `baselineBytes` emits — no JSON-escape handling. Revisit if
/// the full report-schema.json baseline (an object with keys) is ever adopted.
pub fn parseIds(arena: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] != '"') continue;
        i += 1;
        const start = i;
        while (i < bytes.len and bytes[i] != '"') i += 1;
        try ids.append(arena, try arena.dupe(u8, bytes[start..i]));
    }
    return ids.toOwnedSlice(arena);
}

// ── tests (T027 / SC-004 logic) ─────────────────────────────────────────────
const testing = std.testing;

test "regression detection: baseline id no longer passing is flagged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var report: Report = .{ .arena = a };
    try report.add(.{ .path = "a.js", .mode = .strict, .outcome = .pass });
    try report.add(.{ .path = "b.js", .mode = .strict, .outcome = .fail, .reason = .parse_error });

    const baseline = try parseIds(a, try report.baselineBytes(a)); // currently only a.js#strict
    try testing.expectEqual(@as(usize, 1), baseline.len);
    try testing.expectEqualStrings("a.js#strict", baseline[0]);

    // No regression when the same test still passes.
    try testing.expectEqual(@as(usize, 0), (try report.regressionsVs(a, baseline)).len);

    // Now a.js regresses → flagged.
    var report2: Report = .{ .arena = a };
    try report2.add(.{ .path = "a.js", .mode = .strict, .outcome = .fail, .reason = .parse_error });
    const regs = try report2.regressionsVs(a, baseline);
    try testing.expectEqual(@as(usize, 1), regs.len);
    try testing.expectEqualStrings("a.js#strict", regs[0]);
}
