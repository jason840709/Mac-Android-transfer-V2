#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
python3 - "${ROOT}" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
read = lambda relative: (root / relative).read_text(encoding="utf-8")

browser = read("Sources/MTPBridgeApp/BrowserView.swift")
table = read("Sources/MTPBridgeApp/RemoteBrowserTable.swift")
model = read("Sources/MTPBridgeApp/AppModel.swift")
monitor = read("Sources/MTPBridgeApp/USBPresenceMonitor.swift")
transfer = read("Sources/MTPBridgeApp/TransferCoordinator.swift")
client = read("Sources/MTPBridgeApp/LibMTPClient.swift")
bridge = read("Sources/MTPBridgeCLib/mtp_bridge.c")
bridge_header = read("Sources/MTPBridgeCLib/include/mtp_bridge.h")
sorting = read("Sources/MTPBridgeCore/MTPObjectSorting.swift")
sorting_tests = read("Tests/MTPBridgeCoreTests/MTPObjectSortingTests.swift")
filename_tests = read("Tests/MTPBridgeCoreTests/FilenamePolicyTests.swift")
presence_core = read("Sources/MTPBridgeCore/USBPresenceDecision.swift")
presence_tests = read("Tests/MTPBridgeCoreTests/USBPresenceDecisionTests.swift")
connection = read("Sources/MTPBridgeApp/ConnectionView.swift")
shelf = read("Sources/MTPBridgeApp/TransferShelfView.swift")
status = read("Sources/MTPBridgeCore/TransferStatusPresentation.swift")
status_tests = read("Tests/MTPBridgeCoreTests/TransferStatusPresentationTests.swift")
preflight = read("Scripts/preflight-swift-app.sh")
installer = read("Tools/安裝並啟動 Android 傳輸 V2.command")
builder = read("Scripts/build-local-app.sh")
verify = read("Scripts/verify.sh")
config = read("Config/Info.plist")

# Row selection, double-click, resizing, and sorting must all be owned by one
# native AppKit table. Per-cell SwiftUI gestures caused stale selection visuals.
for marker in [
    "struct RemoteBrowserTable: NSViewRepresentable",
    "NSTableView",
    "selectionHighlightStyle = .regular",
    "allowsMultipleSelection = true",
    "allowsColumnResizing = true",
    "allowsColumnReordering = true",
    "tableViewSelectionDidChange",
    "doubleAction",
    "sortDescriptorPrototype",
    "sortDescriptorsDidChange",
    "selectRowIndexes",
    "isSynchronizingSelection = true",
    "tableView.reloadData()",
    "synchronizeSelection()",
    "MTPSelectionMapping.objectIDs",
    "MTPSelectionMapping.rowIndexes",
    "RemoteBrowserTable(",
]:
    haystack = table if marker != "RemoteBrowserTable(" else browser
    if marker not in haystack:
        raise SystemExit(f"Native table regression: missing {marker}")
for forbidden in [".simultaneousGesture(", ".onDrag {", ".dropDestination(", "registerFileRepresentation", "suggestedName"]:
    if forbidden in browser or forbidden in table:
        raise SystemExit(f"Legacy selection/drag regression returned: {forbidden}")
if re.search(r"(?m)^\s*Table\(", browser):
    raise SystemExit("Browser returned to the SwiftUI Table implementation")

selection_tests = read("Tests/MTPBridgeCoreTests/MTPSelectionMappingTests.swift")
for marker in [
    "testSelectionFollowsObjectIdentifierAcrossReordering",
    "testVisibleRowsMapBackToTheCorrectObjectIdentifiers",
]:
    if marker not in selection_tests:
        raise SystemExit(f"Selection mapping regression test missing: {marker}")

# Every visible header must drive a tested real sort order in both directions.
for key in ["name", "type", "size", "created", "modified"]:
    if f"case {key}" not in sorting:
        raise SystemExit(f"Missing sort key: {key}")
    if f".{key}" not in sorting_tests:
        raise SystemExit(f"Sort tests do not cover: {key}")
