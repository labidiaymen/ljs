function inc(x: int): int { return x + 1; }
function apply(f: (n: int) => int, v: int): int { return f(v); }
console.log(apply(inc, "x"));
