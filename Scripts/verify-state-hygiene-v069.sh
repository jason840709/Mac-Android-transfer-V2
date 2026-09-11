#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
STORE="$ROOT/Sources/MTPBridgeApp/TransferQueueStore.swift"
POLICY="$ROOT/Sources/MTPBridgeCore/TransferQueuePersistencePolicy.swift"
RESOLVER="$ROOT/Sources/MTPBridgeCore/RemoteFolderPathResolver.swift"
SERVICE="$ROOT/Sources/MTPBridgeApp/DeviceInsertionService.swift"
MIGRATOR="$ROOT/Scripts/migrate-persistent-state.sh"
CLEANER="$ROOT/Tools/清理舊版本狀態.command"
INSTALLER="$ROOT/Tools/安裝並啟動 Android 傳輸 V2.command"
fail(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for f in "$STORE" "$POLICY" "$RESOLVER" "$SERVICE" "$MIGRATOR" "$CLEANER" "$INSTALLER"; do [[ -f "$f" ]] || fail "Missing state-hygiene file: $f"; done
[[ -x "$MIGRATOR" ]] || fail 'State migrator is not executable.'
[[ -x "$CLEANER" ]] || fail 'State cleanup command is not executable.'
for marker in 'currentSchemaVersion = 3' 'canResumePersistedUpload' 'sourceSchemaVersion == nil'; do grep -Fq "$marker" "$POLICY" || fail "Missing persistence policy marker: $marker"; done
for marker in 'TransferQueueEnvelope' 'schemaVersion: TransferQueuePersistencePolicy.currentSchemaVersion' 'backupLegacyQueue' 'error.legacy_upload_requires_redrag'; do grep -Fq "$marker" "$STORE" || fail "Missing queue migration marker: $marker"; done
grep -Fq 'return nil' "$RESOLVER" || fail 'Legacy upload path resolver can still replay a captured handle.'
for marker in 'DeviceInsertionRegistrationTokenV2' 'recordedToken != currentRegistrationToken' 'currentMainBundlePath' 'application.bundleURL' 'modernService.unregister()'; do grep -Fq "$marker" "$SERVICE" || fail "Missing device-agent migration marker: $marker"; done
grep -Fq 'Scripts/migrate-persistent-state.sh' "$INSTALLER" || fail 'Installer does not run persistent-state migration.'
grep -Fq 'MTPBRIDGE_FORCE_STATE_RESET=1' "$CLEANER" || fail 'Cleanup command does not request a clean queue reset.'
if grep -Eq 'pkill.*Android File Transfer|killall.*Android File Transfer|com\.google\.android\.mtpagent.*bootout' "$CLEANER" "$MIGRATOR"; then
  fail 'State cleanup must not terminate or unregister Google Android File Transfer.'
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
APP_SUPPORT="$TMP/container/Data/Library/Application Support/MTPBridge"
mkdir -p "$APP_SUPPORT" "$TMP/backups"
cat > "$APP_SUPPORT/transfers.json" <<'JSON'
[
  {"state":"completed","direction":"download","displayName":"old-complete"},
  {"state":"retrying","direction":"upload","displayName":"unsafe-old-upload"}
]
JSON
MTPBRIDGE_STATE_CONTAINER="$TMP/container" \
MTPBRIDGE_STATE_APP_SUPPORT="$APP_SUPPORT" \
MTPBRIDGE_STATE_BACKUP_ROOT="$TMP/backups" \
MTPBRIDGE_SKIP_HELPER_CLEANUP=1 \
  "$MIGRATOR" >/dev/null
python3 - "$APP_SUPPORT/transfers.json" "$TMP/backups" <<'PY'
import json,sys
from pathlib import Path
queue=json.loads(Path(sys.argv[1]).read_text())
if queue.get('schemaVersion') != 3: raise SystemExit('queue schema was not migrated to v3')
jobs=queue.get('jobs')
if len(jobs)!=1 or jobs[0].get('state')!='completed': raise SystemExit(f'legacy active jobs survived migration: {jobs!r}')
if not (Path(sys.argv[2])/'transfers.json').is_file(): raise SystemExit('legacy queue backup missing')
PY

cat > "$APP_SUPPORT/transfers.json" <<'JSON'
{"schemaVersion":3,"jobs":[{"state":"completed","direction":"download","displayName":"history"}]}
JSON
MTPBRIDGE_STATE_CONTAINER="$TMP/container" \
MTPBRIDGE_STATE_APP_SUPPORT="$APP_SUPPORT" \
MTPBRIDGE_STATE_BACKUP_ROOT="$TMP/backups-force" \
MTPBRIDGE_SKIP_HELPER_CLEANUP=1 \
MTPBRIDGE_FORCE_STATE_RESET=1 \
  "$MIGRATOR" >/dev/null
python3 - "$APP_SUPPORT/transfers.json" <<'PY'
import json,sys
from pathlib import Path
queue=json.loads(Path(sys.argv[1]).read_text())
if queue != {'schemaVersion':3,'jobs':[]}: raise SystemExit(f'force reset did not produce clean queue: {queue!r}')
PY
printf 'Android Transfer V2 persistent-state migration and 0.7.0 path-bound stale-helper hygiene contract passed.\n'
