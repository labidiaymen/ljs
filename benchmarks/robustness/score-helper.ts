export default function score(value: int, salt: int): int {
  let mixed = value * 31 + salt * 17;
  mixed = mixed % 100000;

  if (mixed < 0) {
    return Math.abs(mixed);
  }

  return mixed;
}
