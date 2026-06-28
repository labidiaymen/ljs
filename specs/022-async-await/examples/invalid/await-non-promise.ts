// `await` requires a Promise operand. Awaiting a plain value is an error.

async function run(): Promise<int> {
  const x: int = 5;
  await x;
  return 0;
}

console.log(await run());
