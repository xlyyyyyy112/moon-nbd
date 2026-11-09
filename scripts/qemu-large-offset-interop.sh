#!/usr/bin/env bash
set -euo pipefail
workdir=$(mktemp -d "${TMPDIR:-/tmp}/moon-nbd-large-interop.XXXXXXXX")
input="$workdir/input.raw"
output="$workdir/output.raw"
qemu-img create -f raw "$input" 5G
qemu-io -f raw -c 'write -P 0x5a 4294967296 512' "$input"
qemu-nbd --fork --bind=127.0.0.1 --port=11093 --read-only --format=raw "$input"
moon run --target native cmd/nbd -- read 127.0.0.1 11093 4294967296 512 "$output"
qemu-io -f raw -c 'read -P 0x5a 0 512' "$output"
