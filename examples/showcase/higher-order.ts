// First-class functions: function-typed params, named functions, and arrows.

function applyTwice(f: (n: int) => int, v: int): int {
  return f(f(v));
}

function triple(x: int): int {
  return x * 3;
}

console.log(applyTwice(triple, 2));
console.log(applyTwice((x: int) => x + 10, 5));

let clamp: (n: int) => int = (x: int) => x > 100 ? 100 : x;
console.log(clamp(250));
console.log(clamp(42));
