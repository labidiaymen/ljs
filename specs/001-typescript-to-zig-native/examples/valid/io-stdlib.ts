let content = fs.readFileSync("specs/001-typescript-to-zig-native/examples/valid/io-stdlib-fixture.txt", "utf8");

if (argsCount() > 0 && String.contains(content, "agent")) {
  console.log("ok");
} else {
  console.log("bad");
}
