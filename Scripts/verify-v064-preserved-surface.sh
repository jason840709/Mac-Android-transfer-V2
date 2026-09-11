#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MANIFEST="${ROOT}/Tests/Compatibility/v063-readable-ui-r2-preserved.sha256"
[[ -f "$MANIFEST" ]] || { echo 'ERROR: 0.6.3 preserved-surface manifest is missing.' >&2; exit 1; }
python3 - "$ROOT" "$MANIFEST" <<'PY'
import hashlib, sys
from pathlib import Path
root=Path(sys.argv[1]); manifest=Path(sys.argv[2])
count=0
for line in manifest.read_text(encoding='utf-8').splitlines():
    if not line.strip(): continue
    digest, rel=line.split('  ',1)
    path=root/rel
    if not path.is_file(): raise SystemExit(f'Preserved 0.6.3 file missing: {rel}')
    data=path.read_bytes()
    if rel == 'Sources/MTPBridgeApp/MTPBridge-Bridging-Header.h':
        # 0.6.7 deliberately adds one Objective-C ServiceManagement bridge to
        # the otherwise preserved main bridging header. Normalize only that
        # exact include before checking the 0.6.3 stable baseline hash.
        text=data.decode('utf-8')
        marker='#include "device_registration.h"\n'
        if text.count(marker) != 1:
            raise SystemExit('Expected exactly one device_registration.h include in the 0.6.7 bridging header')
        data=text.replace(marker, '').encode('utf-8')
    actual=hashlib.sha256(data).hexdigest()
    if actual!=digest: raise SystemExit(f'0.6.3 stable behavior surface changed unexpectedly: {rel}')
    count+=1
print(f'0.6.3 stable transfer/UI surface preserved across {count} files; only the explicit 0.6.7 registration include is normalized.')
PY
