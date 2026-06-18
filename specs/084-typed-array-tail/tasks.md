# Tasks 084

- [x] T1 Data model: add `immutable` to ArrayBufferData, `tracks_length` to TypedArrayData +
      DataViewData (`src/runtime_types.zig`).
- [x] T2 `liveLength` pure helper in `src/typed_array.zig`.
- [x] T3 ArrayBuffer `transfer` / `transferToImmutable` + immutable guards on `resize`;
      wire `array_buffer_method` dispatch + register on the prototype (`src/builtin_arraybuffer.zig`,
      `src/builtins.zig`).
- [x] T4 TypedArray length-tracking: set `tracks_length` in `constructFromBuffer`; route `TA.of`,
      the `length`/`byteLength` getters through `liveLength`; bounds in `typedArrayGet`/`typedArraySet`
      (`src/builtin_typedarray.zig`, `src/interp_property.zig`).
- [x] T5 DataView length-tracking: set `tracks_length` in `construct`; route the `byteLength` getter
      and get/set bounds through the live length (`src/builtin_dataview.zig`).
- [x] T6 Gate: `zig build` + `zig build test` + `zig build lint` + `zig build bench` green.
- [x] T7 Conformance: language no-regression (≥40,450, EXIT 0) + FULL built-ins sweep panics:0 EXIT 0.
