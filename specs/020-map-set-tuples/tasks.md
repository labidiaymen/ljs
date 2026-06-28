# Tasks: Map, Set, Tuples (020)

1. Add `map_type`, `set_type`, `tuple_type` to `Type` (+ MapType struct); extend
   `same`, `mangle`, `zigName`, `toAnnotation`, helpers.
2. Parse `Map<K,V>`, `Set<T>`, `[A,B,...]` annotations in
   `typeFromAnnotation`.
3. Checker: `new Map/Set` instantiation; container method dispatch
   (`mapMethod`/`setMethod`); `.size` property; tuple literal checking; tuple
   indexed access.
4. AST: add fields needed for emission (container type on new_expr/method_call,
   tuple type on array literal/index).
5. Emitter: prologue `LumenMap`/`LumenSet`; `new` Map/Set; container method
   calls; `.size`; tuple literal + index.
6. Examples valid/invalid + manifest.json + wire build.zig; verify
   `zig build conformance` fully green.
</content>
