#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
IDENTIFIERS="${ROOT}/Sources/MTPBridgeApp/DeviceInsertionIdentifiers.swift"
SERVICE="${ROOT}/Sources/MTPBridgeApp/DeviceInsertionService.swift"
POLICY="${ROOT}/Sources/MTPBridgeCore/DeviceAgentLaunchCandidatePolicy.swift"
POLICY_TEST="${ROOT}/Tests/MTPBridgeCoreTests/DeviceAgentLaunchCandidatePolicyTests.swift"
SERVICE_SOURCES=("$IDENTIFIERS" "$SERVICE")
WATCHER_SWIFT="${ROOT}/Sources/MTPDeviceWatcher/MTPDeviceWatcher.swift"
WATCHER_C="${ROOT}/Sources/MTPDeviceWatcher/mtp_device_watcher.c"
WATCHER_HEADER="${ROOT}/Sources/MTPDeviceWatcher/mtp_device_watcher.h"
BRIDGING="${ROOT}/Sources/MTPDeviceWatcher/MTPDeviceWatcher-Bridging-Header.h"
AGENT_INFO="${ROOT}/Config/DeviceInsertionAgent-Info.plist"
AGENT_ENTITLEMENTS="${ROOT}/DeviceInsertionAgent.entitlements"
REGISTRATION_M="${ROOT}/Sources/MTPDeviceRegistration/device_registration.m"
REGISTRATION_H="${ROOT}/Sources/MTPDeviceRegistration/device_registration.h"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for f in "$IDENTIFIERS" "$SERVICE" "$POLICY" "$POLICY_TEST" "$WATCHER_SWIFT" "$WATCHER_C" "$WATCHER_HEADER" "$BRIDGING" "$AGENT_INFO" "$AGENT_ENTITLEMENTS" "$REGISTRATION_M" "$REGISTRATION_H"; do
  [[ -f "$f" ]] || fail "Missing device-insertion source: $f"
done

DIAGNOSTIC="${ROOT}/Tools/診斷手機自動開啟.command"
[[ -x "$DIAGNOSTIC" ]] || fail "Missing executable read-only device-agent diagnostic command."
grep -Fq '只讀取狀態' "$DIAGNOSTIC" || fail "Device-agent diagnostic must remain read-only."

for retired in \
  "${ROOT}/Sources/MTPAutoLaunchHelper" \
  "${ROOT}/Sources/MTPBridgeApp/AutoLaunchService.swift" \
  "${ROOT}/Sources/MTPBridgeApp/AutoLaunchSettingsView.swift" \
  "${ROOT}/Config/AutoLaunchHelper-Info.plist" \
  "${ROOT}/AutoLaunchHelper.entitlements" \
  "${ROOT}/Config/io.github.mtpbridge.DeviceWatcher.plist"
do
  [[ ! -e "$retired" ]] || fail "Retired auto-open implementation is still present: $retired"
done

# 0.7.0 uses a fresh helper identity and binds registration to build, package,
# and exact parent-App path. This prevents ServiceManagement from reviving a
# helper that belongs to a deleted source-folder copy of the App.
grep -Fq 'DeviceInsertionAgentV2' "$IDENTIFIERS" || fail "Fresh 0.7.0 helper identity is missing."
grep -Fq 'retiredDeviceAgentBundleIdentifier' "$IDENTIFIERS" || fail "Old helper identity is not explicitly retired."
grep -Fq 'SMAppService.loginItem(' "$SERVICE" || fail "Main app no longer registers a nested login-item helper."
grep -Fq 'DeviceInsertionRegistrationTokenV2' "$SERVICE" || fail "Device agent registration is not bound to a v2 identity token."
grep -Fq 'currentMainBundlePath' "$SERVICE" || fail "Registration token no longer includes exact parent-App path."
grep -Fq 'currentPackageIdentity' "$SERVICE" || fail "Registration token no longer includes package identity."
grep -Fq 'recordedToken != currentRegistrationToken' "$SERVICE" || fail "Moved/replaced App registrations are no longer migrated."
grep -Fq 'mtp_legacy_retired_device_agent_set_enabled(0)' "$SERVICE" || fail "Retired helper compatibility registration is not disabled."
grep -Fq 'launchHelperForCurrentSession()' "$SERVICE" || fail "Main app no longer starts the current hidden helper."
grep -Fq 'application.bundleURL' "$SERVICE" || fail "Running helper identity is no longer checked by bundle URL."

