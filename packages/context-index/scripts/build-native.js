#!/usr/bin/env node

const { mkdirSync, renameSync, rmSync } = require("node:fs");
const { resolve } = require("node:path");
const { spawnSync } = require("node:child_process");

const root = resolve(__dirname, "../../..");
const packageRoot = resolve(__dirname, "..");
const source = "packages/context-index/src/score-file.ts";
const binaryName = process.platform === "win32" ? "lumen-context-index.exe" : "lumen-context-index";
const generatedName = process.platform === "win32" ? "score-file.exe" : "score-file";

function run(command, args) {
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: "utf8",
    stdio: "inherit",
  });
  if (result.status !== 0) {
    process.exit(result.status || 1);
  }
}

mkdirSync(resolve(packageRoot, "native"), { recursive: true });
run("zig", ["build"]);
run("zig-out/bin/lumen", ["compile", "--release-fast", source]);
rmSync(resolve(packageRoot, "native", binaryName), { force: true });
renameSync(resolve(root, generatedName), resolve(packageRoot, "native", binaryName));
rmSync(resolve(root, "score-file.zig"), { force: true });
