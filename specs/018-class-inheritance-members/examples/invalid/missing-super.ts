class Base {
  x: int;
  constructor(x: int) {
    this.x = x;
  }
}

class Derived extends Base {
  y: int;
  constructor(y: int) {
    this.y = y;
  }
}

let d = new Derived(5);
console.log(d.y);
