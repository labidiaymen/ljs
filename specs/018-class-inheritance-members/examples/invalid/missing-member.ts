interface Sized {
  size: int;
}

class Empty implements Sized {
  name: string;
  constructor(name: string) {
    this.name = name;
  }
}

let e = new Empty("x");
console.log(e.name);
