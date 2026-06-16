# M25 — Raw (non-escaped) non-ASCII Unicode identifiers (§12.7) + Unicode trivia (§12.2/§12.3)

**Status:** in progress. Builds on M23 (`\u` identifier escapes; the `unicode_id.zig` ID_Start/
ID_Continue tables and the `scanIdentifier` `had_escape` flow). M23 deferred RAW non-ASCII identifier
source bytes plus the Unicode-whitespace handling needed to keep them from regressing.

## What
Two coupled changes in `src/lexer.zig`:

### Part 1 — raw UTF-8 in the identifier scanner (§12.7 UnicodeIDStart / UnicodeIDContinue)
- An IdentifierName may now START with a raw multibyte UTF-8 sequence whose decoded code point
  satisfies `unicode_id.isIdStart(cp)` (e.g. `café`, `℘`, `var Ω`), and CONTINUE with any sequence
  whose code point satisfies `unicode_id.isIdContinue(cp)` — which includes ZWNJ (U+200C) and ZWJ
  (U+200D).
- `scanIdentifier` (shared by normal identifiers and private names `#name`) decodes each `>= 0x80`
  byte via `std.unicode.utf8Decode` over the UTF-8 sequence at `self.pos` and validates it:
  - START position → `isIdStart`; PART positions → `isIdContinue`.
  - An invalid UTF-8 sequence OR a decoded code point not valid in the current position simply ENDS
    the identifier (it is not consumed). It is not an error per se — the byte just isn't part of the
    identifier; control returns to `scanToken`, which falls through to the existing
    `UnexpectedCharacter` path if nothing else matches.
- Identifier-START detection at the two call sites in `scanToken` gains
  `or (c >= 0x80 and <decoded cp is isIdStart>)`:
  - normal identifier dispatch (`if (isIdentStart(c) or c == '\\' or rawIdStart)`),
  - private-name start (`#` followed by a raw ID_Start), in addition to the existing ASCII / `\u`.
- The keyword check is unchanged: it compares the (ASCII) StringValue, so a raw-Unicode identifier is
  never a keyword (`std.mem.eql` against the ASCII keyword set never matches a multibyte name).
- Mixed forms work: `\u{e9}` and raw `é` both decode to U+00E9, so `var café` (raw) and `var caf\u{e9}`
  denote the same binding (M23 already handled the escape side; the fast path / buffered path now also
  accept raw multibyte parts).

### Part 2 — Unicode WhiteSpace + LineTerminators in `skipTrivia` (REQUIRED)
Before the identifier scanner sees them, `skipTrivia` must consume the §12.2 Unicode WhiteSpace and
§12.3 LineTerminators that are `>= 0x80`, by decoding UTF-8:
- WhiteSpace (§12.2): U+00A0 NBSP, U+1680, U+2000–U+200A, U+202F, U+205F, U+3000, U+FEFF (ZWNBSP/BOM).
- LineTerminator (§12.3): U+2028 LINE SEPARATOR, U+2029 PARAGRAPH SEPARATOR → set `saw_newline`.
Without this, these `>= 0x80` bytes would be (mis)consumed as identifier parts — the regression that
sank a prior raw-identifier attempt. NOTE: U+200C/U+200D (ZWNJ/ZWJ) are ID_Continue, NOT whitespace —
`skipTrivia` must NOT skip them.

## Why
The remaining `language/identifiers/*` and `class-elements` parse gap (~1000 cases) uses raw non-ASCII
identifier chars: `#℘`, `var café`, `#ZW_<ZWNJ>_NJ`, `o.℘`, etc. The ID tables already exist; this
just wires the raw-UTF-8 source path through the scanner + the matching trivia.

## Out of scope / deferred
- Unicode ≥ 14.0 newly-assigned code points (the tables are Unicode 13.0; a small minority of
  `identifiers/*` use newer code points — see `unicode_id.zig` header).
- Astral (`>= 0x10000`) identifier chars decode and validate the same way (`utf8Decode` yields the full
  code point), so they are covered where the 13.0 tables include them.

## Gates
1. `zig build`  2. `zig build test`  3. `zig build lint` (0/0)  4. full `language/` run, passed ≥ 30056,
`--baseline baseline/language.json` → "no regression vs baseline" (0), then `--update-baseline`.
5. `zig build bench` — ASCII identifier fast path unchanged (only `>= 0x80` bytes take the UTF-8 path).
