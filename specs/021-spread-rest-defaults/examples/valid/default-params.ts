function greet(name: string, greeting: string = "Hello"): string {
  return greeting + ", " + name;
}

function step(start: int = 1, by: int = 2): int {
  return start + by;
}

console.log(greet("World"));
console.log(greet("World", "Hi"));
console.log(step());
console.log(step(10));
console.log(step(10, 5));
