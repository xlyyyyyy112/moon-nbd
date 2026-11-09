#!/usr/bin/env bash
set -euo pipefail

# A raw image begins as zero-filled. Keep a small non-zero island so this test
# verifies both the base:allocation sparse path and byte-for-byte restoration.
workdir=$(mktemp -d "${TMPDIR:-/tmp}/moon-nbd-sparse-export.XXXXXXXX")
input="$workdir/input.raw"
output="$workdir/output.raw"
qemu-img create -f raw "$input" 8M
qemu-io -f raw -c 'write -P 0x5a 1048576 8192' "$input"
qemu-nbd --fork --bind=127.0.0.1 --port=11094 --read-only --format=raw "$input"
moon run --target native cmd/nbd -- export-sparse 127.0.0.1 11094 "$output"
cmp "$input" "$output"
