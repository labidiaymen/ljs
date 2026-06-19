//! §21.4 Date — the Date object: constructor (`new Date(...)` / plain-call `Date(...)`), the
//! statics `Date.now` / `Date.parse` / `Date.UTC`, and the full %Date.prototype% getter/setter/
//! conversion surface. Dispatched from the interpreter's `callNative` (`date_ctor` / `date_static`
//! / `date_proto_method`) and `constructNT` (for `new`). The internal [[DateValue]] (ms since the
//! Unix epoch, NaN-able) lives in `Object.date_value` on a `kind == .date` exotic.
//!
//! TIME ZONE: this milestone implements UTC == local time (LocalTime is the identity), so the
//! `getX` and `getUTCX` families share one implementation and `getTimezoneOffset` returns 0. The
//! §21.4.1 abstract operations (Day/YearFromTime/MakeTime/MakeDay/MakeDate/TimeClip/…) are pure
//! helpers below; they are the spec's exact integer arithmetic over the time value.
const std = @import("std");
const builtin = @import("builtin");
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const Object = @import("object.zig").Object;
const interp_ops = @import("interp_ops.zig");

// ── §21.4.1 Abstract operations (pure integer/float helpers over the time value) ──────────────

const ms_per_second: f64 = 1000;
const ms_per_minute: f64 = 60000;
const ms_per_hour: f64 = 3600000;
const ms_per_day: f64 = 86400000;
const max_time: f64 = 8.64e15; // §21.4.1.1 the valid time-value range is ±8.64e15 ms.

// Zig 0.16 moved the wall-clock to the `std.Io` abstraction (`std.time.milliTimestamp` is gone). For
// the time-value seed (`Date.now` / `new Date()`) we read the OS clock directly: Windows via
// GetSystemTimeAsFileTime (100-ns ticks since 1601-01-01), POSIX via clock_gettime(CLOCK_REALTIME).
const FILETIME = extern struct { low: u32, high: u32 };
extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *FILETIME) callconv(.winapi) void;

/// The current wall-clock time as ms since the Unix epoch (an integral f64).
fn nowMs() f64 {
    if (builtin.os.tag == .windows) {
        // SAFETY: filled in full by GetSystemTimeAsFileTime on the next line before any read.
        var ft: FILETIME = undefined;
        GetSystemTimeAsFileTime(&ft);
        const ticks: u64 = (@as(u64, ft.high) << 32) | @as(u64, ft.low); // 100-ns intervals since 1601.
        // 11644473600 s between 1601-01-01 and 1970-01-01.
        const ms_since_1601 = ticks / 10000;
        const epoch_diff_ms: u64 = 11644473600 * 1000;
        return @floatFromInt(@as(i64, @intCast(ms_since_1601)) - @as(i64, @intCast(epoch_diff_ms)));
    } else {
        // SAFETY: filled in full by clock_gettime on the next line before any read.
        var ts: std.posix.timespec = undefined;
        std.posix.clock_gettime(.REALTIME, &ts) catch return 0;
        const sec: i64 = @intCast(ts.sec);
        const nsec: i64 = @intCast(ts.nsec);
        return @floatFromInt(sec * 1000 + @divTrunc(nsec, 1_000_000));
    }
}

/// §5.2.5 floored modulo: the result has the sign of the divisor `b` (b > 0 here, so result ≥ 0).
fn floorMod(a: f64, b: f64) f64 {
    return a - @floor(a / b) * b;
}

/// §21.4.1.2 Day ( t ) = floor(t / msPerDay).
fn day(t: f64) f64 {
    return @floor(t / ms_per_day);
}

/// §21.4.1.2 TimeWithinDay ( t ) = t modulo msPerDay.
fn timeWithinDay(t: f64) f64 {
    return floorMod(t, ms_per_day);
}

/// §21.4.1.3 DaysInYear ( y ): 365, or 366 in a leap year.
fn daysInYear(y: f64) f64 {
    if (floorMod(y, 4) != 0) return 365;
    if (floorMod(y, 100) != 0) return 366;
    if (floorMod(y, 400) != 0) return 365;
    return 366;
}

/// §21.4.1.3 DayFromYear ( y ) — the day number of 1 January of year `y`.
fn dayFromYear(y: f64) f64 {
    return 365 * (y - 1970) + @floor((y - 1969) / 4) - @floor((y - 1901) / 100) + @floor((y - 1601) / 400);
}

/// §21.4.1.3 TimeFromYear ( y ) = msPerDay * DayFromYear(y).
fn timeFromYear(y: f64) f64 {
    return ms_per_day * dayFromYear(y);
}

/// §21.4.1.3 YearFromTime ( t ) — the (Gregorian) year in which the time value `t` falls.
fn yearFromTime(t: f64) f64 {
    // Estimate then correct (the spec defines it as the year y with TimeFromYear(y) ≤ t).
    var y: f64 = @floor(t / (ms_per_day * 365.2425)) + 1970;
    if (timeFromYear(y) > t) {
        while (timeFromYear(y) > t) y -= 1;
    } else {
        while (timeFromYear(y + 1) <= t) y += 1;
    }
    return y;
}

