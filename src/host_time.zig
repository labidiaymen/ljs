//! Host runtime time/sleep primitives for the event loop (spec 098). Pure std — a MONOTONIC clock
//! (immune to wall-clock jumps, the right base for timer deadlines) and a blocking millisecond sleep.
//! Windows uses QueryPerformanceCounter / Sleep; POSIX uses clock_gettime(MONOTONIC) / nanosleep.
//! NOT on the Test262 path (the conformance engine never sleeps) — host CLI only.
const std = @import("std");
const builtin = @import("builtin");

extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.winapi) c_int;
extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.winapi) c_int;
extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;

/// Milliseconds from an arbitrary fixed origin on a MONOTONIC clock (only differences are meaningful).
pub fn monotonicMs() f64 {
    if (builtin.os.tag == .windows) {
        var counter: i64 = 0;
        var freq: i64 = 1;
        _ = QueryPerformanceCounter(&counter);
        _ = QueryPerformanceFrequency(&freq);
        if (freq == 0) return 0;
        return @as(f64, @floatFromInt(counter)) * 1000.0 / @as(f64, @floatFromInt(freq));
    }
    // SAFETY: filled in full by clock_gettime on the next line before any read.
    var ts: std.posix.timespec = undefined;
    std.posix.clock_gettime(.MONOTONIC, &ts) catch return 0;
    const sec: i64 = @intCast(ts.sec);
    const nsec: i64 = @intCast(ts.nsec);
    return @as(f64, @floatFromInt(sec)) * 1000.0 + @as(f64, @floatFromInt(nsec)) / 1_000_000.0;
}

/// Block the current thread for `ms` milliseconds (clamped ≥ 0). Used by the event loop to wait until
/// the next timer deadline when no microtask/macrotask is immediately runnable.
pub fn sleepMs(ms: f64) void {
    if (ms <= 0) return;
    if (builtin.os.tag == .windows) {
        Sleep(@intFromFloat(@min(ms, @as(f64, std.math.maxInt(u32)))));
        return;
    }
    const total_ns: u64 = @intFromFloat(@min(ms * 1_000_000.0, @as(f64, @floatFromInt(std.math.maxInt(u64)))));
    std.posix.nanosleep(total_ns / 1_000_000_000, total_ns % 1_000_000_000);
}
