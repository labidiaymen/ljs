function identity<T>(x: T): T {
  return x;
}

console.log(identity(42));
console.log(identity("hello"));
console.log(identity(true));
console.log(identity<int>(7));
