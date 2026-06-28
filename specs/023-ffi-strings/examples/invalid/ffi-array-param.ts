// Arrays cannot cross the C ABI: an extern parameter must be a scalar or string.
extern function f(xs: int[]): void;
f([1, 2, 3]);
