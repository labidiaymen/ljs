#!/bin/sh
# Compile the C shim to an object file, build the Lumen program that links it,
# then run it. Run from this directory. Prints: HI THERE
set -e
cc -c shim.c -o shim.o
../../../../zig-out/bin/lumen compile demo.ts
./demo
