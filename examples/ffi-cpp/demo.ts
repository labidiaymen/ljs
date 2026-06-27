// Calls a C++ library through its extern "C" surface.
// Build the library first, then: lumen compile --link ./geometry.o demo.ts
// @link ./geometry.o
extern function rectangle_area(w: int, h: int): int;
extern function circle_area(r: number): number;

console.log(rectangle_area(6, 7));
console.log(circle_area(2.0));
