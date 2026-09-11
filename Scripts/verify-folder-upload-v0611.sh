#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BRIDGE="$ROOT/Sources/MTPBridgeCLib/mtp_bridge.c"
TEST="$ROOT/Tests/CBridgeTests/bridge_tests.c"
FAKE="$ROOT/Tests/CBridgeTests/fake_libmtp.c"
FAKE_HEADER="$ROOT/Tests/CBridgeTests/fake_libmtp.h"
ARCHIVE="$ROOT/Vendor/source-archives/libmtp-1.1.23.tar.gz"

python3 - "$BRIDGE" "$TEST" "$FAKE" "$FAKE_HEADER" "$ARCHIVE" <<'PY'
from pathlib import Path
import sys, tarfile
bridge, test, fake, fake_header, archive = map(Path, sys.argv[1:])
source = bridge.read_text(encoding='utf-8')
start = source.index('int32_t mtp_bridge_create_folder(')
end = source.index('int32_t mtp_bridge_rename_object(', start)
body = source[start:end]
required = [
    'parent_object_id == MTP_BRIDGE_ROOT_OBJECT_ID',
    '? MTP_BRIDGE_ROOT_OBJECT_ID',
    'LIBMTP_Create_Folder(session->device, mutable_name, protocol_parent_id, storage_id)',
]
for marker in required:
    if marker not in body:
        raise SystemExit(f'ERROR: folder-upload root mapping missing: {marker}')
if '? 0 : parent_object_id' in body or 'MTP_BRIDGE_ROOT_OBJECT_ID ? 0' in body:
    raise SystemExit('ERROR: folder creation still converts the MTP root parent to handle 0')

test_text = test.read_text(encoding='utf-8')
for marker in [
    'test_folder_creation_preserves_root_parent',
    'fake_mtp_last_create_folder_parent_id() == MTP_BRIDGE_ROOT_OBJECT_ID',
    'fake_mtp_find_object(1, MTP_BRIDGE_ROOT_OBJECT_ID, "root-folder")',
]:
    if marker not in test_text:
        raise SystemExit(f'ERROR: folder-upload regression test missing: {marker}')

fake_text = fake.read_text(encoding='utf-8')
for marker in [
    'g_last_create_folder_parent_id = parent_id',
    'if (parent_id == 0)',
    'fake_mtp_last_create_folder_parent_id(void)',
]:
    if marker not in fake_text:
        raise SystemExit(f'ERROR: fake Android folder-parent behavior missing: {marker}')
if 'fake_mtp_last_create_folder_parent_id(void);' not in fake_header.read_text(encoding='utf-8'):
    raise SystemExit('ERROR: fake folder-parent observer declaration missing')

with tarfile.open(archive, 'r:gz') as tf:
    member = next((m for m in tf.getmembers() if m.name.endswith('/src/libmtp.c')), None)
    if member is None:
        raise SystemExit('ERROR: bundled libmtp source does not contain src/libmtp.c')
    text = tf.extractfile(member).read().decode('utf-8', errors='replace')
    function_start = text.index('uint32_t LIBMTP_Create_Folder(')
    doc_start = text.rfind('/**', 0, function_start)
    doc = text[doc_start:function_start]
    if 'or 0xFFFFFFFF to put it in the root directory' not in doc:
        raise SystemExit('ERROR: bundled libmtp root-folder API contract changed unexpectedly')

print('Android Transfer V2 0.6.11 root-folder MTP parent sentinel contract passed.')
PY
