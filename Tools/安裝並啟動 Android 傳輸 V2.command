#!/bin/bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
mkdir -p "$ROOT/.local/logs"
LOG="$ROOT/.local/logs/install-$(date '+%Y%m%d-%H%M%S').log"
pause_window(){ if [[ "${MTPBRIDGE_NO_PAUSE:-0}" != "1" && -t 0 ]]; then printf '\n'; read -r -p '按 Return 關閉這個視窗：' _ || true; fi; }
on_error(){ local status=$?; printf '\n安裝未完成。完整紀錄：%s\n' "$LOG" >&2; printf '%s\n' '此安裝器沒有安裝、更新或升級任何系統套件。' >&2; pause_window; exit "$status"; }
trap on_error ERR
exec > >(tee -a "$LOG") 2>&1
printf '%s\n' \
  'Android 傳輸 V2 0.7.0 — 本地隔離安裝並啟動' \
  '套件識別：0.7.0-device-launch-r1' \
  '──────────────────────────────────────────' \
  '• 不使用 Homebrew，也不執行任何系統套件更新。' \
  '• 已存在且相容的工具／函式庫會直接沿用，不重複安裝。' \
  '• 缺少或只有不可用 Intel 版本的開源相依性，只會建立在目前資料夾。' \
  '• App 會建立在 dist/Android 傳輸 V2.app，不會自動複製到 /Applications。' \
  '• 這版改用隱藏 LoginItem App 偵測手機插入，主 App Command+Q 後偵測器仍可繼續執行。' \
  ''

grep -Fq '0.7.0-device-launch-r1' "$ROOT/PACKAGE_ID.txt" || { printf 'ERROR: 套件識別不一致。\n' >&2; false; }
[[ -f "$ROOT/Config/DeviceInsertionAgent-Info.plist" ]] || { printf 'ERROR: 缺少手機插入偵測器 Info.plist。\n' >&2; false; }
[[ -f "$ROOT/DeviceInsertionAgent.entitlements" ]] || { printf 'ERROR: 缺少手機插入偵測器 entitlements。\n' >&2; false; }
grep -Fq 'SMAppService.loginItem(' "$ROOT/Sources/MTPBridgeApp/DeviceInsertionService.swift" || { printf 'ERROR: LoginItem 註冊程式碼不完整。\n' >&2; false; }
grep -Fq 'mtp_legacy_device_agent_set_enabled(1)' "$ROOT/Sources/MTPBridgeApp/DeviceInsertionService.swift" || { printf 'ERROR: 本機相容登入項目備援程式碼不完整。\n' >&2; false; }
grep -Fq 'IOServiceAddMatchingNotification' "$ROOT/Sources/MTPDeviceWatcher/mtp_device_watcher.c" || { printf 'ERROR: USB hot-plug 偵測器原始碼不完整。\n' >&2; false; }

# Migrate only Android Transfer V2 persistent state before building. Legacy
# unversioned active transfer jobs can contain MTP handles captured from older
# USB sessions, and old ServiceManagement helpers can outlive their source tree.
# The migration is backup-first and never touches Google Android File Transfer.
"$ROOT/Scripts/migrate-persistent-state.sh"

# Remove only our retired 0.6.4 LaunchAgent experiment before installing the new
# hidden helper-app design. No packages or unrelated login items are touched.
if [[ "$(uname -s)" == "Darwin" ]]; then
  for OLD_LABEL in io.github.mtpbridge.DeviceInsertionAgent io.github.mtpbridge.DeviceInsertionAgentV2 io.github.mtpbridge.DeviceWatcher io.github.mtpbridge.MTPAutoLaunch; do
    OLD_DOMAIN="gui/$(id -u)/$OLD_LABEL"
    if /bin/launchctl print "$OLD_DOMAIN" >/dev/null 2>&1; then
      printf '正在停止舊手機偵測器註冊：%s…\n' "$OLD_LABEL"
      /bin/launchctl bootout "$OLD_DOMAIN" >/dev/null 2>&1 || true
    fi
  done
  /usr/bin/pkill -x AndroidTransferV2DeviceAgent >/dev/null 2>&1 || true
  /usr/bin/pkill -x AndroidTransferV2DeviceWatcher >/dev/null 2>&1 || true
fi

"${ROOT}/Scripts/preflight-swift-app.sh"
"${ROOT}/Scripts/prepare-local-dependencies.sh"
MTPBRIDGE_REQUIRE_DEVICE_AGENT=1 "${ROOT}/Scripts/build-local-app.sh"

APP="$ROOT/dist/Android 傳輸 V2.app"
AGENT="$APP/Contents/Library/LoginItems/Android 傳輸 V2 裝置偵測器.app"
[[ -d "$AGENT" ]] || { printf 'ERROR: 最終 App 缺少內建手機插入偵測器。\n' >&2; false; }

if [[ "${MTPBRIDGE_NO_OPEN:-0}" != "1" ]]; then
  # Open the current main App first. Its startup service retires stale helper
  # registrations, binds the new helper to this exact App path/package identity,
  # and starts the helper from the current bundle. Starting the helper first can
  # race that migration and preserve an obsolete parent-App path.
  /usr/bin/open "$APP"
  sleep 2
  if ! /usr/bin/pgrep -x AndroidTransferV2DeviceAgent >/dev/null 2>&1; then
    printf '主 App 尚未啟動隱藏偵測器；正在啟動目前 App 內嵌的偵測器…\n'
    /usr/bin/open -g "$AGENT"
  fi
  sleep 1
fi

printf '\n%s\n' \
  '安裝完成，Android 傳輸 V2 已啟動。' \
  "App：$APP" \
  "隱藏手機偵測器：$AGENT" \
  "安裝紀錄：$LOG" \
  '現在可用 Command+Q 關閉主 App，再拔除／插入 MTP 手機測試自動開啟。' \
  'macOS 若要求核准背景項目，App 設定頁會提供前往「登入項目」的按鈕。' \
  '需要釋放空間時，可在 Tools 資料夾雙擊「移除本地安裝.command」。'
trap - ERR
pause_window
