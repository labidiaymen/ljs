# M41 tasks

- [x] T1 Add `global_fn` NativeId (object.zig) + dispatch arm in callNative (interpreter.zig).
- [x] T2 Implement `globalFn`: isNaN / isFinite (coercing) — interpreter.zig.
- [x] T3 Implement parseInt (§19.2.5) — interpreter.zig.
- [x] T4 Implement parseFloat (§19.2.4) — interpreter.zig.
- [x] T5 Implement encodeURI / encodeURIComponent (§19.2.6) — interpreter.zig.
- [x] T6 Implement decodeURI / decodeURIComponent (§19.2.6) — interpreter.zig.
- [x] T7 Install all eight on `env` before the globalThis mirror — builtins.zig.
- [x] T8 Extend number_method to toString(radix)/valueOf/toFixed/toExponential/
        toPrecision/toLocaleString; install on Number.prototype — both files.
        Plus: §21.1.3/§20.3.3 transparent boxing — number/boolean primitives now resolve
        prototype methods (getProperty `.number`/`.boolean` arms; previously a number
        literal's `.toString` returned undefined → "not a function").
- [x] T9 Tests in engine.zig (the milestone's listed cases + extras).
- [x] T10 Gates: build / test / lint / conformance / bench. Commit.

## Deltas (passed/total, before -> after)
- parseInt            0/110  -> 104/110  (+104)
- parseFloat          0/108  -> 102/108  (+102)
- isNaN               0/30   -> 24/30    (+24)
- isFinite            0/30   -> 24/30    (+24)
- encodeURI           0/62   -> 45/62    (+45)
- encodeURIComponent  0/62   -> 46/62    (+46)
- decodeURI           0/110  -> 94/110   (+94)
- decodeURIComponent  0/112  -> 96/112   (+96)
- Number            314/680  -> 404/680  (+90)
- Targets total: +625, 0 within-target regressions. language/: no regression.

## Notes / deferred edges
- toLocaleString is locale-unaware (returns toString form) — noted, intl402 not in tree.
- Radix-toString fractional part uses a bounded expansion (no infinite digits).
- Remaining target failures (≤17 per URI handler, 6 per parse/isNaN) are mostly
  the lone-surrogate / WTF-16 source cases and a few exotic edge assertions, deferred.
