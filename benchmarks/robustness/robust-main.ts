import score from "./score-helper.ts";

type Summary = {
  checksum: int,
  iterations: int,
};

function runBenchmark(rounds: int): int {
  let data: int[] = [3, 11, 23, 31, 47, 59, 61, 73, 89, 97, 101, 113, 127, 131, 149, 157];
  let empty: int[] = [];
  let checksum = 0;
  let cursor = 0;
  let i = 0;

  if (Array.isEmpty(empty)) {
    try {
      throw Error("empty-input");
    } catch (err) {
      if (String.startsWith(err.message, "empty") && String.contains(err.message, "input")) {
        checksum = checksum + 13;
      }
    } finally {
      checksum = checksum + 1;
    }
  }

  while (i < rounds) {
    let value = data[cursor];
    let mixed = score(value, i % 97);
    let bounded = Math.clamp(mixed, 0, 90000);
    checksum = checksum + bounded;
    checksum = checksum % 1000000;

    if (Math.sign(value - 80) > 0) {
      checksum = checksum + Math.min(value, 100);
    } else {
      checksum = checksum + Math.max(value, 7);
    }

    cursor = cursor + 1;
    if (cursor == 16) {
      cursor = 0;
    }

    i = i + 1;
  }

  return checksum;
}

let checksum = runBenchmark(1000000);
let result: Summary = {
  checksum: checksum,
  iterations: 1000000,
};

console.log(result.checksum);
