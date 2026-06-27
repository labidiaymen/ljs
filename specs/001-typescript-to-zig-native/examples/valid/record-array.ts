type FileScore = {
  path: string,
  score: int,
};

let files: FileScore[] = [
  {
    path: "README.md",
    score: 20,
  },
  {
    path: "src/agent.ts",
    score: 30,
  },
];

console.log(files[1].path);
console.log(files.length);
