#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
python3 - "$ROOT/Sources/MTPBridgeApp/ConnectionView.swift" <<'PY'
import sys
from pathlib import Path
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
required = [
    'case .searching, .connecting: return AppPalette.accent',
    'case .failed: return AppPalette.warning',
    'case .connected: return AppPalette.success',
    'case .disconnected: return .secondary',
    'case .searching: return "connection.searching.title"',
    'case .connecting: return "connection.connecting.title"',
    'case .failed: return "connection.failed.title"',
    'default: return "connection.empty.title"',
    'return NSLocalizedString("connection.searching.message", comment: "")',
    'return NSLocalizedString("connection.connecting.message", comment: "")',
    'return error',
    'return NSLocalizedString("connection.empty.message", comment: "")',
    'case .disconnected: return "disconnected"',
    'case .searching: return "searching"',
    'case .connecting: return "connecting"',
    'case .connected: return "connected"',
    'case .failed: return "failed"',
]
missing=[x for x in required if x not in s]
if missing:
    raise SystemExit('ConnectionView Swift-5 explicit-return contract failed; missing: ' + repr(missing))
# Regression guard against the exact r1 form that compiled only as warnings/errors on the real Mac.
for forbidden in [
    'case .searching, .connecting: AppPalette.accent',
    'case .disconnected: .secondary',
    'case .searching: "connection.searching.title"',
    'case .disconnected: "disconnected"',
]:
    if forbidden in s:
        raise SystemExit('r1 implicit-return regression returned: ' + forbidden)
print('ConnectionView Swift 5 multi-statement computed-property return contract passed.')
PY