# The agent must never blindly open a path derived from a stale helper bundle.
grep -Fq 'urlsForApplications(withBundleIdentifier:' "$WATCHER_SWIFT" || fail "Agent lacks Launch Services fallback by main bundle identifier."
grep -Fq 'DeviceAgentLaunchCandidatePolicy.orderedCandidates' "$WATCHER_SWIFT" || fail "Agent no longer validates and ranks launch candidates."
grep -Fq 'bundleExists' "$POLICY" || fail "Launch policy does not reject missing app bundles."
grep -Fq 'executableExists' "$POLICY" || fail "Launch policy does not reject app bundles without executables."
grep -Fq 'MTPBridgePackageID' "$WATCHER_SWIFT" || fail "Agent no longer matches package identity."
grep -Fq 'allowsRunningApplicationSubstitution = false' "$WATCHER_SWIFT" || fail "Agent could substitute an unrelated running copy."
grep -Fq 'ignored the insertion instead of opening a missing file' "$WATCHER_SWIFT" || fail "Missing-app insertion no longer fails silently and safely."
grep -Fq 'openApplication(at:' "$WATCHER_SWIFT" || fail "Agent no longer launches through NSWorkspace."

# USB watcher remains event-driven and does not open merely at login.
grep -Fq 'IOServiceAddMatchingNotification' "$WATCHER_C" || fail "Agent no longer uses IOKit hot-plug notifications."
grep -Fq 'kIOMatchedNotification' "$WATCHER_C" || fail "Agent no longer listens for USB matches."
grep -Fq 'kIOTerminatedNotification' "$WATCHER_C" || fail "Agent no longer tracks USB removal."
grep -Fq 'IOUSBHostDevice' "$WATCHER_C" || fail "Agent no longer watches modern macOS USB host devices."
grep -Fq 'LIBMTP_Detect_Raw_Devices' "$WATCHER_C" || fail "Agent no longer confirms MTP through libmtp."
grep -Fq 'drain_iterator_silently(matched_iterator)' "$WATCHER_C" || fail "Agent could open the main app merely because it started at login."

grep -Fq 'Library/LoginItems' "$ROOT/Scripts/build-local-app.sh" || fail "Local builder no longer embeds a LoginItems helper."
grep -Fq 'DeviceAgentLaunchCandidatePolicy.swift' "$ROOT/Scripts/build-local-app.sh" || fail "Local builder does not compile launch-candidate policy into helper."
grep -Fq 'DeviceInsertionAgent.entitlements' "$ROOT/Scripts/build-local-app.sh" || fail "Helper is no longer signed with dedicated entitlements."

python3 - "$AGENT_INFO" "$AGENT_ENTITLEMENTS" <<'PY'
import plistlib,sys
info=plistlib.load(open(sys.argv[1],'rb'))
expected={
 'CFBundleIdentifier':'io.github.mtpbridge.DeviceInsertionAgentV2',
 'CFBundleExecutable':'AndroidTransferV2DeviceAgent',
 'CFBundlePackageType':'APPL',
 'LSBackgroundOnly':True,
 'MTPBridgePackageID':'0.7.0-device-launch-r1',
}
for k,v in expected.items():
    if info.get(k)!=v: raise SystemExit(f'Helper Info.plist mismatch: {k}={info.get(k)!r}, expected {v!r}')
ent=plistlib.load(open(sys.argv[2],'rb'))
for k in ['com.apple.security.app-sandbox','com.apple.security.device.usb']:
    if ent.get(k) is not True: raise SystemExit(f'Hidden helper missing entitlement: {k}')
PY

grep -Fq 'DeviceInsertionAgentV2' "$REGISTRATION_M" || fail "Compatibility registration bridge still targets old helper identity."
grep -Fq 'mtp_legacy_retired_device_agent_set_enabled' "$REGISTRATION_M" || fail "Compatibility bridge cannot retire old helper identity."
grep -Fq 'Wno-deprecated-declarations' "$ROOT/Scripts/build-local-app.sh" || fail "Deprecated compatibility API is no longer isolated from warning policy."

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/ModuleCache"
command -v swiftc >/dev/null 2>&1 || fail "swiftc is unavailable."

