interface User {
  id: int;
  name: string;
}

function greet(u: User): string {
  return u.name;
}

let admin: User = { id: 1, name: "ada" };
console.log(greet(admin));
console.log(admin.id);
