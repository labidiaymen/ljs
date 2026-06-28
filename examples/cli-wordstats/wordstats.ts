// wordstats — a small command-line tool that reports text statistics.
//
// Usage:
//   lumen compile wordstats.ts
//   ./wordstats sample.txt            # top 5 words (default)
//   ./wordstats sample.txt 10         # top 10 words
//
// Reports: line count, word count, character count, the number of distinct
// words, and the most frequent words. It reads a file, tokenizes it, tallies
// word frequencies in a Map, and selects the top entries.

// Holds the computed statistics for one document.
class Stats {
  lines: int;
  words: int;
  chars: int;
  unique: int;

  constructor(lines: int, words: int, chars: int, unique: int) {
    this.lines = lines;
    this.words = words;
    this.chars = chars;
    this.unique = unique;
  }
}

// True for ASCII letters and digits. Input is lowercased first, so only the
// lowercase letter range needs handling.
function isWordChar(code: int): bool {
  if (code >= 97 && code <= 122) {
    return true;
  }
  if (code >= 48 && code <= 57) {
    return true;
  }
  return false;
}

// Parse a non-negative decimal integer from a string. Returns -1 if the
// string contains any non-digit character or is empty.
function parseDigits(s: string): int {
  if (s == "") {
    return -1;
  }
  let value = 0;
  for (const ch of s.split("")) {
    let code = ch.charCodeAt(0);
    if (code < 48 || code > 57) {
      return -1;
    }
    value = value * 10 + (code - 48);
  }
  return value;
}

// Count newline-separated lines. A trailing newline does not start a new line.
function countLines(text: string): int {
  if (text == "") {
    return 0;
  }
  let n = 1;
  let last = 0;
  for (const ch of text.split("")) {
    last = ch.charCodeAt(0);
    if (last == 10) {
      n += 1;
    }
  }
  // A final newline closed the last line rather than opening a new one.
  if (last == 10) {
    n -= 1;
  }
  return n;
}

// Count characters by walking the string once.
function countChars(text: string): int {
  let n = 0;
  for (const ch of text.split("")) {
    if (ch != "") {
      n += 1;
    }
  }
  return n;
}

// Tally word frequencies into the provided Map and return the total word count.
// Walks the text one character at a time: word characters extend the current
// word, anything else (spaces, newlines, punctuation) ends it. This treats all
// whitespace and punctuation as separators without depending on a fixed list.
function tally(text: string, counts: Map<string, int>): int {
  let lower = text.toLowerCase();
  let total = 0;
  let word = "";
  for (const ch of lower.split("")) {
    if (isWordChar(ch.charCodeAt(0))) {
      word = word + ch;
      continue;
    }
    if (word != "") {
      total += 1;
      let current: int = counts.get(word) ?? 0;
      counts.set(word, current + 1);
      word = "";
    }
  }
  // Flush a trailing word with no separator after it.
  if (word != "") {
    total += 1;
    let current: int = counts.get(word) ?? 0;
    counts.set(word, current + 1);
  }
  return total;
}

// Print the `limit` most frequent words. Ties are broken by Map key order.
function printTop(counts: Map<string, int>, limit: int): void {
  let picked: Set<string> = new Set<string>();
  let shown = 0;
  while (shown < limit) {
    let bestKey = "";
    let bestVal = -1;
    let found = false;
    for (const key of counts.keys()) {
      if (picked.has(key)) {
        continue;
      }
      let value: int = counts.get(key) ?? 0;
      if (value > bestVal) {
        bestVal = value;
        bestKey = key;
        found = true;
      }
    }
    if (!found) {
      return;
    }
    picked.add(bestKey);
    console.log(`  ${bestKey}: ${bestVal}`);
    shown += 1;
  }
}

function run(): void {
  if (argsCount() < 2) {
    console.log("usage: wordstats <file> [top-n]");
    return;
  }

  let path = arg(1);
  let limit = 5;
  if (argsCount() >= 3) {
    let requested = parseDigits(arg(2));
    if (requested > 0) {
      limit = requested;
    }
  }

  let text = fs.readFileSync(path, "utf8");

  let counts: Map<string, int> = new Map<string, int>();
  let words = tally(text, counts);
  let stats = new Stats(countLines(text), words, countChars(text), counts.size);

  console.log(`file:    ${path}`);
  console.log(`lines:   ${stats.lines}`);
  console.log(`words:   ${stats.words}`);
  console.log(`chars:   ${stats.chars}`);
  console.log(`unique:  ${stats.unique}`);
  console.log(`top ${limit} words:`);
  printTop(counts, limit);
}

run();
