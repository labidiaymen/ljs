import { open, exec, queryInt, queryText, errorMessage, close } from "./sqlite.ts";

function run(): void {
  let rc = open(":memory:");
  if (rc != 0) {
    console.log(`failed to open database: ${errorMessage()}`);
    return;
  }
  exec("CREATE TABLE books (title TEXT, year INT)");
  exec("INSERT INTO books VALUES ('The Go Programming Language', 2015)");
  exec("INSERT INTO books VALUES ('Crafting Interpreters', 2021)");
  exec("INSERT INTO books VALUES ('Structure and Interpretation', 1985)");

  let total = queryInt("SELECT COUNT(*) FROM books");
  console.log(`books in catalog: ${total}`);

  let newest = queryText("SELECT title FROM books ORDER BY year DESC LIMIT 1");
  console.log(`newest title:     ${newest}`);

  let oldestYear = queryInt("SELECT MIN(year) FROM books");
  console.log(`oldest year:      ${oldestYear}`);

  close();
}

run();
