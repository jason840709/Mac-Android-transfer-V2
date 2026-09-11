#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BASE="${ROOT}/Tests/Compatibility/v040"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# Keep the native AppKit provider/table implementation that was proven usable in
# 0.4.0. Version 0.6.0 changes destination interpretation; later UI releases only
# restores a visible header plus a fresh autosave key. Normalize that UI-only
# delta before proving the rest of the provider/table implementation unchanged.
"${ROOT}/Scripts/verify-remote-table-drag-contract.py" "${ROOT}"

python3 - "${ROOT}" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
models = (root / "Sources/MTPBridgeCore/MTPModels.swift").read_text(encoding="utf-8")
model_tests = (root / "Tests/MTPBridgeCoreTests/MTPModelsTests.swift").read_text(encoding="utf-8")
layout = (root / "Sources/MTPBridgeCore/FilePromiseDestinationLayout.swift").read_text(encoding="utf-8")
layout_tests = (root / "Tests/MTPBridgeCoreTests/FilePromiseDestinationLayoutTests.swift").read_text(encoding="utf-8")
app_model = (root / "Sources/MTPBridgeApp/AppModel.swift").read_text(encoding="utf-8")
client = (root / "Sources/MTPBridgeApp/LibMTPClient.swift").read_text(encoding="utf-8")
coordinator = (root / "Sources/MTPBridgeApp/TransferCoordinator.swift").read_text(encoding="utf-8")
c_tests = (root / "Tests/CBridgeTests/bridge_tests.c").read_text(encoding="utf-8")

for marker in [
    "enum LocalTransferPlacement",
    "case insideDirectory",
    "case exactItem",
    "var placement: LocalTransferPlacement?",
    "placement ?? .insideDirectory",
]:
    if marker not in models:
        raise SystemExit(f"0.6.0 destination model regression: missing {marker}")

for marker in [
    "testLegacyLocalTransferDestinationDefaultsToDirectoryPlacement",
    "testExactFilePromiseDestinationRoundTrip",
    ".exactItem",
]:
    if marker not in model_tests:
        raise SystemExit(f"0.6.0 destination compatibility test missing: {marker}")

for marker in [
    "relativeComponents.enumerated().reduce(exactDestinationURL)",
    "isFinalComponent ? isDirectory : true",
    "testRemoteRootUsesTheExactFinderURL",
    "testFolderChildrenAreAppendedOnlyBelowThePromisedRoot",
    "testFinderCollisionResolvedNameIsNotReplacedByTheRemoteName",
    "report 2.pdf",
]:
    if marker not in layout + layout_tests:
        raise SystemExit(f"0.6.0 exact destination layout regression: missing {marker}")

promise_start = app_model.index("func fulfillFilePromise(")
promise_end = app_model.index("\n    func showInFinder(for job:", promise_start)
promise_body = app_model[promise_start:promise_end]
for marker in [
    "directoryPath: destinationDirectory.path",
    "placement: .exactItem",
    "enqueueAndWait",
]:
    if marker not in promise_body:
        raise SystemExit(f"Finder promise setup regression: missing {marker}")
if "appendingPathComponent" in promise_body:
    raise SystemExit("Finder promise setup appends a second top-level filename")

for marker in [
    "allowResume: Bool = true",
    "allowResume,",
]:
    if marker not in client:
        raise SystemExit(f"LibMTP exact-write regression: missing {marker}")

helper_start = coordinator.index("private func downloadFilePromiseExactly(")
helper_end = coordinator.index("\n    private func partialDownloadURLs", helper_start)
helper = coordinator[helper_start:helper_end]
for marker in [
    "destination.effectivePlacement == .exactItem",
    "includeTopLevelName: false",
    "allowResume: false",
    "to: targetURL",
    "manager.removeItem(at: destinationURL)",
    "error.file_promise_destination_exists",
    "error.file_promise_type_mismatch",
]:
    if marker not in coordinator:
        raise SystemExit(f"Exact Finder destination regression: missing {marker}")
for forbidden in [
    "partialDownloadURLs",
    ".mtpbridge-partial",
    ".moveItem(",
    ".replaceItemAt(",
    "FilePromiseWriter",
    "DragExports",
]:
    if forbidden in helper:
        raise SystemExit(f"Exact Finder destination incorrectly uses later staging/commit logic: {forbidden}")

# Normal panel downloads retain the established resumable sidecar/atomic-move
# behavior; only file promises bypass it.
normal_start = coordinator.index("private func download(\n")
normal_end = coordinator.index("private func downloadFilePromiseExactly(", normal_start)
normal = coordinator[normal_start:normal_end]
for marker in ["partialDownloadURLs", "preparePartialDownload", "replaceItemAt", "moveItem"]:
    if marker not in normal:
        raise SystemExit(f"Normal Download command regression: missing {marker}")

for marker in [
    "test_nonresumable_download_truncates_exact_destination",
    "false,",
    "resumed_from == 0",
    "exact nonresumable file-promise writes",
]:
    if marker not in c_tests:
        raise SystemExit(f"C exact-write regression test missing: {marker}")

print("Android Transfer V2 0.6.0 exact Finder destination contract passed.")
PY
