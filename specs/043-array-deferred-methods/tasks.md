# M43 tasks

- [x] T1  object.zig: `array_frozen: bool` + `array_length_writable: bool`; `freezeObject` on an Array
          sets both (frozen → elements + length non-writable).
- [x] T2  object.zig: `isFrozenObject` honors array element-writability (a non-frozen array with present
          elements is not frozen even when non-extensible); `isSealedObject` unchanged.
- [x] T3  builtins.zig: added `Symbol.species` to the well-known symbols (§20.4.2).
- [x] T4  object.zig + builtins.zig: `NativeId.species_getter`; `Array[Symbol.species]` getter (returns
          `this`), installed after the Symbol ctor exists.
- [x] T5  interpreter.zig: `arraySpeciesCreate` (§10.4.2.3) — IsArray short-circuit, ctor read
          (poisoned-throw), @@species read (null→undefined, poisoned-throw), undefined→plain
          ArrayCreate, non-ctor→TypeError, else Construct(C,«length»). + `arrayCreateFromCtor` for
          Array.from/of.
- [x] T6  interpreter.zig: `createDataPropertyOrThrow` / `arraySetThrow` / `arraySetLenThrow`
          (Completion-returning); `setProperty` array path honors extensible/frozen/length-writable
          (throw in strict, silent in sloppy); `objectDefineProperty` length via `arrayDefineLength`;
          stale `properties[index]` purge on CreateDataProperty + delete.
- [x] T7  (folded into T6) `setProperty` + the throwing helpers.
- [x] T8  builtin_array.zig: filter/map/flat/flatMap/slice/concat/splice create result via
          ArraySpeciesCreate, populate via createDataPropertyOrThrow.
- [x] T9  builtin_array.zig: push/pop/unshift/shift/splice/fill/copyWithin/reverse/sort mutate via the
          throwing Set/Delete/SetLength wrappers; append-branch hole-clear in `arraySet`.
- [x] T10 builtins.zig: registered filter/concat/splice/flat/flatMap/shift/unshift on Array.prototype;
          Array.from/Array.of as `.array_static`.
- [x] T11 engine.zig: M43 unit tests.
- [x] T12 Gates: build/test/lint all green; built-ins/Array 30.4%→38.4% (+490, 0 regress); language
          "no regression"; bench "perf: ok" (ljs ≤ Node).
