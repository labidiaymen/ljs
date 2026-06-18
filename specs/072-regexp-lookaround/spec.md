# Spec 072 — RegExp lookaround assertions (lookahead + lookbehind)

Status: Done — built-ins/RegExp 1626→1666 (+40); language baseline 0 regressions (+24
quantified-lookaround SyntaxError tests).

## Summary
Implement the four ECMAScript lookaround assertions in the RegExp engine:
`(?=Disjunction)` (lookahead), `(?!Disjunction)` (negative lookahead),
`(?<=Disjunction)` (lookbehind), `(?<!Disjunction)` (negative lookbehind). Before this
cycle the engine's `parseGroup` rejected all four as `SyntaxError`, so every
`built-ins/RegExp/lookBehind/*` and lookahead test (and any pattern using them) failed with
`parse_error`. This was the single highest-leverage non–property-escape failing cluster
(38 `parse_error`s sharing one root cause).

Governing clauses: ECMA-262 §22.2.1 (Patterns — Term / Assertion / QuantifiableAssertion
grammar) and §22.2.2.3 (Assertion runtime semantics; lookbehind evaluates the Disjunction
right-to-left, direction = -1).

## In scope
- Parsing `(?=`, `(?!`, `(?<=`, `(?<!` into a lookaround AST node.
- VM execution: lookahead runs the body forward anchored at the current position; lookbehind
  runs it backward (body compiled in reverse term order). Both consume nothing.
- Capture semantics: a positive assertion's inner captures persist; a negative assertion
  leaves its inner captures undefined; backtracking past an assertion restores captures.
- Static-semantics early errors: a lookbehind is an Assertion (never QuantifiableAssertion),
  so a quantifier on it is always a SyntaxError; a lookahead is QuantifiableAssertion only in
  non-UnicodeMode (Annex B), so a quantifier on it in UnicodeMode (`u`/`v`) is a SyntaxError.

## Out of scope (untouched, owned elsewhere / deferred)
- `String.prototype.match/replace/matchAll/split/search` and the `Symbol.*` RegExp methods
  (live in `builtin_string.zig` / `interpreter.zig`, owned by other agents). Most
  `lookBehind/*` Test262 cases drive lookbehind through `String.prototype.match`, so they stay
  blocked on those methods even though the engine now matches correctly.
- Unicode property escapes (`\p{…}`), full `u`/`v`-mode code-point semantics, astral/surrogate
  handling — the engine remains byte-oriented (documented deviation).

## User scenarios (Given/When/Then)
- Given `/foo(?=bar)/`, When exec on `"foobar"`, Then match `"foo"`; on `"foobaz"` → null.
- Given `/foo(?!bar)/`, When exec on `"foobaz"`, Then match `"foo"`.
- Given `/(?<=abc)def/`, When exec on `"abcdef"`, Then match `"def"`; on `"xbcdef"` → null.
- Given `/(?<!abc)def/`, When exec on `"xyzdef"`, Then match `"def"`; on `"abcdef"` → null.
- Given `/(?<=(b+))c/` on `"abbbbbbc"`, Then group 1 = `"bbbbbb"` (greedy, longest suffix).
- Given `/(?<=(\w(\w)))def/` on `"abcdef"`, Then groups = `"bc"`, `"c"`.
- Given `/(?<=(\w){3})def/` on `"abcdef"`, Then group 1 = `"a"` (last loop iteration wins).
- Given `/.(?<=.)?/`, `/.(?<=.){2,3}/` (any mode) or `/.(?=.)?/u`, `/.(?=.){2,3}/u`, Then the
  literal is a parse-phase SyntaxError.

## Success criteria
- built-ins/RegExp passed count strictly increases; no language baseline regression.
- All four assertion forms reachable via `RegExp.prototype.exec`/`test` behave per the
  scenarios above; quantified-lookaround early errors throw SyntaxError.
