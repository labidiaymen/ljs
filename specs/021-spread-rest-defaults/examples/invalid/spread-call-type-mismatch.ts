function sum(...nums: int[]): int {
  let total: int = 0;
  for (const n of nums) {
    total = total + n;
  }
  return total;
}

let words: string[] = ["a", "b"];
console.log(sum(...words));
