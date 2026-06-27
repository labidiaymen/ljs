function add(a: int, b: int): int {
  return a + b;
}

function isEven(n: int): bool {
  return n % 2 == 0;
}

test "add sums integers" {
  expect(add(2, 3) == 5);
  expect(add(-1, 1) == 0);
}

test "isEven detects parity" {
  expect(isEven(4));
  expect(!isEven(7));
}