for marker in ["ascending: true", "ascending: false", "Unknown dates remain at the bottom"]:
    if marker not in sorting + sorting_tests:
        raise SystemExit(f"Sort regression contract missing: {marker}")

# DateCreated is optional and expensive. Initial listing must remain fast; the
# browser enriches dates lazily and distinguishes pending from unsupported.
for marker in [
    "mtp_bridge_get_object_creation_time",
    "LIBMTP_PROPERTY_DateCreated",
    "LIBMTP_Get_String_From_Object",
    "MTP_BRIDGE_PROPERTY_OPTIMISTIC_PROBE_LIMIT",
    "check_date_created_capability_hint",
    "PROPERTY_SUPPORT_UNKNOWN",
]:
    if marker not in bridge + bridge_header:
        raise SystemExit(f"DateCreated bridge regression: missing {marker}")
try:
    list_start = bridge.index("int32_t mtp_bridge_list_children(")
    creation_reader_start = bridge.index("int32_t mtp_bridge_get_object_creation_time(", list_start)
except ValueError as error:
    raise SystemExit("Could not isolate fast folder-list implementation") from error
if "LIBMTP_Get_String_From_Object" in bridge[list_start:creation_reader_start]:
    raise SystemExit("Folder listing again performs a DateCreated round trip per item")
for marker in [
    "readCreationDate",
    "pendingCreationDateIDs",
    "startCreationDateEnrichment",
    "applyCreationDateBatch",
    "cancelCreationDateEnrichment",
    "browser.date.loading",
    "browser.date.unavailable",
]:
    if marker not in client + model + table:
        raise SystemExit(f"Creation-date UI regression: missing {marker}")

# Finder export uses native file promises. The exact complete filename is
# returned once, so .pdf does not become .pdf.pdf and .txt is a normal file.
for marker in [
    "NSFilePromiseProvider",
    "NSFilePromiseProviderDelegate",
    "pasteboardWriterForRow",
    "fileNameForType",
    "writePromiseTo",
    "UTType(filenameExtension:",
    "FilenamePolicy.promisedFileName",
]:
    if marker not in table:
        raise SystemExit(f"File-promise regression: missing {marker}")
for marker in ["report.pdf", "notes.txt", ".pdf.pdf"]:
    if marker not in filename_tests:
        raise SystemExit(f"Filename promise test missing: {marker}")

# The lightweight probe is independent of the serialized MTP session. Two
# successful misses remove the device; probe errors never count as unplugging.
for marker in [
    "USBPresenceDecision(requiredConsecutiveMisses: 2)",
    "isUSBDevicePresent",
    "milliseconds(250)",
    "probeFailed",
]:
    if marker not in monitor + presence_core:
        raise SystemExit(f"USB monitor regression: missing {marker}")
for marker in ["testRequiresTwoSuccessfulMisses", "testProbeFailureIsNotTreatedAsRemoval"]:
    if marker not in presence_tests:
        raise SystemExit(f"USB decision regression test missing: {marker}")
for marker in [
    "handlePhysicalDisconnect",
    "transitionToDisconnected(preserveNavigation: true)",
    "transfers.deviceDidDisconnect()",
    "Task { await previousClient?.close() }",
]:
    if marker not in model:
        raise SystemExit(f"Disconnect regression: missing {marker}")
physical = re.search(r"private func handlePhysicalDisconnect\(.*?\n    \}", model, flags=re.S)
if not physical:
    raise SystemExit("Could not inspect physical-disconnect handler")
body = physical.group(0)
if not body.index("transitionToDisconnected") < body.index("transfers.deviceDidDisconnect") < body.index("previousClient?.close"):
    raise SystemExit("Disconnect state/cancellation waits for the stale MTP session to close")
for marker in [
    "deviceAvailable = false",
    "token.request()",
    "TransferDisconnectPolicy.nextState",
    "finishWaiter",
    "guard !token.isRequested else { throw cancelledError() }",
]:
    if marker not in transfer:
        raise SystemExit(f"Transfer disconnect regression: missing {marker}")
