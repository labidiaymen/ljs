---
description: "Task list for the UTF-16 strings EPIC (068) — phased; M80 = Phase 1"
---
# Tasks: UTF-16 strings (§6.1.4) — phased epic

## Phase 1 (M80) — char-access family
- [x] T010 `src/string_utf16.zig`: isAscii / utf16Length / codeUnitAt / code-unit↔byte mapping,
  with the ASCII fast path. Unit-verify é / 😀 / lone-surrogate / astral.
- [x] T020 `.length` reads (interpreter.zig wrapper + primitive) → utf16Length.
- [x] T030 string `[index]` access + for-in char boxing → code-unit semantics.
- [x] T040 builtin_string `charCodeAt` / `charAt` / `at` → code-unit semantics.
- [x] T050 Local repros: SC-003 cases pass; ASCII strings unchanged.
- [x] T060 FULL gate: build/test/lint green; language 39116 = 89.6%, +8, 0 regressions; bench ok. (engine_tests astral-length updated; charCodeAt/codePointAt NaN/Inf guards added.)

## Phase 2 (M81) — escapes + fromCharCode/fromCodePoint — DONE (+0 language, +2 built-ins/String, 0 regr)
- [x] canonicalizeSurrogates helper (combine adjacent surrogate-pair WTF-8 → astral 4-byte).
- [x] String.fromCharCode / fromCodePoint apply it; lexer string-literal escapes apply it.

## Phase 3 (M84) — substring family — DONE
- [x] string_utf16 helpers: byteIndex / codeUnitIndex / substringByCodeUnits (re-canonicalizes
  whole surrogate pairs back to astral; ASCII fast path).
- [x] builtin_string slice / substring / substr → code-unit indices.

## Later phases (M85+): see spec.md
