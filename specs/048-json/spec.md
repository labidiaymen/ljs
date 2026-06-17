# M48 — JSON

## Goal
Implement the `JSON` namespace (§25.5) from **0.0%**: `JSON.parse` and `JSON.stringify` (self-contained,
no host dependencies). 330 tests.

## Design (`builtin_json.zig`)
A dedicated module dispatched from `callNative` (`json_parse` / `json_stringify`); `JSON` is registered
as a namespace ordinary object (proto = %Object.prototype%, `[Symbol.toStringTag]` = `"JSON"`).

### JSON.parse (§25.5.1)
A hand-written recursive-descent parser over the UTF-8 bytes implementing the STRICT JSON grammar (not
the JS grammar): double-quoted strings only; the JSON escape set (`\" \\ \/ \b \f \n \r \t \uXXXX`,
surrogate pairs combined, lone surrogate → WTF-8); a restricted number form (no leading zeros / `+` /
bare `.`); whitespace limited to space/tab/LF/CR; no trailing commas; raw control chars rejected. Any
deviation → `SyntaxError`. Objects build ordinary objects (CreateDataProperty, last duplicate key wins);
arrays build dense Array exotics. A callable `reviver` triggers §25.5.1.1 InternalizeJSONProperty (a
recursive walk that replaces or deletes children then calls `reviver(holder, key, value)`).

### JSON.stringify (§25.5.2)
SerializeJSONProperty per spec: `toJSON` method → replacer function → unwrap Number/String/Boolean/
BigInt wrapper → dispatch. `undefined`/function/Symbol are omitted (→ `null` inside arrays); non-finite
numbers → `null`; BigInt → `TypeError`; a cycle → `TypeError` (object stack). The `replacer` may be a
function or an array key allow-list; `space` (Number clamped to 0–10 spaces, or a ≤10-char String) sets
the pretty-print gap/indent. Strings escaped via §25.5.2.5 QuoteJSONString.

## Gates
build / test / lint / **JSON ↑ from 0** / language no-regression / bench perf:ok.

## Result
JSON 0→198/330 (60.0%). No regression: language 87.2%, bench perf:ok. New public interpreter helpers
(`setKeyThrow`, `deleteProperty`, `ownEnumerableKeys`, `toStringValuePub`) — behavior unchanged.

## Deferred
ES2024 `JSON.rawJSON` / `JSON.isRawJSON` (20+12 tests) and the `JSON.parse` reviver **source-context**
arg (~newer). Proxy-targeted parse/stringify tests (need Proxy — a later milestone). Per-native
`.length` / `builtin.js` metadata (deferred engine-wide).
