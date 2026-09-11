#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP_VERSION="0.7.0"
APP_BUILD="22"
LOCAL_ROOT="${ROOT}/.local"
BUILD_DIR="${LOCAL_ROOT}/build/app"
STATE_DIR="${LOCAL_ROOT}/state"
DIST="${ROOT}/dist"
APP="${DIST}/Android 傳輸 V2.app"
STAGING="${DIST}/.Android-Transfer-V2.app.staging"
BACKUP="${DIST}/.Android-Transfer-V2.app.previous"
BUNDLE_ID="io.github.mtpbridge.MTPBridge"
AGENT_APP_NAME="Android 傳輸 V2 裝置偵測器.app"
AGENT_BUNDLE_ID="io.github.mtpbridge.DeviceInsertionAgentV2"
AGENT_EXECUTABLE="AndroidTransferV2DeviceAgent"
AGENT_APP="${STAGING}/Contents/Library/LoginItems/${AGENT_APP_NAME}"
DEPLOYMENT_TARGET="14.0"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "The local App builder must run on macOS."
[[ "$(uname -m)" == "arm64" ]] || fail "The local App builder is Apple-Silicon-only."
[[ "$(/usr/bin/id -u)" -ne 0 ]] || fail "Do not run this builder as root or through sudo."
for tool in xcrun shasum awk find sort cp mv rm mkdir chmod security codesign plutil; do
  command -v "${tool}" >/dev/null 2>&1 || fail "Required system/developer tool is unavailable: ${tool}"
done
[[ -x /usr/libexec/PlistBuddy ]] || fail "Required macOS tool is unavailable: /usr/libexec/PlistBuddy"

SDKROOT="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)" || \
  fail "Apple Command Line Tools or Xcode are not configured. The installer does not install, switch, or update them automatically."
SWIFTC="$(xcrun --sdk macosx --find swiftc)"
CLANG="$(xcrun --sdk macosx --find clang)"
STRIP="$(xcrun --find strip 2>/dev/null || true)"

"${ROOT}/Scripts/preflight-swift-app.sh"

for path in \
  "${ROOT}/Vendor/include/libmtp.h" \
  "${ROOT}/Vendor/include/libusb.h" \
  "${ROOT}/Vendor/lib/libmtp.dylib" \
  "${ROOT}/Vendor/lib/libusb-1.0.dylib" \
  "${ROOT}/Resources/MTPBridge.icns" \
  "${ROOT}/Config/DeviceInsertionAgent-Info.plist" \
  "${ROOT}/DeviceInsertionAgent.entitlements" \
  "${ROOT}/Sources/MTPDeviceRegistration/device_registration.h" \
  "${ROOT}/Sources/MTPDeviceRegistration/device_registration.m"
do
  [[ -f "${path}" ]] || fail "Missing build input: ${path}."
done

mkdir -p "${BUILD_DIR}" "${STATE_DIR}" "${DIST}"

compute_input_hash() {
  {
    find "${ROOT}/Sources" "${ROOT}/Resources" "${ROOT}/Vendor/include" \
      "${ROOT}/Vendor/lib" "${ROOT}/Vendor/licenses" -type f -print
    printf '%s\n' \
      "${ROOT}/MTPBridge.entitlements" \
      "${ROOT}/DeviceInsertionAgent.entitlements" \
      "${ROOT}/Config/DeviceInsertionAgent-Info.plist" \
      "${ROOT}/THIRD_PARTY_NOTICES.md" \
      "${ROOT}/Scripts/build-local-app.sh" \
      "${ROOT}/Scripts/audit-local-app.sh"
    if [[ -f "${ROOT}/Vendor/DEPENDENCY_PROVENANCE.txt" ]]; then
      printf '%s\n' "${ROOT}/Vendor/DEPENDENCY_PROVENANCE.txt"
    fi
  } | LC_ALL=C sort | while IFS= read -r file; do
    shasum -a 256 "${file}"
  done | shasum -a 256 | awk '{print $1}'
}

