type FileScore = {
  path: string,
  score: int,
};

function makeScore(path: string, score: int): FileScore {
  return {
    path: path,
    score: score,
  };
}

function boost(file: FileScore): FileScore {
  return {
    path: file.path,
    score: file.score + 5,
  };
}

let file = boost(makeScore("src/agent.ts", 20));

console.log(file.score);
