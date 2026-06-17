# M51 — dynamic Function constructor

## Goal
Implement `Function(p1, …, pN, body)` / `new Function(...)` (§20.2.1.1 + §20.2.1.1.1
CreateDynamicFunction), previously a hard `TypeError` stub. High-leverage: a large fraction of the
`Function.prototype` (call/apply/bind/toString) tests AND many `language/` tests build their subject via
`Function("...")`, so they could not even run.

## Design
The last argument is the function body; the preceding arguments are parameter texts joined with `,`
(each via ToString, so a Symbol arg throws). Build the source
`(function anonymous(<params>\n) {\n<body>\n})` and evaluate it in the GLOBAL environment (reusing
`performEval`), returning the resulting function. Key points:
- Runs in the **global** scope with the global `this` (a dynamic function closes over global bindings,
  not the caller's frame) — `this_val`/`home_object` saved/restored around the eval.
- The `\n` after the params and around the body match the spec text (a `//` comment or stray `)` in an
  argument cannot hide the closing delimiters → a malformed argument yields a catchable `SyntaxError`
  via `performEval`'s parse-failure path, as required).
- Name is `anonymous`; `.length` is the parsed parameter count; strictness comes from the body's own
  `"use strict"` prologue (the wrapping program is sloppy).
- `new Function` and `Function` behave identically (constructNT's explicit-object-return takes the
  function, mirroring the Promise constructor).

## Gates
build / test / lint / **Function ↑** / language no-regression / bench perf:ok.

## Result
Function 264→354/893 (29.6%→39.6%); +90. Ripple: language 87.3→87.4% (+74 — many language tests build
functions dynamically). No regression; bench perf:ok.

## Deferred
`Function.prototype.toString` source-text reproduction (146 tests — needs the parser to retain source
spans), `Function.prototype[Symbol.hasInstance]` (20), and the param/body *separate-validation* edge
cases (injection tests the wrap-and-parse approach doesn't perfectly mirror).
