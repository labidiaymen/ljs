function firstOf<T>(xs: T[]): T {
  return xs[0];
}

function second<A, B>(a: A, b: B): B {
  return b;
}

let nums: int[] = [10, 20, 30];
console.log(firstOf(nums));

let words: string[] = ["alpha", "beta"];
console.log(firstOf(words));

console.log(second(1, "x"));
console.log(second("y", 99));
