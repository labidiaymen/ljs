# wordstats

A small command-line tool that reads a text file and reports statistics about
it: line count, word count, character count, the number of distinct words, and
the most frequent words.

It shows a realistic mix of language features working together:

- reading command-line arguments (`argsCount()`, `arg(i)`)
- reading a file with `fs.readFileSync`
- string methods (`toLowerCase`, `split`, `charCodeAt`)
- a `Map<string, int>` for word frequencies, plus a `Set<string>` for top-N
- a `class` to hold the computed result
- a graceful message when no file argument is given

## Build

```sh
lumen compile wordstats.ts
```

This produces a native `wordstats` binary in the current directory.

## Run

```sh
./wordstats sample.txt
```

Expected output:

```
file:    sample.txt
lines:   5
words:   57
chars:   273
unique:  28
top 5 words:
  the: 9
  fox: 6
  over: 5
  dog: 4
  and: 4
```

Pass a number to change how many of the top words are shown:

```sh
./wordstats sample.txt 3
```

```
file:    sample.txt
lines:   5
words:   57
chars:   273
unique:  28
top 3 words:
  the: 9
  fox: 6
  over: 5
```

With no arguments it prints usage instead of failing:

```sh
./wordstats
```

```
usage: wordstats <file> [top-n]
```

## How it works

Words are found by scanning the lowercased text one character at a time: runs of
letters and digits form words, and any other character (space, newline,
punctuation) ends the current word. Frequencies are tallied in a `Map`, and the
top-N report repeatedly picks the highest remaining count, tracking what it has
already shown in a `Set`.
