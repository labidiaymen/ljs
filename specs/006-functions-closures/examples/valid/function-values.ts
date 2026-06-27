function inc(x: int): int {
  return x + 1;
}

function dec(x: int): int {
  return x - 1;
}

function apply(f: (n: int) => int, v: int): int {
  return f(v);
}

console.log(apply(inc, 10));
console.log(apply(dec, 10));

let g: (n: int) => int = inc;
console.log(g(41));
