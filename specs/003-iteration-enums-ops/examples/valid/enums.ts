enum Color { Red, Green, Blue }
enum Dir { Up = "up", Down = "down" }

let c: Color = Color.Green;
console.log(c);
if (c === Color.Green) {
  console.log("green");
}

let d: Dir = Dir.Up;
console.log(d);
if (d === Dir.Up) {
  console.log("up-match");
}
