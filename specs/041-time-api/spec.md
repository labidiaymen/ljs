# Spec 041: time API

## Goal

Close the `time` half of the "time · http" Planned-table row:
`time.now()`, `time.monotonic()`. Pure timestamp reads on top of a proven
primitive already used elsewhere in the compiler (the same clock call backs
`fs.mkdtempSync`'s uniqueness suffix), no syscalls beyond one clock read,
portable to both native and wasm targets.

## API

| Function | Type | Notes |
| --- | --- | --- |
| `time.now()` | `() -> i64` | milliseconds since the Unix epoch (wall-clock/real time) |
| `time.monotonic()` | `() -> i64` | milliseconds from an arbitrary, consistent starting point -- never goes backwards, safe for measuring elapsed durations, unaffected by the system clock being changed |

## Design notes

- **Return type is `i64`, not `int`**: real-world epoch milliseconds
  (~1.7 * 10^12 as of this writing) hugely exceeds a 32-bit signed int's
  range (~2.1 * 10^9, about 24.8 days from epoch) -- truncating to `int`
  the way `os.totalmem()`/`freemem()` do wouldn't be an occasional
  deviation, it would make the result meaningless garbage for essentially
  every real call. `i64` (already a real, usable Lumen type -- the same
  one `httpGet`'s status code uses) avoids this entirely; the underlying
  nanosecond value safely fits until year ~2262, the same well-known
  boundary as a 64-bit-nanosecond Unix timestamp anywhere else.
- **`monotonic()` is for elapsed-time measurement, not wall-clock display**:
  its zero point is unspecified and not tied to 1970 -- only differences
  between two calls are meaningful (`time.monotonic() - startedAt`).
  Guaranteed non-decreasing across a program's run, unlike `now()`, which
  can jump backwards if the system clock is corrected.
- **A pre-existing, unrelated `i64` limitation hit while writing the
  verification program**: an `i64` value cannot be compared or used in
  arithmetic directly against an int literal (`time.now() > 1700000000000`
  and even `someI64Diff >= 0` both fail to type-check) -- int literals
  infer as 32-bit `int` and don't widen to `i64` automatically. Not new in
  this milestone or specific to `time`; routed around it in every example
  by keeping both sides of a comparison strictly `i64`.

## Not planned (this pass)

| Group | Needs |
| --- | --- |
| Date formatting / calendar breakdown (year, month, day, etc.) | a real, separate feature (calendar math), not just a clock read |
| `time.sleep(ms)` | a blocking wait; would need to decide whether it blocks the whole event loop or integrates with the async timer machinery, not attempted here |
| Higher-resolution (microsecond/nanosecond) return values | millisecond granularity matches every other stdlib timing value (`setTimeout`/`os.uptime()`) and covers the practical case |
