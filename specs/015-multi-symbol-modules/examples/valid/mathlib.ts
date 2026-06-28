export function add(a: int, b: int): int {
  return a + b;
}

export function mul(a: int, b: int): int {
  return a * b;
}

export const ANSWER: int = 42;

test "mathlib internals are stripped from importers" {
  console.log(add(1, 1));
}
