<!--
Sync Impact Report
- Version change: 1.0.0 → 1.1.0
- Modified principles:
  - IV. "Correctness Before Performance" → "Performance Is Measured From Day One
    (Correctness Still Leads)" — perf elevated to a first-class, continuously-measured
    concern benchmarked against Node.js/V8 from the first runnable build; adds a perf
    no-regression gate peer to the conformance gate.
- Added/expanded sections:
  - Technology & Architecture Constraints: benchmark-gated tier graduation; Node baseline.
  - Development Workflow & Quality Gates: new gate 5 (perf no-regression + Node-ratio recorded).
- Removed sections: none
- Templates requiring updates:
  - ✅ .specify/templates/plan-template.md (Constitution Check gate now also covers perf)
  - ✅ .specify/templates/spec-template.md (no mandatory-section conflict)
  - ✅ .specify/templates/tasks-template.md (benchmark task type fits existing categories)
- Downstream artifacts updated for this amendment:
  - ✅ specs/001-test262-harness/spec.md (added US4 benchmark, FR-014..016, SC-007..009)
  - ✅ specs/001-test262-harness/plan.md, research.md (D10), tasks.md (benchmark tasks)
- Deferred TODOs: none
-->

# ljs Constitution

ljs is a JavaScript engine (an ECMA-262 implementation) written from scratch in Zig,
in the spirit of V8 but optimized for correctness and spec-traceability first. This
constitution governs how the engine is built. It is binding on every spec, plan, task,
and commit.

## Core Principles

### I. The Specification Is the Source of Truth
ECMA-262 (and, where in scope, ECMA-402) is the single normative authority for all
observable behavior. When code and intuition disagree with the spec, the spec wins.
Every implemented operation MUST correspond to a concrete spec construct — an abstract
operation, a grammar production's runtime semantics, an internal method, or a built-in
algorithm. "Looks right" is never sufficient justification; a clause reference is.
**Rationale:** a JS engine's only job is to be indistinguishable from the spec; ad-hoc
behavior is a bug even when it appears to work.

### II. Conformance Is the Acceptance Gate (NON-NEGOTIABLE)
Test262 is the acceptance test suite. A feature is "done" only when its corresponding
Test262 directory passes in BOTH strict and sloppy mode, each test in a fresh realm, per
INTERPRETING.md. The overall Test262 pass count on the main branch MUST be monotonic
non-decreasing: no change may regress a previously passing test (a documented, justified
exception requires a constitution-compliant waiver in the PR). Test262 is vendored at a
pinned commit; bumping it is an explicit, reviewed change.
**Rationale:** an objective, externally-owned conformance metric prevents self-deception
and makes "progress" measurable rather than asserted.

### III. Spec Traceability in Code
Implementation structure MUST mirror the spec's structure: one function per abstract
operation, evaluation organized by grammar production, internal methods named as in the
spec ([[Get]], [[Call]], …). Each non-trivial algorithm MUST carry an inline comment
citing its spec clause (e.g. `// 7.1.4 ToNumber ( argument )`) and SHOULD annotate the
step it implements. Completion Records, Reference Records, and Property Descriptors are
modeled as first-class types, not flattened away.
**Rationale:** spec-shaped code is reviewable against the spec, survives spec updates,
and is the discipline that lets a from-scratch engine reach high conformance.

### IV. Performance Is Measured From Day One (Correctness Still Leads)
Performance is a first-class, continuously-measured concern — never a deferred phase. From the
first runnable build, ljs MUST be benchmarked against Node.js (V8) on a shared benchmark set,
and the ljs-vs-Node ratio MUST be recorded on every run. Correctness still leads: no
optimization may be merged that reduces Test262 conformance or removes a spec-mandated
observable behavior (side-effect ordering, coercion edge cases). The execution architecture
starts as a tree-walking interpreter; a bytecode VM and optimizing/JIT tiers are introduced
when the **benchmark data — not guesswork — justifies them**. ljs performance MUST NOT regress
against its own previously recorded baseline (a perf no-regression gate, peer to the
conformance gate); the absolute gap to Node is reported and tracked but is not itself a hard
failure at this stage.
**Rationale:** discovering the performance gap only after the engine is "done" makes it
unfixable without a rewrite. Measuring against V8 from day one keeps every decision honest,
prevents silent perf rot, and lets data — not dogma — decide when to graduate execution tiers.
A from-scratch tree-walker will be far slower than V8 at first; the point is to *see and
control* that gap continuously, not to pretend it away or defer it.

