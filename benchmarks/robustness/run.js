const { spawnSync } = require("node:child_process");
const { existsSync, rmSync } = require("node:fs");
const { resolve } = require("node:path");

const root = resolve(__dirname, "../..");
const lumenSource = "benchmarks/robustness/robust-main.ts";
const nodeSource = "benchmarks/robustness/robust-main.node.js";
const binary = process.platform === "win32" ? "robust-main.exe" : "robust-main";
const rounds = Number(process.argv[2] || 15);

function run(command, args) {
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: "utf8",
  });

  if (result.error) {
    throw result.error;
  }

  return {
    code: result.status,
    output: `${result.stdout || ""}${result.stderr || ""}`.trim(),
  };
}

function must(command, args) {
  const result = run(command, args);
  if (result.code !== 0) {
    throw new Error(`${command} ${args.join(" ")} failed:\n${result.output}`);
  }
  return result;
}

function timed(label, command, args) {
  let output = "";
  const start = process.hrtime.bigint();

  for (let i = 0; i < rounds; i += 1) {
    const result = must(command, args);
    if (i === 0) {
      output = result.output;
    } else if (result.output !== output) {
      throw new Error(`${label} produced unstable output`);
    }
  }

  const elapsedMs = Number(process.hrtime.bigint() - start) / 1_000_000;
  return {
    label,
    output,
    totalMs: elapsedMs,
    avgMs: elapsedMs / rounds,
  };
}

function cleanup() {
  for (const file of [binary, "robust-main.zig"]) {
    const path = resolve(root, file);
    if (existsSync(path)) {
      rmSync(path);
    }
  }
}

cleanup();
must("zig", ["build"]);
must("zig-out/bin/lumen", ["compile", lumenSource]);

const nativeResult = timed("lumen-native", `./${binary}`, []);
const nodeResult = timed("node", "node", [nodeSource]);

if (nativeResult.output !== nodeResult.output) {
  throw new Error(`output mismatch\nnative: ${nativeResult.output}\nnode: ${nodeResult.output}`);
}

console.log(`workload output: ${nativeResult.output}`);
console.log(`rounds: ${rounds}`);
console.log(`${nativeResult.label}: ${nativeResult.avgMs.toFixed(3)} ms/run`);
console.log(`${nodeResult.label}: ${nodeResult.avgMs.toFixed(3)} ms/run`);
console.log(`ratio node/native: ${(nodeResult.avgMs / nativeResult.avgMs).toFixed(2)}x`);

cleanup();
