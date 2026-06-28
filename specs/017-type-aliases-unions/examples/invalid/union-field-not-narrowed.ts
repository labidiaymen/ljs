type Circle = { kind: "circle", radius: int };
type Square = { kind: "square", side: int };
type Shape = Circle | Square;
const s: Shape = { kind: "circle", radius: 2 };
console.log(s.radius);
