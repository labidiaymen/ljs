// Records cannot cross the C ABI: an FFI parameter must be a scalar or string.
type Point = { x: int, y: int };
declare function g(p: Point): void;
g({ x: 1, y: 2 });
