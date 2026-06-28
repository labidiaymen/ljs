class Shape {
  protected sides: int;
  constructor(sides: int) {
    this.sides = sides;
  }
}

let s = new Shape(3);
console.log(s.sides);
