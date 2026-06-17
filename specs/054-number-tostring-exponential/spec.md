# M54 — Number::toString exponential notation (§6.1.6.1.20)

## Goal
Fix `numberToString` to render large/small magnitudes in EXPONENTIAL form per §6.1.6.1.20, matching the
spec everywhere a Number is stringified (`String(n)`, template literals, `Array.prototype.join`,
`JSON.stringify`, ToString-coercion of a numeric receiver, …).

## Diagnosis
`numberToString` delegated to Zig's `{d}` (shortest FIXED notation), so `String(1e21)` produced
`"1000000000000000000000"` instead of `"1e+21"`, and `String(1e-7)` would mis-render. Surfaced via
`String.prototype.trim.call(1e21)` (a generic-`this` test) expecting `"1e+21"` — String generic-`this`
coercion was already correct; the bug was the number formatting it fed into.

## Fix (targeted, low-risk)
The spec uses exponential form exactly when the magnitude is `≥ 1e21` (leading-digit decimal exponent
≥ 21) or `< 1e-6` (≤ -7) — precisely where `{d}` diverges. So only those magnitudes route to a new
`ecmaExponential` helper; the entire non-exponential range stays on `{d}` (shortest fixed, already
spec-matching) → common-case output is byte-for-byte unchanged (zero regression surface).
`ecmaExponential` takes Zig's shortest scientific form, trims the significand's trailing zeros, and
formats `d`/`d.ddd` + `e` + sign + |E| (E = leading-digit exponent, read directly from Zig's `{e}`).

## Gates
build / test / lint / no-regression / bench perf:ok.

## Result
Verified across ranges (1e21→`1e+21`, 1e-7→`1e-7`, 1.5e-8→`1.5e-8`, 0.000001→`0.000001`, 1e22→`1e+22`,
-1e21→`-1e+21`; 0.1/100/123.45/123456789 unchanged). String 1642→1670/2443 (67.2%→68.4%; +28 — the
large-number generic-`this` tests), language +4 (87.4%). No regression; bench perf:ok.
