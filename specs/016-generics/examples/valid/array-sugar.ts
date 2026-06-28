function head<T>(xs: Array<T>): T {
  return xs[0];
}

let a: Array<int> = [3, 6, 9];
console.log(head(a));
console.log(a.length);

let s: Array<string> = ["x", "y", "z"];
console.log(head(s));
console.log(s.length);
