#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
fail(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in bash clang python3 swift swiftc; do command -v "$tool" >/dev/null 2>&1 || fail "Required verification tool unavailable: $tool"; done
STEP=1; TOTAL=27
step(){ printf '[%s/%s] %s\n' "$STEP" "$TOTAL" "$*"; STEP=$((STEP+1)); }

step "Shell and double-click command syntax"
while IFS= read -r -d '' script; do bash -n "$script"; done < <(find "$ROOT/Scripts" -name '*.sh' -print0)
while IFS= read -r -d '' script; do bash -n "$script"; done < <(find "$ROOT/Tools" -maxdepth 1 -name '*.command' -print0)

step "No-global-install policy"
"$ROOT/Scripts/verify-installer-policy.sh"

step "Swift core tests"
swift test

step "C bridge and device-agent state core warnings-as-errors"
clang -std=c11 -Wall -Wextra -Werror -I"$ROOT/Sources/MTPBridgeCLib/include" -I"$ROOT/Tests/CBridgeStub" -fsyntax-only "$ROOT/Sources/MTPBridgeCLib/mtp_bridge.c"
clang -std=c11 -Wall -Wextra -Werror -I"$ROOT/Sources/MTPDeviceWatcher" -fsyntax-only "$ROOT/Sources/MTPDeviceWatcher/mtp_device_watcher.c"

step "C bridge and device-agent behavior tests"
"$ROOT/Scripts/run-c-bridge-tests.sh"

step "Clang static analyzer"
ANALYZER_OUTPUT="$(mktemp)"; trap 'rm -f "$ANALYZER_OUTPUT"' EXIT
TERM=dumb clang --analyze -std=c11 -Wall -Wextra -I"$ROOT/Sources/MTPBridgeCLib/include" -I"$ROOT/Tests/CBridgeStub" -Xanalyzer -analyzer-output=text "$ROOT/Sources/MTPBridgeCLib/mtp_bridge.c" -o /dev/null 2>"$ANALYZER_OUTPUT"
[[ ! -s "$ANALYZER_OUTPUT" ]] || { cat "$ANALYZER_OUTPUT" >&2; fail "Clang static analyzer emitted diagnostics for MTP bridge."; }
: > "$ANALYZER_OUTPUT"
TERM=dumb clang --analyze -std=c11 -Wall -Wextra -I"$ROOT/Sources/MTPDeviceWatcher" -Xanalyzer -analyzer-output=text "$ROOT/Sources/MTPDeviceWatcher/mtp_device_watcher.c" -o /dev/null 2>"$ANALYZER_OUTPUT"
[[ ! -s "$ANALYZER_OUTPUT" ]] || { cat "$ANALYZER_OUTPUT" >&2; fail "Clang static analyzer emitted diagnostics for device-agent state core."; }
rm -f "$ANALYZER_OUTPUT"; trap - EXIT

step "Swift source parse"
while IFS= read -r -d '' file; do swiftc -frontend -parse "$file"; done < <(find "$ROOT/Sources" -name '*.swift' -print0)

step "Non-UI app logic type-check"
TERM=dumb swiftc -typecheck -parse-as-library -swift-version 5 -strict-concurrency=complete -warn-concurrency \
  -Xcc -I"$ROOT/Sources/MTPBridgeCLib/include" -Xcc -I"$ROOT/Sources/MTPDeviceRegistration" -import-objc-header "$ROOT/Sources/MTPBridgeApp/MTPBridge-Bridging-Header.h" \
  "$ROOT"/Sources/MTPBridgeCore/*.swift \
  "$ROOT/Sources/MTPBridgeApp/BookmarkStore.swift" \
  "$ROOT/Sources/MTPBridgeApp/Formatting.swift" \
  "$ROOT/Sources/MTPBridgeApp/LibMTPClient.swift" \
  "$ROOT/Sources/MTPBridgeApp/TransferQueueStore.swift" \
  "$ROOT/Sources/MTPBridgeApp/TransferCoordinator.swift" \
  "$ROOT/Sources/MTPBridgeApp/USBPresenceMonitor.swift" \
  "$ROOT/Sources/MTPBridgeApp/NavigationInputMonitor.swift" \
  "$ROOT/Sources/MTPBridgeApp/MTPAccessArbiter.swift" \
  "$ROOT/Sources/MTPBridgeApp/DeviceInsertionIdentifiers.swift" \
  "$ROOT/Sources/MTPBridgeApp/DeviceInsertionService.swift" \
  "$ROOT/Sources/MTPBridgeApp/AppModel.swift"

step "Plists, localization, assets, and executable commands"
python3 - "$ROOT" <<'PY'
import json, os, plistlib, re, struct, sys
from pathlib import Path
root=Path(sys.argv[1])
for path in [root/'Config/Info.plist', root/'MTPBridge.entitlements', root/'Config/DeviceInsertionAgent-Info.plist', root/'DeviceInsertionAgent.entitlements']:
    with path.open('rb') as h: plistlib.load(h)
with (root/'MTPBridge.entitlements').open('rb') as h: ent=plistlib.load(h)
for key in ['com.apple.security.app-sandbox','com.apple.security.device.usb','com.apple.security.files.user-selected.read-write','com.apple.security.files.bookmarks.app-scope']:
    if ent.get(key) is not True: raise SystemExit(f'Missing required entitlement: {key}')
with (root/'Config/DeviceInsertionAgent-Info.plist').open('rb') as h: agent=plistlib.load(h)
expected={'CFBundleIdentifier':'io.github.mtpbridge.DeviceInsertionAgentV2','CFBundleExecutable':'AndroidTransferV2DeviceAgent','CFBundlePackageType':'APPL','LSBackgroundOnly':True,'MTPBridgePackageID':'0.7.0-device-launch-r1'}
for k,v in expected.items():
    if agent.get(k)!=v: raise SystemExit(f'Device agent Info.plist mismatch: {k}')
with (root/'DeviceInsertionAgent.entitlements').open('rb') as h: agent_ent=plistlib.load(h)
for key in ['com.apple.security.app-sandbox','com.apple.security.device.usb']:
    if agent_ent.get(key) is not True: raise SystemExit(f'Hidden device agent missing required entitlement: {key}')
line_pattern=re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')
localizations={}
for path in sorted((root/'Resources').glob('*.lproj/Localizable.strings')):
    keys=[]
    for n,line in enumerate(path.read_text(encoding='utf-8').splitlines(),1):
        s=line.strip()
        if not s or s.startswith('//'): continue
        m=line_pattern.match(line)
        if not m: raise SystemExit(f'Invalid .strings syntax at {path}:{n}')
        keys.append(m.group(1))
    if len(keys)!=len(set(keys)): raise SystemExit(f'Duplicate localization keys in {path}')
    localizations[path.parent.name]=set(keys)
ref=next(iter(localizations.values()))
for name,keys in localizations.items():
    if keys!=ref: raise SystemExit(f'Localization key mismatch for {name}')
used=set(); pat=re.compile(r'NSLocalizedString\(\s*"([^"]+)"')
for path in (root/'Sources').rglob('*.swift'): used.update(pat.findall(path.read_text(encoding='utf-8')))
missing=sorted(used-ref)
if missing: raise SystemExit(f'Missing localized strings: {missing}')
# App icons
catalog=root/'Assets.xcassets'; json.loads((catalog/'Contents.json').read_text())
appset=catalog/'AppIcon.appiconset'; contents=json.loads((appset/'Contents.json').read_text())
expected_dims={("16x16","1x"):16,("16x16","2x"):32,("32x32","1x"):32,("32x32","2x"):64,("128x128","1x"):128,("128x128","2x"):256,("256x256","1x"):256,("256x256","2x"):512,("512x512","1x"):512,("512x512","2x"):1024}
seen=set()
for item in contents.get('images',[]):
    if item.get('idiom')!='mac': continue
    key=(item.get('size'),item.get('scale')); fn=item.get('filename')
    if key not in expected_dims or not fn: raise SystemExit(f'Unexpected AppIcon entry: {item}')
    data=(appset/fn).read_bytes(); width,height=struct.unpack('>II',data[16:24]); req=expected_dims[key]
    if data[:8]!=b'\x89PNG\r\n\x1a\n' or (width,height)!=(req,req): raise SystemExit(f'Bad AppIcon: {fn}')
    seen.add(key)
if seen!=set(expected_dims): raise SystemExit('Incomplete AppIcon set')
icns=(root/'Resources/MTPBridge.icns').read_bytes()
if len(icns)<8 or icns[:4]!=b'icns' or struct.unpack('>I',icns[4:8])[0]!=len(icns): raise SystemExit('Invalid ICNS')
for credits in [root/'Resources/en.lproj/Credits.rtf',root/'Resources/zh-Hant.lproj/Credits.rtf']:
    if not credits.is_file() or credits.stat().st_size<80: raise SystemExit(f'Missing About credits: {credits}')
for cmd in [root/'Tools/安裝並啟動 Android 傳輸 V2.command',root/'Tools/移除本地安裝.command',root/'Tools/診斷手機自動開啟.command',root/'Tools/清理舊版本狀態.command']:
    if not os.access(cmd,os.X_OK): raise SystemExit(f'Command not executable: {cmd}')
PY
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$ROOT/Config/Info.plist" "$ROOT/MTPBridge.entitlements" "$ROOT/Config/DeviceInsertionAgent-Info.plist" "$ROOT/DeviceInsertionAgent.entitlements" >/dev/null
  plutil -lint "$ROOT/Resources/en.lproj/Localizable.strings" "$ROOT/Resources/zh-Hant.lproj/Localizable.strings" >/dev/null
fi

step "Version, package identity, and dependency source consistency"
python3 - "$ROOT" <<'PY'
import hashlib, plistlib, sys
from pathlib import Path
root=Path(sys.argv[1]); version='0.7.0'; build='22'; package='0.7.0-device-launch-r1'
if package not in (root/'PACKAGE_ID.txt').read_text(): raise SystemExit('Package identity mismatch')
with (root/'Config/Info.plist').open('rb') as h: info=plistlib.load(h)
if info.get('CFBundleShortVersionString')!=version or info.get('CFBundleVersion')!=build: raise SystemExit('Info.plist version/build mismatch')
if info.get('MTPBridgePackageID')!=package: raise SystemExit('Info.plist package identity mismatch')
with (root/'Config/DeviceInsertionAgent-Info.plist').open('rb') as h: agent_info=plistlib.load(h)
if agent_info.get('MTPBridgePackageID')!=package: raise SystemExit('Agent Info.plist package identity mismatch')
xc=(root/'Config/Shared.xcconfig').read_text()
for marker in [f'MARKETING_VERSION = {version}',f'CURRENT_PROJECT_VERSION = {build}']:
    if marker not in xc: raise SystemExit(f'xcconfig mismatch: {marker}')
for path,label in [(root/'Tools/安裝並啟動 Android 傳輸 V2.command','installer'),(root/'Scripts/build-local-app.sh','builder')]:
    if version not in path.read_text(): raise SystemExit(f'{label} version mismatch')
expected={'libmtp-1.1.23.tar.gz':'74a2b6e8cb4a0304e95b995496ea3ac644c29371649b892b856e22f12a0bdeed','libusb-1.0.30.tar.bz2':'fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf'}
for name,digest in expected.items():
    p=root/'Vendor/source-archives'/name
    if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest()!=digest: raise SystemExit(f'Bundled source checksum mismatch: {name}')
PY

step "Stable 0.4.0 Finder foundation plus intentional 0.6.x deltas"
"$ROOT/Scripts/verify-v040-drag-baseline.sh"

step "0.6.0 exact Finder file-promise destination contract"
"$ROOT/Scripts/verify-file-promise-v060.sh"

step "0.6.1 visible headers and transfer-shelf behavior"
"$ROOT/Scripts/verify-ui-v061.sh"

step "0.6.3 readable palette and text-size controls"
"$ROOT/Scripts/verify-ui-v063.sh"

step "Stable 0.4.0 UI and transfer regressions"
"$ROOT/Scripts/verify-ui-v040.sh"

step "Inherited 0.4.1 navigation, tooltip, and About regressions"
"$ROOT/Scripts/verify-ui-v041.sh"

step "0.7.0 preserves the accepted 0.6.11 transfer/UI/MTP surface"
"$ROOT/Scripts/verify-v069-preserved-surface.sh"

step "Inherited persistent queue and stale-helper state migration"
"$ROOT/Scripts/verify-state-hygiene-v069.sh"

step "Inherited MTP coexistence and Android USB-mode safety"
"$ROOT/Scripts/verify-mtp-coexistence-v066.sh"

step "Inherited ConnectionView Swift-5 return regression"
"$ROOT/Scripts/verify-connection-view-swift5-r2.sh"

step "0.7.0 path-safe hidden login-item phone-insertion agent contract"
"$ROOT/Scripts/verify-device-insertion-api.sh"


step "Inherited 0.6.8 upload destination handle rebinding"
"$ROOT/Scripts/verify-upload-parent-rebind-v068.sh"

step "Inherited Android root file-upload parent sentinel"
"$ROOT/Scripts/verify-upload-root-v0610.sh"

step "Inherited 0.6.11 Android root folder-creation parent sentinel"
"$ROOT/Scripts/verify-folder-upload-v0611.sh"

step "Inherited transfer pause/resume/terminate/delete controls"
"$ROOT/Scripts/verify-transfer-controls-v0610.sh"

step "Xcode/local builder hidden device-agent integration contract"
python3 - "$ROOT" <<'PY'
import sys
from pathlib import Path
root=Path(sys.argv[1]); project=(root/'project.yml').read_text(); builder=(root/'Scripts/build-local-app.sh').read_text(); app=(root/'Sources/MTPBridgeApp/MTPBridgeApp.swift').read_text(); service=(root/'Sources/MTPBridgeApp/DeviceInsertionService.swift').read_text()
for marker in ['MTPDeviceInsertionAgent:','type: application','Library/LoginItems/Android 傳輸 V2 裝置偵測器.app','DeviceInsertionAgent.entitlements','DeviceAgentLaunchCandidatePolicy.swift','DeviceInsertionAgentV2']:
    if marker not in project: raise SystemExit(f'Xcode hidden device-agent integration missing: {marker}')
for marker in ['DeviceInsertionService()','deviceInsertion.start()','DeviceInsertionSettingsView(service: deviceInsertion)']:
    if marker not in app: raise SystemExit(f'Main-app device-agent integration missing: {marker}')
for marker in ['Android 傳輸 V2 裝置偵測器.app','DeviceInsertionAgent.entitlements','MTPBRIDGE_REQUIRE_DEVICE_AGENT']:
    if marker not in builder: raise SystemExit(f'Local builder hidden agent integration missing: {marker}')
for marker in ['SMAppService.loginItem(','mtp_legacy_device_agent_set_enabled(1)','launchHelperForCurrentSession()','DeviceInsertionRegistrationTokenV2','currentMainBundlePath']:
    if marker not in service: raise SystemExit(f'DeviceInsertionService missing registration/start behavior: {marker}')
for forbidden in ['MTPAutoLaunchHelper.swift','Contents/Library/LaunchAgents/io.github.mtpbridge.DeviceWatcher.plist','SMAppService.agent(']:
    if forbidden in project+builder+service: raise SystemExit(f'Retired device-watcher integration returned: {forbidden}')
PY

step "Native local App plus hidden device agent build when macOS is available"
if [[ "$(uname -s)" == "Darwin" ]]; then
  MTPBRIDGE_FORCE_PREFLIGHT=1 "$ROOT/Scripts/preflight-swift-app.sh"
  "$ROOT/Scripts/prepare-local-dependencies.sh"
  MTPBRIDGE_REQUIRE_DEVICE_AGENT=1 MTPBRIDGE_NO_OPEN=1 MTPBRIDGE_FORCE_REBUILD=1 "$ROOT/Scripts/build-local-app.sh"
  MTPBRIDGE_REQUIRE_DEVICE_AGENT=1 "$ROOT/Scripts/audit-local-app.sh" "$ROOT/dist/Android 傳輸 V2.app"
else
  printf '  skipped: macOS SDK and code-signing tools are unavailable on %s.\n' "$(uname -s)"
fi

printf 'Verification passed.\n'
