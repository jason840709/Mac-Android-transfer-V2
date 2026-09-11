#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

if [[ "$(uname -s)" == "Darwin" ]]; then
  if /usr/bin/pgrep -x AndroidTransferV2DeviceAgent >/dev/null 2>&1; then
    printf '%s\n' \
      '目前偵測到「插入手機時自動開啟」的隱藏裝置偵測器仍在背景執行。' \
      '為避免留下失效的登入項目，請先：' \
      '  1. 開啟 Android 傳輸 V2 → 設定' \
      '  2. 關閉「插入 MTP 手機時開啟 Android 傳輸 V2」' \
      '  3. 確認背景偵測器已停止，再重新執行這個移除工具。' \
      ''
    if [[ "${MTPBRIDGE_NO_PAUSE:-0}" != "1" && -t 0 ]]; then read -r -p '按 Return 關閉這個視窗：' _ || true; fi
    exit 1
  fi
fi

printf '%s\n' \
  '這只會刪除 Android 傳輸 V2 在目前專案資料夾產生的內容：' \
  '  dist/Android 傳輸 V2.app' \
  '  dist/INSTALLATION_REPORT.txt' \
  '  .local/' \
  '  Vendor/include/libmtp.h、libusb.h' \
  '  Vendor/lib/libmtp.dylib、libusb-1.0.dylib' \
  '不會修改 Homebrew、系統套件、其他專案或你的手機資料。' \
  ''

if [[ "${MTPBRIDGE_REMOVE_CONFIRM:-}" != "REMOVE" ]]; then
  read -r -p '輸入 REMOVE 後按 Return 才會繼續：' answer
  [[ "$answer" == "REMOVE" ]] || { printf '已取消。\n'; exit 0; }
fi

case "$ROOT/.local" in "$ROOT"/*) rm -rf "$ROOT/.local" ;; *) exit 1 ;; esac
case "$ROOT/dist" in "$ROOT"/*) rm -rf "$ROOT/dist" ;; *) exit 1 ;; esac
rm -f \
  "$ROOT/Vendor/include/libmtp.h" \
  "$ROOT/Vendor/include/libusb.h" \
  "$ROOT/Vendor/lib/libmtp.dylib" \
  "$ROOT/Vendor/lib/libusb-1.0.dylib" \
  "$ROOT/Vendor/DEPENDENCY_PROVENANCE.txt"

printf '已移除所有專案內產生的安裝內容。\n'
if [[ "${MTPBRIDGE_NO_PAUSE:-0}" != "1" && -t 0 ]]; then read -r -p '按 Return 關閉這個視窗：' _ || true; fi
