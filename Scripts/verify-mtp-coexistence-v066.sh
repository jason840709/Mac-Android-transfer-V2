#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ARBITER="$ROOT/Sources/MTPBridgeApp/MTPAccessArbiter.swift"
POLICY="$ROOT/Sources/MTPBridgeCore/LegacyMTPProcessPolicy.swift"
MODEL="$ROOT/Sources/MTPBridgeApp/AppModel.swift"
VIEW="$ROOT/Sources/MTPBridgeApp/ConnectionView.swift"
PREP="$ROOT/Scripts/prepare-local-dependencies.sh"
PATCH_FILE="$ROOT/Vendor/Patches/libmtp-1.1.23-macos-no-usb-reset.patch"
AUDIT="$ROOT/docs/research/ANDROID_FILE_TRANSFER_MTP_AUDIT_0.6.7.md"

for f in "$ARBITER" "$POLICY" "$MODEL" "$VIEW" "$PREP" "$PATCH_FILE" "$AUDIT"; do
  [[ -f "$f" ]] || { echo "ERROR: missing coexistence file: $f" >&2; exit 1; }
done

grep -Fq 'com.google.android.mtpviewer' "$POLICY" || { echo 'ERROR: old Android File Transfer viewer identity missing.' >&2; exit 1; }
grep -Fq 'com.google.android.mtpagent' "$POLICY" || { echo 'ERROR: old Android File Transfer agent identity missing.' >&2; exit 1; }
grep -Fq 'case androidFileTransferViewerBundleIdentifier:' "$POLICY" || { echo 'ERROR: viewer role mapping missing.' >&2; exit 1; }
grep -Fq 'return .blockingViewer' "$POLICY" || { echo 'ERROR: viewer is not classified as a blocking MTP owner.' >&2; exit 1; }
grep -Fq 'case androidFileTransferAgentBundleIdentifier:' "$POLICY" || { echo 'ERROR: legacy agent role mapping missing.' >&2; exit 1; }
grep -Fq 'return .passiveObserver' "$POLICY" || { echo 'ERROR: legacy background agent is not classified as a passive observer.' >&2; exit 1; }

grep -Fq 'requestTemporaryTermination()' "$ARBITER" || { echo 'ERROR: user-initiated temporary legacy viewer shutdown missing.' >&2; exit 1; }
grep -Fq 'passiveLegacyAgentIsRunning()' "$ARBITER" || { echo 'ERROR: passive legacy-agent diagnostics missing.' >&2; exit 1; }
grep -Fq 'try await Task.sleep(for: .milliseconds(650))' "$MODEL" || { echo 'ERROR: Android USB mode settling window missing.' >&2; exit 1; }
grep -Fq 'updateMTPAccessConflict()' "$MODEL" || { echo 'ERROR: MTP ownership gate missing from AppModel.' >&2; exit 1; }
grep -Fq 'for _ in 0..<8' "$MODEL" || { echo 'ERROR: viewer-only termination polling window missing.' >&2; exit 1; }
grep -Fq 'connection.conflict.stop_legacy' "$VIEW" || { echo 'ERROR: ownership conflict UI missing.' >&2; exit 1; }
grep -Fq 'libmtp-1.1.23-macos-no-usb-reset.patch' "$PREP" || { echo 'ERROR: local libmtp safety patch is not wired into the dependency build.' >&2; exit 1; }
grep -Fq 'refusing USB reset' "$PATCH_FILE" || { echo 'ERROR: libmtp open-session no-reset patch marker missing.' >&2; exit 1; }
grep -Fq 'skipping force-reset-on-close' "$PATCH_FILE" || { echo 'ERROR: libmtp close no-reset patch marker missing.' >&2; exit 1; }

# Prove that only the visible legacy viewer is consulted by currentConflict()
# and by the temporary termination path. The background Agent may be observed
# for diagnostics, but must never be a hard ownership gate again.
python3 - "$ARBITER" <<'PY'
import re, sys
from pathlib import Path
text=Path(sys.argv[1]).read_text(encoding='utf-8')

def block(name, next_name):
    m=re.search(rf'static func {name}\(.*?\) -> .*? \{{(.*?)\n    static func {next_name}', text, re.S)
    if not m:
        raise SystemExit(f'ERROR: could not isolate {name}() block')
    return m.group(1)

conflict=block('currentConflict', 'passiveLegacyAgentIsRunning')
if 'androidFileTransferViewerBundleIdentifier' not in conflict:
    raise SystemExit('ERROR: currentConflict() no longer checks the visible viewer')
if 'androidFileTransferAgentBundleIdentifier' in conflict:
    raise SystemExit('ERROR: background Android File Transfer Agent regressed into the hard MTP conflict gate')

terminate=re.search(r'static func requestTemporaryTermination\(\) -> Bool \{(.*)\n    \}\n\}', text, re.S)
if not terminate:
    raise SystemExit('ERROR: could not isolate requestTemporaryTermination()')
t=terminate.group(1)
if 'androidFileTransferViewerBundleIdentifier' not in t:
    raise SystemExit('ERROR: temporary shutdown no longer targets the visible viewer')
if 'androidFileTransferAgentBundleIdentifier' in t:
    raise SystemExit('ERROR: temporary shutdown must not terminate the passive background Agent')
print('Legacy AFT ownership policy: viewer blocks; background Agent remains passive.')
PY

# Prove the no-reset patch applies cleanly to the exact bundled upstream source.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tar -xzf "$ROOT/Vendor/source-archives/libmtp-1.1.23.tar.gz" -C "$TMP"
(
  cd "$TMP/libmtp-1.1.23"
  patch -p1 < "$PATCH_FILE" >/dev/null
)
grep -Fq 'refusing USB reset' "$TMP/libmtp-1.1.23/src/libusb1-glue.c" || { echo 'ERROR: patched libmtp source lacks no-reset branch.' >&2; exit 1; }

# Type-check the actual policy + AppKit ownership arbiter on every platform.
# On Linux, provide only the narrow NSRunningApplication surface it may use.
TMP_SWIFT="$(mktemp -d)"
trap 'rm -rf "$TMP" "$TMP_SWIFT"' EXIT
if [[ "$(uname -s)" == "Darwin" ]]; then
  SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
  SWIFTC="$(xcrun --sdk macosx --find swiftc)"
  TERM=dumb "$SWIFTC" -typecheck -parse-as-library -swift-version 5 -warnings-as-errors \
    -target arm64-apple-macosx14.0 -sdk "$SDKROOT" "$POLICY" "$ARBITER"
else
  cat > "$TMP_SWIFT/AppKit.swift" <<'SWIFT'
@_exported import Foundation
public final class NSRunningApplication: @unchecked Sendable {
    public var localizedName: String? { "Android File Transfer" }
    public static func runningApplications(withBundleIdentifier: String) -> [NSRunningApplication] { [] }
    public func terminate() -> Bool { true }
}
SWIFT
  swiftc -emit-module -parse-as-library -module-name AppKit "$TMP_SWIFT/AppKit.swift" -emit-module-path "$TMP_SWIFT/AppKit.swiftmodule"
  TERM=dumb swiftc -typecheck -parse-as-library -swift-version 5 -warnings-as-errors -I "$TMP_SWIFT" "$POLICY" "$ARBITER"
fi

printf 'Android Transfer V2 0.6.7 viewer-only MTP coexistence and no-USB-reset contract passed.\n'
