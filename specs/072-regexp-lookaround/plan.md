# Plan 072 — RegExp lookaround

## Files touched
- `src/builtin_regexp_engine.zig` — the only code file. Parser, compiler, and VM changes.
- `src/builtin_regexp.zig` — none needed; `builtinExec` already extracts captures generically
  from the shared saves array, so named/positional captures inside lookaround surface for free.

## Approach

### Parser (`Parser.parseGroup`, `Parser.parseQuantifier`)
- `parseGroup`: when the `(?` prefix is followed by `=`/`!`, parse a lookahead; when followed
  by `<=`/`<!`, parse a lookbehind; the existing `<name>` branch stays for named groups. Each
  produces a `look` Node (`negated`, `behind`, `sub` = body Disjunction). Groups inside a
  lookaround keep their global capture indices (so captures are visible in the result).
- `parseQuantifier`: after confirming a real quantifier follows, reject it on a lookaround when
  the atom is a lookbehind (always) or a lookahead in UnicodeMode — matching the §22.2.1
  Term grammar (Assertion vs QuantifiableAssertion). A `{` that is not a valid quantifier
  remains a literal brace (Annex B), unaffected.

### Compiler (`Compiler.compileLook`, reverse flag)
- New `look` Inst holding a `*const Look` (a self-contained sub-program: its own instruction
  slice ending in `match`, its own counter count, and a `reverse` flag).
- `compileLook` compiles the body with a fresh sub-Compiler. For lookbehind, set the compiler's
  `reverse` flag so `concat` emits terms in reverse order and `group` emits its end-save before
  its start-save (keeping recorded start ≤ end while scanning backward).

### VM (`run`, direction-aware)
- Refactor `matchAt`'s loop into `run(ctx, insts, counters, start, dir)` returning the end
  position on success. `dir` = +1 (forward: whole pattern + lookahead bodies) or -1 (backward:
  lookbehind bodies). `char`/`class`/`any`/`backref` read/advance in the current direction.
- A shared `Ctx` threads the single capture array and the step budget through all (possibly
  nested) sub-matches, so captures inside lookaround write to the same slots the result reads.
- On a `look` inst: snapshot captures, run the body anchored at the current position with the
  right direction; a positive assertion keeps the body's captures (logging a snapshot so a
  later backtrack restores them); a negative assertion restores the snapshot (its inner
  captures stay undefined) and inverts success.

## Constitution Check
- **Correctness leads**: a pure conformance feature (ECMA-262 §22.2), additive; no behavior
  change for patterns without lookaround.
- **Perf no-regression**: the hot path (no lookaround) is unchanged except that the inner loop
  now branches on a compile-time-constant `fwd`; `zig build bench` must stay green. Lookaround
  bodies allocate a small snapshot/counters array per evaluation from the request arena only
  when a `look` inst is hit. Verified: bench `perf: ok`.

## Risks
- Reverse-compiled capture ordering: mitigated by swapping the group save order under `reverse`
  and verified against the V8-derived `lookBehind/captures.js` / `greedy-loop.js` patterns.
- Early-error scope creep: the quantifier rejection is gated precisely on lookbehind-always vs
  lookahead-in-UnicodeMode to avoid regressing the Annex B `(?=.)?` acceptance.
