class Counter {
  count: int;
  constructor(start: int) {
    this.count = start;
  }
  increment(): void {
    this.count = this.count + 1;
  }
  add(n: int): void {
    this.count += n;
  }
  get(): int {
    return this.count;
  }
}

let c = new Counter(5);
c.increment();
c.add(10);
console.log(c.get());

class Point {
  x: int;
  y: int;
  constructor(x: int, y: int) {
    this.x = x;
    this.y = y;
  }
  manhattan(): int {
    return this.x + this.y;
  }
}
let p = new Point(3, 4);
console.log(p.manhattan());
console.log(p.x);
