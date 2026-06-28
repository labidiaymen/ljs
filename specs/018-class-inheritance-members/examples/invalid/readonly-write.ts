class Config {
  readonly version: int;
  constructor(v: int) {
    this.version = v;
  }
  bump(): void {
    this.version = this.version + 1;
  }
}

let c = new Config(1);
console.log(c.version);
