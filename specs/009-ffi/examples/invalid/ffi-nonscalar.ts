// @link m
// An array crosses no C ABI: FFI params/returns must be scalar or string.
declare function sum(xs: int[]): int;
console.log(sum([1, 2, 3]));
