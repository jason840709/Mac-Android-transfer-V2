#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${ROOT}/.build/mtp-smoke-test"
mkdir -p "$(dirname "${OUTPUT}")"
clang -std=c11 -arch arm64 -mmacosx-version-min=14.0 \
  -I"${ROOT}/Sources/MTPBridgeCLib/include" \
  -I"${ROOT}/Vendor/include" \
  "${ROOT}/Sources/MTPBridgeCLib/mtp_bridge.c" \
  "${ROOT}/Scripts/mtp-smoke-test.c" \
  -L"${ROOT}/Vendor/lib" -lmtp -lusb-1.0 \
  -Wl,-rpath,"${ROOT}/Vendor/lib" \
  -o "${OUTPUT}"
"${OUTPUT}"
