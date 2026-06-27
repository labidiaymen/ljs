function termScore(content: string, term: string): int {
  if (String.isEmpty(term)) {
    return 0;
  }

  if (String.contains(content, term)) {
    return 10;
  }

  return 0;
}

function scoreFile(content: string, first: string, second: string, third: string): int {
  let score = 0;
  score = score + termScore(content, first);
  score = score + termScore(content, second);
  score = score + termScore(content, third);
  return score;
}

let first = arg(1);
let second = arg(2);
let third = arg(3);
let i = 4;

while (i < argsCount()) {
  let path = arg(i);
  let content = fs.readFileSync(path, "utf8");
  console.log(scoreFile(content, first, second, third));
  i = i + 1;
}
