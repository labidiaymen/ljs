// A thrown error is caught by the matching catch, and the message is readable
// through the catch binding. The finally block always runs last.
try {
  console.log("before");
  throw Error("boom");
  console.log("unreached");
} catch (e) {
  console.log("caught");
  console.log(e.message);
} finally {
  console.log("cleanup");
}

// finally also runs when the try body completes without throwing, and the
// catch binding may be left unused.
try {
  console.log("clean");
} catch (e) {
  console.log("never");
} finally {
  console.log("done");
}
