// Arrays cannot cross the C ABI: an FFI parameter must be a scalar or string.
declare function f(xs: int[]): void;
f([1, 2, 3]);
