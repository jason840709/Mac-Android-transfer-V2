#!/usr/bin/env python3
from pathlib import Path
import sys

root = Path(sys.argv[1])
current = (root / "Sources/MTPBridgeApp/RemoteBrowserTable.swift").read_text(encoding="utf-8")
baseline = (root / "Tests/Compatibility/v062/RemoteBrowserTable.swift").read_text(encoding="utf-8")

def slice_between(text: str, start: str, end: str, label: str) -> str:
    try:
        i = text.index(start)
        j = text.index(end, i)
    except ValueError as exc:
        raise SystemExit(f"Could not isolate {label}: {exc}")
    return text[i:j]

contracts = [
    (
        "table drag source/drop methods",
        "        func tableView(\n            _ tableView: NSTableView,\n            pasteboardWriterForRow row: Int\n",
        "        func contextMenu(forRow row: Int) -> NSMenu? {\n",
    ),
    (
        "Finder file URL reader",
        "        private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {\n",
        "        private func nameCell(in tableView: NSTableView, object: MTPObject) -> NSTableCellView {\n",
    ),
    (
        "NSFilePromiseProvider delegate",
        "private final class RemoteFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {\n",
        "private extension NSUserInterfaceItemIdentifier {\n",
    ),
]

for label, start, end in contracts:
    cur = slice_between(current, start, end, label)
    base = slice_between(baseline, start, end, label)
    if cur != base:
        raise SystemExit(f"RemoteBrowserTable transfer regression: {label} changed from the 0.6.2 stable contract")

for marker in [
    'tableView.registerForDraggedTypes([.fileURL])',
    'tableView.setDraggingSourceOperationMask(.copy, forLocal: false)',
    'NSFilePromiseProvider(fileType: typeIdentifier, delegate: delegate)',
    'Task { @MainActor in',
    'try await fulfill(object, url, promisedName)',
]:
    if marker not in current:
        raise SystemExit(f"RemoteBrowserTable drag contract missing: {marker}")

print("RemoteBrowserTable Finder drag/file-promise contract matches 0.6.2 stable baseline.")
