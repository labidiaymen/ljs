// `using` with a class instance that exposes `dispose(): void`. The bound value
// is disposed at scope exit, in reverse (LIFO) order across declarations.

class Resource {
  name: string;
  constructor(name: string) {
    this.name = name;
  }
  dispose(): void {
    console.log(`closing ${this.name}`);
  }
}

function open(name: string): Resource {
  return new Resource(name);
}

function run(): void {
  using r = open("db");
  using s = open("file");
  console.log(`using ${r.name} and ${s.name}`);
}

run();
