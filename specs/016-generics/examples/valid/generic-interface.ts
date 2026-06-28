interface Pair<A, B> {
  first: A;
  second: B;
}

let p: Pair<int, string> = { first: 7, second: "seven" };
console.log(p.first);
console.log(p.second);

let q: Pair<string, bool> = { first: "on", second: true };
console.log(q.first);
console.log(q.second);