/// §21.4.1.3 InLeapYear ( t ) — 1 if `t` is within a leap year, else 0.
fn inLeapYear(t: f64) f64 {
    return if (daysInYear(yearFromTime(t)) == 366) 1 else 0;
}

/// §21.4.1.4 DayWithinYear ( t ) = Day(t) − DayFromYear(YearFromTime(t)).
fn dayWithinYear(t: f64) f64 {
    return day(t) - dayFromYear(yearFromTime(t));
}

/// §21.4.1.4 MonthFromTime ( t ) — 0 (January) … 11 (December).
fn monthFromTime(t: f64) f64 {
    const d = dayWithinYear(t);
    const leap = inLeapYear(t);
    if (d < 31) return 0;
    if (d < 59 + leap) return 1;
    if (d < 90 + leap) return 2;
    if (d < 120 + leap) return 3;
    if (d < 151 + leap) return 4;
    if (d < 181 + leap) return 5;
    if (d < 212 + leap) return 6;
    if (d < 243 + leap) return 7;
    if (d < 273 + leap) return 8;
    if (d < 304 + leap) return 9;
    if (d < 334 + leap) return 10;
    return 11;
}

/// §21.4.1.5 DateFromTime ( t ) — the day of the month, 1 … 31.
fn dateFromTime(t: f64) f64 {
    const d = dayWithinYear(t);
    const leap = inLeapYear(t);
    return switch (@as(u8, @intFromFloat(monthFromTime(t)))) {
        0 => d + 1,
        1 => d - 30,
        2 => d - 58 - leap,
        3 => d - 89 - leap,
        4 => d - 119 - leap,
        5 => d - 150 - leap,
        6 => d - 180 - leap,
        7 => d - 211 - leap,
        8 => d - 242 - leap,
        9 => d - 272 - leap,
        10 => d - 303 - leap,
        else => d - 333 - leap,
    };
}

/// §21.4.1.6 WeekDay ( t ) — 0 (Sunday) … 6 (Saturday). 1 January 1970 was a Thursday (4).
fn weekDay(t: f64) f64 {
    return floorMod(day(t) + 4, 7);
}

/// §21.4.1.9 HourFromTime ( t ).
fn hourFromTime(t: f64) f64 {
    return floorMod(@floor(t / ms_per_hour), 24);
}
/// §21.4.1.9 MinFromTime ( t ).
fn minFromTime(t: f64) f64 {
    return floorMod(@floor(t / ms_per_minute), 60);
}
/// §21.4.1.9 SecFromTime ( t ).
fn secFromTime(t: f64) f64 {
    return floorMod(@floor(t / ms_per_second), 60);
}
/// §21.4.1.9 msFromTime ( t ).
fn msFromTime(t: f64) f64 {
    return floorMod(t, 1000);
}

/// §21.4.1.11 MakeTime ( hour, min, sec, ms ) — combine into ms within a day (NaN propagates).
fn makeTime(hour: f64, min: f64, sec: f64, ms: f64) f64 {
    if (!std.math.isFinite(hour) or !std.math.isFinite(min) or !std.math.isFinite(sec) or !std.math.isFinite(ms)) return std.math.nan(f64);
    const h = std.math.trunc(hour);
    const m = std.math.trunc(min);
    const s = std.math.trunc(sec);
    const milli = std.math.trunc(ms);
    return h * ms_per_hour + m * ms_per_minute + s * ms_per_second + milli;
}

