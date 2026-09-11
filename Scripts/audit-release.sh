#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${ROOT}/Scripts/macho-utils.sh"
APP="${1:-${ROOT}/dist/Android 傳輸 V2.app}"
APP_VERSION="0.7.0"
APP_BUILD="22"
AGENT_APP_NAME="Android 傳輸 V2 裝置偵測器.app"
AGENT_BUNDLE_ID="io.github.mtpbridge.DeviceInsertionAgentV2"
AGENT_EXECUTABLE_NAME="AndroidTransferV2DeviceAgent"
AGENT_APP="${APP}/Contents/Library/LoginItems/${AGENT_APP_NAME}"
AGENT_PLIST="${AGENT_APP}/Contents/Info.plist"
AGENT_EXECUTABLE="${AGENT_APP}/Contents/MacOS/${AGENT_EXECUTABLE_NAME}"
AGENT_FRAMEWORKS="${AGENT_APP}/Contents/Frameworks"
fail(){ echo "error: $*" >&2; exit 1; }
[[ "$(uname -s)" == "Darwin" ]] || fail "Release auditing requires macOS tools."
[[ -d "$APP" ]] || fail "App bundle not found: $APP"
for tool in /usr/bin/codesign /usr/bin/file /usr/bin/otool /usr/bin/lipo /usr/libexec/PlistBuddy /usr/bin/plutil; do [[ -x "$tool" ]] || fail "Required tool unavailable: $tool"; done

PLIST="$APP/Contents/Info.plist"; [[ -f "$PLIST" ]] || fail "Missing Contents/Info.plist."
/usr/bin/plutil -lint "$PLIST" "$AGENT_PLIST" >/dev/null
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
EXECUTABLE="$APP/Contents/MacOS/$EXECUTABLE_NAME"
FRAMEWORKS="$APP/Contents/Frameworks"
[[ -x "$EXECUTABLE" ]] || fail "Main executable missing."
[[ -d "$AGENT_APP" ]] || fail "Release is missing the required hidden device-insertion login item app."
[[ -x "$AGENT_EXECUTABLE" ]] || fail "Release is missing the hidden device-insertion executable."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$AGENT_PLIST")" == "$AGENT_BUNDLE_ID" ]] || fail "Unexpected hidden agent bundle identifier."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$AGENT_PLIST")" == "$AGENT_EXECUTABLE_NAME" ]] || fail "Unexpected hidden agent executable name."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSBackgroundOnly' "$AGENT_PLIST")" == "true" ]] || fail "Hidden device agent must be LSBackgroundOnly."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$AGENT_PLIST")" == "$APP_VERSION" ]] || fail "Hidden agent version mismatch."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$AGENT_PLIST")" == "$APP_BUILD" ]] || fail "Hidden agent build mismatch."
[[ ! -e "$APP/Contents/Library/LaunchAgents/io.github.mtpbridge.DeviceWatcher.plist" ]] || fail "Retired LaunchAgent plist remains in Release."
[[ ! -e "$APP/Contents/MacOS/AndroidTransferV2DeviceWatcher" ]] || fail "Retired command-line DeviceWatcher remains in Release."
for f in "$FRAMEWORKS/libmtp.dylib" "$FRAMEWORKS/libusb-1.0.dylib" "$AGENT_FRAMEWORKS/libmtp.dylib" "$AGENT_FRAMEWORKS/libusb-1.0.dylib"; do [[ -f "$f" ]] || fail "Missing embedded framework: $f"; done

audit_binary(){
  local binary="$1" archs deps bad
  archs="$(MTPBRIDGE_LIPO=/usr/bin/lipo MTPBRIDGE_FILE_TOOL=/usr/bin/file mtpbridge_macho_architectures "$binary" 2>/dev/null || true)"
  [[ "$archs" == "arm64" ]] || fail "$(basename "$binary") must be arm64-only; found: ${archs:-unknown}"
  deps="$(MTPBRIDGE_OTOOL=/usr/bin/otool mtpbridge_otool_dependencies "$binary")" || fail "Could not inspect $(basename "$binary")."
  bad="$(printf '%s\n' "$deps" | mtpbridge_nonportable_dependencies)"
  [[ -z "$bad" ]] || { printf '%s:\n%s\n' "$binary" "$bad" >&2; fail "Non-relocatable dependency in $(basename "$binary")."; }
  echo "  arm64  $(basename "$binary")"
}
for b in "$EXECUTABLE" "$AGENT_EXECUTABLE" "$FRAMEWORKS/libmtp.dylib" "$FRAMEWORKS/libusb-1.0.dylib" "$AGENT_FRAMEWORKS/libmtp.dylib" "$AGENT_FRAMEWORKS/libusb-1.0.dylib"; do audit_binary "$b"; done
for frameworks in "$FRAMEWORKS" "$AGENT_FRAMEWORKS"; do
  mtpdeps="$(MTPBRIDGE_OTOOL=/usr/bin/otool mtpbridge_otool_dependencies "$frameworks/libmtp.dylib")"
  grep -Fxq '@rpath/libusb-1.0.dylib' <<<"$mtpdeps" || fail "libmtp does not use embedded @rpath libusb."
done
for b in "$EXECUTABLE" "$AGENT_EXECUTABLE"; do deps="$(MTPBRIDGE_OTOOL=/usr/bin/otool mtpbridge_otool_dependencies "$b")"; grep -Fxq '@rpath/libmtp.dylib' <<<"$deps" || fail "$(basename "$b") does not use embedded @rpath libmtp."; done

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$AGENT_APP"
verify_release_signature(){
  local binary="$1" details
  details="$(/usr/bin/codesign -d --verbose=4 "$binary" 2>&1)"
  grep -Eq '^Authority=Developer ID Application:' <<<"$details" || fail "$(basename "$binary") is not Developer ID signed."
  grep -Eq '^Timestamp=' <<<"$details" || fail "$(basename "$binary") lacks a secure timestamp."
  grep -Eq '^CodeDirectory .*flags=.*\(runtime\)' <<<"$details" || fail "$(basename "$binary") lacks Hardened Runtime."
}
for b in "$EXECUTABLE" "$AGENT_EXECUTABLE" "$FRAMEWORKS/libmtp.dylib" "$FRAMEWORKS/libusb-1.0.dylib" "$AGENT_FRAMEWORKS/libmtp.dylib" "$AGENT_FRAMEWORKS/libusb-1.0.dylib"; do verify_release_signature "$b"; done
main_entitlements="$(/usr/bin/codesign -d --entitlements :- "$APP" 2>&1)"
for key in com.apple.security.app-sandbox com.apple.security.device.usb com.apple.security.files.user-selected.read-write com.apple.security.files.bookmarks.app-scope; do grep -Fq "$key" <<<"$main_entitlements" || fail "Signed app missing entitlement: $key"; done
agent_entitlements="$(/usr/bin/codesign -d --entitlements :- "$AGENT_APP" 2>&1)"
for key in com.apple.security.app-sandbox com.apple.security.device.usb; do grep -Fq "$key" <<<"$agent_entitlements" || fail "Signed hidden agent missing entitlement: $key"; done
minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
[[ "$minimum" == "14.0" ]] || fail "Unexpected minimum macOS version: $minimum"
[[ "$version" == "$APP_VERSION" && "$build" == "$APP_BUILD" ]] || fail "Unexpected main app version/build: $version ($build)"
echo "Release audit passed: Android 傳輸 V2 $version build $build, hidden LoginItems device agent included, macOS $minimum+, arm64-only."
