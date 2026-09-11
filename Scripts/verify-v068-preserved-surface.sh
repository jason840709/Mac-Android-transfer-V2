#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MANIFEST="$ROOT/Tests/Compatibility/v068-preserved-surface.sha256"
python3 - "$ROOT" "$MANIFEST" <<'PY2'
import hashlib, sys
from pathlib import Path
root=Path(sys.argv[1]); manifest=Path(sys.argv[2]); count=0
for line in manifest.read_text().splitlines():
    if not line.strip(): continue
    digest, rel=line.split('  ',1); p=root/rel
    if not p.is_file(): raise SystemExit(f'Preserved 0.6.7 file missing: {rel}')
    data=p.read_bytes()
    if rel == 'Sources/MTPBridgeApp/MTPBridge-Bridging-Header.h':
        marker=b'#include "device_registration.h"\n'
        if data.count(marker)!=1: raise SystemExit('Expected one device_registration include')
        data=data.replace(marker,b'')
    if hashlib.sha256(data).hexdigest()!=digest:
        raise SystemExit(f'Unexpected change outside upload-parent fix: {rel}')
    count+=1
print(f'0.6.7 accepted transfer/UI/coexistence surface preserved across {count} files.')
PY2
for changed in \
  Sources/MTPBridgeApp/AppModel.swift \
  Sources/MTPBridgeApp/TransferCoordinator.swift \
  Sources/MTPBridgeCore/MTPModels.swift \
  Sources/MTPBridgeCore/RemoteFolderPathResolver.swift; do
  [[ -f "$ROOT/$changed" ]] || { echo "ERROR: required 0.6.8 upload rebind file missing: $changed" >&2; exit 1; }
done
echo '0.6.8 delta is isolated to upload destination rebinding, versioning, tests, localization, and docs.'