/// §21.4.1.12 MakeDay ( year, month, date ) — the day number for the given Y/M/D (NaN propagates).
fn makeDay(year: f64, month: f64, date: f64) f64 {
    if (!std.math.isFinite(year) or !std.math.isFinite(month) or !std.math.isFinite(date)) return std.math.nan(f64);
    const y = std.math.trunc(year);
    const m = std.math.trunc(month);
    const dt = std.math.trunc(date);
    const ym = y + @floor(m / 12);
    const mn = floorMod(m, 12);
    // Find the day number t for 1 (mn+1) ym, then add (dt - 1).
    // Search by computing DayFromYear(ym) plus the month offset.
    var days = dayFromYear(ym);
    const leap: f64 = if (daysInYear(ym) == 366) 1 else 0;
    const month_days = [_]f64{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
    days += month_days[@as(usize, @intFromFloat(mn))];
    if (mn >= 2) days += leap;
    return days + dt - 1;
}

/// §21.4.1.13 MakeDate ( day, time ) = day * msPerDay + time.
fn makeDate(d: f64, time: f64) f64 {
    if (!std.math.isFinite(d) or !std.math.isFinite(time)) return std.math.nan(f64);
    return d * ms_per_day + time;
}

/// §21.4.1.14 TimeClip ( time ) — NaN / |time| > 8.64e15 → NaN; else truncate toward zero (and
/// normalize -0 → +0).
fn timeClip(time: f64) f64 {
    if (!std.math.isFinite(time)) return std.math.nan(f64);
    if (@abs(time) > max_time) return std.math.nan(f64);
    const t = std.math.trunc(time);
    return if (t == 0) 0 else t;
}

// ── §21.4 receiver helpers ────────────────────────────────────────────────────────────────────

/// thisTimeValue (§21.4.4.x RequireInternalSlot([[DateValue]])): the [[DateValue]] of a Date
/// instance, else null (→ TypeError).
fn thisTimeValue(this_val: Value) ?f64 {
    if (this_val != .object) return null;
    if (this_val.object.kind != .date) return null;
    return this_val.object.date_value;
}

fn dateProto(it: *Interpreter) ?*Object {
    return it.globalProto("Date");
}

// ── Constructor (§21.4.2) ───────────────────────────────────────────────────────────────────

/// §21.4.2.1 Date ( ... ) called WITHOUT new — return a String of the current time (step 1).
pub fn callAsFunction(it: *Interpreter, args: []const Value) EvalError!Completion {
    _ = args;
    const now: f64 = nowMs();
    return .{ .normal = .{ .string = try formatToString(it, timeClip(now)) } };
}

/// §21.4.2.1 [[Construct]] — `new Date(...)`. `this_val` is the pre-created instance (proto-linked to
/// new_target.prototype) from `constructNT`; flip it into a `.date` exotic and compute [[DateValue]].
pub fn construct(it: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    const obj: *Object = if (this_val == .object) this_val.object else try Object.create(it.arena, dateProto(it));
    obj.kind = .date;

    if (args.len == 0) {
        // §21.4.2.1 step 3.a: no arguments → the current time.
        obj.date_value = timeClip(nowMs());
    } else if (args.len == 1) {
        // §21.4.2.1 step 4: one argument.
        const v = args[0];
        // SAFETY: assigned on every branch below (Date / string / number) before it is read.
        var tv: f64 = undefined;
        if (v == .object and v.object.kind == .date) {
            // step 4.a: a Date object → its [[DateValue]] verbatim (no re-clip needed, already clipped).
            tv = v.object.date_value orelse std.math.nan(f64);
        } else {
            // step 4.b: ToPrimitive(value) (no hint). A String → Date.parse; else ToNumber.
            const pc = try it.toPrimitive(v, .default);
            if (pc.isAbrupt()) return pc;
            if (pc.normal == .string) {
                tv = parseDateString(pc.normal.string);
            } else {
                const nc = try it.toNumberV(pc.normal);
                if (nc.isAbrupt()) return nc;
                tv = timeClip(nc.normal.number);
            }
        }
        obj.date_value = timeClip(tv);
    } else {
        // §21.4.2.1 step 5: two or more arguments — Y/M[/D/h/m/s/ms] in LOCAL time (== UTC here).
        var fields: [7]f64 = .{ 0, 0, 1, 0, 0, 0, 0 }; // year, month, date=1, hours, min, sec, ms
        const n = @min(args.len, 7);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const nc = try it.toNumberV(args[i]);
            if (nc.isAbrupt()) return nc;
            fields[i] = nc.normal.number;
        }
        // step 5.h: MakeFullYear on the year (2-digit-year rule).
        const yr = makeFullYear(fields[0]);
        const finalDate = makeDate(makeDay(yr, fields[1], fields[2]), makeTime(fields[3], fields[4], fields[5], fields[6]));
        obj.date_value = timeClip(finalDate); // local == UTC, so no UTC() adjustment
    }
    return .{ .normal = .{ .object = obj } };
}

/// §21.4.1.x MakeFullYear — the 2-digit-year rule: an integer year in [0, 99] maps to 1900 + y.
fn makeFullYear(year: f64) f64 {
    if (std.math.isNan(year)) return std.math.nan(f64);
    const y = std.math.trunc(year);
    if (y >= 0 and y <= 99) return 1900 + y;
    return y;
}

// ── Statics (§21.4.3) ───────────────────────────────────────────────────────────────────────

pub fn static(it: *Interpreter, name: []const u8, args: []const Value) EvalError!Completion {
    if (std.mem.eql(u8, name, "now")) {
        // §21.4.3.1 Date.now() — the current time, ms since the epoch (an integral Number).
        const now: f64 = nowMs();
        return .{ .normal = .{ .number = now } };
    }
    if (std.mem.eql(u8, name, "parse")) {
        // §21.4.3.2 Date.parse(string) — ToString then parse.
        const s = try it.toString(if (args.len > 0) args[0] else .undefined);
        return .{ .normal = .{ .number = parseDateString(s) } };
    }
    if (std.mem.eql(u8, name, "UTC")) {
        // §21.4.3.4 Date.UTC(year[, month[, date[, hours[, min[, sec[, ms]]]]]]).
        var fields: [7]f64 = .{ std.math.nan(f64), 0, 1, 0, 0, 0, 0 };
        const n = @min(args.len, 7);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const nc = try it.toNumberV(args[i]);
            if (nc.isAbrupt()) return nc;
            fields[i] = nc.normal.number;
        }
        if (args.len == 0) return .{ .normal = .{ .number = std.math.nan(f64) } };
        const yr = makeFullYear(fields[0]);
        const t = makeDate(makeDay(yr, fields[1], fields[2]), makeTime(fields[3], fields[4], fields[5], fields[6]));
        return .{ .normal = .{ .number = timeClip(t) } };
    }
    return it.throwError("TypeError", "Unknown Date static method");
}

