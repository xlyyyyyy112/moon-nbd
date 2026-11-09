#!/usr/bin/env bash
set -euo pipefail

workdir=$(mktemp -d "${TMPDIR:-/tmp}/moon-nbd-interop.XXXXXXXX")
image="$workdir/disk.raw"
qemu-img create -f raw "$image" 1M
qemu-nbd --fork --bind=127.0.0.1 --port=11089 --format=raw "$image"
moon run --target native cmd/main
