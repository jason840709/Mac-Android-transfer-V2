#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MANIFEST="${ROOT}/Tests/Compatibility/v066-preserved-surface.sha256"
[[ -f "$MANIFEST" ]] || { echo 'ERROR: 0.6.7 preserved-surface manifest is missing.' >&2; exit 1; }
python3 - "$ROOT" "$MANIFEST" <<'PY'
import hashlib, sys
from pathlib import Path
root=Path(sys.argv[1]); manifest=Path(sys.argv[2])
count=0
for line in manifest.read_text(encoding='utf-8').splitlines():
    if not line.strip(): continue
    digest, rel=line.split('  ',1)
    path=root/rel
    if not path.is_file(): raise SystemExit(f'Preserved stable file missing: {rel}')
    data=path.read_bytes()
    if rel == 'Sources/MTPBridgeApp/MTPBridge-Bridging-Header.h':
        text=data.decode('utf-8')
        marker='#include "device_registration.h"\n'
        if text.count(marker) != 1:
            raise SystemExit('Expected exactly one device_registration.h include in the bridging header')
        data=text.replace(marker, '').encode('utf-8')
    actual=hashlib.sha256(data).hexdigest()
    if actual!=digest: raise SystemExit(f'Stable transfer/UI surface changed unexpectedly: {rel}')
    count+=1
print(f'Stable transfer/UI surface preserved across {count} files; AppModel/ConnectionView are intentionally excluded for MTP coexistence handling.')
PY

grep -Fq 'MTPAccessArbiter.currentConflict()' "$ROOT/Sources/MTPBridgeApp/AppModel.swift" || { echo 'ERROR: coexistence gate missing from AppModel.' >&2; exit 1; }
grep -Fq 'try await Task.sleep(for: .milliseconds(650))' "$ROOT/Sources/MTPBridgeApp/AppModel.swift" || { echo 'ERROR: USB mode settling window missing.' >&2; exit 1; }
grep -Fq 'connection.conflict.stop_legacy' "$ROOT/Sources/MTPBridgeApp/ConnectionView.swift" || { echo 'ERROR: conflict-resolution UI missing.' >&2; exit 1; }

echo '0.6.7 MTP coexistence delta is isolated from the previously accepted transfer/UI surface.'