// ── Prototype methods (§21.4.4) ─────────────────────────────────────────────────────────────

pub fn method(it: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    // §21.4.4.45 Date.prototype[Symbol.toPrimitive](hint) — receiver must be an Object; "default"/
    // "string" → ToString, "number" → ToNumber. (This is the ONLY prototype method whose receiver
    // need not be a Date; it is checked separately.)
    if (std.mem.eql(u8, name, "[Symbol.toPrimitive]")) return toPrimitive(it, this_val, args);

    // ── Getters (no [[DateValue]] mutation) ──
    if (getterTimeField(name)) |field| {
        const t = thisTimeValue(this_val) orelse return it.throwError("TypeError", "Date.prototype method called on incompatible receiver");
        if (std.math.isNan(t)) return .{ .normal = .{ .number = std.math.nan(f64) } };
        return .{ .normal = .{ .number = field(t) } };
    }
    if (std.mem.eql(u8, name, "getTime") or std.mem.eql(u8, name, "valueOf")) {
        // §21.4.4.10 / §21.4.4.44 — the raw time value.
        const t = thisTimeValue(this_val) orelse return it.throwError("TypeError", "Date.prototype method called on incompatible receiver");
        return .{ .normal = .{ .number = t } };
    }
    if (std.mem.eql(u8, name, "getTimezoneOffset")) {
        // §21.4.4.11 — local == UTC here, so the offset is 0 (NaN for an invalid Date).
        const t = thisTimeValue(this_val) orelse return it.throwError("TypeError", "Date.prototype method called on incompatible receiver");
        if (std.math.isNan(t)) return .{ .normal = .{ .number = std.math.nan(f64) } };
        return .{ .normal = .{ .number = 0 } };
    }

    // ── Conversions (need a valid Date receiver) ──
    if (isConversion(name)) return conversion(it, name, this_val);

    // ── Setters (mutate [[DateValue]]) ──
    if (std.mem.startsWith(u8, name, "set")) return setter(it, name, this_val, args);

    return it.throwError("TypeError", "Unknown Date.prototype method");
}

/// Map a getter method name to the §21.4.1 field-extraction function (UTC == local here, so the
/// `getX`/`getUTCX` pair share one entry). `getTime`/`valueOf`/`getTimezoneOffset` are handled
/// separately by the caller.
fn getterTimeField(name: []const u8) ?*const fn (f64) f64 {
    const Pair = struct { []const u8, *const fn (f64) f64 };
    const table = [_]Pair{
        .{ "getFullYear", yearFromTime },   .{ "getUTCFullYear", yearFromTime },
        .{ "getMonth", monthFromTime },     .{ "getUTCMonth", monthFromTime },
        .{ "getDate", dateFromTime },       .{ "getUTCDate", dateFromTime },
        .{ "getDay", weekDay },             .{ "getUTCDay", weekDay },
        .{ "getHours", hourFromTime },      .{ "getUTCHours", hourFromTime },
        .{ "getMinutes", minFromTime },     .{ "getUTCMinutes", minFromTime },
        .{ "getSeconds", secFromTime },     .{ "getUTCSeconds", secFromTime },
        .{ "getMilliseconds", msFromTime }, .{ "getUTCMilliseconds", msFromTime },
    };
    for (table) |e| if (std.mem.eql(u8, name, e[0])) return e[1];
    return null;
}

// ── Setters (§21.4.4.20–.31) ────────────────────────────────────────────────────────────────

/// Which time components a setter replaces, and from which argument index. Index into the canonical
/// component vector [year, month, date, hours, minutes, seconds, ms].
const SetterSpec = struct {
    start: u8, // first component replaced (0..6)
    count: u8, // how many components it accepts (clamped by args.len)
};

fn setterSpec(name: []const u8) ?SetterSpec {
    const T = struct { []const u8, u8, u8 };
    const table = [_]T{
        .{ "setMilliseconds", 6, 1 }, .{ "setUTCMilliseconds", 6, 1 },
        .{ "setSeconds", 5, 2 },      .{ "setUTCSeconds", 5, 2 },
        .{ "setMinutes", 4, 3 },      .{ "setUTCMinutes", 4, 3 },
        .{ "setHours", 3, 4 },        .{ "setUTCHours", 3, 4 },
        .{ "setDate", 2, 1 },         .{ "setUTCDate", 2, 1 },
        .{ "setMonth", 1, 2 },        .{ "setUTCMonth", 1, 2 },
        .{ "setFullYear", 0, 3 },     .{ "setUTCFullYear", 0, 3 },
    };
    for (table) |e| if (std.mem.eql(u8, name, e[0])) return .{ .start = e[1], .count = e[2] };
    return null;
}

