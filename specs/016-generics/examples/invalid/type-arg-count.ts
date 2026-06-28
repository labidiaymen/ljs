function identity<T>(x: T): T {
  return x;
}

console.log(identity<int, string>(5));
