interface Named {
  label: string;
}

class Animal implements Named {
  protected name: string;
  readonly label: string;
  static count: int;
  constructor(name: string) {
    this.name = name;
    this.label = "animal";
    Animal.count += 1;
  }
  speak(): string {
    return this.name + " makes a sound";
  }
  describe(): string {
    return this.name + " [" + this.label + "]";
  }
}

class Dog extends Animal {
  private tricks: int;
  constructor(name: string, tricks: int) {
    super(name);
    this.tricks = tricks;
  }
  speak(): string {
    return super.speak() + " (woof)";
  }
  trickCount(): int {
    return this.tricks;
  }
}

class Counter {
  private value: int;
  constructor(start: int) {
    this.value = start;
  }
  get current(): int {
    return this.value;
  }
  set current(v: int) {
    this.value = v;
  }
  static zero(): Counter {
    return new Counter(0);
  }
}

let a = new Animal("Cat");
console.log(a.speak());

let d = new Dog("Rex", 3);
console.log(d.speak());
console.log(d.describe());
console.log(d.trickCount());
console.log(Animal.count);

let c = Counter.zero();
console.log(c.current);
c.current = 42;
console.log(c.current);
