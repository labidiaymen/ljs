// @link m
// An array crosses no C ABI: extern params/returns must be scalar or string.
extern function sum(xs: int[]): int;
console.log(sum([1, 2, 3]));
