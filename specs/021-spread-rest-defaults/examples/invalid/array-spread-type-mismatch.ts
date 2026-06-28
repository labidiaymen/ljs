let a: int[] = [1, 2];
let s: string[] = ["x"];
let bad: int[] = [...a, ...s];
console.log(bad.length);
