# Tasks — 086 RegExp Symbol methods

- [x] RegExpExec(R, S) abstraction honoring overridden `exec` (§22.2.7.1)
- [x] builtinExec emits `indices` array when `d` flag set (§22.2.7.2)
- [x] Symbol.search (§22.2.6.12)
- [x] Symbol.match (§22.2.6.8)
- [x] Symbol.matchAll + RegExpStringIterator (§22.2.6.9 / §22.2.9)
- [x] Symbol.replace + GetSubstitution (§22.2.6.11 / §22.2.7.5)
- [x] Symbol.split + SpeciesConstructor (§22.2.6.14)
- [x] Symbol.species getter on RegExp ctor (§22.2.5.2)
- [x] RegExp.escape static (§22.2.5.2) + EncodeForRegExpEscape
- [x] Constructor IsRegExp / from-regexp-like (read source/flags off a @@match object)
- [x] generic `get flags` (§22.2.6.4) reading each flag property
- [x] Getter length/name/descriptor fixes (nativeLength entries)
- [x] Throwing Set(lastIndex) to avoid sloppy-mode infinite loop
- [x] Wire native ids in builtins.zig + interp_native.zig (RegExp-localized)
- [x] Gate: build/test/lint/bench + language no-regression + RegExp sweep
