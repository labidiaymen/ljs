// A `using` value must be the built-in `defer(...)` helper or a class instance
// exposing `dispose(): void`. A plain scalar is not disposable.

function run(): void {
  using x = 42;
  console.log("hi");
}

run();
