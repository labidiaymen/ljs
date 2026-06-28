// Records cannot cross the C ABI: an extern parameter must be a scalar or string.
type Point = { x: int, y: int };
extern function g(p: Point): void;
g({ x: 1, y: 2 });
