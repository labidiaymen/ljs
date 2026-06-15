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
};
