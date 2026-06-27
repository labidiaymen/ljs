let total = 0;

for (let i = 0; i < 8; i++) {
  if (i == 2) {
    continue;
  }
  if (i == 6) {
    break;
  }
  total += i;
}

console.log(total);
