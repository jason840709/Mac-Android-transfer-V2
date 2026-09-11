#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
python3 - "${ROOT}" <<'PY'
import re
import sys
from pathlib import Path
root=Path(sys.argv[1])
read=lambda p:(root/p).read_text(encoding='utf-8')
table=read('Sources/MTPBridgeApp/RemoteBrowserTable.swift')
shelf=read('Sources/MTPBridgeApp/TransferShelfView.swift')
sidebar=read('Sources/MTPBridgeApp/SidebarView.swift')

for marker in [
    'NSTableHeaderView(',
    'height: 28',
    'headerView.isHidden = false',
    'tableView.headerView = headerView',
    'AndroidTransferV2.RemoteBrowserTable.v3',
    'sortDescriptorPrototype',
    'sortDescriptorsDidChange',
]:
    if marker not in table:
        raise SystemExit(f'0.6.3 table-header regression: missing {marker}')
if 'NSTableHeaderView(frame: .zero)' in table:
    raise SystemExit('0.6.3 table header returned to zero height')

for marker in [
    '@State private var autoCollapseTask',
    'allTransfersCompleted',
    'Task.sleep(for: .milliseconds(650))',
    'model.transfers.isExpanded = false',
    'handleDialogClose()',
    'hasUnfinishedTransfers',
    'model.transfers.clearFinished()',
    'Image(systemName: "stop.circle")',
    'transfer.close',
    '.easeOut(duration: 0.20)',
]:
    if marker not in shelf:
        raise SystemExit(f'0.6.3 transfer-shelf regression: missing {marker}')

# There must still be exactly one plain xmark, the dialog-level close button.
# 0.6.10 intentionally adds a circled xmark only for a paused transfer, where
# it means terminate, plus a trash button that explicitly removes the row.
if shelf.count('Image(systemName: "xmark")') != 1:
    raise SystemExit('Transfer shelf must have exactly one dialog-level plain xmark')
for required in [
    'job.state == .paused',
    'Image(systemName: "play.circle.fill")',
    'Image(systemName: "xmark.circle")',
    'Image(systemName: "trash")',
    'model.transfers.terminate(jobID: job.id)',
    'model.transfers.remove(jobID: job.id)',
]:
    if required not in shelf:
        raise SystemExit(f'0.6.10 paused-transfer control missing: {required}')
if '.spring(' in shelf or '.spring(' in sidebar:
    raise SystemExit('Transfer panel navigation returned to spring animation')

# Close semantics: active work collapses, terminal-only work clears the panel.
body=re.search(r'private func handleDialogClose\(\) \{(.*?)\n    \}', shelf, re.S)
if not body:
    raise SystemExit('Could not inspect transfer-panel close behavior')
text=body.group(1)
if not ('if hasUnfinishedTransfers' in text and 'isExpanded = false' in text and 'clearFinished()' in text):
    raise SystemExit('Transfer-panel close semantics do not match active-vs-finished policy')

print('Android Transfer V2 0.6.3 visible-header/transfer-shelf contract passed.')
PY
