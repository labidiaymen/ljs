// An async function awaiting another async function, with arithmetic on the
// resolved values. Demonstrates that `await` composes across call layers.

async function base(): Promise<int> {
  return 10;
}

async function addBase(n: int): Promise<int> {
  const b: int = await base();
  return b + n;
}

async function doubleSum(x: int, y: int): Promise<int> {
  const left: int = await addBase(x);
  const right: int = await addBase(y);
  return left + right;
}

console.log(await base());
console.log(await addBase(5));
console.log(await doubleSum(1, 2));

// Awaiting inside an expression context.
const total: int = (await addBase(0)) + (await addBase(0));
console.log(total);
