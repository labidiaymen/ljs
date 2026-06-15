<!-- SPECKIT START -->
For additional context about technologies to be used, project structure,
shell commands, and other important information, read the current plan:
`specs/001-test262-harness/plan.md` (feature: M0 — Test262 harness & minimal eval).

Active stack: Zig 0.16.0 (pinned), pure std, tree-walk interpreter, in-process Test262 runner.
Constitution: `.specify/memory/constitution.md` — correctness/conformance before performance.
<!-- SPECKIT END -->

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

Surface significant assumptions/decisions at the gate, not mid-cycle. Never push without the
user's per-cycle validation.