if [[ "$(uname -s)" == "Darwin" ]]; then
  command -v xcrun >/dev/null 2>&1 || fail "xcrun is unavailable on macOS."
  SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
  SWIFTC="$(xcrun --sdk macosx --find swiftc)"
  CLANG="$(xcrun --sdk macosx --find clang)"
  "$CLANG" -fsyntax-only -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -target arm64-apple-macosx14.0 -isysroot "$SDKROOT" \
    -I"$ROOT/Sources/MTPDeviceRegistration" "$REGISTRATION_M"
  TERM=dumb "$SWIFTC" -typecheck -parse-as-library -swift-version 5 \
    -strict-concurrency=targeted -warnings-as-errors \
    -target arm64-apple-macosx14.0 -sdk "$SDKROOT" \
    -module-name DeviceInsertionServiceContract -module-cache-path "$TMP/ModuleCache" \
    -import-objc-header "$ROOT/Sources/MTPBridgeApp/MTPBridge-Bridging-Header.h" \
    -Xcc -I"$ROOT/Sources/MTPBridgeCLib/include" \
    -Xcc -I"$ROOT/Sources/MTPDeviceRegistration" \
    "${SERVICE_SOURCES[@]}"
  TERM=dumb "$SWIFTC" -typecheck -parse-as-library -swift-version 5 \
    -strict-concurrency=targeted -warnings-as-errors \
    -target arm64-apple-macosx14.0 -sdk "$SDKROOT" \
    -module-name DeviceInsertionAgentContract -module-cache-path "$TMP/ModuleCache" \
    -import-objc-header "$BRIDGING" -Xcc -I"$ROOT/Sources/MTPDeviceWatcher" \
    "$POLICY" "$WATCHER_SWIFT"
else
  cat > "$TMP/AppKit.swift" <<'SWIFT'
@_exported import Foundation
public final class NSRunningApplication: @unchecked Sendable {
    public struct ActivationOptions: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let activateAllWindows = ActivationOptions(rawValue: 1)
    }
    public static func runningApplications(withBundleIdentifier: String) -> [NSRunningApplication] { [] }
    public var bundleURL: URL? { nil }
    public var isTerminated: Bool { false }
    public func activate(options: ActivationOptions = []) -> Bool { true }
    public func terminate() -> Bool { true }
    public func forceTerminate() -> Bool { true }
}
public final class NSWorkspace: @unchecked Sendable {
    public final class OpenConfiguration: @unchecked Sendable {
        public var activates = true
        public var addsToRecentItems = true
        public var allowsRunningApplicationSubstitution = true
        public var createsNewApplicationInstance = false
        public init() {}
    }
    public static let shared = NSWorkspace()
    public static func openSystemSettingsLoginItems() {}
    public func urlsForApplications(withBundleIdentifier: String) -> [URL] { [] }
    public func openApplication(at url: URL, configuration: OpenConfiguration, completionHandler: @escaping @Sendable (NSRunningApplication?, (any Error)?) -> Void) {
        completionHandler(nil, nil)
    }
}
SWIFT
  cat > "$TMP/ServiceManagement.swift" <<'SWIFT'
@_exported import Foundation
public final class SMAppService: @unchecked Sendable {
    public enum Status: Equatable { case notRegistered, enabled, requiresApproval, notFound }
    public var status: Status { .notRegistered }
    public static func loginItem(identifier: String) -> SMAppService { SMAppService() }
    public static func openSystemSettingsLoginItems() {}
    public func register() throws {}
    public func unregister() throws {}
}
SWIFT
  cat > "$TMP/LegacyRegistration.swift" <<'SWIFT'
func mtp_legacy_device_agent_set_enabled(_ enabled: Int32) -> Int32 { 1 }
func mtp_legacy_retired_device_agent_set_enabled(_ enabled: Int32) -> Int32 { 1 }
func mtp_legacy_retired_auto_launch_set_enabled(_ enabled: Int32) -> Int32 { 1 }
SWIFT
  cat > "$TMP/WatcherBridge.swift" <<'SWIFT'
func mtp_device_watcher_run(
    _ callback: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?,
    _ context: UnsafeMutableRawPointer?
) -> Int32 { 0 }
SWIFT
  swiftc -emit-module -parse-as-library -module-name AppKit "$TMP/AppKit.swift" -emit-module-path "$TMP/AppKit.swiftmodule"
  swiftc -emit-module -parse-as-library -module-name ServiceManagement "$TMP/ServiceManagement.swift" -emit-module-path "$TMP/ServiceManagement.swiftmodule"
  TERM=dumb swiftc -typecheck -parse-as-library -swift-version 5 \
    -strict-concurrency=targeted -warnings-as-errors \
    -I "$TMP" -module-cache-path "$TMP/ModuleCache" \
    "$TMP/LegacyRegistration.swift" "${SERVICE_SOURCES[@]}"
  TERM=dumb swiftc -typecheck -parse-as-library -swift-version 5 \
    -strict-concurrency=targeted -warnings-as-errors \
    -I "$TMP" -module-cache-path "$TMP/ModuleCache" \
    "$TMP/WatcherBridge.swift" "$POLICY" "$WATCHER_SWIFT"
fi

printf 'Path-safe hidden login-item device agent, current-bundle re-registration, Launch Services fallback, and IOKit MTP hot-plug contract passed.\n'
