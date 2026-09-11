#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FILES=(
  "${ROOT}/Tools/安裝並啟動 Android 傳輸 V2.command"
  "${ROOT}/Tools/移除本地安裝.command"
  "${ROOT}/Tools/診斷手機自動開啟.command"
  "${ROOT}/Tools/清理舊版本狀態.command"
)
while IFS= read -r script; do
  FILES+=("${script}")
done < <(find "${ROOT}/Scripts" -maxdepth 1 -type f -name '*.sh' | LC_ALL=C sort)

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

for file in "${FILES[@]}"; do
  [[ -f "${file}" ]] || fail "Missing installer file: ${file}"
  bash -n "${file}"
done

# Match executable command positions, not explanatory text inside here-docs.
FORBIDDEN='(^|[;&|])[[:space:]]*([^[:space:]]*/)?(brew[[:space:]]+(install|update|upgrade)|port[[:space:]]+(install|selfupdate|upgrade)|softwareupdate([[:space:]]|$)|xcode-select[[:space:]]+--install|sudo([[:space:]]|$)|(pip|pip3)[[:space:]]+install|gem[[:space:]]+install|npm[[:space:]].*-g|cargo[[:space:]]+install)'
if grep -EIn "${FORBIDDEN}" "${FILES[@]}"; then
  fail "Installer contains a forbidden global installation/update command."
fi

for command_file in \
  "${ROOT}/Tools/安裝並啟動 Android 傳輸 V2.command" \
  "${ROOT}/Tools/移除本地安裝.command" \
  "${ROOT}/Tools/診斷手機自動開啟.command" \
  "${ROOT}/Tools/清理舊版本狀態.command"
do
  [[ -x "${command_file}" ]] || fail "Double-click command is not executable: ${command_file}"
done

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT INT TERM
mkdir -p "${TMP}/include/libusb-1.0" "${TMP}/lib"
: > "${TMP}/include/libusb-1.0/libusb.h"
MTPBRIDGE_PKGCONFIG_PREFIX="${TMP}" "${ROOT}/Scripts/local-pkg-config.sh" --exists 'libusb-1.0 >= 1.0.0'
[[ "$(MTPBRIDGE_PKGCONFIG_PREFIX="${TMP}" "${ROOT}/Scripts/local-pkg-config.sh" --modversion libusb-1.0)" == "1.0.30" ]] \
  || fail "Local pkg-config shim returned the wrong version."
[[ "$(MTPBRIDGE_PKGCONFIG_PREFIX="${TMP}" MTPBRIDGE_PKGCONFIG_VERSION="1.0.24" \
  "${ROOT}/Scripts/local-pkg-config.sh" --modversion libusb-1.0)" == "1.0.24" ]] \
  || fail "Local pkg-config shim did not preserve a reused dependency version."
MTPBRIDGE_PKGCONFIG_PREFIX="${TMP}" "${ROOT}/Scripts/local-pkg-config.sh" --cflags --libs libusb-1.0 | grep -Fq "${TMP}" \
  || fail "Local pkg-config shim did not return the isolated prefix."

"${ROOT}/Scripts/prepare-local-dependencies.sh" --print-policy | grep -Fq 'Never runs brew install/update/upgrade'

command -v python3 >/dev/null 2>&1 || fail "python3 is required for the installer policy audit."
python3 - "${ROOT}" <<'PYVERIFY'
import hashlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
expected = {
    "libmtp-1.1.23.tar.gz": "74a2b6e8cb4a0304e95b995496ea3ac644c29371649b892b856e22f12a0bdeed",
    "libusb-1.0.30.tar.bz2": "fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf",
}
archive_dir = root / "Vendor/source-archives"
for name, digest in expected.items():
    path = archive_dir / name
    if not path.is_file():
        raise SystemExit(f"Missing bundled source archive: {path}")
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != digest:
        raise SystemExit(f"Bundled source archive checksum mismatch: {name}: {actual}")

prepare = (root / "Scripts/prepare-local-dependencies.sh").read_text(encoding="utf-8")
required_pins = [
    'LIBMTP_VERSION="1.1.23"',
    'LIBMTP_ARCHIVE="libmtp-${LIBMTP_VERSION}.tar.gz"',
    'LIBMTP_SHA256="74a2b6e8cb4a0304e95b995496ea3ac644c29371649b892b856e22f12a0bdeed"',
    'LIBUSB_VERSION="1.0.30"',
    'LIBUSB_ARCHIVE="libusb-${LIBUSB_VERSION}.tar.bz2"',
    'LIBUSB_SHA256="fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf"',
]
for pin in required_pins:
    if pin not in prepare:
        raise SystemExit(f"Dependency resolver is missing a bundled-source pin: {pin}")
if 'Vendor/source-archives' not in prepare and 'BUNDLED_ARCHIVES' not in prepare:
    raise SystemExit("Dependency resolver does not reference the bundled archive directory")

macho = (root / "Scripts/macho-utils.sh").read_text(encoding="utf-8")
if "-verify_arch" in macho or "-verify_arch" in prepare:
    raise SystemExit("The obsolete/incorrect lipo -verify_arch path returned to the installer")
for required in [
    '--remove-signature',
    '--force --sign - --timestamp=none',
    '@rpath/libusb-1.0.dylib',
    '@rpath/libmtp.dylib',
    'mtpbridge_macho_dependency_paths_from_otool_output',
    'mtpbridge_nonportable_dependencies',
]:
    if required not in macho:
        raise SystemExit(f"Mach-O normalizer is missing required behavior marker: {required}")

for audit_name in ["audit-local-app.sh", "audit-release.sh"]:
    audit = (root / "Scripts" / audit_name).read_text(encoding="utf-8")
    if "mtpbridge_otool_dependencies" not in audit:
        raise SystemExit(f"{audit_name} does not parse otool dependency rows through the shared helper")
    if 'dependencies="$(/usr/bin/otool -L' in audit:
        raise SystemExit(f"{audit_name} again audits the otool display header as a dependency")
    if "mtpbridge_nonportable_dependencies" not in audit:
        raise SystemExit(f"{audit_name} does not use the shared portable-dependency allowlist")
PYVERIFY
"${ROOT}/Scripts/test-macho-utils.sh"

printf 'Installer policy audit passed.\n'
