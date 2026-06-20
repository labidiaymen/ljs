# Spec 093 — Class private names (PrivateEnvironment) + super in direct eval (§15.7, §13.3.7, §9.2)

Status: Done — class/elements 2848→2996 (stmt) / 2716→2788 (expr); language 41,672 → ~41,950 (+~280),
0 regressions vs baseline (after a follow-up fix), 0 panics, bench ok.
Owner: Aymen

## Fixes
1. **Real PrivateEnvironment** (§9.2 / §8.2.x ResolvePrivateIdentifier): private slots were keyed by
   the string spelling `#x`, so two classes' `#x` collided and a nested class couldn't shadow an
   outer `#x`. Each `evalClass` now mints a fresh `PrivateName` per declared element with a unique
   interned slot key, pushes a `PrivateEnv` frame (parent = enclosing), and every get/set/`#x in`/
   install resolves the spelling through the running chain (innermost wins). Brand-check TypeError
   (§13.15) now fires when a `#x` minted by class A is read on a B-branded instance.
2. **Declaration-order private TypeError**: instance private *fields* merged into the single ordered
   `[[Fields]]` list; a field's brand is added when its initializer runs, so a forward `this.#x`
   throws.
3. **Direct-eval `super`/`new.target`/private/arguments**: `eval('super.x')` etc. failed to parse
   (forbidden at script top level). Added `Parser.parseEvalMode` + an `EvalContext` seeded from the
   interpreter's running context (home_object→in_method, this_init_cell→in_derived_ctor, a `func_depth`
   counter→in_function, the live PrivateEnvironment→in_class_body + visible spellings). Indirect eval
   resets them.
4. **PrivateEnvironment propagation** through inner function/async/generator/arrow bodies (captured in
   `instantiateFunctionObject`/`evalFunctionExpr`/the Generator record).
5. **`for (this.#x of/in …)`** and double-init / super-return-object honoring (§13.3.7.1).

## Follow-up fix (this integration) — subclass-builtins regression
The §13.3.7.1 super-return rebind (take the parent [[Construct]] result as `this`) regressed 16
`subclass-builtins` cases (`class X extends Object/Function/RegExp`): ljs models a NATIVE parent as
initializing the pre-created, proto-correct `instance` in place, and such a native may return a
separate non-proto-linked receiver. The rebind is now gated to **user (non-native) parent
constructors** (`sup.native == .none`); a native parent keeps the proto-correct `instance`.

## Module split
`interp_expr.zig` exceeded the 2000-line budget (2057); `functionConstructor` + `performEval` (the
eval / dynamic-Function machinery) were extracted into `interp_eval.zig` (1949 lines after).

Files: `runtime_types.zig`, `object.zig`, `interpreter.zig`, `interp_class.zig`, `interp_property.zig`,
`interp_expr.zig`, `interp_native.zig`, `interp_stmt.zig`, `interp_async.zig`, `parser.zig`,
`parse_validate.zig`, new `interp_eval.zig`.
