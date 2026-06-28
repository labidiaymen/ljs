#!/bin/sh
# Build the SQLite example: compile the C shim, then build the Lumen program
# that links it. Run from this directory.
set -e

# 1. Compile the C shim against the installed SQLite headers.
cc -c sqlite_shim.c -I/opt/homebrew/opt/sqlite/include -o sqlite_shim.o

# 2. Build the Lumen program. The // @link pragmas in sqlite.ts pull in the
#    shim object and libsqlite3.
../../zig-out/bin/lumen compile app.ts

echo "built ./app"
