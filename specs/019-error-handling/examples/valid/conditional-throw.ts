// A try/catch/finally inside a function, with a throw guarded by a branch.
// Local variables declared in the try body stay in scope across statements,
// and the finally runs on every path.
function classify(n: int): void {
  try {
    let label: string = "checking";
    console.log(label);
    if (n < 0) {
      throw Error("too small");
    }
    if (n > 100) {
      throw Error("too big");
    }
    console.log("in range");
  } catch (e) {
    console.log(e.message);
  } finally {
    console.log("checked");
  }
}

classify(42);
classify(-3);
classify(250);
