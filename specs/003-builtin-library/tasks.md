---
description: "Task list for M2 — core built-in library"
---

# Tasks: M2 — Core Built-in Library

**Cadence**: one cycle = one user story = one commit (build + test + lint + **bench (ljs ≤ Node)**
green, then commit). Conformance-driven: re-measure `language/expressions` each cycle.

## Cycle 1 — US1 Arrays (P1) 🎯
- [x] M2-T010 [US1] Array literal `[a, b, ...]` (parser + ast) + `array` Object kind backed by an element list
- [x] M2-T011 [US1] Array index get/set routes to the element list; live `.length` (read + truncate/extend); array `toString`/display = join
- [x] M2-T012 [US1] `Array.prototype` natives: `push`/`pop`/`indexOf`/`includes`/`join`/`slice`/`forEach`/`map`; `Array` global + `Array.isArray`; literals proto-link to Array.prototype
- [x] M2-T013 [P] [US1] array tests (14, inline). Note: `language/expressions` ~flat (3960) — arrays pay off in `built-ins/Array` (Cycle close). Bench green (ljs 0.2–0.5× Node).

## Refactor (between Cycle 1 and 2) ✅
- [x] M2-R01 Extract `src/abstract_ops.zig` (ECMA-262 §7.1/§7.2 ops) + `src/builtin_array.zig` (Array.prototype bodies); interpreter.zig 836→634 lines, now evaluator+dispatch. Behavior-preserving (23.3% unchanged, bench green). Sets up per-file built-ins → Cycles 2–4 land as siblings + parallelizable.

## Cycle 2 — US2 Strings (P1)
- [x] M2-T020 [US2] Transparent string boxing in `getProperty` (`.length`, integer index, method lookup via String.prototype) — no heap wrapper; `stringProto` helper
- [x] M2-T021 [US2] `builtin_string.zig` natives: `charAt`/`charCodeAt`/`indexOf`/`includes`/`slice`/`substring`/`toUpperCase`/`toLowerCase`/`split` (byte-oriented; full Unicode deferred)
- [x] M2-T022 [P] [US2] string tests (11, inline). Note: `language/expressions` plateaued at 23.3% — those failures need other features; strings/arrays pay off in `built-ins/*` → measure at close (SC-003). Bench green (ljs ≤ Node).

## Cycles 3–4 — Object statics + Number/Math — DEFERRED (conformance-driven pivot)
> Diagnostic at Cycle-2 close: `language/expressions` fails are **10,763 parse_error** vs only
> **1,817 unexpected_error**. Object/Math built-ins attack the small bucket → **deferred** in
> favor of **M3 (parser/syntax coverage)**, which attacks the 6× larger parse_error bucket.
> Revisit Object/Math after syntax (they still help `built-ins/*` + the unexpected_error bucket).
- [ ] M2-T030 [US3] (deferred) `Object.keys`/`create`/`getPrototypeOf`/`assign`/`defineProperty`/`hasOwnProperty`
- [ ] M2-T040 [US4] (deferred) `Math` + `Number` + numeric globals

## Close
- [ ] M2-T050 Record new conformance baseline (`language/expressions` + `built-ins/Array`+`/String` slices, SC-002/003); README/roadmap; bench green; no M1 regression (27/6/2)

## Dependencies
Cycle 1 (arrays) first — biggest unblock + arrays underpin many tests. Then strings, objects,
math. Each cycle bench-gated (ljs ≤ Node) before commit.
