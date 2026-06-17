# Plan: UTF-16 strings — Phase 1 (char-access) — M80 / 068

## Phase 1 scope (this milestone)
New `src/string_utf16.zig`:
- `fn isAscii(s) bool` — no byte ≥ 0x80 (fast-path gate; can cache later).
- `fn utf16Length(s) usize` — code-unit count: decode WTF-8 code points; astral (cp ≥ 0x10000) = 2
  units, else 1. ASCII fast path returns `s.len`.
- `fn codeUnitAt(s, i) ?u16` — the i-th UTF-16 code unit (decompose astral → surrogates), or null
  if out of range. ASCII fast path: `s[i]`.
- helpers to map a code-unit index → byte offset (for charAt slicing).

Wire into:
- `interpreter.zig` string `.length` reads (~3251 wrapper, ~3279 primitive) → `utf16Length(s)`.
- string index access `s[i]` (the numeric-key path near ~3362) → `codeUnitAt` → a 1-code-unit
  string (WTF-8 of that unit).
- `builtin_string.zig` `charCodeAt` (→ `codeUnitAt`), `charAt`/`at` (→ 1-unit substring), and the
  bounds checks that currently use `s.len` for these.
- string for-in char-index boxing (`interpreter.zig` ~1013) → `utf16Length`.

NOT in Phase 1: slice/substring/indexOf/iteration/escapes/regex (later phases keep using bytes;
that's an acceptable interim inconsistency since the char-access tests are self-contained).

## Risks
MED — cross-cutting. Mitigate: ASCII fast path makes all-ASCII strings byte-identical to today (the
vast majority of tests + the perf benches), so regressions can only appear on non-ASCII tests
(currently mostly failing). Gate: full conformance 0-regression + bench. Verify the WTF-8 decode
against known cases (é, 😀, lone surrogate) before the gate.

## Constitution Check
Correctness leads (§6.1.4/§22.1) ✔; perf: ASCII fast path preserves hot-path O(1), bench-gated ✔.
