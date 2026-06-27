function apply(f: (n: int) => int, v: int): int {
  return f(v);
}

console.log(apply((x: int) => x * 2, 21));
console.log(apply((x: int) => x + 100, 5));

let square: (n: int) => int = (x: int) => x * x;
console.log(square(9));

let isPos: (n: int) => bool = (x: int) => x > 0;
console.log(isPos(3));
console.log(isPos(-1));
