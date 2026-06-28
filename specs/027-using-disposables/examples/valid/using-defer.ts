// `using` declarations (TypeScript 5.2) with the built-in `defer` helper.
//
// `using x = defer(() => BODY);` runs BODY when the enclosing scope exits.
// Multiple declarations dispose in reverse (LIFO) order, and `using` interleaves
// correctly with the legacy `defer` statement.

function helper(): void {
  using _a = defer(() => console.log("a"));
  using _b = defer(() => console.log("b"));
  console.log("work");
}

function mixed(): void {
  defer console.log("legacy1");
  using _u = defer(() => console.log("using1"));
  defer console.log("legacy2");
  console.log("body");
}

function block(): void {
  using _x = defer(() => {
    console.log("x1");
    console.log("x2");
  });
  console.log("blockbody");
}

function scoped(): void {
  console.log("start");
  if (true) {
    using _ = defer(() => console.log("inner"));
    console.log("inside");
  }
  console.log("end");
}

helper();
mixed();
block();
scoped();