fn setter(it: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object or this_val.object.kind != .date)
        return it.throwError("TypeError", "Date.prototype method called on incompatible receiver");
    const obj = this_val.object;

    if (std.mem.eql(u8, name, "setTime")) {
        // §21.4.4.27 setTime(time) — ToNumber, TimeClip, store.
        const nc = try it.toNumberV(if (args.len > 0) args[0] else .undefined);
        if (nc.isAbrupt()) return nc;
        const v = timeClip(nc.normal.number);
        obj.date_value = v;
        return .{ .normal = .{ .number = v } };
    }

    const spec = setterSpec(name) orelse return it.throwError("TypeError", "Unknown Date setter");
    const t = obj.date_value orelse std.math.nan(f64);

    // §21.4.4.21 setFullYear: if [[DateValue]] is NaN, the baseline t is +0 (the year is being set
    // outright); every other setter keeps t (so an invalid Date stays invalid — its broken-down fields
    // are NaN and MakeDate propagates NaN). The first governed component is ALWAYS ToNumber'd (an
    // omitted arg → ToNumber(undefined) = NaN → the Date becomes invalid), per the spec's step 2.
    const is_full_year = spec.start == 0;
    const base: f64 = if (std.math.isNan(t) and is_full_year) 0 else t;

    // Break the current time value into components [year, month, date, hours, minutes, seconds, ms].
    var comp = [_]f64{
        yearFromTime(base), monthFromTime(base), dateFromTime(base),
        hourFromTime(base), minFromTime(base),   secFromTime(base),
        msFromTime(base),
    };

    // Overwrite the governed components from the arguments (coercing each, in spec order). The FIRST
    // governed component (relative index 0) is always read — `undefined` when no arg was passed; the
    // trailing optional components keep the existing field when their argument is absent.
    var idx: usize = 0;
    while (idx < spec.count) : (idx += 1) {
        if (idx == 0) {
            const nc = try it.toNumberV(if (args.len > 0) args[0] else .undefined);
            if (nc.isAbrupt()) return nc;
            comp[spec.start] = nc.normal.number;
        } else if (idx < args.len) {
            const nc = try it.toNumberV(args[idx]);
            if (nc.isAbrupt()) return nc;
            comp[spec.start + idx] = nc.normal.number;
        }
    }

    // §21.4.4.x: if the ORIGINALLY-read [[DateValue]] was NaN (and this is not setFullYear), the result
    // is NaN and [[DateValue]] is NOT written — so a mutation the argument's `valueOf` made to the Date
    // (e.g. setTime(0)) persists (the "date-value-read-before-tonumber-when-date-is-invalid" tests).
    if (std.math.isNan(t) and !is_full_year) return .{ .normal = .{ .number = std.math.nan(f64) } };

    const newDate = makeDate(makeDay(comp[0], comp[1], comp[2]), makeTime(comp[3], comp[4], comp[5], comp[6]));
    const v = timeClip(newDate); // local == UTC
    obj.date_value = v;
    return .{ .normal = .{ .number = v } };
}

// ── Conversions (§21.4.4.35–.43) ────────────────────────────────────────────────────────────

