// An async function must declare a Promise<T> return type.

async function bad(): int {
  return 1;
}

console.log(bad());
