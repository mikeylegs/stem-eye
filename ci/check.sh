#!/bin/bash
# Stem Eye CI check (GitHub's Mac): the iPad's frame code compiled for macOS, fed a djay screen recording, talking to a
# stand-in Controller that runs the Controller's own stem reader. See ci/main.swift for what it checks.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build build-logs
echo "== compile the check (Shared + Broadcast sources, macOS)"
xcrun -sdk macosx swiftc -O -swift-version 5 -o build/stemeye-check \
  Shared/Program.swift Shared/Shared.swift Broadcast/TileSampler.swift Broadcast/Pipeline.swift ci/main.swift \
  2>&1 | tee build-logs/check-compile.log
node --version
node ci/reader-server.js 18990 > build-logs/reader-server.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
for i in $(seq 1 50); do
  if curl -fs http://127.0.0.1:18990/sr/program > /dev/null; then break; fi
  sleep 0.2
done
curl -fs http://127.0.0.1:18990/sr/program > /dev/null || { echo "the stand-in Controller did not start"; cat build-logs/reader-server.log; exit 1; }
build/stemeye-check ci/djay-clip.mp4 http://127.0.0.1:18990 2>&1 | tee build-logs/check.log
