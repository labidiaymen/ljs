# ljs autonomous loop prompt

Paste the block below into a fresh Claude Code session (run from `~/ljs`) to resume the
conformance-driving loop. Keep the **CURRENT STATE** section updated as milestones land so the
loop doesn't chase stale guidance.

---

```
You are working on ljs, a JavaScript engine in Zig at ~/ljs, driving Test262/ECMAScript
conformance toward 100%. This is an autonomous feature loop — run it on the main thread,
no subagents. Don't stop the loop until 100%.

SETUP (first time on this machine): if vendor/test262 is missing, run `zig build vendor` once.

METHOD — Spec-Driven Development, one feature per gated commit:
1. Find the next-highest-leverage gap: run the Test262 runner on a target dir, read the
   failures, pick ONE coherent feature.
2. Implement it (cite ECMA-262 clauses inline, match surrounding code style).
3. Pass the FULL gate before committing — every step must be green:
   - zig build
   - zig build test
   - zig build lint            (zlint --deny-warnings + zig fmt --check)
   - conformance UP on the target dir, and NO regression vs baseline:
     ./zig-out/bin/ljs-test262 --path vendor/test262/test/language \
       --harness-dir vendor/test262/harness --baseline baseline/language.json
   - zig build bench  → must print "perf: ok" (±15%; str_build.js is known noise,
     re-run once if it flaps).
4. Commit, then push.

RUNNER (note: summary prints at the TOP of output; many failures are parse_error):
  ./zig-out/bin/ljs-test262 --path vendor/test262/test/<dir> --harness-dir vendor/test262/harness

GIT: author `Aymen <labidi@aymen.co>`. NO "Generated with Claude Code", NO Co-Authored-By.
Commit to main (authorized) and push. Commit style: "M<NN>: <feature> — <dir> X%->Y%".

SCOPE (hard constraints — do not implement these):
- NO Node/host APIs: require, ESM host loading, fs/http/net/process/Buffer, host timers.
- Promises/microtasks are IN scope; the event loop is deferred.
- dynamic import() is out of scope by design (don't chase those ~1100 failures).
- Strings are UTF-8 bytes (documented deviation); the regex engine matches byte-by-byte.

CURRENT STATE: last commit is M61 (RegExp matcher: exec/test via builtin_regexp_engine.zig,
iterative backtracking VM). The next big lever is RE-ENABLING REGEX LITERALS at the lexer —
they're dormant (the .regex TokenKind/ast/parser/eval paths exist but lexer scanning is
disabled). The engine now validates patterns, so enabling literals should NOT regress
language/ the way M60 did. After literals: RegExp Symbol.match/replace/search/split +
String.prototype match/matchAll/replace/replaceAll/search/split integration.

Begin by checking out the state (git log, run the RegExp + language dirs) and pick the next feature.
```
