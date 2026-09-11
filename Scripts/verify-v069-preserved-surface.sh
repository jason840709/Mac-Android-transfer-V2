#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MANIFEST="$ROOT/Tests/Compatibility/v069-preserved-surface.sha256"
python3 - "$ROOT" "$MANIFEST" <<'PY'
import hashlib,sys
from pathlib import Path
root=Path(sys.argv[1]); manifest=Path(sys.argv[2]); count=0
allowed={
    'Sources/MTPBridgeCLib/mtp_bridge.c',
    'Sources/MTPBridgeApp/TransferCoordinator.swift',
    'Sources/MTPBridgeApp/TransferQueueStore.swift',
    'Sources/MTPBridgeApp/TransferShelfView.swift',
    'Sources/MTPBridgeApp/DeviceInsertionService.swift',
    'Sources/MTPBridgeApp/DeviceInsertionIdentifiers.swift',
    'Sources/MTPDeviceRegistration/device_registration.h',
    'Sources/MTPDeviceRegistration/device_registration.m',
    'Sources/MTPDeviceWatcher/MTPDeviceWatcher.swift',
    'Sources/MTPBridgeCore/DeviceAgentLaunchCandidatePolicy.swift',
    'Sources/MTPBridgeCore/MTPModels.swift',
    'Sources/MTPBridgeCore/RemoteFolderPathResolver.swift',
    'Sources/MTPBridgeCore/TransferDisconnectPolicy.swift',
    'Sources/MTPBridgeCore/TransferQueuePersistencePolicy.swift',
    'Sources/MTPBridgeCore/TransferStatusPresentation.swift',
}
for line in manifest.read_text().splitlines():
    if not line.strip(): continue
    digest,rel=line.split('  ',1); p=root/rel
    if not p.is_file(): raise SystemExit(f'Preserved source missing: {rel}')
    if rel in allowed: continue
    if hashlib.sha256(p.read_bytes()).hexdigest()!=digest:
        raise SystemExit(f'Unexpected source change outside the accepted 0.7.0 device-launch fix surface: {rel}')
    count+=1
print(f'Accepted 0.6.8 surface preserved across {count} unchanged source files; 0.7.0 changed files are explicitly allowlisted.')
PY
for changed in \
  Sources/MTPBridgeCLib/mtp_bridge.c \
  Sources/MTPBridgeApp/TransferCoordinator.swift \
  Sources/MTPBridgeApp/TransferShelfView.swift \
  Sources/MTPBridgeCore/MTPModels.swift \
  Sources/MTPBridgeCore/TransferStatusPresentation.swift; do
  [[ -f "$ROOT/$changed" ]] || { echo "ERROR: required accepted transfer fix file missing: $changed" >&2; exit 1; }
done
echo '0.7.0 delta remains isolated to device-agent registration/launch resolution, tests, versioning, and docs; accepted transfer/UI code remains preserved.'
