type Point = { x: int, y: int, label: string };

let a: int[] = [1, 2, 3];
let b: int[] = [4, 5];
let merged: int[] = [...a, ...b];
let withExtra: int[] = [0, ...a, 99, ...b];

for (const n of merged) {
  console.log(n);
}
console.log(merged.length);
console.log(withExtra.length);

let p: Point = { x: 1, y: 2, label: "orig" };
let moved: Point = { ...p, x: 10 };
console.log(moved.x);
console.log(moved.y);
console.log(moved.label);
