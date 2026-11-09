#!/usr/bin/env bash
set -euo pipefail
workdir=$(mktemp -d "${TMPDIR:-/tmp}/moon-nbd-export-interop.XXXXXXXX")
input="$workdir/input.raw"
output="$workdir/output.raw"
qemu-img create -f raw "$input" 1M
qemu-io -f raw -c 'write -P 0xa5 4096 4096' "$input"
qemu-nbd --fork --bind=127.0.0.1 --port=11092 --read-only --format=raw "$input"
moon run --target native cmd/nbd -- export 127.0.0.1 11092 "$output"
cmp "$input" "$output"
