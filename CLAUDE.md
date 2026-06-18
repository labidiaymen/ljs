<!-- SPECKIT START -->
For additional context about technologies to be used, project structure,
shell commands, and other important information, read the current plan:
`specs/004-parser-syntax/` (active: M3 — parser/syntax coverage, conformance-driven). Done: M0
(`001-test262-harness`), M1 core language (`002-core-language`), M2 arrays+strings (`003-builtin-library`;
Object/Math deferred per the parse_error diagnostic). Real conformance: 23.3% of `language/expressions`.

Active stack: Zig 0.16.0 (pinned), pure std, tree-walk interpreter, in-process Test262 runner.
Constitution: `.specify/memory/constitution.md` — correctness/conformance before performance.
<!-- SPECKIT END -->

## Scope — 100% ECMAScript, NO Node host APIs
- **Goal:** 100% **ECMAScript** conformance — the JS *language* plus the standard built-in
  *library*, i.e. exactly what Test262 covers under `test/language/` and `test/built-ins/`.
  Conformance is tracked over the full `language/` tree (no longer just `language/expressions`).
- **Explicitly out of scope — Node host APIs.** ljs does **NOT** implement any Node/host
  runtime surface: CommonJS `require` / module loading, ESM host module loading, `fs` / `http` /
  `net` / `process` / `Buffer`, and host timers (`setTimeout` / `setInterval`). These are host
  embeddings, not ECMA-262.
- **In scope (it's ECMAScript):** Promises and the microtask / Job queue (`Promise`, `await`,
  Job scheduling) — these are defined by ECMA-262, not the host. Host *timers* are not.
- **Stop rule:** when the only remaining work to advance conformance would be implementing a
  Node host API, **stop** — that is by definition out of scope.

### Scope expansion (2026-06-17, user-authorized — to break past the ~92-93% ceiling)
- **UTF-16 string semantics — IN SCOPE (always was; a documented deviation being corrected).**
  ECMA-262 strings are sequences of UTF-16 code units. ljs stores `[]const u8` and currently
  reports `length`/`charCodeAt`/indexing over BYTES (`"é".length === 2`). The fix is a phased epic
  (`specs/068-utf16-strings/`): treat the storage as WTF-8 (lone surrogates representable) with an
  ASCII fast path, and compute code-unit `length`/indexing/methods/escapes/iteration/regex on
  demand. No charter conflict — pure language conformance.
- **Module LANGUAGE part — IN SCOPE (ECMA-262 §16.2).** The ESM grammar (`import`/`export`
  declarations, early errors), module linking/evaluation semantics, and the `import()` dynamic
  ImportCall expression ARE ECMAScript. A **minimal test-harness module loader** (resolve a
  specifier to source by reading the referenced file relative to the test) is permitted to drive
  the Test262 module corpus — it is a test harness, NOT a general Node host API. General Node host
  APIs (`require`, `fs`/`http`/`net`/`process`/`Buffer`, host timers) remain OUT of scope.
  Sequencing: tackle UTF-16 first (no loader nuance, biggest scattered payoff), modules second.

## Git / commits
- Do **not** add a `Co-Authored-By: Claude` (or any Claude/Anthropic) trailer to commit messages.
- Do **not** set Claude/Anthropic as the commit author — commits are authored by the user.
- No "Generated with Claude Code" or similar attribution in commit messages or PR descriptions.

