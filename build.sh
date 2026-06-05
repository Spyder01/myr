#!/bin/sh
set -e

ODIN=${ODIN:-/Users/suhanj/.lang/Odin/odin}
OUT=bin/myr

mkdir -p bin
$ODIN build . -o:speed -out:$OUT
echo "built $OUT"
