// A `Ref<T>` over a record/interface passes by reference: the callee mutates the
// field and the caller observes the change. The call site stays plain.
type Counter = { n: int };

function bump(c: Ref<Counter>): void {
  c.n += 1;
}

function bumpBy(c: Ref<Counter>, by: int): void {
  c.n = c.n + by;
}

let ct: Counter = { n: 5 };
bump(ct);
console.log(ct.n);
bumpBy(ct, 10);
console.log(ct.n);

// A field path is an addressable lvalue too.
type Pair = { left: Counter, right: Counter };
let pr: Pair = { left: { n: 0 }, right: { n: 100 } };
bump(pr.left);
bump(pr.right);
console.log(pr.left.n);
console.log(pr.right.n);
