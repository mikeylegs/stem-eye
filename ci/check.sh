#!/bin/bash
# Stem Eye CI check (GitHub's Mac): the iPad's frame code compiled for macOS, fed a djay screen recording, talking to a
# stand-in Controller that runs the Controller's own stem reader. See ci/main.swift for what it checks.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build build-logs
echo "== compile the check (Shared + Broadcast sources, macOS)"
if ! xcrun -sdk macosx swiftc -O -swift-version 5 -o build/stemeye-check \
  Shared/Program.swift Shared/Shared.swift Broadcast/TileSampler.swift Broadcast/Pipeline.swift ci/main.swift \
  > build-logs/check-compile.log 2>&1; then
  cat build-logs/check-compile.log; bash ci/annotate.sh "check: swiftc" build-logs/check-compile.log "error:" 60; exit 1
fi
cat build-logs/check-compile.log
node --version
node ci/reader-server.js 18990 > build-logs/reader-server.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
for i in $(seq 1 50); do
  if curl -fs http://127.0.0.1:18990/sr/program > /dev/null; then break; fi
  sleep 0.2
done
curl -fs http://127.0.0.1:18990/sr/program > /dev/null || { echo "the stand-in Controller did not start"; cat build-logs/reader-server.log; exit 1; }
if ! build/stemeye-check ci/djay-clip.mp4 http://127.0.0.1:18990 > build-logs/check.log 2>&1; then
  cat build-logs/check.log; bash ci/annotate.sh "check: failed" build-logs/check.log "FAIL|rror|fatal|\\[main\\] \\{|\\[flip\\] \\{" 60; exit 1
fi
cat build-logs/check.log
bash ci/annotate.sh "check: passed (notice)" build-logs/check.log "PASS|ALL" 80 | sed 's/^::error/::notice/' 