fn isConversion(name: []const u8) bool {
    const set = [_][]const u8{
        "toISOString", "toJSON",         "toString",           "toDateString",       "toTimeString",
        "toUTCString", "toLocaleString", "toLocaleDateString", "toLocaleTimeString",
    };
    for (set) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

fn conversion(it: *Interpreter, name: []const u8, this_val: Value) EvalError!Completion {
    if (std.mem.eql(u8, name, "toJSON")) {
        // §21.4.4.37 toJSON(key): ToObject(this); ToPrimitive(number); a non-finite Number → null;
        // else Invoke(O, "toISOString") — a GENERIC property lookup + call (NOT a Date-only path: any
        // object with a callable `toISOString` works), so a thrown / non-Date `toISOString` propagates.
        const oc = try it.toObjectForArrayLike(this_val);
        const o = switch (oc) {
            .obj => |o| o,
            .abrupt => |a| return a,
        };
        const pc = try it.toPrimitive(.{ .object = o }, .number);
        if (pc.isAbrupt()) return pc;
        if (pc.normal == .number and !std.math.isFinite(pc.normal.number)) return .{ .normal = .null };
        const fc = try it.getProperty(.{ .object = o }, "toISOString");
        if (fc.isAbrupt()) return fc;
        if (fc.normal != .object or !interp.isCallable(fc.normal.object)) {
            return it.throwError("TypeError", "Date.prototype.toJSON: toISOString is not callable");
        }
        return it.callFunction(fc.normal.object, &.{}, .{ .object = o });
    }

    const t = thisTimeValue(this_val) orelse return it.throwError("TypeError", "Date.prototype conversion called on incompatible receiver");

    if (std.mem.eql(u8, name, "toISOString")) {
        // §21.4.4.36 — RangeError on a non-finite time value.
        if (!std.math.isFinite(t)) return it.throwError("RangeError", "Invalid time value");
        return .{ .normal = .{ .string = try formatISO(it, t) } };
    }

    // The remaining textual conversions all yield "Invalid Date" for a NaN time value.
    if (std.math.isNan(t)) return .{ .normal = .{ .string = "Invalid Date" } };

    if (std.mem.eql(u8, name, "toDateString")) return .{ .normal = .{ .string = try formatDate(it, t) } };
    if (std.mem.eql(u8, name, "toTimeString")) return .{ .normal = .{ .string = try formatTime(it, t) } };
    if (std.mem.eql(u8, name, "toUTCString")) return .{ .normal = .{ .string = try formatUTC(it, t) } };
    // toString / toLocaleString / toLocaleDateString / toLocaleTimeString — fixed reasonable forms.
    if (std.mem.eql(u8, name, "toLocaleDateString")) return .{ .normal = .{ .string = try formatDate(it, t) } };
    if (std.mem.eql(u8, name, "toLocaleTimeString")) return .{ .normal = .{ .string = try formatTime(it, t) } };
    // toString / toLocaleString → full date + time.
    return .{ .normal = .{ .string = try formatToString(it, t) } };
}

/// §21.4.4.45 Date.prototype[Symbol.toPrimitive](hint).
fn toPrimitive(it: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object) return it.throwError("TypeError", "Date.prototype[Symbol.toPrimitive] called on a non-object");
    const hint: Value = if (args.len > 0) args[0] else .undefined;
    if (hint != .string) return it.throwError("TypeError", "Date.prototype[Symbol.toPrimitive]: invalid hint");
    const h = hint.string;
    // §21.4.4.45: "string"/"default" → OrdinaryToPrimitive(string); "number" → ...(number). Call
    // OrdinaryToPrimitive DIRECTLY (NOT it.toPrimitive, which would re-dispatch to THIS method via
    // the @@toPrimitive lookup → infinite recursion). OrdinaryToPrimitive only tries toString/valueOf.
    if (std.mem.eql(u8, h, "string") or std.mem.eql(u8, h, "default")) {
        return interp_ops.ordinaryToPrimitive(it, this_val.object, .string);
    }
    if (std.mem.eql(u8, h, "number")) {
        return interp_ops.ordinaryToPrimitive(it, this_val.object, .number);
    }
    return it.throwError("TypeError", "Date.prototype[Symbol.toPrimitive]: invalid hint");
}

// ── String formatting ───────────────────────────────────────────────────────────────────────

const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// Format the year with a sign for ISO extended years (§21.4.1.33 — 6 digits for |y| ≥ 10000).
fn isoYear(arena: std.mem.Allocator, y: f64) ![]const u8 {
    const yi: i64 = @intFromFloat(y);
    if (yi >= 0 and yi <= 9999) return std.fmt.allocPrint(arena, "{d:0>4}", .{@as(u64, @intCast(yi))});
    const sign: u8 = if (yi < 0) '-' else '+';
    const mag: u64 = @intCast(if (yi < 0) -yi else yi);
    return std.fmt.allocPrint(arena, "{c}{d:0>6}", .{ sign, mag });
}

/// §21.4.4.36 the ISO 8601 form `YYYY-MM-DDTHH:mm:ss.sssZ`.
fn formatISO(it: *Interpreter, t: f64) ![]const u8 {
    const yr = try isoYear(it.arena, yearFromTime(t));
    return std.fmt.allocPrint(it.arena, "{s}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        yr,
        @as(u64, @intFromFloat(monthFromTime(t))) + 1,
        @as(u64, @intFromFloat(dateFromTime(t))),
        @as(u64, @intFromFloat(hourFromTime(t))),
        @as(u64, @intFromFloat(minFromTime(t))),
        @as(u64, @intFromFloat(secFromTime(t))),
        @as(u64, @intFromFloat(msFromTime(t))),
    });
}

/// Format the year for toString/toUTCString — at least 4 digits, zero-padded, with a leading `-`
/// for a negative year. (Zig's `{d:0>4}` on a SIGNED int emits a spurious `+` sign, so we format the
/// magnitude as unsigned and prepend the sign ourselves.)
fn yearStr(arena: std.mem.Allocator, y: f64) ![]const u8 {
    const yi: i64 = @intFromFloat(y);
    if (yi < 0) return std.fmt.allocPrint(arena, "-{d:0>4}", .{@as(u64, @intCast(-yi))});
    return std.fmt.allocPrint(arena, "{d:0>4}", .{@as(u64, @intCast(yi))});
}

/// §21.4.4.3 toDateString form `Www Mmm DD YYYY`.
fn formatDate(it: *Interpreter, t: f64) ![]const u8 {
    return std.fmt.allocPrint(it.arena, "{s} {s} {d:0>2} {s}", .{
        day_names[@as(usize, @intFromFloat(weekDay(t)))],
        month_names[@as(usize, @intFromFloat(monthFromTime(t)))],
        @as(u64, @intFromFloat(dateFromTime(t))),
        try yearStr(it.arena, yearFromTime(t)),
    });
}

