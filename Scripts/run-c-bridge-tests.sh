#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${ROOT}/.build"
BRIDGE_OUTPUT="${BUILD_ROOT}/c-bridge-tests"
WATCHER_OUTPUT="${BUILD_ROOT}/c-device-watcher-tests"
mkdir -p "${BUILD_ROOT}"

clang -std=c11 -Wall -Wextra -Werror -pthread \
  -I"${ROOT}/Sources/MTPBridgeCLib/include" \
  -I"${ROOT}/Tests/CBridgeStub" \
  -I"${ROOT}/Tests/CBridgeTests" \
  "${ROOT}/Sources/MTPBridgeCLib/mtp_bridge.c" \
  "${ROOT}/Tests/CBridgeTests/fake_libmtp.c" \
  "${ROOT}/Tests/CBridgeTests/bridge_tests.c" \
  -o "${BRIDGE_OUTPUT}"
"${BRIDGE_OUTPUT}"

clang -std=c11 -Wall -Wextra -Werror \
  -I"${ROOT}/Sources/MTPDeviceWatcher" \
  "${ROOT}/Sources/MTPDeviceWatcher/mtp_device_watcher.c" \
  "${ROOT}/Tests/DeviceWatcherTests/watcher_state_tests.c" \
  -o "${WATCHER_OUTPUT}"
"${WATCHER_OUTPUT}"
