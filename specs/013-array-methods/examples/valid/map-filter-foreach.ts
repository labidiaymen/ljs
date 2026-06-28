function show(x: int): void {
  console.log(x);
}

let xs: int[] = [1, 2, 3, 4, 5];

let doubled = xs.map((x: int) => x * 2);
console.log(doubled[0]);
console.log(doubled[4]);
console.log(doubled.length);

let evens = xs.filter((x: int) => x % 2 == 0);
console.log(evens.length);
console.log(evens[0]);

xs.forEach((x: int) => show(x));