disconnect_policy = read("Sources/MTPBridgeCore/TransferDisconnectPolicy.swift")
disconnect_tests = read("Tests/MTPBridgeCoreTests/TransferDisconnectPolicyTests.swift")
for marker in [
    "isEphemeral ? .failed : .queued",
    "testEveryNonterminalEphemeralJobFailsImmediately",
    "testPersistentNonterminalJobsReturnToQueue",
]:
    if marker not in disconnect_policy + disconnect_tests:
        raise SystemExit(f"Disconnect policy regression: missing {marker}")

# Preserve earlier animation, transfer-finalization, and compiler regressions.
for forbidden in ["symbolEffect", "contentTransition"]:
    if forbidden in connection:
        raise SystemExit(f"Connection animation regression returned: {forbidden}")
if "accessibilityReduceMotion" not in connection:
    raise SystemExit("Connection view no longer respects Reduce Motion")
if ".easeOut(duration: 0.20)" not in shelf:
    raise SystemExit("Transfer shelf no longer uses the short ease-out transition")
if ".spring(" in shelf:
    raise SystemExit("Transfer shelf returned to spring animation")
# 0.6.11 intentionally uses a trash icon only for the explicit, labeled
# "delete transfer job" action after a job is paused/terminal. The old
# regression we still forbid is an ambiguous per-row destructive-looking
# history control without explicit removal semantics.
if 'Image(systemName: "trash")' in shelf:
    for required in [
        'model.transfers.remove(jobID: job.id)',
        '.help("transfer.delete_job")',
    ]:
        if required not in shelf:
            raise SystemExit("Transfer trash icon lacks explicit delete-job semantics")
if re.search(r"(?m)^\s*fsync\s*\(", bridge):
    raise SystemExit("Download completion again performs a synchronous fsync")
for key in [
    "transfer.state.queued", "transfer.state.preparing", "transfer.state.running",
    "transfer.state.retrying", "transfer.state.completed", "transfer.state.failed",
    "transfer.state.cancelled", "transfer.phase.finalizing",
]:
    if key not in status or key not in status_tests:
        raise SystemExit(f"Transfer status regression: {key}")

# The Mac's selected SDK type-checks all AppKit/SwiftUI files before dependency
# compilation, preventing another long build followed by a trivial UI error.
for marker in [
    "-typecheck",
    '-sdk "${SDKROOT}"',
    '"${ROOT}"/Sources/MTPBridgeCore/*.swift',
    '"${ROOT}"/Sources/MTPBridgeApp/*.swift',
    "swift-preflight.sha256",
]:
    if marker not in preflight:
        raise SystemExit(f"Swift App preflight regression: missing {marker}")
preflight_call = '"${ROOT}/Scripts/preflight-swift-app.sh"'
prepare_call = '"${ROOT}/Scripts/prepare-local-dependencies.sh"'
build_call = '"${ROOT}/Scripts/build-local-app.sh"'
for marker in [preflight_call, prepare_call, build_call]:
    if marker not in installer:
        raise SystemExit(f"Double-click installer is missing {marker}")
if not installer.index(preflight_call) < installer.index(prepare_call) < installer.index(build_call):
    raise SystemExit("Installer does not preflight AppKit/SwiftUI before dependency compilation")
if preflight_call not in builder:
    raise SystemExit("Direct builder can bypass AppKit/SwiftUI preflight")
if "verify-ui-v040.sh" not in verify:
    raise SystemExit("Main verification does not run the stable 0.4.0 regression audit")

if "Android 傳輸 V2" not in config or "0.7.0" not in config:
    raise SystemExit("App name/version metadata mismatch")
if "dist/Android 傳輸 V2.app" not in installer:
    raise SystemExit("Double-click installer points to the wrong App bundle")
print("Android Transfer V2 stable 0.4.0 native-table/file-promise/disconnect baseline passed inside 0.7.0.")
PY