### V. Incremental, Milestone-Gated Delivery
Work proceeds in small, independently verifiable milestones, each gated by a defined
Test262 subset (e.g. lexer/parser → expressions → objects → functions → built-ins).
Every change ships with the tests that prove it and leaves the build green. The harness
(a Test262 runner with a pass/fail signal) is built before the features it measures.
**Rationale:** a JS engine is too large to validate at the end; continuous, subset-scoped
verification is the only way to keep a from-scratch effort honest.

## Technology & Architecture Constraints

- **Language:** Zig (pinned toolchain version recorded in the repo). Implementation is
  pure Zig from scratch; third-party libraries are permitted only for genuinely
  out-of-scope concerns (e.g. Unicode tables, regex, ICU/Temporal) and MUST be declared
  in the plan.
- **Memory:** explicit, allocator-based ownership; no leaks in the test harness; no
  undefined behavior. A garbage collector is introduced as a deliberate, planned
  subsystem, not improvised.
- **Target spec edition:** a specific ECMA-262 edition/draft is pinned per the plan and
  recorded alongside the pinned Test262 commit.
- **Scope — 100% ECMAScript, no host APIs:** the conformance target is the ECMAScript
  *language* and standard built-in *library* in full — exactly Test262's `test/language/` and
  `test/built-ins/` (conformance is tracked over the whole `language/` tree, not just
  `language/expressions`). Node/host runtime surfaces are **out of scope**: CommonJS
  `require` / module loading, ESM host loading, `fs` / `http` / `net` / `process` / `Buffer`,
  and host timers (`setTimeout` / `setInterval`). Promises and the microtask / Job queue ARE
  in scope (they are ECMA-262, not host). When the only remaining conformance work would be a
  Node host API, stop — it is out of scope by definition.
- **Architecture order:** tree-walk interpreter → bytecode VM → (optional) optimizing
  tier. Each tier is a separate, planned milestone, and **graduating to the next tier is
  gated by benchmark data** (Principle IV), not by a fixed schedule.
- **Performance baseline:** Node.js (V8) is the reference engine. A shared benchmark set runs
  both ljs and Node every measurement run; results are recorded with the engine build and the
  pinned Test262 commit.
- **Determinism:** given the same input, the engine produces spec-identical observable
  output; no reliance on undefined ordering or platform-specific behavior. (Benchmarks measure
  wall-clock time and are reported separately from the deterministic correctness signal.)

## Development Workflow & Quality Gates

- **Spec-Driven flow:** every feature follows constitution → `/speckit-specify` →
  (optional `/speckit-clarify`) → `/speckit-plan` → `/speckit-tasks` →
  (optional `/speckit-analyze`) → `/speckit-implement`. Specs describe *what/why*
  (observable behavior + spec clauses); plans choose *how* (Zig data structures, tiers).
- **Quality gates (all MUST pass to merge):**
  1. Build is green on the pinned Zig toolchain, and `zig build fmt-check` passes
     (`zig build lint` additionally runs ZLint when installed).
  2. No Test262 regression; new feature's Test262 subset passes (strict + sloppy).
  3. New/changed algorithms carry spec-clause citations (Principle III).
  4. No undefined behavior; no leaks in the harness.
  5. No performance regression vs the recorded ljs baseline; the ljs-vs-Node ratio is
     recorded for the run (Principle IV). The gap to Node is reported, not hard-failed.
- **Conformance & performance tracking:** the current Test262 pass rate AND the ljs-vs-Node
  benchmark ratios are recorded and reported per milestone. Conformance trends up-and-to-the
  right or the change is rejected; ljs perf must not regress against its own baseline.

## Governance

This constitution supersedes ad-hoc practice. Amendments are made by editing this file
via `/speckit-constitution`, which MUST include a Sync Impact Report and propagate
changes to dependent templates (plan, spec, tasks).

Versioning follows semantic versioning for governance:
- **MAJOR:** backward-incompatible removal or redefinition of a principle.
- **MINOR:** a new principle or materially expanded guidance.
- **PATCH:** clarifications and wording that do not change obligations.

Compliance: every plan includes a Constitution Check; every PR/review verifies the
quality gates above. Complexity that violates a principle MUST be justified in the plan's
Complexity Tracking section or be removed. When this document and a downstream artifact
conflict, this document governs until formally amended.

**Version**: 1.1.0 | **Ratified**: 2026-06-15 | **Last Amended**: 2026-06-15
