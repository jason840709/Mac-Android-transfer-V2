#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP_VERSION="0.7.0"
APP_BUILD="22"
source "${ROOT}/Scripts/macho-utils.sh"
APP="${1:-${ROOT}/dist/Android 傳輸 V2.app}"
AGENT_APP_NAME="Android 傳輸 V2 裝置偵測器.app"
AGENT_BUNDLE_ID="io.github.mtpbridge.DeviceInsertionAgentV2"
AGENT_EXECUTABLE_NAME="AndroidTransferV2DeviceAgent"
AGENT_APP="${APP}/Contents/Library/LoginItems/${AGENT_APP_NAME}"
AGENT_PLIST="${AGENT_APP}/Contents/Info.plist"
AGENT_EXECUTABLE="${AGENT_APP}/Contents/MacOS/${AGENT_EXECUTABLE_NAME}"
AGENT_FRAMEWORKS="${AGENT_APP}/Contents/Frameworks"

fail(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == "Darwin" ]] || fail "App auditing requires macOS tools."
[[ -d "$APP" ]] || fail "App bundle not found: $APP"
for tool in /usr/bin/codesign /usr/bin/file /usr/bin/otool /usr/bin/lipo /usr/libexec/PlistBuddy /usr/bin/plutil; do [[ -x "$tool" ]] || fail "Required macOS tool unavailable: $tool"; done

PLIST="$APP/Contents/Info.plist"; [[ -f "$PLIST" ]] || fail "Missing Contents/Info.plist."; /usr/bin/plutil -lint "$PLIST" >/dev/null
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
EXECUTABLE="$APP/Contents/MacOS/$EXECUTABLE_NAME"
FRAMEWORKS="$APP/Contents/Frameworks"; RESOURCES="$APP/Contents/Resources"
[[ -x "$EXECUTABLE" ]] || fail "Main executable is missing: $EXECUTABLE"
for framework in "$FRAMEWORKS/libmtp.dylib" "$FRAMEWORKS/libusb-1.0.dylib"; do [[ -f "$framework" ]] || fail "Embedded framework missing: $framework"; done
for resource in "$RESOURCES/MTPBridge.icns" "$RESOURCES/en.lproj/Localizable.strings" "$RESOURCES/zh-Hant.lproj/Localizable.strings" "$RESOURCES/en.lproj/Credits.rtf" "$RESOURCES/zh-Hant.lproj/Credits.rtf"; do [[ -f "$resource" ]] || fail "Required resource missing: $resource"; done

# 0.6.11 makes the hidden agent a required part of this product build. Never
# silently ship a core-only app that exposes a non-functional enabled toggle.
[[ -d "$AGENT_APP" ]] || fail "Required hidden device-agent app is missing: $AGENT_APP"
[[ -f "$AGENT_PLIST" ]] || fail "Hidden device-agent Info.plist is missing."
[[ -x "$AGENT_EXECUTABLE" ]] || fail "Hidden device-agent executable is missing."
/usr/bin/plutil -lint "$AGENT_PLIST" >/dev/null
agent_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$AGENT_PLIST")"
agent_exec="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$AGENT_PLIST")"
agent_background="$(/usr/libexec/PlistBuddy -c 'Print :LSBackgroundOnly' "$AGENT_PLIST")"
agent_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$AGENT_PLIST")"
agent_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$AGENT_PLIST")"
[[ "$agent_id" == "$AGENT_BUNDLE_ID" ]] || fail "Unexpected hidden agent bundle identifier: $agent_id"
[[ "$agent_exec" == "$AGENT_EXECUTABLE_NAME" ]] || fail "Unexpected hidden agent executable: $agent_exec"
[[ "$agent_background" == "true" ]] || fail "Hidden device agent must use LSBackgroundOnly."
[[ "$agent_version" == "$APP_VERSION" && "$agent_build" == "$APP_BUILD" ]] || fail "Hidden agent version/build is not aligned with main app."
for framework in "$AGENT_FRAMEWORKS/libmtp.dylib" "$AGENT_FRAMEWORKS/libusb-1.0.dylib"; do [[ -f "$framework" ]] || fail "Hidden agent framework missing: $framework"; done

