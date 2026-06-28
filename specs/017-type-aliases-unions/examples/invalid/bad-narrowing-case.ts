type Circle = { kind: "circle", radius: int };
type Square = { kind: "square", side: int };
type Shape = Circle | Square;
function area(s: Shape): int {
  switch (s.kind) {
    case "triangle":
      return 1;
  }
  return 0;
}
console.log(area({ kind: "circle", radius: 2 }));
