# Tasks: By-Reference Parameters (`Ref<T>`)

- [x] T1 — AST: `FunctionParam.is_ref`/`ref_scalar`; `var_ref.deref`;
      `Assign.deref`; `call.ref_args`.
- [x] T2 — Types: `refZigName`, `isRefAllowed`, `isRefScalar`.
- [x] T3 — Checker: `refInner` marker detection; `resolveParam` interception and
      inner-type validation (`E_REF_TARGET`) ahead of the generics machinery.
- [x] T4 — Checker: reject `Ref<T>` on constructor params (`E_REF_TARGET`) and
      extern params (`E_FFI_TYPE`).
- [x] T5 — Checker: bind ref params with `is_ref`/`ref_scalar`; set `deref` on
      scalar ref reads and assignments; allow record-ref field writes.
- [x] T6 — Checker: call-site `ref_args`, lvalue/mutability validation
      (`E_REF_ARG`), force mutable root binding.
- [x] T7 — Emitter: `*T` param lowering (functions and methods); scalar `.*`
      read/write; `&arg` at call sites.
- [x] T8 — Examples: valid `record-by-ref.ts`, `scalar-out-param.ts`; invalid
      `ref-on-class.ts`, `ref-non-lvalue.ts`.
- [x] T9 — Conformance manifest + `build.zig` wiring (`conformance_cmd_024`).
- [x] T10 — Ambient `lumen.d.ts` (`type Ref<T> = T;`).
- [x] T11 — Verify: `zig build` clean; run valid examples (caller observes
      mutation); invalid examples emit expected diagnostics; `zig build
      conformance` green.
