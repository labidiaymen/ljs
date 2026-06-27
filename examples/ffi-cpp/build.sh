#!/bin/sh
# Compile the C++ source to an object file, then build the Lumen program that
# links it. Run from this directory.
set -e
zig c++ -O2 -c geometry.cpp -o geometry.o
../../zig-out/bin/lumen compile demo.ts
echo "built ./demo"
