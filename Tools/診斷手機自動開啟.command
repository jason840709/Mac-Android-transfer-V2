#!/bin/bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
LOG_DIR="$ROOT/.local/logs"
mkdir -p "$LOG_DIR"
STAMP="$(date '+%Y%m%d-%H%M%S')"
LOG="$LOG_DIR/device-agent-diagnostic-$STAMP.log"
exec > >(tee "$LOG") 2>&1

printf 'Android 傳輸 V2 0.7.0 — 手機插入自動開啟診斷（唯讀）\n'
printf '────────────────────────────────────────────\n'
printf '套件識別：0.7.0-device-launch-r1\n'
printf '這個工具只讀取狀態，不會註冊、停用、更新或刪除任何服務。\n\n'

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '此診斷工具只能在 macOS 上讀取背景項目狀態。\n報告：%s\n' "$LOG"
  read -r -p '按 Return 關閉這個視窗：' _
  exit 0
fi

APP="$ROOT/dist/Android 傳輸 V2.app"
AGENT="$APP/Contents/Library/LoginItems/Android 傳輸 V2 裝置偵測器.app"
AGENT_EXE="$AGENT/Contents/MacOS/AndroidTransferV2DeviceAgent"
MAIN_ID="io.github.mtpbridge.MTPBridge"
AGENT_ID="io.github.mtpbridge.DeviceInsertionAgentV2"
OLD_AGENT_ID="io.github.mtpbridge.DeviceInsertionAgent"

plist_value() {
  local plist="$1" key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || printf '（無）'
}

printf '專案：%s\nApp：%s\n' "$ROOT" "$APP"
[[ -d "$APP" ]] && printf '✓ App 已建立\n' || printf '✗ 找不到 dist App\n'
[[ -d "$AGENT" ]] && printf '✓ 內建 LoginItem 偵測器 App 存在\n' || printf '✗ 內建 LoginItem 偵測器 App 不存在\n'
[[ -x "$AGENT_EXE" ]] && printf '✓ 偵測器可執行檔存在\n' || printf '✗ 偵測器可執行檔不存在\n'

if [[ -f "$APP/Contents/Info.plist" ]]; then
  printf '\n目前主 App identity：\n'
  printf '  bundle id: %s\n' "$(plist_value "$APP/Contents/Info.plist" CFBundleIdentifier)"
  printf '  version:   %s\n' "$(plist_value "$APP/Contents/Info.plist" CFBundleShortVersionString)"
  printf '  build:     %s\n' "$(plist_value "$APP/Contents/Info.plist" CFBundleVersion)"
  printf '  package:   %s\n' "$(plist_value "$APP/Contents/Info.plist" MTPBridgePackageID)"
fi
if [[ -f "$AGENT/Contents/Info.plist" ]]; then
  printf '\n目前內嵌 Agent identity：\n'
  printf '  bundle id: %s\n' "$(plist_value "$AGENT/Contents/Info.plist" CFBundleIdentifier)"
  printf '  build:     %s\n' "$(plist_value "$AGENT/Contents/Info.plist" CFBundleVersion)"
  printf '  package:   %s\n' "$(plist_value "$AGENT/Contents/Info.plist" MTPBridgePackageID)"
  printf '  預期父 App: %s\n' "$APP"
fi

printf '\n正在執行的 Android 傳輸 V2 Agent：\n'
PIDS="$(/usr/bin/pgrep -x AndroidTransferV2DeviceAgent 2>/dev/null || true)"
if [[ -z "$PIDS" ]]; then
  printf '✗ 沒有偵測到 Agent process\n'
else
  for pid in $PIDS; do
    printf '  pid %s: ' "$pid"
    /bin/ps -p "$pid" -o command= 2>/dev/null || printf '（無法讀取路徑）\n'
  done
fi

printf '\nlaunchd / ServiceManagement：\n'
for label in "$AGENT_ID" "$OLD_AGENT_ID" io.github.mtpbridge.DeviceWatcher io.github.mtpbridge.MTPAutoLaunch; do
  domain="gui/$(id -u)/$label"
  tmp="/tmp/android-transfer-v2-launchctl-$$"
  if /bin/launchctl print "$domain" >"$tmp" 2>&1; then
    printf '✓ %s\n' "$domain"
    /usr/bin/grep -E '^\s*(state|path|program|pid|parent bundle version|last exit code)\s*=' "$tmp" || true
  else
    printf '• 未註冊：%s\n' "$domain"
  fi
  /bin/rm -f "$tmp"
done

printf '\nLaunch Services / Spotlight 找到的主 App 候選：\n'
if [[ -x /usr/bin/mdfind ]]; then
  FOUND=0
  while IFS= read -r candidate; do
    [[ -n "$candidate" && -d "$candidate" ]] || continue
    FOUND=1
    plist="$candidate/Contents/Info.plist"
    printf '  • %s\n' "$candidate"
    if [[ -f "$plist" ]]; then
      printf '    build=%s package=%s executable=%s\n' \
        "$(plist_value "$plist" CFBundleVersion)" \
        "$(plist_value "$plist" MTPBridgePackageID)" \
        "$(plist_value "$plist" CFBundleExecutable)"
    fi
  done < <(/usr/bin/mdfind "kMDItemCFBundleIdentifier == '$MAIN_ID'" 2>/dev/null | /usr/bin/sort -u)
  [[ "$FOUND" -eq 1 ]] || printf '  （Spotlight 沒有找到候選 App）\n'
else
  printf '  （mdfind 不可用）\n'
fi

printf '\n舊 Android File Transfer 共存狀態：\n'
if /usr/bin/pgrep -fl 'Android File Transfer$' >/dev/null 2>&1; then
  /usr/bin/pgrep -fl 'Android File Transfer$' || true
  printf '⚠ 可見舊主程式仍在執行，可能持有 MTP session。\n'
else
  printf '✓ 沒有偵測到舊 Android File Transfer 主程式\n'
fi
if /usr/bin/pgrep -fl 'Android File Transfer Agent$' >/dev/null 2>&1; then
  /usr/bin/pgrep -fl 'Android File Transfer Agent$' || true
  printf '• 舊背景 Agent 可繼續存在，不會被當成 MTP session owner。\n'
else
  printf '• 沒有偵測到舊 Android File Transfer Agent\n'
fi

if [[ -x /usr/bin/sfltool ]]; then
  printf '\nBackground Task Management 片段：\n'
  /usr/bin/sfltool dumpbtm 2>/dev/null | /usr/bin/grep -i -C 4 -E 'io\.github\.mtpbridge\.(DeviceInsertionAgentV2|DeviceInsertionAgent|MTPBridge)|Android 傳輸 V2' | /usr/bin/head -n 120 || printf '（沒有找到相關 BTM 片段）\n'
fi

if [[ -x /usr/bin/codesign && -d "$APP" ]]; then
  printf '\n簽章檢查：\n'
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 || true
  if [[ -d "$AGENT" ]]; then
    printf '\nAgent entitlements：\n'
    /usr/bin/codesign -d --entitlements :- "$AGENT" 2>&1 | /usr/bin/grep -E 'app-sandbox|device.usb' || true
  fi
fi

printf '\n報告：%s\n' "$LOG"
read -r -p '按 Return 關閉這個視窗：' _
