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
- [ ] M2-T020 [US2] Primitive boxing in `getProperty` for strings (and numbers) → method/`.length` lookup without a heap wrapper
- [ ] M2-T021 [US2] `String.prototype` natives: `charAt`, `charCodeAt`, `indexOf`, `includes`, `slice`, `substring`, `toUpperCase`, `toLowerCase`, `split`; string `.length` + index
- [ ] M2-T022 [P] [US2] string tests + re-measure

## Cycle 3 — US3 Object statics (P2)
- [ ] M2-T030 [US3] `Object.keys`/`getOwnPropertyNames`/`create`/`getPrototypeOf`/`assign`/`defineProperty`; `Object.prototype.hasOwnProperty`
- [ ] M2-T031 [P] [US3] object tests + re-measure

## Cycle 4 — US4 Number/Math/globals (P2)
- [ ] M2-T040 [US4] `Math` (floor/ceil/abs/max/min/pow/sqrt/round/…), `Number` (isNaN/isFinite/isInteger/parseInt/parseFloat), globals `NaN`/`Infinity`/`isNaN`/`isFinite`/`parseInt`/`parseFloat`
- [ ] M2-T041 [P] [US4] number/math tests + re-measure

## Close
- [ ] M2-T050 Record new conformance baseline (`language/expressions` + `built-ins/Array`+`/String` slices, SC-002/003); README/roadmap; bench green; no M1 regression (27/6/2)

## Dependencies
Cycle 1 (arrays) first — biggest unblock + arrays underpin many tests. Then strings, objects,
math. Each cycle bench-gated (ljs ≤ Node) before commit.
