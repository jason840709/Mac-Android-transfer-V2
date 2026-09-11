#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
python3 - "${ROOT}" <<'PY'
import plistlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
read = lambda relative: (root / relative).read_text(encoding="utf-8")
model = read("Sources/MTPBridgeApp/AppModel.swift")
browser = read("Sources/MTPBridgeApp/BrowserView.swift")
app = read("Sources/MTPBridgeApp/MTPBridgeApp.swift")
monitor = read("Sources/MTPBridgeApp/NavigationInputMonitor.swift")
history = read("Sources/MTPBridgeCore/BrowserNavigationHistory.swift")
mouse = read("Sources/MTPBridgeCore/AuxiliaryMouseNavigation.swift")
history_tests = read("Tests/MTPBridgeCoreTests/BrowserNavigationHistoryTests.swift")
mouse_tests = read("Tests/MTPBridgeCoreTests/AuxiliaryMouseNavigationTests.swift")

for marker in [
    "BrowserNavigationHistory()",
    "NavigationInputMonitor()",
    "navigationInputMonitor.start(",
    "func navigateBack() async",
    "func navigateForward() async",
    "canNavigateBack",
    "canNavigateForward",
]:
    if marker not in model:
        raise SystemExit(f"0.4.1 navigation regression: missing {marker}")

for marker in [
    ".otherMouseDown", ".otherMouseUp", ".swipe", ".keyDown",
    "event.specialKey == .prev", "event.specialKey == .next",
    'characters == "["', 'characters == "]"',
]:
    if marker not in monitor:
        raise SystemExit(f"0.4.1 input regression: missing {marker}")

for marker in ["case 3, 5, 7", "case 4, 6, 8"]:
    if marker not in mouse:
        raise SystemExit(f"0.4.1 Logitech mapping regression: missing {marker}")

for marker in [
    "testBackAndForwardFollowVisitedLocations",
    "testNewVisitAfterBackClearsForwardBranch",
]:
    if marker not in history_tests:
        raise SystemExit(f"0.4.1 history test regression: missing {marker}")
for marker in ["testStandardLogitechSideButtons", "testHorizontalSwipeMapping"]:
    if marker not in mouse_tests:
        raise SystemExit(f"0.4.1 mouse test regression: missing {marker}")

for marker in [
    'Label("browser.back", systemImage: "chevron.left")',
    'Label("browser.forward", systemImage: "chevron.right")',
    '.help("browser.back.help")',
    '.help("browser.forward.help")',
    '.help("browser.up.help")',
    '.help("browser.refresh.help")',
    '.help("browser.new_folder.help")',
    '.help("browser.upload.help")',
    '.help("browser.download.help")',
    '.help("browser.sort.help")',
    '.help("browser.rename.help")',
    '.help("browser.search.help")',
]:
    if marker not in browser:
        raise SystemExit(f"0.4.1 tooltip regression: missing {marker}")

for marker in [
    'CommandMenu("command.navigation")',
    '.keyboardShortcut("[", modifiers: [.command])',
    '.keyboardShortcut("]", modifiers: [.command])',
]:
    if marker not in app:
        raise SystemExit(f"0.4.1 menu navigation regression: missing {marker}")

for relative in ["Resources/en.lproj/Credits.rtf", "Resources/zh-Hant.lproj/Credits.rtf"]:
    path = root / relative
    if not path.is_file() or path.stat().st_size < 80:
        raise SystemExit(f"About credits are missing: {relative}")
with (root / "Config/Info.plist").open("rb") as handle:
    info = plistlib.load(handle)
if info.get("NSHumanReadableCopyright") != "Copyright © 2026 Jason Chen":
    raise SystemExit("About-panel copyright metadata mismatch")

print("Android Transfer V2 inherited 0.4.1 navigation, tooltip, and About regressions passed.")

PY
