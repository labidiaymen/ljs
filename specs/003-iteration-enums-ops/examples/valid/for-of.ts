let nums: int[] = [10, 20, 30];
let total = 0;
for (const n of nums) {
  total += n;
}
console.log(total);

let word = "abc";
for (const ch of word) {
  console.log(ch);
}

let sum = 0;
for (const n of nums) {
  if (n === 20) {
    continue;
  }
  sum += n;
}
console.log(sum);
