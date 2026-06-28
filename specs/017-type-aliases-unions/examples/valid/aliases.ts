type Id = int;
type Label = string;
type Scores = int[];

function double(n: Id): Id {
  return n * 2;
}

const id: Id = 21;
const label: Label = "lumen";
const scores: Scores = [1, 2, 3];

console.log(double(id));
console.log(label);
console.log(scores[0] + scores[1] + scores[2]);
const widened: string = (label as string);
console.log(widened);
