class Box<T> {
  value: T;
  constructor(v: T) {
    this.value = v;
  }
  get(): T {
    return this.value;
  }
  set(v: T): void {
    this.value = v;
  }
}

let bi = new Box<int>(5);
console.log(bi.get());
bi.set(42);
console.log(bi.get());
console.log(bi.value);

let bs = new Box<string>("hi");
console.log(bs.get());
