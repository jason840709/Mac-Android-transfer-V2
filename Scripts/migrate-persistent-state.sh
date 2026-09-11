#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
STATE_CONTAINER="${MTPBRIDGE_STATE_CONTAINER:-$HOME/Library/Containers/io.github.mtpbridge.MTPBridge}"
APP_SUPPORT="${MTPBRIDGE_STATE_APP_SUPPORT:-$STATE_CONTAINER/Data/Library/Application Support/MTPBridge}"
QUEUE="$APP_SUPPORT/transfers.json"
PREFS="$STATE_CONTAINER/Data/Library/Preferences/io.github.mtpbridge.MTPBridge.plist"
STAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP_ROOT="${MTPBRIDGE_STATE_BACKUP_ROOT:-$ROOT/.local/state-backups/$STAMP}"
FORCE_RESET="${MTPBRIDGE_FORCE_STATE_RESET:-0}"
mkdir -p "$BACKUP_ROOT"

backup_file() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  cp -p "$path" "$BACKUP_ROOT/$(basename "$path")"
}

if [[ -f "$QUEUE" ]]; then
  backup_file "$QUEUE"
  python3 - "$QUEUE" "$FORCE_RESET" <<'PY'
import json, os, sys, tempfile
from pathlib import Path
path=Path(sys.argv[1]); force=sys.argv[2]=='1'
try:
    payload=json.loads(path.read_text(encoding='utf-8'))
except Exception:
    # Unknown queue data is unsafe to execute. Keep it only in the backup and
    # replace the active queue with a clean schema-aware envelope.
    payload=[]

if isinstance(payload, list):
    source_jobs=payload
    legacy=True
elif isinstance(payload, dict) and isinstance(payload.get('jobs'), list):
    source_jobs=payload['jobs']
    legacy=int(payload.get('schemaVersion',0) or 0) < 3
else:
    source_jobs=[]
    legacy=True

terminal={'completed','failed','cancelled'}
if force:
    kept=[]
elif legacy:
    # Legacy active jobs may carry MTP object handles captured from a different
    # USB/session generation. Preserve terminal history but never replay active
    # work from an unversioned queue.
    kept=[job for job in source_jobs if isinstance(job,dict) and job.get('state') in terminal]
else:
    kept=source_jobs

result={'schemaVersion':3,'jobs':kept}
data=(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True)+'\n').encode('utf-8')
fd,tmp=tempfile.mkstemp(prefix='.transfers.', suffix='.tmp', dir=str(path.parent))
try:
    with os.fdopen(fd,'wb') as h:
        h.write(data); h.flush(); os.fsync(h.fileno())
    os.replace(tmp,path)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
print(f'queue-migrated legacy={legacy} force={force} original={len(source_jobs)} active={len(kept)}')
PY
fi

backup_file "$PREFS"
if [[ -f "$PREFS" ]]; then
  python3 - "$PREFS" <<'PY_PREFS'
import plistlib, sys
from pathlib import Path
p=Path(sys.argv[1])
try:
    with p.open('rb') as h: data=plistlib.load(h)
except Exception:
    data={}
removed=[]
for key in [
    'AndroidTransferV2.AutoLaunchEnabled',
    'AndroidTransferV2.DeviceInsertionRegistrationBackend',
    'AndroidTransferV2.DeviceInsertionRegisteredBuild',
    'AndroidTransferV2.DeviceInsertionRegistrationBackendV2',
    'AndroidTransferV2.DeviceInsertionRegistrationTokenV2',
]:
    if key in data:
        removed.append(key); data.pop(key,None)
if removed:
    with p.open('wb') as h: plistlib.dump(data,h,fmt=plistlib.FMT_BINARY)
print('preferences-reset keys=' + (','.join(removed) if removed else 'none'))
PY_PREFS
else
  printf 'preferences-reset keys=none (preferences file absent)\n'
fi

if [[ "$(uname -s)" == "Darwin" && "${MTPBRIDGE_SKIP_HELPER_CLEANUP:-0}" != "1" ]]; then
  UID_VALUE="$(id -u)"
  for label in \
    io.github.mtpbridge.DeviceInsertionAgentV2 \
    io.github.mtpbridge.DeviceInsertionAgent \
    io.github.mtpbridge.DeviceWatcher \
    io.github.mtpbridge.MTPAutoLaunch; do
    if /bin/launchctl print "gui/$UID_VALUE/$label" >/dev/null 2>&1; then
      /bin/launchctl bootout "gui/$UID_VALUE/$label" >/dev/null 2>&1 || true
      printf 'helper-bootout %s\n' "$label"
    else
      printf 'helper-not-loaded %s\n' "$label"
    fi
  done

  PKILL="$(command -v pkill || true)"
  if [[ -n "$PKILL" ]]; then
    for process in MTPBridge AndroidTransferV2DeviceAgent AndroidTransferV2DeviceWatcher; do
      if "$PKILL" -x "$process" >/dev/null 2>&1; then
        printf 'process-stopped %s\n' "$process"
      else
        printf 'process-not-running %s\n' "$process"
      fi
    done
  fi
fi

printf 'Android 傳輸 V2 舊狀態已備份／遷移：%s\n' "$BACKUP_ROOT"
