#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
python3 - "${ROOT}" <<'PY'
import colorsys
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
read = lambda p: (root / p).read_text(encoding='utf-8')
palette = read('Sources/MTPBridgeApp/AppPalette.swift')
typography = read('Sources/MTPBridgeApp/InterfaceTypography.swift')
root_view = read('Sources/MTPBridgeApp/RootView.swift')
commands = read('Sources/MTPBridgeApp/MTPBridgeApp.swift')
sidebar = read('Sources/MTPBridgeApp/SidebarView.swift')
browser = read('Sources/MTPBridgeApp/BrowserView.swift')
table = read('Sources/MTPBridgeApp/RemoteBrowserTable.swift')
shelf = read('Sources/MTPBridgeApp/TransferShelfView.swift')
connection = read('Sources/MTPBridgeApp/ConnectionView.swift')
settings = read('Sources/MTPBridgeApp/DeviceInsertionSettingsView.swift')
en = read('Resources/en.lproj/Localizable.strings')
zh = read('Resources/zh-Hant.lproj/Localizable.strings')
style = read('docs/development/UI_STYLE_GUIDE_0.6.3.md')

# General palette must match 0.6.2 muted-ui-r1 exactly.
for marker in [
    'dark: 0x94A0C8',
    'dark: 0xC09B70', 'dark: 0xA18CB8', 'dark: 0xB98D99',
    'dark: 0x79A7AD', 'dark: 0xC7817D', 'dark: 0xA99480',
    'dark: 0x8799BC', 'dark: 0x8BA98D',
    'static let upload = Color(nsColor: documentNSColor)',
    'static let download = Color(nsColor: applicationNSColor)',
    'static let success = Color(nsColor: applicationNSColor)',
    'dark: 0xBA956A',
    'static let failure = Color(nsColor: pdfNSColor)',
    'static let capability = Color(nsColor: audioNSColor)',
]:
    if marker not in palette:
        raise SystemExit(f'0.6.3 r2 0.6.2-palette restoration regression: missing {marker}')

# The only requested chromatic delta is the storage usage fill.
for marker in [
    'light: 0x9485B6', 'dark: 0xB8A9D8',
    'static let storageTrack = Color.secondary.opacity(0.20)',
]:
    if marker not in palette:
        raise SystemExit(f'0.6.3 r2 storage-violet regression: missing {marker}')

# Prevent the broad 0.6.3 r1 lightening pass from returning.
for forbidden in [
    'dark: 0xB4C0E4', 'dark: 0xC5CDEA', 'dark: 0xAEBBDD',
    'dark: 0xA8C5AC', 'dark: 0x9FC5CA', 'dark: 0xD1AE82',
    'dark: 0xD19A96',
]:
    if forbidden in palette:
        raise SystemExit(f'0.6.3 r2 broad-palette lightening returned: {forbidden}')

# Sanity-check the special storage fill: muted violet, but visibly lighter than
# the restored 0.6.2 accent on a very dark sidebar.
def rgb(hex_value):
    return tuple(int(hex_value[i:i+2], 16) / 255 for i in (0, 2, 4))
r, g, b = rgb('B8A9D8')
h, l, sat = colorsys.rgb_to_hls(r, g, b)
if not (0.69 <= h <= 0.76):
    raise SystemExit(f'0.6.3 r2 storage fill is no longer violet: hue={h:.3f}')
if l < 0.72:
    raise SystemExit(f'0.6.3 r2 storage fill is too dark: lightness={l:.3f}')
if sat > 0.42:
    raise SystemExit(f'0.6.3 r2 storage fill is too saturated: saturation={sat:.3f}')

for marker in [
    'enum InterfaceTextSize', 'case small', 'case medium', 'case large',
    'case .small: 13.0', 'case .medium: 14.5', 'case .large: 16.0',
    'tablePointSize', 'tableHeaderPointSize', 'tableRowHeight',
    'storageBarHeight', 'transferBarHeight', 'sidebarWidths',
    'AndroidTransferV2.InterfaceTextSize',
    'defaultValue: InterfaceTextSize = .medium',
    '?? .medium',
]:
    if marker not in typography:
        raise SystemExit(f'0.6.3 typography regression: missing {marker}')

for marker in [
    '@AppStorage(InterfaceTextSize.defaultsKey)',
    'InterfaceTextSize.medium.rawValue',
    '.environment(\\.interfaceTextSize, textSize)',
    'textSize.sidebarWidths',
]:
    if marker not in root_view:
        raise SystemExit(f'0.6.3 root typography wiring missing: {marker}')

# This CommandGroup placement appends to the standard macOS View/顯示方式 menu.
for marker in [
    'CommandGroup(after: .sidebar)', 'Picker("view.text_size"',
    'InterfaceTextSize.allCases', 'InterfaceTextSize.medium.rawValue',
]:
    if marker not in commands:
        raise SystemExit(f'0.6.3 View-menu text-size control missing: {marker}')

for key in [
    'view.text_size', 'view.text_size.small', 'view.text_size.medium',
    'view.text_size.large', 'sidebar.storage_usage',
]:
    if f'"{key}"' not in en or f'"{key}"' not in zh:
        raise SystemExit(f'0.6.3 localization missing: {key}')

for marker in [
    '@Environment(\\.interfaceTextSize)', 'interfaceTextSize.secondaryPointSize',
    'StorageUsageBar(value: storage.usedFraction)', 'AppPalette.storageTrack',
    'AppPalette.storage', 'interfaceTextSize.storageBarHeight',
]:
    if marker not in sidebar:
        raise SystemExit(f'0.6.3 sidebar readability missing: {marker}')
if 'ProgressView(value: storage.usedFraction)' in sidebar:
    raise SystemExit('0.6.3 storage usage reverted to the thin mini ProgressView')

for marker in ['textSize: interfaceTextSize']:
    if marker not in browser:
        raise SystemExit(f'0.6.3 browser typography bridge missing: {marker}')

for marker in [
    'var textSize: InterfaceTextSize', 'textSize.tableRowHeight',
    'textSize.tableHeaderPointSize', 'parent.textSize.tablePointSize',
    'applyTypography(to: tableView)',
]:
    if marker not in table:
        raise SystemExit(f'0.6.3 native table typography missing: {marker}')

for marker in [
    '@Environment(\\.interfaceTextSize)',
    'interfaceTextSize.transferBarHeight',
    'interfaceTextSize.secondaryPointSize',
]:
    if marker not in shelf:
        raise SystemExit(f'0.6.3 transfer typography missing: {marker}')

for marker in ['@Environment(\\.interfaceTextSize)', 'interfaceTextSize.bodyPointSize']:
    if marker not in connection:
        raise SystemExit(f'0.6.3 connection typography missing: {marker}')

for marker in ['@AppStorage(InterfaceTextSize.defaultsKey)', 'InterfaceTextSize.medium.rawValue']:
    if marker not in settings:
        raise SystemExit(f'0.6.3 settings typography missing: {marker}')

for source_name, text in [('shelf', shelf), ('connection', connection)]:
    for forbidden in ['.systemBlue', '.systemGreen', '.systemRed', '.systemOrange']:
        if forbidden in text:
            raise SystemExit(f'0.6.3 high-saturation system color returned in {source_name}: {forbidden}')

for marker in ['0.6.2', '小 / 中 / 大', 'Finder', '#94A0C8', '#B8A9D8', '低飽和', '進度條']:
    if marker not in style:
        raise SystemExit(f'0.6.3 style guide incomplete: missing {marker}')

print('Android Transfer V2 0.6.3 r2 restored 0.6.2 palette + light-violet storage bar + text-size contract passed.')
PY
