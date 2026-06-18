# Tasks 076 — Array sort SortCompare coercion fidelity

- [x] Histogram `built-ins/Array/prototype` failures; identify `sort` as the largest cluster
      (58 fails) and isolate the in-scope root cause (SortCompare coercions in `compare`).
- [x] Comparator path: throwing `ToNumber` on the comparator result (Symbol/BigInt → TypeError).
- [x] Default path: throwing `ToString` on elements (objects via ToPrimitive; Symbol → TypeError;
      objects ordered by their real `toString`, not `"[object Object]"`).
- [x] Verify repros: `[obj,"X"].sort()` orders by `obj.toString()`; `[Symbol(),1].sort()` throws;
      `[1,2].sort(()=>Symbol())` throws.
- [x] `zig build` / `zig build test` / `zig build lint` green.
- [x] Measure `built-ins/Array/prototype/sort`: 49 → 55 passing (+6 / +3 unique).
- [x] 0 regressions vs `baseline/language.json`.
- [x] `zig build bench` no regression.
