// Test blocks. Run with: lumen test examples/showcase/math.test.ts

function gcd(a: int, b: int): int {
  let x = a;
  let y = b;
  while (y != 0) {
    let t = y;
    y = x % y;
    x = t;
  }
  return x;
}

function isPrime(n: int): bool {
  if (n < 2) {
    return false;
  }
  let i = 2;
  while (i * i <= n) {
    if (n % i == 0) {
      return false;
    }
    i += 1;
  }
  return true;
}

test "gcd computes greatest common divisor" {
  expect(gcd(12, 8) == 4);
  expect(gcd(17, 5) == 1);
}

test "isPrime detects primes" {
  expect(isPrime(7));
  expect(isPrime(13));
  expect(!isPrime(1));
  expect(!isPrime(9));
}
