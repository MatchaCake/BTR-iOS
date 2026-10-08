#!/usr/bin/env bash
# Host tests: builds the Foundation-only sources for macOS with BTR_TESTING and runs them
# against three loopback servers (fast, slow, refusing).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun clang -fobjc-arc -fmodules -DBTR_TESTING -O1 -g -Wall -Wno-unused-parameter \
  -framework Foundation -lz \
  src/BTRCore.m src/BTRRewriter.m src/BTRProxy.m src/BTRHooks.m tests/BTRTests.m \
  -o build/BTRTests

OK=18731; SLOW=18732; BAD=18733
python3 tests/range_server.py $OK ok & P1=$!
python3 tests/range_server.py $SLOW slow & P2=$!
python3 tests/range_server.py $BAD forbidden & P3=$!
trap 'kill $P1 $P2 $P3 2>/dev/null || true' EXIT
for port in $OK $SLOW $BAD; do
  for _ in $(seq 1 50); do
    if curl -s -o /dev/null "http://127.0.0.1:$port/"; then break; fi
    sleep 0.1
  done
done
./build/BTRTests $OK $SLOW $BAD
