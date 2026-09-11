#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MODEL="$ROOT/Sources/MTPBridgeCore/MTPModels.swift"
COORD="$ROOT/Sources/MTPBridgeApp/TransferCoordinator.swift"
VIEW="$ROOT/Sources/MTPBridgeApp/TransferShelfView.swift"
STATUS="$ROOT/Sources/MTPBridgeCore/TransferStatusPresentation.swift"
STORE="$ROOT/Sources/MTPBridgeApp/TransferQueueStore.swift"
for marker in 'case paused' 'case .paused:'; do grep -Fq "$marker" "$MODEL" "$STATUS" || { echo "ERROR: paused transfer state missing: $marker" >&2; exit 1; }; done
for marker in 'func pause(jobID:' 'func resume(jobID:' 'func terminate(jobID:' 'private func markPaused(jobID:'; do grep -Fq "$marker" "$COORD" || { echo "ERROR: transfer control missing: $marker" >&2; exit 1; }; done
for marker in 'play.circle.fill' 'xmark.circle' 'Image(systemName: "trash")' 'model.transfers.pause(jobID:' 'model.transfers.resume(jobID:' 'model.transfers.terminate(jobID:'; do grep -Fq "$marker" "$VIEW" || { echo "ERROR: transfer shelf control missing: $marker" >&2; exit 1; }; done
grep -Fq 'job.state == .paused' "$STORE" || { echo 'ERROR: persisted paused jobs are not preserved.' >&2; exit 1; }
printf 'Android Transfer V2 0.6.10 pause/resume/terminate/delete transfer-control contract passed.\n'