# The failed 0.6.4 LaunchAgent experiment must not be embedded alongside the new
# old-AFT-style hidden helper application.
if [[ -e "$APP/Contents/Library/LaunchAgents/io.github.mtpbridge.DeviceWatcher.plist" || -e "$APP/Contents/MacOS/AndroidTransferV2DeviceWatcher" ]]; then
  fail "Retired 0.6.4 LaunchAgent payload is still embedded."
fi

main_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
main_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
[[ "$main_version" == "$APP_VERSION" ]] || fail "Unexpected app version: $main_version; expected $APP_VERSION"
[[ "$main_build" == "$APP_BUILD" ]] || fail "Unexpected app build: $main_build; expected $APP_BUILD"

check_binary(){
  local binary="$1" archs dependencies nonportable
  archs="$(MTPBRIDGE_LIPO=/usr/bin/lipo MTPBRIDGE_FILE_TOOL=/usr/bin/file mtpbridge_macho_architectures "$binary" 2>/dev/null || true)"
  [[ "$archs" == "arm64" ]] || fail "$(basename "$binary") must be arm64-only; found: ${archs:-unknown}"
  dependencies="$(MTPBRIDGE_OTOOL=/usr/bin/otool mtpbridge_otool_dependencies "$binary")" || fail "Could not inspect dependencies for $(basename "$binary")."
  nonportable="$(printf '%s\n' "$dependencies" | mtpbridge_nonportable_dependencies)"
  [[ -z "$nonportable" ]] || { printf '%s:\n%s\n' "$binary" "$nonportable" >&2; fail "$(basename "$binary") contains a non-relocatable dependency."; }
}
for binary in "$EXECUTABLE" "$FRAMEWORKS/libmtp.dylib" "$FRAMEWORKS/libusb-1.0.dylib" "$AGENT_EXECUTABLE" "$AGENT_FRAMEWORKS/libmtp.dylib" "$AGENT_FRAMEWORKS/libusb-1.0.dylib"; do check_binary "$binary"; done

verify_rpath_linkage(){
  local executable="$1" frameworks="$2" executable_dependencies mtp_dependencies
  executable_dependencies="$(MTPBRIDGE_OTOOL=/usr/bin/otool mtpbridge_otool_dependencies "$executable")" || fail "Could not inspect dependencies for $executable."
  mtp_dependencies="$(MTPBRIDGE_OTOOL=/usr/bin/otool mtpbridge_otool_dependencies "$frameworks/libmtp.dylib")" || fail "Could not inspect libmtp dependencies."
  /usr/bin/grep -Fxq '@rpath/libmtp.dylib' <<<"$executable_dependencies" || fail "$(basename "$executable") is not linked to @rpath/libmtp.dylib."
  /usr/bin/grep -Fxq '@rpath/libusb-1.0.dylib' <<<"$mtp_dependencies" || fail "libmtp is not linked to @rpath/libusb-1.0.dylib."
}
verify_rpath_linkage "$EXECUTABLE" "$FRAMEWORKS"
verify_rpath_linkage "$AGENT_EXECUTABLE" "$AGENT_FRAMEWORKS"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$AGENT_APP"
main_entitlements="$(/usr/bin/codesign -d --entitlements :- "$APP" 2>&1)"
for key in com.apple.security.app-sandbox com.apple.security.device.usb com.apple.security.files.user-selected.read-write com.apple.security.files.bookmarks.app-scope; do printf '%s\n' "$main_entitlements" | /usr/bin/grep -Fq "$key" || fail "Signed app missing entitlement: $key"; done
agent_entitlements="$(/usr/bin/codesign -d --entitlements :- "$AGENT_APP" 2>&1)"
for key in com.apple.security.app-sandbox com.apple.security.device.usb; do printf '%s\n' "$agent_entitlements" | /usr/bin/grep -Fq "$key" || fail "Signed hidden agent missing entitlement: $key"; done

minimum_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
printf 'Local app audit passed: Android 傳輸 V2 %s (build %s), required hidden LoginItems device agent included, macOS %s+, arm64-only.\n' "$main_version" "$main_build" "$minimum_system"
