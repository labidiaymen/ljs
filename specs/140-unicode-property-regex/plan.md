# Plan — spec 139 cycle 1

## Files / functions
- **src/lexer.zig** — regex-literal scanning currently rejects `\p`/`\P` as InvalidEscape. Accept them
  in a regex literal (the regex body is captured raw + compiled lazily; the lexer must not reject the
  escape). Find the regex escape-validation site.
- **src/builtin_regexp_engine.zig** —
  - `parseAtomEscape`: handle `'p','P'` → parse `{ Name }` → a new `.uprop` node (or a `.class` that
    carries property refs).
  - class-escape path (`appendClassEscape` / the `[...]` parser): handle `\p{…}` INSIDE a class
    (`[_\p{L}]`) — the class node must carry property refs alongside byte ranges.
  - Node: add `uprops: []const UProp` (property id + negated) to the `.class` payload, OR a dedicated
    `.uprop` tag. Decision: extend `.class` so in-class + standalone share one matcher.
  - Matcher (`classMatch` / the `.class` VM op): when the class carries uprops OR the pattern is
    unicode-mode, take a CODE-POINT path — decode the cp at `sp` (std.unicode.utf8Decode), test byte
    ranges (cp<256) + uprops, advance by the cp's utf8 byte length. Byte-only classes keep the fast
    single-byte path (no regression).
- **src/unicode_props.zig** (NEW) — `pub fn lookup(name) ?PropId` + `pub fn contains(PropId, cp) bool`
  over curated, sorted u21 range tables (General_Category groups + key binaries). Binary-search ranges.

## Design calls
- **Isolation:** existing `Range{u8,u8}` byte classes are UNTOUCHED. Property membership is a separate
  u21-range test reached only when a class has uprops (or atom is a standalone `\p`). This sidesteps the
  risky engine-wide widening — the cycle-2 wildcard from the estimate is avoided by construction.
- **Code-point advance:** the property/unicode class path advances `sp` by the decoded cp's utf8 length
  (1–4), not 1 — so an astral match consumes the whole sequence. Byte path unchanged.
- **`u`-mode gating:** `\p{…}` is only a property escape with the `u`/`v` flag; otherwise the existing
  Annex-B `p` literal path runs. Don't change non-`u` behavior.

## Constitution check
- Correctness-leads: new behavior is additive; gated hard on Test262 language (no regression) + the
  RegExp property-escapes suite (gain). Re-run the language differential vs baseline.
- Perf: the byte-class fast path is preserved (single-byte read) for property-free classes; the cp path
  runs only for `\p`-bearing/unicode classes. Re-bench (regex isn't on the hot interpreter bench, but
  confirm no global regression).
