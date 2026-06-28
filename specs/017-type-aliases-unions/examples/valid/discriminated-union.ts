type Circle = { kind: "circle", radius: int };
type Square = { kind: "square", side: int };
type Shape = Circle | Square;

function area(s: Shape): int {
  switch (s.kind) {
    case "circle":
      return s.radius * s.radius * 3;
    case "square":
      return s.side * s.side;
  }
  return 0;
}

function name(s: Shape): string {
  if (s.kind === "circle") {
    return "circle";
  }
  return "square";
}

const c: Shape = { kind: "circle", radius: 4 };
const q: Shape = { kind: "square", side: 5 };

console.log(area(c));
console.log(area(q));
console.log(name(c));
console.log(name(q));
