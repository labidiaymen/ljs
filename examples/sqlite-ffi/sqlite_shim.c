// A scalar/string-friendly C shim over SQLite.
//
// SQLite's real C API uses out-pointers (sqlite3_open takes a sqlite3**,
// sqlite3_step walks a statement handle, etc.). The Lumen FFI marshals only
// scalars and strings, so this shim hides the handles behind a single global
// connection and exposes plain functions that take/return ints and C strings.
//
// Build:
//   cc -c sqlite_shim.c -I/opt/homebrew/opt/sqlite/include -o sqlite_shim.o

#include <sqlite3.h>
#include <string.h>

// The one connection this shim manages.
static sqlite3 *g_db = 0;

// A small buffer that owns the most recent text result so the pointer we hand
// back to the caller stays valid until the next query.
static char g_text[4096];

// Open a database at `path`. Use ":memory:" for an in-memory database.
// Returns the SQLite result code (0 == SQLITE_OK).
int db_open(const char *path) {
    if (g_db) {
        sqlite3_close(g_db);
        g_db = 0;
    }
    return sqlite3_open(path, &g_db);
}

// Run a statement that returns no rows (CREATE, INSERT, UPDATE, ...).
// Returns the SQLite result code (0 == SQLITE_OK).
int db_exec(const char *sql) {
    if (!g_db) return -1;
    return sqlite3_exec(g_db, sql, 0, 0, 0);
}

// Run a query and return the first column of the first row as an integer.
// Returns 0 if the query yields no rows or fails to prepare.
int db_query_int(const char *sql) {
    if (!g_db) return -1;
    sqlite3_stmt *stmt = 0;
    if (sqlite3_prepare_v2(g_db, sql, -1, &stmt, 0) != SQLITE_OK) {
        return -1;
    }
    int result = 0;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        result = sqlite3_column_int(stmt, 0);
    }
    sqlite3_finalize(stmt);
    return result;
}

// Run a query and return the first column of the first row as text.
// Returns an empty string if the query yields no rows or fails.
const char *db_query_text(const char *sql) {
    g_text[0] = 0;
    if (!g_db) return g_text;
    sqlite3_stmt *stmt = 0;
    if (sqlite3_prepare_v2(g_db, sql, -1, &stmt, 0) != SQLITE_OK) {
        return g_text;
    }
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        const unsigned char *text = sqlite3_column_text(stmt, 0);
        if (text) {
            strncpy(g_text, (const char *)text, sizeof(g_text) - 1);
            g_text[sizeof(g_text) - 1] = 0;
        }
    }
    sqlite3_finalize(stmt);
    return g_text;
}

// The most recent error message from the connection.
const char *db_errmsg(void) {
    if (!g_db) return "no open database";
    return sqlite3_errmsg(g_db);
}

// Close the connection. Returns the SQLite result code (0 == SQLITE_OK).
int db_close(void) {
    if (!g_db) return 0;
    int rc = sqlite3_close(g_db);
    g_db = 0;
    return rc;
}
