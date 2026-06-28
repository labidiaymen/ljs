let pair: [int, string] = [42, "hi"];
console.log(pair[0]);
console.log(pair[1]);

let triple: [string, int, bool] = ["x", 7, true];
console.log(triple[0]);
console.log(triple[1]);
console.log(triple[2]);

function makePoint(x: int, y: int): [int, int] {
  return [x, y];
}

let p: [int, int] = makePoint(3, 4);
console.log(p[0] + p[1]);
