// Only error values may be thrown; a bare string is rejected.
try {
  throw "boom";
} catch (e) {
  console.log(e.message);
}
