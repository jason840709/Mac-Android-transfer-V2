#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
LOCAL_ROOT="${ROOT}/.local"
BUILD_DIR="${LOCAL_ROOT}/build/swift-preflight"
STATE_DIR="${LOCAL_ROOT}/state"
STAMP="${STATE_DIR}/swift-preflight.sha256"
DEPLOYMENT_TARGET="14.0"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == "Darwin" ]] || fail "The SwiftUI preflight must run on macOS."
[[ "$(uname -m)" == "arm64" ]] || fail "The SwiftUI preflight is Apple-Silicon-only."
[[ "$(/usr/bin/id -u)" -ne 0 ]] || fail "Do not run this preflight as root or through sudo."
for tool in xcrun shasum awk find sort rm mkdir python3 cmp; do command -v "$tool" >/dev/null 2>&1 || fail "Required tool unavailable: $tool"; done

"${ROOT}/Scripts/verify-v040-drag-baseline.sh"
"${ROOT}/Scripts/verify-file-promise-v060.sh"
"${ROOT}/Scripts/verify-device-insertion-api.sh"
"${ROOT}/Scripts/verify-connection-view-swift5-r2.sh"

SDKROOT="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)" || fail "The selected macOS SDK is unavailable."
SWIFTC="$(xcrun --sdk macosx --find swiftc 2>/dev/null)" || fail "The selected Swift compiler is unavailable."
CLANG="$(xcrun --sdk macosx --find clang 2>/dev/null)" || fail "The selected Clang compiler is unavailable."

compute_input_hash() {
  {
    find "${ROOT}/Sources" -type f \( -name '*.swift' -o -name '*.h' -o -name '*.c' -o -name '*.m' \) -print | LC_ALL=C sort | while IFS= read -r file; do shasum -a 256 "$file"; done
    printf '%s\n' "${ROOT}/Scripts/preflight-swift-app.sh" "${ROOT}/Scripts/verify-device-insertion-api.sh" "${ROOT}/DeviceInsertionAgent.entitlements" "${ROOT}/Config/DeviceInsertionAgent-Info.plist" | while IFS= read -r file; do shasum -a 256 "$file"; done
    printf 'deployment-target=%s\nsdk-root=%s\n' "$DEPLOYMENT_TARGET" "$SDKROOT"
    "$SWIFTC" --version
  } | shasum -a 256 | awk '{print $1}'
}

mkdir -p "$STATE_DIR" "$LOCAL_ROOT/build"
INPUT_HASH="$(compute_input_hash)"
if [[ "${MTPBRIDGE_FORCE_PREFLIGHT:-0}" != "1" && -f "$STAMP" && "$(cat "$STAMP")" == "$INPUT_HASH" ]]; then
  printf 'SwiftUI 與隱藏裝置偵測器原始碼預檢已通過且內容未變更；略過重複檢查。\n'
  exit 0
fi
case "$BUILD_DIR" in "$LOCAL_ROOT"/*) rm -rf "$BUILD_DIR" ;; *) fail "Unsafe preflight build path." ;; esac
mkdir -p "$BUILD_DIR/ModuleCache"

# The legacy ServiceManagement compatibility bridge is intentionally isolated in
# Objective-C so deprecated API warnings never leak into Swift -warnings-as-errors.
"$CLANG" -fsyntax-only -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations \
  -target arm64-apple-macosx${DEPLOYMENT_TARGET} -isysroot "$SDKROOT" \
  -I"$ROOT/Sources/MTPDeviceRegistration" \
  "$ROOT/Sources/MTPDeviceRegistration/device_registration.m"

SWIFT_SOURCES=(
  "${ROOT}"/Sources/MTPBridgeCore/*.swift
  "${ROOT}"/Sources/MTPBridgeApp/*.swift
)
printf '正在以目前 Mac 的 SwiftUI／AppKit SDK 預檢主 App…\n'
TERM=dumb "$SWIFTC" -typecheck -parse-as-library -swift-version 5 -strict-concurrency=targeted \
  -target "arm64-apple-macosx${DEPLOYMENT_TARGET}" -sdk "${SDKROOT}" \
  -module-name MTPBridgePreflight -module-cache-path "$BUILD_DIR/ModuleCache" -warnings-as-errors \
  -import-objc-header "$ROOT/Sources/MTPBridgeApp/MTPBridge-Bridging-Header.h" \
  -Xcc -I"$ROOT/Sources/MTPBridgeCLib/include" \
  -Xcc -I"$ROOT/Sources/MTPDeviceRegistration" \
  "${SWIFT_SOURCES[@]}"

printf '正在預檢隱藏的手機插入偵測器 App…\n'
TERM=dumb "$SWIFTC" -typecheck -parse-as-library -swift-version 5 -strict-concurrency=targeted -warnings-as-errors \
  -target "arm64-apple-macosx${DEPLOYMENT_TARGET}" -sdk "${SDKROOT}" \
  -module-name MTPDeviceInsertionAgentPreflight -module-cache-path "$BUILD_DIR/ModuleCache" \
  -import-objc-header "$ROOT/Sources/MTPDeviceWatcher/MTPDeviceWatcher-Bridging-Header.h" \
  -Xcc -I"$ROOT/Sources/MTPDeviceWatcher" \
  "$ROOT/Sources/MTPBridgeCore/DeviceAgentLaunchCandidatePolicy.swift" \
  "$ROOT/Sources/MTPDeviceWatcher/MTPDeviceWatcher.swift"

printf '%s\n' "$INPUT_HASH" > "$STAMP"
printf 'SwiftUI／AppKit 與隱藏裝置偵測器原始碼預檢通過。\n'
