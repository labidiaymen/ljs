function add(a: int, b: int): int {
  return a + b;
}

function isEven(n: int): bool {
  return n % 2 == 0;
}

function greet(name: string): string {
  return "hi " + name;
}

test("add sums integers", () => {
  expect(add(2, 3)).toBe(5);
  expect(add(-1, 1)).toEqual(0);
  expect(add(2, 3) == 5);
});

test("isEven detects parity", () => {
  expect(isEven(4));
  expect(!isEven(7));
});

test("greet builds a string", () => {
  expect(greet("a")).toBe("hi a");
});
