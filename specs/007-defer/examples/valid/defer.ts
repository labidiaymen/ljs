function run(): void {
  defer console.log("a");
  defer console.log("b");
  console.log("work");
}

run();

function withBlock(): void {
  defer {
    console.log("x");
    console.log("y");
  }
  console.log("body");
}

withBlock();
