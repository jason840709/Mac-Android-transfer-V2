#!/bin/bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
mkdir -p "$ROOT/.local/logs"
LOG="$ROOT/.local/logs/state-cleanup-$(date '+%Y%m%d-%H%M%S').log"
pause_window(){ if [[ "${MTPBRIDGE_NO_PAUSE:-0}" != "1" && -t 0 ]]; then printf '\n'; read -r -p '按 Return 關閉這個視窗：' _ || true; fi; }
exec > >(tee -a "$LOG") 2>&1
printf '%s\n' \
  'Android 傳輸 V2 — 舊版本狀態安全清理' \
  '────────────────────────────────────' \
  '• 先備份，再清空 Android 傳輸 V2 自己的傳輸佇列。' \
  '• 停止已淘汰／舊版本的 Android 傳輸 V2 背景偵測程序。' \
  '• 不會刪除手機檔案。' \
  '• 不會解除安裝或停止 Google Android File Transfer Agent。' \
  '• 不會修改 Homebrew、其他 App 或系統套件。' \
  ''
if [[ "${MTPBRIDGE_REMOVE_CONFIRM:-}" != "CLEAN" ]]; then
  read -r -p '輸入 CLEAN 後按 Return 才會繼續：' answer
  [[ "$answer" == "CLEAN" ]] || { printf '已取消。\n'; pause_window; exit 0; }
fi
MTPBRIDGE_FORCE_STATE_RESET=1 "$ROOT/Scripts/migrate-persistent-state.sh"
printf '\n清理完成。備份位於本專案 .local/state-backups/。\n'
printf '接著可在 Tools 資料夾雙擊「安裝並啟動 Android 傳輸 V2.command」。\n'
printf '紀錄：%s\n' "$LOG"
pause_window
