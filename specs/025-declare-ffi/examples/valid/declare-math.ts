// Call C standard-library math functions using the TypeScript-valid `declare
// function` FFI form. Identical to `extern function`; links libm via `// @link`.
// @link m
declare function pow(base: number, exp: number): number;
declare function sqrt(x: number): number;

let hypotSq = pow(3.0, 2.0) + pow(4.0, 2.0);
console.log(sqrt(hypotSq));
console.log(pow(2.0, 10.0));
