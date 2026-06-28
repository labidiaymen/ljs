// A `declare function` follows the same FFI type rules as `extern function`:
// non-scalar, non-string parameter types are rejected with E_FFI_TYPE.
declare function f(xs: int[]): void;
