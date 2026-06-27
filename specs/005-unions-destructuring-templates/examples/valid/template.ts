let name = "ada";
let age = 30;
console.log(`hello ${name}, age ${age}`);
console.log(`sum is ${1 + 2}`);
console.log(`no holes here`);

interface User {
  id: int;
  handle: string;
}
let u: User = { id: 7, handle: "neo" };
console.log(`user ${u.handle} #${u.id}`);
