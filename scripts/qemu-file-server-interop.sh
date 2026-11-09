#!/usr/bin/env bash
set -euo pipefail
workdir=$(mktemp -d "${TMPDIR:-/tmp}/moon-nbd-file-interop.XXXXXXXX")
image="$workdir/disk.raw"
qemu-img create -f raw "$image" 1M
moon build --target native cmd/nbd
server=_build/native/debug/build/cmd/nbd/nbd.exe
"$server" serve "$image" 11091 --write &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT
sleep 1
qemu-io -f raw -c 'write -P 0x6b 512 512' -c 'flush' -c 'read -P 0x6b 512 512' 'nbd://127.0.0.1:11091/'
kill "$server_pid"
wait "$server_pid" 2>/dev/null || true
trap - EXIT
qemu-io -f raw -c 'read -P 0x6b 512 512' "$image"
