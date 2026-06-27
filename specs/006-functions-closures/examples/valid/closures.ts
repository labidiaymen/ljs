function makeAdder(n: int): (x: int) => int {
  return (x: int) => x + n;
}

let add10 = makeAdder(10);
let add100 = makeAdder(100);
console.log(add10(5));
console.log(add100(5));

function apply(f: (n: int) => int, v: int): int {
  return f(v);
}

let factor = 3;
console.log(apply((x: int) => x * factor, 14));

let base = 1000;
let label = "n=";
let show: (n: int) => string = (x: int) => `${label}${x + base}`;
console.log(show(7));
