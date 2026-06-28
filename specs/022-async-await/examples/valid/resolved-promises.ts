// Awaiting an already-resolved promise: from `Promise.resolve` and from an
// `async function` whose body returns synchronously.

async function answer(): Promise<int> {
  return 42;
}

async function greet(name: string): Promise<string> {
  return name;
}

const a: int = await answer();
console.log(a);

const r: int = await Promise.resolve(7);
console.log(r);

const who: string = await greet("lumen");
console.log(who);

// A promise can be stored and awaited later.
const pending: Promise<int> = answer();
const again: int = await pending;
console.log(again);
