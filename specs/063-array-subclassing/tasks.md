---
description: "Task list for M75 / 063 — Array subclassing exotic instance via super()"
---

# Tasks: M75 — Array subclassing (§23.1.1.1 / §15.7.14)

- [x] T010 `interpreter.zig` `callNative` `.array_ctor`: when `native_new_target` is defined and
  `this_val` is an object, initialize the Array state on that instance (flip kind=.array) and
  return it; else allocate a fresh array. Apply the existing length/elements rule to it.
- [x] T020 Local repros: spec.md US1 (new S(3).length, index→length, elements, default ctor) +
  regression guards (new Array, Array() call, isArray) all pass.
- [x] T030 FULL gate: build/test/lint green; conformance 39040 = 89.4%, +14 vs M74, 0 regressions; bench ok.
