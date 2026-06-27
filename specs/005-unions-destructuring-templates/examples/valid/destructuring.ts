interface Point {
  x: int;
  y: int;
}

let nums: int[] = [10, 20, 30];
let [first, second] = nums;
console.log(first);
console.log(second);

let p: Point = { x: 3, y: 4 };
let { x, y } = p;
console.log(x);
console.log(y);
