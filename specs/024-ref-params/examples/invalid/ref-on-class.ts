// A class is already a reference type, so `Ref<Class>` is rejected.
class Box {
  v: int;
  constructor(v: int) {
    this.v = v;
  }
}

function tweak(b: Ref<Box>): void {
  b.v = 0;
}

let bx = new Box(1);
tweak(bx);
console.log(bx.v);
