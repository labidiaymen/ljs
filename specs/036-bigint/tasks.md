# M36 Tasks — BigInt

- [x] T1 `src/bigint.zig`: Managed-backed helpers, arena-allocated `*const Const`; JS-semantic
      add/sub/mul/pow/divTrunc/rem/bitAnd/bitOr/bitXor/shl/shr/neg/bitNot; fromI64/fromString/fromF64;
      toStringRadix; order/eql/sign; asIntN/asUintN.
- [x] T2 `Value.bigint` variant (`src/value.zig`) + `writeDisplay` decimal print.
- [x] T3 `abstract_ops.zig`: toBoolean / typeOf / toString / strictEquals / sameValue / looseEquals /
      relational bigint cases.
- [x] T4 Lexer: consume trailing `n`, tag `is_bigint`; reject `n` after fraction/exponent/non-octal.
- [x] T5 Parser: `bigint` AST node from the digits at the right radix.
- [x] T6 Interpreter: evalBinary BigInt paths (both-bigint ops, mixing TypeError, cross-type
      relational/equality, string `+`), unary `-`/`~`/`+`-TypeError; `BigInt()` ctor + prototype
      methods; getProperty bigint boxing → BigInt.prototype.
- [x] T7 builtins: install `BigInt` (callable, non-ctor) + `BigInt.prototype` (constructor/toString/
      valueOf) + `BigInt.asIntN`/`asUintN`.
- [x] T8 NativeId: `bigint_ctor`, `bigint_method`, `bigint_static`.
- [x] T9 engine.zig tests.
- [x] T10 Gates: build / test / lint / conformance (no regression) / bench.
