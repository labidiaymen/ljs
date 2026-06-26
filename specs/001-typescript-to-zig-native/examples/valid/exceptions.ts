try {
  throw Error("boom");
  console.log("skip");
} catch (err) {
  console.log(err.message);
} finally {
  console.log("done");
}
