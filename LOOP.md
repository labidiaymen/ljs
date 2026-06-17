# ljs autonomous loop prompt

Paste the block below into a fresh Claude Code session (run from `~/ljs`) to resume the
conformance-driving loop. Keep the **CURRENT STATE** section updated as milestones land so the
loop doesn't chase stale guidance.

---

```
You are working on ljs, a JavaScript engine in Zig at ~/ljs, driving Test262/ECMAScript
conformance toward 100%. This is an autonomous feature loop. Don't stop the loop until 100%.

SETUP (first time on this machine): if vendor/test262 is missing, run `zig build vendor` once.

METHOD — FULL Spec-Driven Development, one feature per gated commit. Every milestone gets a
spec folder; no skipping the paper trail even for small fixes:
1. Find the next-highest-leverage gap: run the Test262 runner on a target dir, read the
   failures, pick ONE coherent feature. (Discovery and gate EXECUTION may be delegated to
   subagents to keep the main thread's context lean; INTEGRATION + the build gate stay on the
   main thread — one compiling codebase, one sequential gate.)
2. WRITE THE SPEC FIRST. Create `specs/NNN-<slug>/` (next free NNN) with three files, seeded
   from `.specify/templates/`:
   - `spec.md` — User Scenarios (Given/When/Then acceptance from the failing Test262 cases),
     the ECMA-262 clause(s), in/out of scope, success criteria (the expected conformance delta).
   - `plan.md` — the implementation approach: which files/functions change, the design calls,
     risks (esp. perf hot-path), and the Constitution Check (correctness-leads + perf gate).
   - `tasks.md` — an ordered, checkable task list (`- [ ]`). Mark each `[x]` as it lands.
3. Implement the tasks in order (cite ECMA-262 clauses inline, match surrounding code style),
   checking off `tasks.md` as you go.
4. Pass the FULL gate before committing — every step must be green:
   - zig build
   - zig build test
   - zig build lint            (zlint --deny-warnings + zig fmt --check)
   - conformance UP on the target dir, and NO regression vs baseline (use the FRESH runner —
     `ls -t .zig-cache/o/*/ljs-test262.exe | head -1`, NOT a stale alphabetical pick):
     ./zig-out/bin/ljs-test262 --path vendor/test262/test/language \
       --harness-dir vendor/test262/harness --baseline baseline/language.json
   - zig build bench  → must print "perf: ok" (±15%; str_build.js is known noise,
     re-run once if it flaps).
5. Update the spec folder's Status to Done with the measured delta; commit the spec folder
   TOGETHER WITH the code, then push.

Note on the baseline: `baseline/language.json` is a FIXED historical floor (a list of passing
test-ids) — the gate only enforces "0 regressions vs floor"; do NOT `--update-baseline` per
milestone. The headline % is computed from the live run (`passed/(total-skipped)`).

RUNNER (note: summary prints at the TOP of output; many failures are parse_error):
  ./zig-out/bin/ljs-test262 --path vendor/test262/test/<dir> --harness-dir vendor/test262/harness

GIT: author `Aymen <labidi@aymen.co>`. NO "Generated with Claude Code", NO Co-Authored-By.
Commit to main (authorized) and push. Commit style: "M<NN>: <feature> — <dir> X%->Y%".

SCOPE (hard constraints — do not implement these):
- NO Node/host APIs: require, ESM host loading, fs/http/net/process/Buffer, host timers.
- Promises/microtasks are IN scope; the event loop is deferred.
- dynamic import() is out of scope by design (don't chase those ~1100 failures).
- Strings are UTF-8 bytes (documented deviation); the regex engine matches byte-by-byte.

CURRENT STATE: last commit is M70 (for-in/of lexical duplicate binding-name early error),
language/ = 89.0%. IN PROGRESS: M71 `var` hoisting (specs/059-var-hoisting/) — `var` declared
inside a child scope (try/while/for/block) currently traps in that block env instead of hoisting
to the Function/Script VariableEnvironment; adding `Environment.is_var_scope` + `varScope()` + a
deep `hoistVarNames` pass + retargeting `var` writes. After M71: the async/Promise/microtask
family (~325 tests, also the Node bridge), then the class runtime-semantics long-tail. Target: 93%.

Begin by checking out the state (git log, run the language dirs) and continue the loop under FULL SDD.
```
