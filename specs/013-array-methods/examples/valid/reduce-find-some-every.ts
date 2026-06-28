let xs: int[] = [1, 2, 3, 4, 5];

let sum = xs.reduce((acc: int, x: int) => acc + x, 0);
console.log(sum);

let product = xs.reduce((acc: int, x: int) => acc * x, 1);
console.log(product);

let found = xs.find((x: int) => x > 3);
console.log(found);

let missing = xs.find((x: int) => x > 99);
console.log(missing);

console.log(xs.some((x: int) => x > 4));
console.log(xs.some((x: int) => x > 9));
console.log(xs.every((x: int) => x > 0));
console.log(xs.every((x: int) => x > 1));
