# M39 tasks — String.prototype methods

- [x] T1 Add `string_static` NativeId (object.zig).
- [x] T2 Register new String.prototype methods + statics (builtins.zig), non-enumerable.
- [x] T3 builtin_string.zig: at, codePointAt, concat, endsWith, startsWith, indexOf(pos), lastIndexOf,
      includes(pos), padStart, padEnd, repeat, trim/trimStart/trimEnd, substr, localeCompare,
      string-arg replace/replaceAll.
- [x] T4 builtin_string.zig: staticCall — fromCharCode, fromCodePoint, raw.
- [x] T5 Wire string_static in interpreter callNative.
- [x] T6 Tests in engine.zig (at/padStart/repeat/trim/startsWith/endsWith/concat/fromCharCode/codePointAt/replace).
- [x] T7 Gates: build, test, lint, conformance (String ↑, 0 regressions; language no-regression), bench.

## Done — delta
built-ins/String: 494/2443 (20.2%) -> 1402/2443 (57.4%) [+908 passing]. 0 regressions within String;
language/ "conformance: ok (no regression vs baseline)".

Supporting fixes landed alongside the methods (each needed for 0 within-String regressions, all
spec-correct + language-safe):
- §22.1.4.1/§10.4.3: `new String(s)` wrapper exposes `.length` + integer indices [0,len) reading
  [[StringData]] (interpreter getProperty .object branch).
- §17/§10.3: built-in methods/statics have no [[Construct]] — `new String.prototype.concat` /
  `new String.fromCharCode` now throw "not a constructor" (interpreter construct guard).
- §7.1.4 step 2: ToNumber(BigInt) throws a TypeError (interpreter toNumberV) — so
  `String.fromCharCode(0n)` propagates it.
- §7.1.17: string-library argument/`this` ToString is throwing (Symbol / throwing-ToPrimitive object
  → TypeError) via a new public `Interpreter.toStringThrowing`.
Methods landed: at, codePointAt, concat, endsWith, startsWith, indexOf(pos), lastIndexOf, includes(pos),
padStart, padEnd, repeat, trim, trimStart, trimEnd, substr, localeCompare, replace(string), replaceAll(string),
String.fromCharCode, String.fromCodePoint, String.raw.
Deferred: match, matchAll, search, replace/replaceAll(regex), split(regex), normalize, isWellFormed,
toWellFormed, toLocale{Upper,Lower}Case.
