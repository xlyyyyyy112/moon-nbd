#!/usr/bin/env bash
set -euo pipefail
moon build --target native cmd/server
server=_build/native/debug/build/cmd/server/server.exe
"$server" &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT
sleep 1
qemu-io -f raw -c 'write -P 0x5a 0 512' -c 'read -P 0x5a 0 512' 'nbd://127.0.0.1:11090/'
wait "$server_pid"
trap - EXIT
