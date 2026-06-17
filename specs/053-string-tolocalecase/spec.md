# M53 — String.prototype.toLocaleLowerCase / toLocaleUpperCase

## Goal
Register `String.prototype.toLocaleLowerCase` / `toLocaleUpperCase` (§22.1.3.21/.22), which were absent
(`TypeError: value is not a function`), raising `built-ins/String`.

## Design
In a non-Intl engine the locale-sensitive case mappers are defined to behave exactly like the
locale-independent `toLowerCase` / `toUpperCase` (Test262's base — non-`intl402` — suite asserts this).
So they alias the existing `string_method` case path: added to the prototype registration list, and the
dispatch's case branch matches the two extra names (`toLocaleUpperCase` shares the upper path).

## Gates
build / test / lint / **String ↑** / language no-regression / bench perf:ok.

## Result
String 1560→1642/2443 (63.9%→67.2%); +82. No regression: language 87.4%, bench perf:ok.

## Notes
The remaining big String clusters need other features: match/split/search/replace/matchAll/replaceAll
(~428) require the **RegExp** engine + the `Symbol.match`/`replace`/`search`/`split` protocols; `trim`
and friends' remaining failures are **generic-`this`** (ToString-coercion of a non-string receiver —
a String-wide milestone mirroring M44's Array work); `normalize` needs Unicode normalization;
`isWellFormed`/`toWellFormed` need lone-surrogate detection over the WTF-8 store.
