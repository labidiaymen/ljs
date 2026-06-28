function sum(...nums: int[]): int {
  let total: int = 0;
  for (const n of nums) {
    total = total + n;
  }
  return total;
}

function label(prefix: string, ...rest: string[]): string {
  let out: string = prefix;
  for (const r of rest) {
    out = out + "-" + r;
  }
  return out;
}

console.log(sum());
console.log(sum(1, 2, 3));

let xs: int[] = [4, 5, 6];
console.log(sum(...xs));
console.log(sum(1, ...xs, 10));

console.log(label("p"));
console.log(label("p", "a", "b"));
let tags: string[] = ["x", "y"];
console.log(label("p", ...tags));
