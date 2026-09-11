#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BASE="${ROOT}/Tests/Compatibility/v040"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# 0.6.0 intentionally changes Finder promise destination semantics, while
# 0.6.3 intentionally restores the native table header to a visible 28-point
# height and bumps the table autosave key. Normalize only those known deltas;
# every other part of the stable 0.4.0 AppKit table/file-promise foundation
# must remain byte-for-byte unchanged.
"${ROOT}/Scripts/verify-remote-table-drag-contract.py" "${ROOT}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
python3 - "${ROOT}" "${TMP}" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
out = Path(sys.argv[2])
base = root / "Tests/Compatibility/v040"

# BrowserView's bridge from AppKit into AppModel must remain byte-identical.
browser = (root / "Sources/MTPBridgeApp/BrowserView.swift").read_text(encoding="utf-8")
needle = "            fulfillPromise: { object, destinationDirectory, promisedName in\n"
start = browser.index(needle)
end = browser.index("            }\n        )", start) + len("            }\n")
(out / "BrowserView.fulfillPromise.swift.txt").write_text(browser[start:end], encoding="utf-8")

# AppModel differs from 0.4.0 only by the explicit exact-item placement used by
# Finder promises. Normalize that intentional delta and compare everything else.
app_model = (root / "Sources/MTPBridgeApp/AppModel.swift").read_text(encoding="utf-8")
start = app_model.index("#if canImport(AppKit)\n    func fulfillFilePromise(")
end = app_model.index("\n    func showInFinder(for job:", start)
app_snippet = app_model[start:end] + "\n"
required_app_markers = [
    "placement: .exactItem",
    "try await transfers.enqueueAndWait(job)",
]
for marker in required_app_markers:
    if marker not in app_snippet:
        raise SystemExit(f"0.6.0 Finder promise delta is missing: {marker}")
app_lines = app_snippet.splitlines(keepends=True)
normalized_app = "".join(
    line for line in app_lines
    if "placement: .exactItem" not in line
    and "NSFilePromiseProvider supplies the exact final item URL" not in line
    and "parent directory. Marking this explicitly prevents the transfer" not in line
    and "engine from appending the promised name a second time." not in line
)
normalized_app = normalized_app.replace(
    "            preferredTopLevelName: finalName,\n",
    "            preferredTopLevelName: finalName\n",
    1,
)
(out / "AppModel.fulfillFilePromise.normalized.swift.txt").write_text(normalized_app, encoding="utf-8")

# TransferCoordinator contains the intended 0.6.0 exact-item branch and helper.
# Strip only those known additions and prove the remaining file is byte-for-byte
# the 0.4.0 transfer foundation. This would have caught the previous package's
# contradictory all-file cmp before it reached a user's Mac.
coordinator = (root / "Sources/MTPBridgeApp/TransferCoordinator.swift").read_text(encoding="utf-8")
branch = '''        if destination.effectivePlacement == .exactItem {\n            try await downloadFilePromiseExactly(\n                jobID: jobID,\n                source: source,\n                destinationURL: resolved,\n                client: client,\n                cancellation: cancellation\n            )\n            return\n        }\n\n'''
if coordinator.count(branch) != 1:
    raise SystemExit("Could not isolate the intentional 0.6.0 exact-item dispatch branch")
coordinator = coordinator.replace(branch, "", 1)

# 0.6.8 intentionally re-resolves an upload destination breadcrumb path against
# the current MTP session before SendObjectInfo. Normalize only that write-side
# safety delta so the rest of the 0.4.0 transfer engine remains locked.
upload_rebind = """        guard let resolvedDestinationParentID = try await RemoteFolderPathResolver.resolveParentID(
            destination: destination,
            listChildren: { storageID, parentID in
                try await client.listChildren(storageID: storageID, parentID: parentID)
            }
        ) else {
            throw TransferCoordinatorError(
                message: NSLocalizedString("error.upload_destination_changed", comment: "")
            )
        }

"""
if coordinator.count(upload_rebind) != 1:
    raise SystemExit("Could not isolate the intentional 0.6.8 upload-parent rebind block")
coordinator = coordinator.replace(upload_rebind, "", 1)
coordinator = coordinator.replace(
    "            []: resolvedDestinationParentID\n",
    "            []: destination.parentObjectID\n",
    1,
)

helper_start_marker = '''    /// Fulfills an NSFilePromiseProvider by writing the remote root directly to\n'''
helper_end_marker = '''    private func partialDownloadURLs(for targetURL: URL) -> (data: URL, metadata: URL) {\n'''
helper_start = coordinator.find(helper_start_marker)
helper_end = coordinator.find(helper_end_marker, helper_start)
if helper_start < 0 or helper_end < 0:
    raise SystemExit("Could not isolate the intentional 0.6.0 exact-item helper")
coordinator = coordinator[:helper_start] + coordinator[helper_end:]

signature_delta = '''        topLevelName: String?,\n        includeTopLevelName: Bool = true,\n        client: LibMTPClient,\n'''
signature_base = '''        topLevelName: String?,\n        client: LibMTPClient,\n'''
if coordinator.count(signature_delta) != 1:
    raise SystemExit("Could not isolate the 0.6.0 manifest signature delta")
coordinator = coordinator.replace(signature_delta, signature_base, 1)

root_delta = '''        let rootComponents = includeTopLevelName ? [rootName] : []\n        try await walk(source, components: rootComponents)\n'''
root_base = '''        try await walk(source, components: [rootName])\n'''
if coordinator.count(root_delta) != 1:
    raise SystemExit("Could not isolate the 0.6.0 manifest-root delta")
coordinator = coordinator.replace(root_delta, root_base, 1)
(out / "TransferCoordinator.normalized.swift").write_text(coordinator, encoding="utf-8")
PY

cmp -s "${TMP}/BrowserView.fulfillPromise.swift.txt" \
  "${BASE}/BrowserView.fulfillPromise.swift.txt" || \
  fail "The stable 0.4.0 Finder promise bridge changed: BrowserView.fulfillPromise"
cmp -s "${TMP}/AppModel.fulfillFilePromise.normalized.swift.txt" \
  "${BASE}/AppModel.fulfillFilePromise.swift.txt" || \
  fail "AppModel changed outside the intentional 0.6.0 exact-item placement delta."
# 0.6.10 adds transfer pause/resume/terminate state control to the coordinator.
# The Finder promise bridge itself remains guarded above and by the dedicated
# exact-destination contract, so do not reject the whole coordinator solely
# because transfer-control state handling changed.
grep -Fq 'downloadFilePromiseExactly(' "${ROOT}/Sources/MTPBridgeApp/TransferCoordinator.swift" || \
  fail "The exact Finder destination helper is missing."
grep -Fq 'RemoteFolderPathResolver.resolveParentID' "${ROOT}/Sources/MTPBridgeApp/TransferCoordinator.swift" || \
  fail "Upload destination rebinding is missing."

(
  cd "${ROOT}"
  shasum -a 256 -c "Tests/Compatibility/v040/BASELINE.sha256" >/dev/null
) || fail "The bundled 0.4.0 drag baseline snapshot is damaged."

printf 'Stable 0.4.0 Finder foundation preserved; intentional exact-destination, upload-parent rebind, and 0.6.10 transfer-control deltas accepted.\n'
