function score(value, salt) {
  let mixed = value * 31 + salt * 17;
  mixed = mixed % 100000;

  if (mixed < 0) {
    return Math.abs(mixed);
  }

  return mixed;
}

function runBenchmark(rounds) {
  const data = [3, 11, 23, 31, 47, 59, 61, 73, 89, 97, 101, 113, 127, 131, 149, 157];
  const empty = [];
  let checksum = 0;
  let cursor = 0;
  let i = 0;

  if (empty.length === 0) {
    try {
      throw new Error("empty-input");
    } catch (err) {
      if (err.message.startsWith("empty") && err.message.includes("input")) {
        checksum = checksum + 13;
      }
    } finally {
      checksum = checksum + 1;
    }
  }

  while (i < rounds) {
    const value = data[cursor];
    const mixed = score(value, i % 97);
    const bounded = Math.min(Math.max(mixed, 0), 90000);
    checksum = checksum + bounded;
    checksum = checksum % 1000000;

    if (Math.sign(value - 80) > 0) {
      checksum = checksum + Math.min(value, 100);
    } else {
      checksum = checksum + Math.max(value, 7);
    }

    cursor = cursor + 1;
    if (cursor === data.length) {
      cursor = 0;
    }

    i = i + 1;
  }

  return checksum;
}

const checksum = runBenchmark(1000000);
const result = {
  checksum,
  iterations: 1000000,
};

console.log(result.checksum);
