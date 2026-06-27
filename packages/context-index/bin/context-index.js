#!/usr/bin/env node

const { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } = require("node:fs");
const { dirname, extname, join, relative, resolve } = require("node:path");
const { spawnSync } = require("node:child_process");

const packageRoot = resolve(__dirname, "..");
const nativeBinary = resolve(packageRoot, "native", process.platform === "win32" ? "lumen-context-index.exe" : "lumen-context-index");
const supported = new Set([".ts", ".js", ".zig", ".md", ".json"]);
const ignored = new Set([".git", "node_modules", "dist", "build", "zig-cache", "zig-out", ".lumen"]);

function usage() {
  console.error("usage: context-index <build|search> [root] [query]");
  process.exit(2);
}

function walk(root, dir = root, out = []) {
  for (const entry of readdirSync(dir)) {
    if (ignored.has(entry)) continue;
    const path = join(dir, entry);
    const st = statSync(path);
    if (st.isDirectory()) {
      walk(root, path, out);
      continue;
    }
    if (st.isFile() && supported.has(extname(path))) {
      out.push(path);
    }
  }
  return out;
}

function language(path) {
  const ext = extname(path);
  if (ext === ".ts") return "typescript";
  if (ext === ".js") return "javascript";
  if (ext === ".zig") return "zig";
  if (ext === ".md") return "markdown";
  if (ext === ".json") return "json";
  return "text";
}

function symbols(text) {
  const names = [];
  const patterns = [
    /\bfunction\s+([A-Za-z_][A-Za-z0-9_]*)/g,
    /\bclass\s+([A-Za-z_][A-Za-z0-9_]*)/g,
    /\btype\s+([A-Za-z_][A-Za-z0-9_]*)/g,
    /\bconst\s+([A-Za-z_][A-Za-z0-9_]*)/g,
  ];
  for (const pattern of patterns) {
    let match;
    while ((match = pattern.exec(text)) && names.length < 12) {
      names.push(match[1]);
    }
  }
  return names;
}

function build(root) {
  const absRoot = resolve(root);
  const files = walk(absRoot).map((path) => {
    const text = readFileSync(path, "utf8");
    return {
      path: relative(absRoot, path),
      language: language(path),
      lines: text.length === 0 ? 0 : text.split(/\r?\n/).length,
      symbols: symbols(text),
    };
  });
  const indexPath = join(absRoot, ".lumen", "context-index.json");
  mkdirSync(dirname(indexPath), { recursive: true });
  writeFileSync(indexPath, JSON.stringify({ version: 1, files }, null, 2));
  console.log(`indexed ${files.length} files -> ${relative(process.cwd(), indexPath)}`);
}

function scoreFiles(paths, terms) {
  if (!existsSync(nativeBinary)) {
    throw new Error(`native binary missing: ${nativeBinary}\nrun: node packages/context-index/scripts/build-native.js`);
  }
  const result = spawnSync(nativeBinary, [terms[0] || "", terms[1] || "", terms[2] || "", ...paths], {
    encoding: "utf8",
  });
  if (result.status !== 0) {
    throw new Error(`${nativeBinary} failed:\n${result.stdout}${result.stderr}`);
  }
  const lines = `${result.stdout || ""}${result.stderr || ""}`.trim().split(/\r?\n/);
  return paths.map((_, index) => Number(lines[index] || "0"));
}

function search(root, query) {
  const absRoot = resolve(root);
  const indexPath = join(absRoot, ".lumen", "context-index.json");
  if (!existsSync(indexPath)) {
    build(absRoot);
  }
  const index = JSON.parse(readFileSync(indexPath, "utf8"));
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean).slice(0, 3);
  const paths = index.files.map((file) => join(absRoot, file.path));
  const scores = scoreFiles(paths, terms);
  const ranked = index.files
    .map((file, index) => ({
      ...file,
      score: scores[index] || 0,
    }))
    .filter((file) => file.score > 0)
    .sort((a, b) => b.score - a.score || a.path.localeCompare(b.path))
    .slice(0, 10);

  for (const file of ranked) {
    const symbolText = file.symbols.length ? ` ${file.symbols.join(",")}` : "";
    console.log(`${file.score}\t${file.path}\t${file.language}\t${file.lines} lines${symbolText}`);
  }
}

const [, , command, rootArg, ...rest] = process.argv;
if (!command) usage();

if (command === "build") {
  build(rootArg || ".");
} else if (command === "search") {
  const query = rest.join(" ");
  if (!query) usage();
  search(rootArg || ".", query);
} else {
  usage();
}
