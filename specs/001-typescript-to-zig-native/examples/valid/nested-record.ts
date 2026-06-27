type Stats = {
  lines: int,
};

type FileMeta = {
  path: string,
  stats: Stats,
};

let file: FileMeta = {
  path: "src/agent.ts",
  stats: {
    lines: 24,
  },
};

console.log(file.stats.lines);
