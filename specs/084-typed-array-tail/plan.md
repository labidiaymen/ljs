# Plan 084 — implementation approach

## Data model (`src/runtime_types.zig`)
- `ArrayBufferData`: add `immutable: bool = false`.
- `TypedArrayData`: add `tracks_length: bool = false`.
- `DataViewData`: add `tracks_length: bool = false`.

## A. transfer / transferToImmutable (`src/builtin_arraybuffer.zig`)
- New `transfer(it, this_val, args, to_immutable)` helper:
  - RequireInternalSlot (ArrayBuffer) + IsDetachedBuffer → TypeError.
  - `newLength`: `transfer(newLength?)` → ToIndex, default = source byteLength;
    `transferToImmutable` → always source byteLength (no arg).
  - New data block: `min(old, new)` bytes copied, growth zero-filled.
  - Resizable carry: `transfer` keeps `max_byte_length` (resizable iff source was);
    `transferToImmutable` → fixed (`max_byte_length = null`), `immutable = true`.
  - DETACH source: `detached = true`, `bytes = &.{}` (per ownership convention — arena-owned,
    no free needed).
  - Build result via a fresh `array_buffer` Object proto-linked to %ArrayBuffer.prototype%.
- `resize`: reject `immutable` buffers up front (TypeError). (A resizable buffer is never immutable,
  so this only matters defensively; immutable buffers are non-resizable → already the
  "not resizable" TypeError, but make the immutable message explicit.)
- `method` dispatch: add `"transfer"` / `"transferToImmutable"`.

## B. length-tracking views
### Construction (set `tracks_length`)
- `builtin_typedarray.zig` `constructFromBuffer`: set `tracks_length = (explicit_len == null and
  buf is resizable)`.
- `builtin_dataview.zig` `construct`: set `tracks_length = (length_arg == .undefined and
  buffer is resizable)`.

### A single `liveLength` helper (`src/typed_array.zig`, pure, shared)
- `pub fn liveLength(tracks: bool, stored_len: usize, byte_offset: usize, buffer_byte_len: usize,
  bpe: usize) usize`:
  - tracking: `if byte_offset > buffer_byte_len → 0 else (buffer_byte_len - byte_offset) / bpe`.
  - non-tracking: `min(stored_len, (buffer_byte_len - min(byte_offset, buffer_byte_len)) / bpe)`
    (the existing crash-safe clamp).

### Route ALL length reads through it
- `builtin_typedarray.zig` `TA.of`: `.length = liveLength(...)`.
- `builtin_typedarray.zig` `getter` `length` / `byteLength`: use the live length (× bpe).
- `builtin_typedarray.zig` `method` dispatcher `len`: already `TA.of(o).length` → automatic.
- `interp_property.zig` `typedArrayGet` / `typedArraySet`: bounds against the live length, not
  `ta.array_length`.
- `builtin_dataview.zig` getters + get/set bounds: use the live byteLength
  (`liveLength(tracks, byte_length, byte_offset, buffer_len, 1)`).

## Perf
- Non-tracking, non-resizable: `liveLength` takes the `min(stored, ...)` branch — same arithmetic as
  the existing clamp, no extra allocation/branching on the hot index path. The bench (`loop_mix`,
  no typed arrays) is untouched.

## Constitution check
- Correctness-first: every byte access stays bounds-validated against the LIVE buffer (preserves the
  spec-083 crash-safety). No perf regression (fixed-view path unchanged).