/// §21.4.4.42 toTimeString form `HH:mm:ss GMT+0000 (Coordinated Universal Time)`.
fn formatTime(it: *Interpreter, t: f64) ![]const u8 {
    return std.fmt.allocPrint(it.arena, "{d:0>2}:{d:0>2}:{d:0>2} GMT+0000 (Coordinated Universal Time)", .{
        @as(u64, @intFromFloat(hourFromTime(t))),
        @as(u64, @intFromFloat(minFromTime(t))),
        @as(u64, @intFromFloat(secFromTime(t))),
    });
}

/// §21.4.4.41 toString form `Www Mmm DD YYYY HH:mm:ss GMT+0000 (Coordinated Universal Time)`.
fn formatToString(it: *Interpreter, t: f64) ![]const u8 {
    if (std.math.isNan(t)) return "Invalid Date";
    const d = try formatDate(it, t);
    const tm = try formatTime(it, t);
    return std.fmt.allocPrint(it.arena, "{s} {s}", .{ d, tm });
}

/// §21.4.4.43 toUTCString form `Www, DD Mmm YYYY HH:mm:ss GMT`.
fn formatUTC(it: *Interpreter, t: f64) ![]const u8 {
    return std.fmt.allocPrint(it.arena, "{s}, {d:0>2} {s} {s} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        day_names[@as(usize, @intFromFloat(weekDay(t)))],
        @as(u64, @intFromFloat(dateFromTime(t))),
        month_names[@as(usize, @intFromFloat(monthFromTime(t)))],
        try yearStr(it.arena, yearFromTime(t)),
        @as(u64, @intFromFloat(hourFromTime(t))),
        @as(u64, @intFromFloat(minFromTime(t))),
        @as(u64, @intFromFloat(secFromTime(t))),
    });
}

// ── §21.4.3.2 Date.parse — the Date Time String Format (§21.4.1.33) + a tolerant fallback ──────

/// Parse a date string to a time value (ms since epoch), or NaN if unparsable. Supports the
/// ECMAScript Date Time String Format (`YYYY`, `YYYY-MM`, `YYYY-MM-DD`, optionally `THH:mm`,
/// `:ss`, `.sss`, and a `Z` / `±HH:mm` zone). All times are treated as UTC (== local here); a
/// date-only form is UTC midnight, a date-time form with no zone is local (== UTC).
fn parseDateString(s: []const u8) f64 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    if (parseISO(trimmed)) |t| return t;
    // Fallback: the engine's own `toString` / `toUTCString` output (so `Date.parse(d.toString())`
    // round-trips). Implementation-defined per §21.4.3.2, but expected to round-trip our own forms.
    if (parseNonISO(trimmed)) |t| return t;
    return std.math.nan(f64);
}

/// Look up a 3-letter month/day abbreviation (case-sensitive, matching our output). Returns the
/// 0-based month index, or null.
fn monthIndex(abbr: []const u8) ?usize {
    for (month_names, 0..) |m, i| if (std.mem.eql(u8, m, abbr)) return i;
    return null;
}

/// Parse the engine's `toString` (`Www Mmm DD YYYY HH:mm:ss GMT+0000 (...)`) and `toUTCString`
/// (`Www, DD Mmm YYYY HH:mm:ss GMT`) output forms. Tokenizes on spaces/commas; recognizes a month
/// abbreviation to disambiguate the two field orders. Returns the time value, or null if unrecognized.
fn parseNonISO(s: []const u8) ?f64 {
    // SAFETY: only slots `[0, n)` are read below, and each is written before `n` is incremented.
    var toks: [12][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, s, " ,");
    while (it.next()) |tok| {
        if (n >= toks.len) break;
        toks[n] = tok;
        n += 1;
    }
    if (n < 5) return null;

    // toUTCString: `Www, DD Mmm YYYY HH:mm:ss GMT`. Detect by a month abbreviation in slot 2; the
    // toString form `Www Mmm DD YYYY HH:mm:ss GMT+0000 (...)` has the month in slot 1.
    const parsed: struct { month: usize, dayv: i64, year: i64, time: []const u8 } =
        if (monthIndex(toks[2])) |m| .{
            .month = m,
            .dayv = std.fmt.parseInt(i64, toks[1], 10) catch return null,
            .year = std.fmt.parseInt(i64, toks[3], 10) catch return null,
            .time = if (n > 4) toks[4] else "00:00:00",
        } else if (monthIndex(toks[1])) |m| .{
            .month = m,
            .dayv = std.fmt.parseInt(i64, toks[2], 10) catch return null,
            .year = std.fmt.parseInt(i64, toks[3], 10) catch return null,
            .time = if (n > 4) toks[4] else "00:00:00",
        } else return null;
    const month = parsed.month;
    const dayv = parsed.dayv;
    const year = parsed.year;

    // Time `HH:mm:ss`.
    var hh: i64 = 0;
    var mm: i64 = 0;
    var ss: i64 = 0;
    var tp = std.mem.splitScalar(u8, parsed.time, ':');
    if (tp.next()) |h| hh = std.fmt.parseInt(i64, h, 10) catch return null;
    if (tp.next()) |m| mm = std.fmt.parseInt(i64, m, 10) catch return null;
    if (tp.next()) |sec| ss = std.fmt.parseInt(i64, sec, 10) catch return null;

    const t = makeDate(
        makeDay(@floatFromInt(year), @floatFromInt(@as(i64, @intCast(month))), @floatFromInt(dayv)),
        makeTime(@floatFromInt(hh), @floatFromInt(mm), @floatFromInt(ss), 0),
    );
    return timeClip(t);
}

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn peek(p: *Parser) ?u8 {
        return if (p.i < p.s.len) p.s[p.i] else null;
    }
    fn eat(p: *Parser, c: u8) bool {
        if (p.i < p.s.len and p.s[p.i] == c) {
            p.i += 1;
            return true;
        }
        return false;
    }
    /// Read exactly `n` digits into an integer; null on shortfall / non-digit.
    fn digits(p: *Parser, n: usize) ?i64 {
        if (p.i + n > p.s.len) return null;
        var v: i64 = 0;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const c = p.s[p.i + k];
            if (c < '0' or c > '9') return null;
            v = v * 10 + (c - '0');
        }
        p.i += n;
        return v;
    }
};

