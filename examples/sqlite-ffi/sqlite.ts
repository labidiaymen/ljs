// A typed wrapper over SQLite, backed by a small C shim (sqlite_shim.c).
// @link ./sqlite_shim.o
// @link /opt/homebrew/opt/sqlite/lib/libsqlite3.dylib
// @link c
declare function db_open(path: string): int;
declare function db_exec(sql: string): int;
declare function db_query_int(sql: string): int;
declare function db_query_text(sql: string): string;
declare function db_errmsg(): string;
declare function db_close(): int;

export function open(path: string): int {
  return db_open(path);
}
export function exec(sql: string): int {
  return db_exec(sql);
}
export function queryInt(sql: string): int {
  return db_query_int(sql);
}
export function queryText(sql: string): string {
  return db_query_text(sql);
}
export function errorMessage(): string {
  return db_errmsg();
}
export function close(): int {
  return db_close();
}
