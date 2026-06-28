// A nested try handles its own throw without disturbing the outer try. The
// inner finally runs before control resumes after the inner try.
try {
  console.log("outer-start");
  try {
    throw Error("inner");
  } catch (e) {
    console.log("inner-catch");
    console.log(e.message);
  } finally {
    console.log("inner-finally");
  }
  console.log("outer-continue");
} catch (e) {
  console.log("outer-never");
} finally {
  console.log("outer-finally");
}

// A throw inside a catch re-propagates to the enclosing try. The inner finally
// still runs before the rethrow reaches the outer catch.
try {
  try {
    throw Error("first");
  } catch (e) {
    console.log("rethrowing");
    throw Error("second");
  } finally {
    console.log("rethrow-finally");
  }
} catch (e) {
  console.log("outer-handler");
  console.log(e.message);
}
