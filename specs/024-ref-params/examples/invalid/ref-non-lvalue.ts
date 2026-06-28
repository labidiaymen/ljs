// A `Ref<T>` argument must be an addressable lvalue; a literal/temporary is not.
function inc(x: Ref<int>): void {
  x = x + 1;
}

inc(5);
