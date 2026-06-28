// A `Ref<T>` over a scalar is an out-style parameter: assignment in the callee is
// visible to the caller. Inside the body it reads and writes exactly as `T`.
function inc(x: Ref<int>): void {
  x = x + 1;
}

function addInto(acc: Ref<int>, v: int): void {
  acc += v;
}

let n = 0;
inc(n);
console.log(n);
inc(n);
console.log(n);

let total = 10;
addInto(total, 5);
addInto(total, 7);
console.log(total);
