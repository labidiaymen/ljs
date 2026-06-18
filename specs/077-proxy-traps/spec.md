# 077 — Proxy exotic-object trap set (ECMA-262 §10.5)

Status: Done — built-ins/Proxy 132/607 (21.7%) → 476/607 (78.4%); 0 language regressions.

## Summary
Implement the full Proxy exotic-object internal-method set so every §10.5.x internal method
routes through the handler trap (or forwards to the target when the trap is absent), with the
§10.5.x invariant checks. Currently only `[[Get]]` is wired.

## Governing clauses
- §10.5.1 [[GetPrototypeOf]], §10.5.2 [[SetPrototypeOf]], §10.5.3 [[IsExtensible]],
  §10.5.4 [[PreventExtensions]], §10.5.5 [[GetOwnProperty]], §10.5.6 [[DefineOwnProperty]],
  §10.5.7 [[HasProperty]], §10.5.8 [[Get]], §10.5.9 [[Set]], §10.5.10 [[Delete]],
  §10.5.11 [[OwnPropertyKeys]], §10.5.12 [[Call]], §10.5.13 [[Construct]].
- §28.2 Proxy constructor / Proxy.revocable / revoke.

## Scope
In: all 13 internal methods routed through the handler with invariants; revoked-proxy TypeError;
absent-trap forwarding; Proxy callability/constructability deriving from the target.
Out: nothing host-specific. for-in enumeration over a proxy is best-effort via OwnPropertyKeys.

## Acceptance (derived from Test262 built-ins/Proxy)
- Given a revoked proxy, When any internal method runs, Then it throws TypeError.
- Given a handler with no trap for op X, When X runs, Then the target's ordinary X is used.
- Given a trap that violates its §10.5.x invariant, Then a TypeError is thrown.
- built-ins/Proxy conformance rises substantially from the 21.7% baseline (132/607).
- 0 regressions across test/language vs baseline/language.json.
