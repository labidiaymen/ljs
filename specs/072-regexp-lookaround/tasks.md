# Tasks 072 — RegExp lookaround

- [x] Histogram built-ins/RegExp failures; identify lookaround (38 parse_errors) as the
      highest-leverage shared-root-cause cluster (excluding property-escapes).
- [x] Add `look` Inst variant + `Look` sub-program struct; add `look` NodeTag and `behind` field.
- [x] `parseGroup`: parse `(?=`, `(?!`, `(?<=`, `(?<!` into lookaround nodes; keep `(?<name>`.
- [x] Compiler: `reverse` flag; reverse `concat` order and swap group save order under reverse;
      `compileLook` emits a self-contained body sub-program.
- [x] VM: refactor `matchAt` loop into direction-aware `run`; share captures/steps via `Ctx`;
      handle `look` recursively (positive keeps captures, negative restores; snapshot undo).
- [x] Static semantics: reject quantifier on lookbehind (always) and on lookahead in UnicodeMode.
- [x] Verify with minimal `exec`/`test` repros (lookahead, lookbehind, greedy captures, nested,
      negative, quantified-lookaround SyntaxError).
- [x] Gates: `zig build`, `zig build test`, `zig build lint`, `zig build bench` all green;
      language baseline RC=0 (0 regressions); built-ins/RegExp 1626→1666 (+40).
