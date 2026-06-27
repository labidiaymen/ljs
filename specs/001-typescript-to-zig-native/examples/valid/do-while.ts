let i = 0;
let total = 0;

do {
  i++;
  if (i == 2) {
    continue;
  }
  total += i;
} while (i < 4);

console.log(total);
