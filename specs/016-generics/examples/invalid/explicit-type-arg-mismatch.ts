function identity<T>(x: T): T {
  return x;
}

console.log(identity<int>("hello"));
