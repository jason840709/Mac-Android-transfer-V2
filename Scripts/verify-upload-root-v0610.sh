#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BRIDGE="$ROOT/Sources/MTPBridgeCLib/mtp_bridge.c"
TEST="$ROOT/Tests/CBridgeTests/bridge_tests.c"
FAKE="$ROOT/Tests/CBridgeTests/fake_libmtp.c"

grep -Fq 'metadata->parent_id = parent_object_id == MTP_BRIDGE_ROOT_OBJECT_ID' "$BRIDGE" || {
  echo 'ERROR: upload root mapping is missing.' >&2; exit 1;
}
grep -Fq '? MTP_BRIDGE_ROOT_OBJECT_ID' "$BRIDGE" || {
  echo 'ERROR: Android upload root is not sent as the explicit MTP root sentinel.' >&2; exit 1;
}
python3 - "$BRIDGE" <<'PY2'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text(encoding="utf-8")
start = s.index("int32_t mtp_bridge_upload_file_atomic(")
body = s[start:]
if "? 0 : parent_object_id" in body:
    raise SystemExit("ERROR: upload path maps the Android root to handle 0; SendObjectInfo can reject it")
if "? MTP_BRIDGE_ROOT_OBJECT_ID" not in body:
    raise SystemExit("ERROR: upload path does not preserve the explicit MTP root sentinel")
PY2
grep -Fq 'fake_mtp_last_send_parent_id() == MTP_BRIDGE_ROOT_OBJECT_ID' "$TEST" || {
  echo 'ERROR: root upload parent regression test is missing.' >&2; exit 1;
}
grep -Fq 'g_last_send_parent_id = metadata->parent_id' "$FAKE" || {
  echo 'ERROR: fake libmtp does not capture the upload parent sent by the bridge.' >&2; exit 1;
}
printf 'Android Transfer V2 0.6.10 explicit MTP root upload-parent contract passed.\n'