## Code organization — subsystem modules, NOT monoliths
The interpreter and parser are split into focused per-subsystem modules. `src/interpreter.zig`
and `src/parser.zig` are now THIN cores (struct definition, fields, `init`, top-level entry
points, named result types, and thin delegating wrappers). **Behavior lives in the subsystem
modules — add new code THERE, never by growing the core struct file.**
- **Where new behavior goes** (route by subsystem; check the file's doc-comment header):
  - interpreter: `interp_expr` (expressions/calls), `interp_stmt` (statements/loops/hoisting),
    `interp_ops` (operators/coercion), `interp_async` (promises/generators/async),
    `interp_native` (callNative dispatch, global fns), `interp_class`, `interp_property`,
    `interp_module`, `interp_iter`, `interp_destr`, `interp_collection`, `interp_arraylike`.
  - parser: `parse_expr`, `parse_stmt`, `parse_class`, `parse_pattern`, `parse_validate`
    (early errors / scope validation).
  - built-ins: the matching `builtin_*.zig`.
- **File-size budget: keep every source file under ~2000 lines (aim <1500).** When a file
  approaches the budget, SPLIT it as part of the same cycle using the delegation pattern below —
  do not let a monolith re-form. Adding a whole new subsystem? Start it in its own `*_<area>.zig`.
- **Delegation pattern (Zig 0.16 removed `usingnamespace`):** in the module write a free function
  `pub fn name(self: *Interpreter, …) Ret { …body… }`; in the core file keep a thin method
  `fn name(self: *Interpreter, …) Ret { return mod.name(self, …); }` so `self.name(…)` call sites
  are unchanged. Share types across files by promoting anonymous `union(enum)` returns to NAMED
  `pub` types in the core file; widen visibility (`pub`) only as needed.
- **Perf rule (learned the hard way):** a thin forwarder on a HOT recursive path (`evalStmt`,
  `evalExpr`, `evalBinary`, the recursive-descent `parse*`) MUST be `pub inline fn`, or the extra
  call layer regresses the bench (the interpreter split cost +14% on loop_mix until inlined). Keep
  tiny high-fan-in plumbing (`peek`/`advance`/`expect`) in the core file. Re-bench vs the pre-split
  commit after any extraction, since the ±15% gate can mask a real regression.
- **Layout:** flat `src/`, subsystem encoded by filename PREFIX (`interp_*`, `parse_*`,
  `builtin_*`). No directory nesting (Zig `@import` is relative-path; nesting buys `../` churn and
  zero compile benefit at this size). Revisit only past ~50–60 files, via named `build.zig` modules.

## Autonomous implementation loop — FULL Spec-Driven Development
Every milestone is one **cycle** and gets its OWN spec folder; do not skip the paper trail even
for a small fix. One **cycle** at a time:
0. **Spec first.** Create `specs/NNN-<slug>/` (next free NNN) seeded from `.specify/templates/`:
   - `spec.md` — User Scenarios with Given/When/Then acceptance derived from the failing
     Test262 cases, the governing ECMA-262 clause(s), in/out of scope, and success criteria
     (the expected conformance delta).
   - `plan.md` — implementation approach (files/functions touched, design calls, perf-hot-path
     risk), plus the Constitution Check (correctness-leads + the perf no-regression gate).
   - `tasks.md` — an ordered, checkable `- [ ]` task list.
1. **Implement** the tasks in order. Make reasonable design calls autonomously — do NOT stop for
   per-step confirmation. Mark tasks `[x]` in the cycle's `tasks.md` as they complete. (Discovery
   and gate EXECUTION may be delegated to subagents to keep main-thread context lean; INTEGRATION
   and the build gate stay sequential on the main thread.)
2. **Verify** before the gate: `zig build`, `zig build test`, and `zig build lint` all green,
   plus the relevant `quickstart.md` checks (for perf cycles, `zig build bench`). Use the FRESH
   runner exe (`ls -t .zig-cache/o/*/ljs-test262.exe | head -1`), never a stale alphabetical pick.
3. **Commit gate (the ONLY stop):** present a short summary, the verification results, the
   diff stat, and the exact proposed commit message. Then wait.
4. On the user's validation → set the spec folder's Status to **Done** with the measured
   conformance delta, then commit the **spec folder together with the code** (author
   `Aymen <labidi@aymen.co>`, no Claude attribution) + push, then **immediately begin the next
   cycle** and run it to its gate.

Surface significant assumptions/decisions at the gate, not mid-cycle. Each milestone's spec
folder (`spec.md`/`plan.md`/`tasks.md`) is part of its commit — the code and its paper trail
land together.

### Autonomous mode
When the user authorizes autonomous looping ("loop by yourself", "don't wait for me"), the
per-cycle commit gate is waived: **auto-commit + push every cycle** that passes `zig build` +
`zig build test` + `zig build lint` + **`zig build bench` (no ljs-vs-self perf regression)**.
**Bench is an absolute pre-commit gate**: run `zig build bench` immediately before EVERY
commit. If it shows any regression (or fails), you MUST fix it — the offending code or the
bench — BEFORE committing. Never, ever commit with a failing or regressed bench. Keep cycling through `tasks.md` until the milestone is done or the user
interrupts; record decisions in each commit message. **Put new behavior in the right subsystem
module (see "Code organization") — do not grow `interpreter.zig`/`parser.zig`; split any file
nearing ~2000 lines in the same cycle.** Outside autonomous mode, never push
without the user's per-cycle validation.

### Agent parallelism within a cycle
Delegate and parallelise where tasks are **independent**, but keep ONE integration point:
- **Fan out** (parallel sub-agents; worktree isolation if they write files) for independent
  leaf work — separate non-importing modules, fixtures/test data, research/design, docs.
- **Integrate + `zig build`/`test`/`lint`/`bench` SEQUENTIALLY** — a single compiling codebase
  has one build gate; never parallelise edits to the same file or interdependent files.
- **Parallel review** before the gate: fan out reviewer agents on the diff (correctness /
  spec-fidelity / Zig-idioms) and fold their findings.
Dependent chains (foundational → dependents) stay sequential. Prefer the Workflow tool to
orchestrate fan-out → integrate → review deterministically. Parallelism pays off most in large
cycles (e.g. M1's many independent built-ins); for small cycles, the overhead can exceed the
gain — use judgement.