fn parseISO(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    var p = Parser{ .s = s };

    // Year — optional sign + 6 digits (extended), or 4 digits.
    // SAFETY: assigned on both branches below (signed-extended / 4-digit) before any read.
    var year: i64 = undefined;
    if (p.peek() == '+' or p.peek() == '-') {
        const neg = p.s[p.i] == '-';
        p.i += 1;
        const y = p.digits(6) orelse return null;
        // §21.4.1.33: `-000000` (negative extended year zero) is NOT a valid representation — year 0
        // must be written `+000000`. Reject it.
        if (neg and y == 0) return null;
        year = if (neg) -y else y;
    } else {
        year = p.digits(4) orelse return null;
    }

    var month: i64 = 1;
    var dayv: i64 = 1;
    var hour: i64 = 0;
    var minute: i64 = 0;
    var second: i64 = 0;
    var milli: i64 = 0;
    var has_time = false;
    var tz_offset_min: ?i64 = null; // null = no zone given

    if (p.eat('-')) {
        month = p.digits(2) orelse return null;
        if (p.eat('-')) {
            dayv = p.digits(2) orelse return null;
        }
    }

    if (p.peek() == 'T' or p.peek() == ' ') {
        p.i += 1;
        has_time = true;
        hour = p.digits(2) orelse return null;
        if (!p.eat(':')) return null;
        minute = p.digits(2) orelse return null;
        if (p.eat(':')) {
            second = p.digits(2) orelse return null;
            if (p.eat('.')) {
                // Fractional seconds — take up to 3 digits (ms), ignore extra.
                var frac: i64 = 0;
                var count: usize = 0;
                while (p.peek()) |c| {
                    if (c < '0' or c > '9') break;
                    if (count < 3) frac = frac * 10 + (c - '0');
                    count += 1;
                    p.i += 1;
                }
                if (count == 0) return null;
                while (count < 3) : (count += 1) frac *= 10;
                milli = frac;
            }
        }
        // Optional zone.
        if (p.eat('Z')) {
            tz_offset_min = 0;
        } else if (p.peek() == '+' or p.peek() == '-') {
            const neg = p.s[p.i] == '-';
            p.i += 1;
            const zh = p.digits(2) orelse return null;
            _ = p.eat(':');
            const zm = p.digits(2) orelse return null;
            const off = zh * 60 + zm;
            tz_offset_min = if (neg) -off else off;
        }
    }

    // Any trailing characters → not a valid ISO string.
    if (p.i != p.s.len) return null;

    // Range validation (months 1..12, day 1..31, etc.) — out of range → NaN (don't normalize).
    if (month < 1 or month > 12) return null;
    if (dayv < 1 or dayv > 31) return null;
    if (hour > 24 or minute > 59 or second > 59) return null;
    if (hour == 24 and (minute != 0 or second != 0 or milli != 0)) return null;

    const t = makeDate(
        makeDay(@floatFromInt(year), @floatFromInt(month - 1), @floatFromInt(dayv)),
        makeTime(@floatFromInt(hour), @floatFromInt(minute), @floatFromInt(second), @floatFromInt(milli)),
    );
    // Apply the zone offset: a `+HH:mm` zone means local is ahead of UTC, so subtract to reach UTC.
    const adjusted = if (tz_offset_min) |off| t - @as(f64, @floatFromInt(off)) * ms_per_minute else t;
    return timeClip(adjusted);
}
