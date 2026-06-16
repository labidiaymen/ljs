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

## Git / commits
- Do **not** add a `Co-Authored-By: Claude` (or any Claude/Anthropic) trailer to commit messages.
- Do **not** set Claude/Anthropic as the commit author — commits are authored by the user.
- No "Generated with Claude Code" or similar attribution in commit messages or PR descriptions.

## Autonomous implementation loop
Drive `specs/001-test262-harness/tasks.md` in priority order, one **cycle** at a time:
1. **Implement** the next coherent increment (a user story / phase, or a self-contained task
   group) end to end. Make reasonable design calls autonomously — do NOT stop for per-step
   confirmation. Mark tasks `[x]` in `tasks.md` as they complete.
2. **Verify** before the gate: `zig build`, `zig build test`, and `zig build lint` all green,
   plus the relevant `quickstart.md` checks (for perf cycles, `zig build bench`).
3. **Commit gate (the ONLY stop):** present a short summary, the verification results, the
   diff stat, and the exact proposed commit message. Then wait.
4. On the user's validation → commit (author `Aymen <labidi@aymen.co>`, no Claude
   attribution) + push, then **immediately begin the next cycle** and run it to its gate.

Surface significant assumptions/decisions at the gate, not mid-cycle.

### Autonomous mode
When the user authorizes autonomous looping ("loop by yourself", "don't wait for me"), the
per-cycle commit gate is waived: **auto-commit + push every cycle** that passes `zig build` +
`zig build test` + `zig build lint` + **`zig build bench` (no ljs-vs-self perf regression)**.
**Bench is an absolute pre-commit gate**: run `zig build bench` immediately before EVERY
commit. If it shows any regression (or fails), you MUST fix it — the offending code or the
bench — BEFORE committing. Never, ever commit with a failing or regressed bench. Keep cycling through `tasks.md` until the milestone is done or the user
interrupts; record decisions in each commit message. Outside autonomous mode, never push
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