INPUT_HASH="$(compute_input_hash)"
STAMP="${STATE_DIR}/app-build.sha256"
if [[ "${MTPBRIDGE_FORCE_REBUILD:-0}" != "1" && -d "${APP}" && -f "${STAMP}" ]] && \
   [[ "$(cat "${STAMP}")" == "${INPUT_HASH}" ]]; then
  if MTPBRIDGE_REQUIRE_DEVICE_AGENT=1 "${ROOT}/Scripts/audit-local-app.sh" "${APP}" >/dev/null 2>&1; then
    printf 'Android 傳輸 V2.app 已是最新版本，不重複編譯。\n'
    exit 0
  fi
fi

case "${BUILD_DIR}" in "${LOCAL_ROOT}"/*) rm -rf "${BUILD_DIR}" ;; *) fail "Unsafe build path." ;; esac
mkdir -p "${BUILD_DIR}/ModuleCache"
case "${STAGING}" in "${DIST}"/*) rm -rf "${STAGING}" ;; *) fail "Unsafe staging path." ;; esac
mkdir -p \
  "${STAGING}/Contents/MacOS" \
  "${STAGING}/Contents/Frameworks" \
  "${STAGING}/Contents/Resources" \
  "${AGENT_APP}/Contents/MacOS" \
  "${AGENT_APP}/Contents/Frameworks"

printf '正在編譯 C MTP bridge…\n'
"${CLANG}" \
  -std=c11 -Wall -Wextra -Werror -O2 \
  -arch arm64 -mmacosx-version-min="${DEPLOYMENT_TARGET}" -isysroot "${SDKROOT}" \
  -I"${ROOT}/Sources/MTPBridgeCLib/include" \
  -I"${ROOT}/Vendor/include" \
  -c "${ROOT}/Sources/MTPBridgeCLib/mtp_bridge.c" \
  -o "${BUILD_DIR}/mtp_bridge.o"

printf '正在編譯登入項目相容註冊橋接…\n'
"${CLANG}" \
  -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations -O2 \
  -arch arm64 -mmacosx-version-min="${DEPLOYMENT_TARGET}" -isysroot "${SDKROOT}" \
  -I"${ROOT}/Sources/MTPDeviceRegistration" \
  -c "${ROOT}/Sources/MTPDeviceRegistration/device_registration.m" \
  -o "${BUILD_DIR}/device_registration.o"

SWIFT_SOURCES=(
  "${ROOT}"/Sources/MTPBridgeCore/*.swift
  "${ROOT}"/Sources/MTPBridgeApp/*.swift
)

printf '正在編譯 arm64 SwiftUI App…\n'
"${SWIFTC}" \
  -parse-as-library \
  -swift-version 5 \
  -strict-concurrency=targeted \
  -target "arm64-apple-macosx${DEPLOYMENT_TARGET}" \
  -sdk "${SDKROOT}" \
  -module-name MTPBridge \
  -module-cache-path "${BUILD_DIR}/ModuleCache" \
  -import-objc-header "${ROOT}/Sources/MTPBridgeApp/MTPBridge-Bridging-Header.h" \
  -Xcc -I"${ROOT}/Sources/MTPBridgeCLib/include" \
  -Xcc -I"${ROOT}/Sources/MTPDeviceRegistration" \
  -Xcc -I"${ROOT}/Vendor/include" \
  -O -whole-module-optimization \
  "${SWIFT_SOURCES[@]}" \
  "${BUILD_DIR}/mtp_bridge.o" \
  "${BUILD_DIR}/device_registration.o" \
  -L"${ROOT}/Vendor/lib" \
  -lmtp -lusb-1.0 \
  -framework ServiceManagement -framework CoreFoundation \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  -Xlinker -dead_strip \
  -o "${STAGING}/Contents/MacOS/MTPBridge"

printf '正在編譯隱藏的 Android 裝置偵測器 App…\n'
"${CLANG}" \
  -std=c11 -Wall -Wextra -Werror -O2 \
  -arch arm64 -mmacosx-version-min="${DEPLOYMENT_TARGET}" -isysroot "${SDKROOT}" \
  -I"${ROOT}/Sources/MTPDeviceWatcher" \
  -I"${ROOT}/Vendor/include" \
  -c "${ROOT}/Sources/MTPDeviceWatcher/mtp_device_watcher.c" \
  -o "${BUILD_DIR}/mtp_device_watcher.o"

"${SWIFTC}" \
  -parse-as-library \
  -swift-version 5 \
  -strict-concurrency=targeted \
  -target "arm64-apple-macosx${DEPLOYMENT_TARGET}" \
  -sdk "${SDKROOT}" \
  -module-name MTPDeviceInsertionAgent \
  -module-cache-path "${BUILD_DIR}/ModuleCache" \
  -import-objc-header "${ROOT}/Sources/MTPDeviceWatcher/MTPDeviceWatcher-Bridging-Header.h" \
  -Xcc -I"${ROOT}/Sources/MTPDeviceWatcher" \
  -Xcc -I"${ROOT}/Vendor/include" \
  -O -whole-module-optimization \
  "${ROOT}/Sources/MTPBridgeCore/DeviceAgentLaunchCandidatePolicy.swift" \
  "${ROOT}/Sources/MTPDeviceWatcher/MTPDeviceWatcher.swift" \
  "${BUILD_DIR}/mtp_device_watcher.o" \
  -L"${ROOT}/Vendor/lib" \
  -lmtp -lusb-1.0 \
  -framework IOKit -framework CoreFoundation \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  -Xlinker -dead_strip \
  -o "${AGENT_APP}/Contents/MacOS/${AGENT_EXECUTABLE}"

cp "${ROOT}/Vendor/lib/libmtp.dylib" "${STAGING}/Contents/Frameworks/libmtp.dylib"
cp "${ROOT}/Vendor/lib/libusb-1.0.dylib" "${STAGING}/Contents/Frameworks/libusb-1.0.dylib"
cp "${ROOT}/Vendor/lib/libmtp.dylib" "${AGENT_APP}/Contents/Frameworks/libmtp.dylib"
cp "${ROOT}/Vendor/lib/libusb-1.0.dylib" "${AGENT_APP}/Contents/Frameworks/libusb-1.0.dylib"
cp "${ROOT}/Config/DeviceInsertionAgent-Info.plist" "${AGENT_APP}/Contents/Info.plist"
cp "${ROOT}/Resources/MTPBridge.icns" "${STAGING}/Contents/Resources/MTPBridge.icns"
mkdir -p "${STAGING}/Contents/Resources/en.lproj" "${STAGING}/Contents/Resources/zh-Hant.lproj"
cp "${ROOT}/Resources/en.lproj/Localizable.strings" "${STAGING}/Contents/Resources/en.lproj/Localizable.strings"
cp "${ROOT}/Resources/zh-Hant.lproj/Localizable.strings" "${STAGING}/Contents/Resources/zh-Hant.lproj/Localizable.strings"
cp "${ROOT}/Resources/en.lproj/Credits.rtf" "${STAGING}/Contents/Resources/en.lproj/Credits.rtf"
cp "${ROOT}/Resources/zh-Hant.lproj/Credits.rtf" "${STAGING}/Contents/Resources/zh-Hant.lproj/Credits.rtf"
cp "${ROOT}/THIRD_PARTY_NOTICES.md" "${STAGING}/Contents/Resources/THIRD_PARTY_NOTICES.md"
if [[ -f "${ROOT}/Vendor/DEPENDENCY_PROVENANCE.txt" ]]; then
  cp "${ROOT}/Vendor/DEPENDENCY_PROVENANCE.txt" "${STAGING}/Contents/Resources/DEPENDENCY_PROVENANCE.txt"
fi
if [[ -d "${ROOT}/Vendor/licenses" ]]; then
  mkdir -p "${STAGING}/Contents/Resources/ThirdPartyLicenses"
  find "${ROOT}/Vendor/licenses" -type f ! -name '.gitkeep' -exec cp {} "${STAGING}/Contents/Resources/ThirdPartyLicenses/" \;
fi

cat > "${STAGING}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>Android 傳輸 V2</string>
    <key>CFBundleExecutable</key><string>MTPBridge</string>
    <key>CFBundleGetInfoString</key><string>Android 傳輸 V2 ${APP_VERSION} — local isolated build</string>
    <key>CFBundleIconFile</key><string>MTPBridge.icns</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hant</string></array>
    <key>CFBundleName</key><string>Android 傳輸 V2</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
    <key>CFBundleVersion</key><string>${APP_BUILD}</string>
    <key>ITSAppUsesNonExemptEncryption</key><false/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key><string>${DEPLOYMENT_TARGET}</string>
    <key>LSMultipleInstancesProhibited</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Jason Chen</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>MTPBridgeBuildMode</key><string>project-local-source</string>
    <key>MTPBridgePackageID</key><string>0.7.0-device-launch-r1</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "${STAGING}/Contents/Info.plist" "${AGENT_APP}/Contents/Info.plist" >/dev/null
chmod 755 \
  "${STAGING}/Contents/MacOS/MTPBridge" \
  "${STAGING}/Contents/Frameworks/"*.dylib \
  "${AGENT_APP}/Contents/MacOS/${AGENT_EXECUTABLE}" \
  "${AGENT_APP}/Contents/Frameworks/"*.dylib
chmod 644 "${STAGING}/Contents/Info.plist" "${AGENT_APP}/Contents/Info.plist" "${STAGING}/Contents/Resources/MTPBridge.icns"

if [[ -n "${STRIP}" && "${MTPBRIDGE_SKIP_STRIP:-0}" != "1" ]]; then
  "${STRIP}" -S "${STAGING}/Contents/MacOS/MTPBridge" || true
  "${STRIP}" -S "${STAGING}/Contents/Frameworks/libmtp.dylib" || true
  "${STRIP}" -S "${STAGING}/Contents/Frameworks/libusb-1.0.dylib" || true
  "${STRIP}" -S "${AGENT_APP}/Contents/MacOS/${AGENT_EXECUTABLE}" || true
  "${STRIP}" -S "${AGENT_APP}/Contents/Frameworks/libmtp.dylib" || true
  "${STRIP}" -S "${AGENT_APP}/Contents/Frameworks/libusb-1.0.dylib" || true
fi

SIGNING_IDENTITY="${MTPBRIDGE_SIGNING_IDENTITY:-}"
REQUIRE_DEVELOPER_ID="${MTPBRIDGE_REQUIRE_DEVELOPER_ID:-0}"
SIGNING_TIMESTAMP="${MTPBRIDGE_SIGNING_TIMESTAMP:-0}"

find_identity() {
  local expression="$1" line
  line="$(security find-identity -v -p codesigning 2>/dev/null | grep -E "\"${expression}:" | head -n 1 || true)"
  if [[ -n "${line}" ]]; then
    line="${line#*\"}"
    printf '%s\n' "${line%\"*}"
  fi
}

if [[ -z "${SIGNING_IDENTITY}" ]]; then
  if [[ "${REQUIRE_DEVELOPER_ID}" == "1" ]]; then
    SIGNING_IDENTITY="$(find_identity 'Developer ID Application' || true)"
  else
    SIGNING_IDENTITY="$(find_identity 'Apple Development' || true)"
    [[ -n "${SIGNING_IDENTITY}" ]] || SIGNING_IDENTITY="$(find_identity 'Developer ID Application' || true)"
  fi
fi
if [[ "${REQUIRE_DEVELOPER_ID}" == "1" && "${SIGNING_IDENTITY}" != Developer\ ID\ Application:* ]]; then
  fail "Release build requires a Developer ID Application signing identity."
fi

sign_leaf() {
  local target="$1"
  if [[ -n "${SIGNING_IDENTITY}" ]]; then
    local arguments=(--force --sign "${SIGNING_IDENTITY}" --options runtime)
    [[ "${SIGNING_TIMESTAMP}" == "1" ]] && arguments+=(--timestamp) || arguments+=(--timestamp=none)
    /usr/bin/codesign "${arguments[@]}" "${target}"
  else
    /usr/bin/codesign --force --sign - "${target}"
  fi
}

sign_bundle() {
  local target="$1" entitlements="$2"
  if [[ -n "${SIGNING_IDENTITY}" ]]; then
    local arguments=(--force --sign "${SIGNING_IDENTITY}" --options runtime --entitlements "${entitlements}")
    [[ "${SIGNING_TIMESTAMP}" == "1" ]] && arguments+=(--timestamp) || arguments+=(--timestamp=none)
    /usr/bin/codesign "${arguments[@]}" "${target}"
  else
    /usr/bin/codesign --force --sign - --entitlements "${entitlements}" "${target}"
  fi
}

# Sign inside-out. The hidden agent has its own sandbox+USB entitlements, matching
# the sandboxed parent app instead of installing an unsandboxed launchd job.
sign_leaf "${AGENT_APP}/Contents/Frameworks/libusb-1.0.dylib"
sign_leaf "${AGENT_APP}/Contents/Frameworks/libmtp.dylib"
sign_bundle "${AGENT_APP}" "${ROOT}/DeviceInsertionAgent.entitlements"
sign_leaf "${STAGING}/Contents/Frameworks/libusb-1.0.dylib"
sign_leaf "${STAGING}/Contents/Frameworks/libmtp.dylib"
sign_bundle "${STAGING}" "${ROOT}/MTPBridge.entitlements"

if [[ -n "${SIGNING_IDENTITY}" ]]; then
  SIGNING_MODE="identity: ${SIGNING_IDENTITY}"
else
  SIGNING_MODE="ad-hoc"
fi

MTPBRIDGE_REQUIRE_DEVICE_AGENT=1 "${ROOT}/Scripts/audit-local-app.sh" "${STAGING}"

case "${BACKUP}" in "${DIST}"/*) rm -rf "${BACKUP}" ;; *) fail "Unsafe backup path." ;; esac
if [[ -d "${APP}" ]]; then mv "${APP}" "${BACKUP}"; fi
if mv "${STAGING}" "${APP}"; then
  rm -rf "${BACKUP}"
else
  [[ -d "${BACKUP}" ]] && mv "${BACKUP}" "${APP}"
  fail "Could not atomically replace the local App."
fi

printf '%s\n' "${INPUT_HASH}" > "${STAMP}"
cat > "${DIST}/INSTALLATION_REPORT.txt" <<REPORT
Android 傳輸 V2 ${APP_VERSION} local installation
App: ${APP}
Generated data: ${LOCAL_ROOT}
Signing: ${SIGNING_MODE}
Architecture: arm64
Minimum macOS: ${DEPLOYMENT_TARGET}
Embedded device agent: Contents/Library/LoginItems/${AGENT_APP_NAME}
Device agent bundle identifier: ${AGENT_BUNDLE_ID}
Auto-open behavior: hidden login-item helper is started for the current session and registered for future logins; modern SMAppService is preferred with deprecated ServiceManagement compatibility fallback for local builds
System packages changed: none
REPORT

printf '\n建立完成：\n%s\n' "${APP}"
printf '簽章模式：%s\n' "${SIGNING_MODE}"
printf '手機插入偵測器：%s\n' "${APP}/Contents/Library/LoginItems/${AGENT_APP_NAME}"
printf '所有下載、快取與中間檔都留在：%s\n' "${LOCAL_ROOT}"
