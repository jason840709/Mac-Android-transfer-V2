#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP="${ROOT}/dist/Android 傳輸 V2.app"
EXPORT_DIR="${ROOT}/.build/release"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Release builds require macOS."
[[ "$(uname -m)" == "arm64" ]] || fail "Release builds must run on Apple Silicon."
for tool in security codesign ditto shasum; do
  command -v "${tool}" >/dev/null 2>&1 || fail "Required macOS tool is unavailable: ${tool}"
done

SIGNING_IDENTITY="${MTPBRIDGE_SIGNING_IDENTITY:-}"
if [[ -z "${SIGNING_IDENTITY}" ]]; then
  identity_line="$(security find-identity -v -p codesigning 2>/dev/null | \
    grep -E '"Developer ID Application:' | head -n 1 || true)"
  if [[ -n "${identity_line}" ]]; then
    SIGNING_IDENTITY="${identity_line#*\"}"
    SIGNING_IDENTITY="${SIGNING_IDENTITY%\"*}"
  fi
fi
[[ "${SIGNING_IDENTITY}" == Developer\ ID\ Application:* ]] || \
  fail "A Developer ID Application certificate is required. No certificate is installed or updated automatically."

"${ROOT}/Scripts/prepare-local-dependencies.sh"
MTPBRIDGE_SIGNING_IDENTITY="${SIGNING_IDENTITY}" \
MTPBRIDGE_REQUIRE_DEVELOPER_ID=1 \
MTPBRIDGE_SIGNING_TIMESTAMP=1 \
MTPBRIDGE_FORCE_REBUILD=1 \
MTPBRIDGE_REQUIRE_DEVICE_AGENT=1 \
  "${ROOT}/Scripts/build-local-app.sh"

"${ROOT}/Scripts/audit-release.sh" "${APP}"

rm -rf "${EXPORT_DIR}"
mkdir -p "${EXPORT_DIR}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist")"
ZIP="${EXPORT_DIR}/Android-Transfer-V2-${VERSION}-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "${APP}" "${ZIP}"
"${ROOT}/Scripts/audit-release.sh" "${APP}" > "${EXPORT_DIR}/Android-Transfer-V2-audit.txt"
(
  cd "${EXPORT_DIR}"
  shasum -a 256 "$(basename "${ZIP}")" > "$(basename "${ZIP}").sha256"
)

printf 'Created %s\n' "${ZIP}"
printf 'Audit: %s\n' "${EXPORT_DIR}/Android-Transfer-V2-audit.txt"
printf 'Checksum: %s\n' "${ZIP}.sha256"
