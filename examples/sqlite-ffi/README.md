# sqlite-ffi

A typed wrapper over [SQLite](https://sqlite.org) reached through the C foreign
function interface. It opens a database, creates a table, inserts rows, and runs
queries that return both an integer (`SELECT COUNT(*)`) and text (`SELECT title`).

This shows how to call a real C library from the language: declare the external
functions, link the library with `// @link` pragmas, and pass strings and
integers across the boundary.

## Dependency

SQLite is provided by Homebrew:

```sh
brew install sqlite
```

This example expects it at the default Homebrew prefix
`/opt/homebrew/opt/sqlite` (headers in `include/`, the library in `lib/`).

## How it is structured

SQLite's C API uses out-pointers (for example `sqlite3_open` takes a
`sqlite3**`), which the scalar-and-string FFI cannot express directly. A small C
shim, `sqlite_shim.c`, hides the connection handle behind a global and exposes a
flat, FFI-friendly surface:

| Function                  | Meaning                                            |
| ------------------------- | -------------------------------------------------- |
| `db_open(path)`           | open a database (`":memory:"` for in-memory); rc   |
| `db_exec(sql)`            | run a statement with no result rows; rc            |
| `db_query_int(sql)`       | first column of the first row, as an integer       |
| `db_query_text(sql)`      | first column of the first row, as text             |
| `db_errmsg()`             | the most recent error message                      |
| `db_close()`              | close the connection; rc                           |

`sqlite.ts` declares these external functions and re-exports them as a typed
API. `app.ts` imports that API and uses it.

## Build

```sh
./build.sh
```

That runs:

```sh
cc -c sqlite_shim.c -I/opt/homebrew/opt/sqlite/include -o sqlite_shim.o
lumen compile app.ts
```

The linking is driven by the pragmas at the top of `sqlite.ts`:

```ts
// @link ./sqlite_shim.o
// @link /opt/homebrew/opt/sqlite/lib/libsqlite3.dylib
// @link c
```

## Run

```sh
./app
```

Expected output:

```
books in catalog: 3
newest title:     Crafting Interpreters
oldest year:      1985
```
