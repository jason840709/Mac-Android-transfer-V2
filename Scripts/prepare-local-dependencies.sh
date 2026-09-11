#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=Scripts/macho-utils.sh
source "${ROOT}/Scripts/macho-utils.sh"
LOCAL_ROOT="${ROOT}/.local"
DOWNLOADS="${LOCAL_ROOT}/downloads"
SOURCES="${LOCAL_ROOT}/sources"
PREFIX="${LOCAL_ROOT}/prefix-arm64"
STATE="${LOCAL_ROOT}/state"
VENDOR_ROOT="${ROOT}/Vendor"
VENDOR_INCLUDE="${VENDOR_ROOT}/include"
VENDOR_LIB="${VENDOR_ROOT}/lib"
BUNDLED_ARCHIVES="${VENDOR_ROOT}/source-archives"
PROVENANCE="${VENDOR_ROOT}/DEPENDENCY_PROVENANCE.txt"
DEPLOYMENT_TARGET="14.0"

LIBUSB_VERSION="1.0.30"
LIBUSB_ARCHIVE="libusb-${LIBUSB_VERSION}.tar.bz2"
LIBUSB_URL="https://github.com/libusb/libusb/releases/download/v${LIBUSB_VERSION}/${LIBUSB_ARCHIVE}"
LIBUSB_SHA256="fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf"

LIBMTP_VERSION="1.1.23"
LIBMTP_ARCHIVE="libmtp-${LIBMTP_VERSION}.tar.gz"
LIBMTP_URL="https://github.com/libmtp/libmtp/releases/download/v${LIBMTP_VERSION}/${LIBMTP_ARCHIVE}"
LIBMTP_SHA256="74a2b6e8cb4a0304e95b995496ea3ac644c29371649b892b856e22f12a0bdeed"

FORCE_LOCAL=0
RESET_VENDOR=0
PRINT_POLICY=0

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*"
}

usage() {
  cat <<'USAGE'
Usage: ./Scripts/prepare-local-dependencies.sh [options]

Options:
  --force-local    Ignore compatible system libmtp/libusb and build isolated copies.
  --reset-vendor   Recreate generated Vendor headers and dylibs.
  --print-policy   Print the no-global-install policy and exit.
  --help           Show this help.
USAGE
}

print_policy() {
  cat <<'POLICY'
MTPBridge dependency policy
- Never runs brew install/update/upgrade, softwareupdate, sudo, pip, gem, npm -g, or cargo install.
- Never writes to /Applications, /usr/local, /opt/homebrew, /opt/local, /Library, or another project.
- Uses an existing pkg-config/pkgconf exactly as installed; it is never upgraded.
- Reuses existing compatible arm64 libmtp/libusb without modifying their original files.
- If no compatible arm64 libraries exist, builds isolated copies under this project only.
- Fixed fallback source archives are bundled and SHA-256 verified; a project-local download is used only if a bundled archive was removed.
- Generated data is limited to .local/, Vendor/include, Vendor/lib, and dist/.
POLICY
}

for argument in "$@"; do
  case "${argument}" in
    --force-local) FORCE_LOCAL=1 ;;
    --reset-vendor) RESET_VENDOR=1 ;;
    --print-policy) PRINT_POLICY=1 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown option: ${argument}" ;;
  esac
done

if [[ "${PRINT_POLICY}" -eq 1 ]]; then
  print_policy
  exit 0
fi

[[ "$(uname -s)" == "Darwin" ]] || fail "This dependency builder must run on macOS."
[[ "$(uname -m)" == "arm64" ]] || fail "This build is Apple-Silicon-only. Please run it on an M-series Mac."
[[ "$(/usr/bin/id -u)" -ne 0 ]] || fail "Do not run this installer as root or through sudo. It is intentionally user-local."

if command -v sw_vers >/dev/null 2>&1; then
  MACOS_VERSION="$(sw_vers -productVersion)"
  MACOS_MAJOR="${MACOS_VERSION%%.*}"
  case "${MACOS_MAJOR}" in
    ''|*[!0-9]*) fail "Could not read the macOS version: ${MACOS_VERSION}" ;;
  esac
  [[ "${MACOS_MAJOR}" -ge 14 ]] || fail "Android 傳輸 V2 requires macOS 14 or newer; found ${MACOS_VERSION}."
fi

for tool in xcrun curl make tar shasum awk sed grep cp mv rm mkdir chmod find date file codesign ln patch; do
  command -v "${tool}" >/dev/null 2>&1 || fail "Required system/developer tool is unavailable: ${tool}"
done
if ! xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
  fail "Apple Command Line Tools or Xcode are not configured. This script will not install, switch, or update them automatically."
fi

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --sdk macosx --find clang)"
INSTALL_NAME_TOOL="$(xcrun --find install_name_tool)"
OTOOL="$(xcrun --find otool)"
LIPO="$(xcrun --find lipo)"
FILE_TOOL="$(command -v file)"
CODESIGN="$(command -v codesign)"

mkdir -p "${DOWNLOADS}" "${SOURCES}" "${PREFIX}" "${STATE}" \
  "${VENDOR_INCLUDE}" "${VENDOR_LIB}" "${VENDOR_ROOT}/licenses"

safe_remove_tree() {
  local target="$1"
  case "${target}" in
    "${LOCAL_ROOT}"/*) rm -rf "${target}" ;;
    *) fail "Safety check refused to remove path outside .local: ${target}" ;;
  esac
}

find_first_file() {
  local candidate
  for candidate in "$@"; do
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

find_dylib_in_dir() {
  local directory="$1"
  local stem="$2"
  local candidate
  for candidate in "${directory}/${stem}.dylib" "${directory}/${stem}.0.dylib" "${directory}/${stem}."*.dylib; do
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

thin_to_arm64() {
  MTPBRIDGE_LIPO="${LIPO}" \
  MTPBRIDGE_FILE_TOOL="${FILE_TOOL}" \
    mtpbridge_thin_to_arm64 "$1"
}

is_thin_arm64() {
  local architectures
  architectures="$(
    MTPBRIDGE_LIPO="${LIPO}" \
    MTPBRIDGE_FILE_TOOL="${FILE_TOOL}" \
      mtpbridge_macho_architectures "$1"
  )" || return 1
  [[ "${architectures}" == "arm64" ]]
}

normalize_libusb() {
  MTPBRIDGE_LIPO="${LIPO}" \
  MTPBRIDGE_FILE_TOOL="${FILE_TOOL}" \
  MTPBRIDGE_CODESIGN="${CODESIGN}" \
  MTPBRIDGE_INSTALL_NAME_TOOL="${INSTALL_NAME_TOOL}" \
  MTPBRIDGE_OTOOL="${OTOOL}" \
    mtpbridge_normalize_libusb_library "$1"
}

normalize_libraries() {
  MTPBRIDGE_LIPO="${LIPO}" \
  MTPBRIDGE_FILE_TOOL="${FILE_TOOL}" \
  MTPBRIDGE_CODESIGN="${CODESIGN}" \
  MTPBRIDGE_INSTALL_NAME_TOOL="${INSTALL_NAME_TOOL}" \
  MTPBRIDGE_OTOOL="${OTOOL}" \
    mtpbridge_normalize_libraries "$1"
}

has_only_portable_dependencies() {
  local library="$1"
  local dependency
  while IFS= read -r dependency; do
    [[ -n "${dependency}" ]] || continue
    if ! mtpbridge_dependency_is_portable "${dependency}"; then
      printf '  incompatible external dependency: %s\n' "${dependency}" >&2
      return 1
    fi
  done < <(MTPBRIDGE_OTOOL="${OTOOL}" mtpbridge_otool_dependencies "${library}")
  return 0
}

bridge_compile_and_link() {
  local stage="$1"
  local main_source="${STATE}/dependency-link-main.c"
  local output="${STATE}/dependency-link-test"
  cat > "${main_source}" <<'MAIN'
int main(void) { return 0; }
MAIN
  "${CC}" -std=c11 -Wall -Wextra -Werror -arch arm64 \
    -mmacosx-version-min="${DEPLOYMENT_TARGET}" -isysroot "${SDKROOT}" \
    -I"${ROOT}/Sources/MTPBridgeCLib/include" -I"${stage}/include" \
    "${ROOT}/Sources/MTPBridgeCLib/mtp_bridge.c" "${main_source}" \
    -L"${stage}/lib" -lmtp -lusb-1.0 \
    -Xlinker -rpath -Xlinker "${stage}/lib" \
    -o "${output}" >/dev/null 2>&1
  rm -f "${main_source}" "${output}"
}

vendor_is_valid() {
  [[ -f "${VENDOR_INCLUDE}/libmtp.h" ]] || return 1
  [[ -f "${VENDOR_INCLUDE}/libusb.h" ]] || return 1
  [[ -f "${VENDOR_LIB}/libmtp.dylib" ]] || return 1
  [[ -f "${VENDOR_LIB}/libusb-1.0.dylib" ]] || return 1
  is_thin_arm64 "${VENDOR_LIB}/libmtp.dylib" >/dev/null 2>&1 || return 1
  is_thin_arm64 "${VENDOR_LIB}/libusb-1.0.dylib" >/dev/null 2>&1 || return 1
  "${CODESIGN}" --verify --strict "${VENDOR_LIB}/libmtp.dylib" >/dev/null 2>&1 || return 1
  "${CODESIGN}" --verify --strict "${VENDOR_LIB}/libusb-1.0.dylib" >/dev/null 2>&1 || return 1
  has_only_portable_dependencies "${VENDOR_LIB}/libmtp.dylib" || return 1
  has_only_portable_dependencies "${VENDOR_LIB}/libusb-1.0.dylib" || return 1
  "${OTOOL}" -L "${VENDOR_LIB}/libmtp.dylib" | grep -Fq '@rpath/libusb-1.0.dylib' || return 1
  bridge_compile_and_link "${VENDOR_ROOT}" || return 1
  return 0
}

replace_vendor_from_stage() {
  local stage="$1"
  [[ -f "${stage}/include/libmtp.h" ]] || return 1
  [[ -f "${stage}/include/libusb.h" ]] || return 1
  [[ -f "${stage}/lib/libmtp.dylib" ]] || return 1
  [[ -f "${stage}/lib/libusb-1.0.dylib" ]] || return 1

  rm -f "${VENDOR_INCLUDE}/libmtp.h" "${VENDOR_INCLUDE}/libusb.h"
  rm -f "${VENDOR_LIB}/libmtp.dylib" "${VENDOR_LIB}/libusb-1.0.dylib"
  cp -f "${stage}/include/libmtp.h" "${VENDOR_INCLUDE}/libmtp.h"
  cp -f "${stage}/include/libusb.h" "${VENDOR_INCLUDE}/libusb.h"
  cp -f "${stage}/lib/libmtp.dylib" "${VENDOR_LIB}/libmtp.dylib"
  cp -f "${stage}/lib/libusb-1.0.dylib" "${VENDOR_LIB}/libusb-1.0.dylib"
  chmod 644 "${VENDOR_INCLUDE}/libmtp.h" "${VENDOR_INCLUDE}/libusb.h"
  chmod 755 "${VENDOR_LIB}/libmtp.dylib" "${VENDOR_LIB}/libusb-1.0.dylib"
}

write_provenance() {
  local mode="$1"
  local mtp_version="$2"
  local usb_version="$3"
  local detail="$4"
  cat > "${PROVENANCE}" <<REPORT
MTPBridge dependency provenance
Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Mode: ${mode}
libmtp: ${mtp_version}
libusb: ${usb_version}
Detail: ${detail}
Architecture: arm64
Deployment target: macOS ${DEPLOYMENT_TARGET}
Policy: no system package was installed, upgraded, removed, or modified.
REPORT
}

if [[ "${RESET_VENDOR}" -eq 1 ]]; then
  rm -f "${VENDOR_INCLUDE}/libmtp.h" "${VENDOR_INCLUDE}/libusb.h"
  rm -f "${VENDOR_LIB}/libmtp.dylib" "${VENDOR_LIB}/libusb-1.0.dylib"
  rm -f "${PROVENANCE}"
fi

if [[ "${FORCE_LOCAL}" -eq 0 ]] && vendor_is_valid; then
  note "相依性已就緒；沿用專案內現有的 arm64 staging，不重複安裝。"
  exit 0
fi

SYSTEM_PKG_TOOL=""
if command -v pkg-config >/dev/null 2>&1; then
  SYSTEM_PKG_TOOL="$(command -v pkg-config)"
elif command -v pkgconf >/dev/null 2>&1; then
  SYSTEM_PKG_TOOL="$(command -v pkgconf)"
fi

stage_system_candidate() {
  local mtp_header="$1"
  local usb_header="$2"
  local mtp_dylib="$3"
  local usb_dylib="$4"
  local mtp_version="$5"
  local usb_version="$6"
  local detail="$7"
  local stage="${LOCAL_ROOT}/stage-system"

  [[ -f "${mtp_header}" && -f "${usb_header}" && -f "${mtp_dylib}" && -f "${usb_dylib}" ]] || return 1
  safe_remove_tree "${stage}"
  mkdir -p "${stage}/include" "${stage}/lib"
  cp -L "${mtp_header}" "${stage}/include/libmtp.h"
  cp -L "${usb_header}" "${stage}/include/libusb.h"
  cp -L "${mtp_dylib}" "${stage}/lib/libmtp.dylib"
  cp -L "${usb_dylib}" "${stage}/lib/libusb-1.0.dylib"

  if ! normalize_libraries "${stage}/lib"; then
    note "偵測到既有函式庫，但不是可用的 arm64 內容；保留原版本不動。"
    safe_remove_tree "${stage}"
    return 1
  fi
  if ! has_only_portable_dependencies "${stage}/lib/libmtp.dylib" || \
     ! has_only_portable_dependencies "${stage}/lib/libusb-1.0.dylib"; then
    note "既有 libmtp/libusb 含其他非系統動態相依性；為避免把外部環境帶進 App，改用專案內隔離版本。"
    safe_remove_tree "${stage}"
    return 1
  fi
  if ! bridge_compile_and_link "${stage}"; then
    note "偵測到既有 libmtp/libusb，但其 API 或二進位不相容；保留原版本不動，改用專案內隔離版本。"
    safe_remove_tree "${stage}"
    return 1
  fi

  replace_vendor_from_stage "${stage}" || return 1
  write_provenance "compatible-system-copy" "${mtp_version}" "${usb_version}" "${detail}; originals were read-only and untouched"
  safe_remove_tree "${stage}"
  vendor_is_valid || return 1
  note "已沿用系統中相容的 libmtp/libusb；只複製必要 arm64 內容到專案，沒有更新系統套件。"
  return 0
}

try_pkg_config_candidate() {
  [[ -n "${SYSTEM_PKG_TOOL}" ]] || return 1
  "${SYSTEM_PKG_TOOL}" --exists libmtp libusb-1.0 >/dev/null 2>&1 || return 1

  local mtp_inc usb_inc mtp_libdir usb_libdir
  local mtp_header usb_header mtp_dylib usb_dylib mtp_version usb_version
  mtp_inc="$("${SYSTEM_PKG_TOOL}" --variable=includedir libmtp 2>/dev/null || true)"
  usb_inc="$("${SYSTEM_PKG_TOOL}" --variable=includedir libusb-1.0 2>/dev/null || true)"
  mtp_libdir="$("${SYSTEM_PKG_TOOL}" --variable=libdir libmtp 2>/dev/null || true)"
  usb_libdir="$("${SYSTEM_PKG_TOOL}" --variable=libdir libusb-1.0 2>/dev/null || true)"

  mtp_header="$(find_first_file "${mtp_inc}/libmtp.h" "${mtp_inc}/libmtp/libmtp.h" || true)"
  usb_header="$(find_first_file "${usb_inc}/libusb.h" "${usb_inc}/libusb-1.0/libusb.h" || true)"
  mtp_dylib="$(find_dylib_in_dir "${mtp_libdir}" 'libmtp' || true)"
  usb_dylib="$(find_dylib_in_dir "${usb_libdir}" 'libusb-1.0' || true)"
  mtp_version="$("${SYSTEM_PKG_TOOL}" --modversion libmtp 2>/dev/null || printf 'unknown')"
  usb_version="$("${SYSTEM_PKG_TOOL}" --modversion libusb-1.0 2>/dev/null || printf 'unknown')"

  stage_system_candidate "${mtp_header}" "${usb_header}" "${mtp_dylib}" "${usb_dylib}" \
    "${mtp_version}" "${usb_version}" "discovered through ${SYSTEM_PKG_TOOL}"
}

try_prefix_candidate() {
  local prefix="$1"
  local mtp_header usb_header mtp_dylib usb_dylib
  [[ -d "${prefix}" ]] || return 1
  mtp_header="$(find_first_file "${prefix}/include/libmtp.h" "${prefix}/include/libmtp/libmtp.h" || true)"
  usb_header="$(find_first_file "${prefix}/include/libusb-1.0/libusb.h" "${prefix}/include/libusb.h" || true)"
  mtp_dylib="$(find_dylib_in_dir "${prefix}/lib" 'libmtp' || true)"
  usb_dylib="$(find_dylib_in_dir "${prefix}/lib" 'libusb-1.0' || true)"
  stage_system_candidate "${mtp_header}" "${usb_header}" "${mtp_dylib}" "${usb_dylib}" \
    "detected-compatible" "detected-compatible" "discovered under ${prefix}"
}

REUSE_SYSTEM_LIBUSB=0
SYSTEM_LIBUSB_STAGE=""
SYSTEM_LIBUSB_VERSION=""
SYSTEM_LIBUSB_DETAIL=""

stage_libusb_candidate() {
  local usb_header="$1"
  local usb_dylib="$2"
  local usb_version="$3"
  local detail="$4"
  local stage="${LOCAL_ROOT}/stage-system-libusb"
  local test_source="${STATE}/libusb-link-main.c"
  local test_output="${STATE}/libusb-link-test"

  [[ -f "${usb_header}" && -f "${usb_dylib}" ]] || return 1
  safe_remove_tree "${stage}"
  mkdir -p "${stage}/include/libusb-1.0" "${stage}/lib"
  cp -L "${usb_header}" "${stage}/include/libusb-1.0/libusb.h"
  cp -L "${usb_dylib}" "${stage}/lib/libusb-1.0.dylib"

  if ! normalize_libusb "${stage}/lib/libusb-1.0.dylib"; then
    safe_remove_tree "${stage}"
    return 1
  fi
  if ! has_only_portable_dependencies "${stage}/lib/libusb-1.0.dylib"; then
    safe_remove_tree "${stage}"
    return 1
  fi

  cat > "${test_source}" <<'LIBUSB_TEST'
#include <libusb.h>
int main(void) {
  libusb_context *context = 0;
  return libusb_init(&context);
}
LIBUSB_TEST
  if ! "${CC}" -std=c11 -Wall -Wextra -Werror -arch arm64 \
      -mmacosx-version-min="${DEPLOYMENT_TARGET}" -isysroot "${SDKROOT}" \
      -I"${stage}/include/libusb-1.0" "${test_source}" \
      -L"${stage}/lib" -lusb-1.0 \
      -Xlinker -rpath -Xlinker "${stage}/lib" \
      -o "${test_output}" >/dev/null 2>&1; then
    rm -f "${test_source}" "${test_output}"
    safe_remove_tree "${stage}"
    return 1
  fi
  rm -f "${test_source}" "${test_output}"

  REUSE_SYSTEM_LIBUSB=1
  SYSTEM_LIBUSB_STAGE="${stage}"
  SYSTEM_LIBUSB_VERSION="${usb_version}"
  SYSTEM_LIBUSB_DETAIL="${detail}"
  return 0
}

try_pkg_config_libusb_candidate() {
  [[ -n "${SYSTEM_PKG_TOOL}" ]] || return 1
  "${SYSTEM_PKG_TOOL}" --exists libusb-1.0 >/dev/null 2>&1 || return 1
  local usb_inc usb_libdir usb_header usb_dylib usb_version
  usb_inc="$("${SYSTEM_PKG_TOOL}" --variable=includedir libusb-1.0 2>/dev/null || true)"
  usb_libdir="$("${SYSTEM_PKG_TOOL}" --variable=libdir libusb-1.0 2>/dev/null || true)"
  usb_header="$(find_first_file "${usb_inc}/libusb.h" "${usb_inc}/libusb-1.0/libusb.h" || true)"
  usb_dylib="$(find_dylib_in_dir "${usb_libdir}" 'libusb-1.0' || true)"
  usb_version="$("${SYSTEM_PKG_TOOL}" --modversion libusb-1.0 2>/dev/null || printf 'detected-compatible')"
  stage_libusb_candidate "${usb_header}" "${usb_dylib}" "${usb_version}" \
    "reused through ${SYSTEM_PKG_TOOL}; original remained untouched"
}

try_prefix_libusb_candidate() {
  local prefix="$1"
  local usb_header usb_dylib
  [[ -d "${prefix}" ]] || return 1
  usb_header="$(find_first_file "${prefix}/include/libusb-1.0/libusb.h" "${prefix}/include/libusb.h" || true)"
  usb_dylib="$(find_dylib_in_dir "${prefix}/lib" 'libusb-1.0' || true)"
  stage_libusb_candidate "${usb_header}" "${usb_dylib}" "detected-compatible" \
    "reused from ${prefix}; original remained untouched"
}

if [[ "${FORCE_LOCAL}" -eq 0 ]]; then
  if try_pkg_config_candidate; then
    exit 0
  fi

  PREFIX_LIST="${MTPBRIDGE_SYSTEM_PREFIXES:-/opt/homebrew:/usr/local:/opt/local}"
  old_ifs="${IFS}"
  IFS=':'
  for candidate_prefix in ${PREFIX_LIST}; do
    [[ -n "${candidate_prefix}" ]] || continue
    if try_prefix_candidate "${candidate_prefix}"; then
      IFS="${old_ifs}"
      exit 0
    fi
  done
  IFS="${old_ifs}"

  # A compatible libusb is still reused even when libmtp is missing or too old.
  if try_pkg_config_libusb_candidate; then
    note "已找到可單獨沿用的既有 libusb；只會在專案內建立缺少的 libmtp。"
  else
    old_ifs="${IFS}"
    IFS=':'
    for candidate_prefix in ${PREFIX_LIST}; do
      [[ -n "${candidate_prefix}" ]] || continue
      if try_prefix_libusb_candidate "${candidate_prefix}"; then
        note "已找到可單獨沿用的既有 libusb；只會在專案內建立缺少的 libmtp。"
        break
      fi
    done
    IFS="${old_ifs}"
  fi
fi

fetch_and_verify() {
  local url="$1"
  local destination="$2"
  local expected="$3"
  local name
  local bundled
  local actual
  name="$(basename "${destination}")"
  bundled="${BUNDLED_ARCHIVES}/${name}"

  # A moved or partially deleted project can leave a dangling cache symlink.
  [[ -L "${destination}" && ! -f "${destination}" ]] && rm -f "${destination}"

  if [[ ! -f "${destination}" ]]; then
    if [[ -f "${bundled}" ]]; then
      actual="$(shasum -a 256 "${bundled}" | awk '{print $1}')"
      if [[ "${actual}" != "${expected}" ]]; then
        fail "Bundled source archive failed checksum validation: ${name}. Please download a fresh Android 傳輸 V2 package."
      fi
      note "使用套件內附的 ${name}；不需要重新下載。"
      rm -f "${destination}"
      # destination is .local/downloads/<name>; this relative link remains valid
      # if the whole MTPBridge folder is moved to another location.
      ln -s "../../Vendor/source-archives/${name}" "${destination}"
    else
      note "下載 ${name}（只存於 .local/downloads）…"
      rm -f "${destination}.partial"
      curl --disable --fail --location --retry 4 --retry-delay 2 --connect-timeout 20 \
        --output "${destination}.partial" "${url}"
      mv -f "${destination}.partial" "${destination}"
    fi
  fi

  actual="$(shasum -a 256 "${destination}" | awk '{print $1}')"
  if [[ "${actual}" != "${expected}" ]]; then
    rm -f "${destination}"
    fail "Checksum mismatch for ${name}. The invalid project-local cache entry was removed."
  fi
}

if [[ "${REUSE_SYSTEM_LIBUSB}" -eq 0 ]]; then
  fetch_and_verify "${LIBUSB_URL}" "${DOWNLOADS}/${LIBUSB_ARCHIVE}" "${LIBUSB_SHA256}"
fi
fetch_and_verify "${LIBMTP_URL}" "${DOWNLOADS}/${LIBMTP_ARCHIVE}" "${LIBMTP_SHA256}"

safe_remove_tree "${SOURCES}/libusb-${LIBUSB_VERSION}"
safe_remove_tree "${SOURCES}/libmtp-${LIBMTP_VERSION}"
safe_remove_tree "${PREFIX}"
mkdir -p "${SOURCES}" "${PREFIX}"

if [[ "${REUSE_SYSTEM_LIBUSB}" -eq 0 ]]; then
  tar -xjf "${DOWNLOADS}/${LIBUSB_ARCHIVE}" -C "${SOURCES}"
fi
tar -xzf "${DOWNLOADS}/${LIBMTP_ARCHIVE}" -C "${SOURCES}"

# macOS safety patch: libmtp upstream retries PTP open-session I/O failures by
# resetting the physical USB device. When two MTP applications race for the
# phone, that reset can tear down Android's freshly selected File Transfer
# gadget mode. Our app arbitrates ownership and retries instead, so the local
# fallback build must never issue that reset.
PATCH_FILE="${ROOT}/Vendor/Patches/libmtp-1.1.23-macos-no-usb-reset.patch"
[[ -f "${PATCH_FILE}" ]] || fail "Required libmtp macOS safety patch is missing."
(
  cd "${SOURCES}/libmtp-${LIBMTP_VERSION}"
  patch -p1 < "${PATCH_FILE}" >/dev/null
) || fail "Could not apply the libmtp macOS no-reset safety patch."

CPU_COUNT="$(sysctl -n hw.logicalcpu 2>/dev/null || printf '4')"
case "${CPU_COUNT}" in ''|*[!0-9]*) CPU_COUNT=4 ;; esac
COMMON_CFLAGS="-arch arm64 -mmacosx-version-min=${DEPLOYMENT_TARGET} -isysroot ${SDKROOT} -O2"
COMMON_LDFLAGS="-arch arm64 -mmacosx-version-min=${DEPLOYMENT_TARGET} -isysroot ${SDKROOT}"
USB_EFFECTIVE_VERSION="${LIBUSB_VERSION}"

if [[ "${REUSE_SYSTEM_LIBUSB}" -eq 1 ]]; then
  mkdir -p "${PREFIX}/include/libusb-1.0" "${PREFIX}/lib/pkgconfig"
  cp "${SYSTEM_LIBUSB_STAGE}/include/libusb-1.0/libusb.h" "${PREFIX}/include/libusb-1.0/libusb.h"
  cp "${SYSTEM_LIBUSB_STAGE}/lib/libusb-1.0.dylib" "${PREFIX}/lib/libusb-1.0.dylib"
  USB_EFFECTIVE_VERSION="${SYSTEM_LIBUSB_VERSION}"
  USB_PC_VERSION="${USB_EFFECTIVE_VERSION}"
  case "${USB_PC_VERSION}" in
    [0-9]*.[0-9]*) ;;
    *) USB_PC_VERSION="1.0.0" ;;
  esac
  cat > "${PREFIX}/lib/pkgconfig/libusb-1.0.pc" <<PCFILE
prefix=${PREFIX}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libusb-1.0
Description: Reused compatible libusb staged by MTPBridge
Version: ${USB_PC_VERSION}
Libs: -L\${libdir} -lusb-1.0
Cflags: -I\${includedir}/libusb-1.0
PCFILE
  note "沿用既有 libusb ${USB_EFFECTIVE_VERSION} 的專案內複本；原安裝未變更。"
else
  USB_PC_VERSION="${LIBUSB_VERSION}"
  note "系統沒有可直接沿用的相容 libusb；正在專案內編譯 libusb ${LIBUSB_VERSION}…"
  (
    cd "${SOURCES}/libusb-${LIBUSB_VERSION}"
    env \
      CONFIG_SITE=/dev/null \
      CPATH= C_INCLUDE_PATH= CPLUS_INCLUDE_PATH= LIBRARY_PATH= DYLD_LIBRARY_PATH= \
      MACOSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
      CC="${CC}" CFLAGS="${COMMON_CFLAGS}" LDFLAGS="${COMMON_LDFLAGS}" \
      ./configure \
        --prefix="${PREFIX}" \
        --disable-static \
        --enable-shared \
        --disable-dependency-tracking
    env MAKEFLAGS= CPATH= C_INCLUDE_PATH= CPLUS_INCLUDE_PATH= LIBRARY_PATH= DYLD_LIBRARY_PATH= \
      make -j"${CPU_COUNT}"
    env MAKEFLAGS= DESTDIR= CPATH= C_INCLUDE_PATH= CPLUS_INCLUDE_PATH= LIBRARY_PATH= DYLD_LIBRARY_PATH= \
      make install
  )
fi

PKG_TOOL_NAME=""
PKG_TOOL_PATH="${PATH}"
if [[ -n "${SYSTEM_PKG_TOOL}" ]] && \
   env PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig" PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig" \
       "${SYSTEM_PKG_TOOL}" --exists libusb-1.0 >/dev/null 2>&1; then
  PKG_TOOL_NAME="$(basename "${SYSTEM_PKG_TOOL}")"
  PKG_TOOL_PATH="$(dirname "${SYSTEM_PKG_TOOL}"):${PATH}"
else
  PKG_TOOL_NAME="local-pkg-config.sh"
  PKG_TOOL_PATH="${ROOT}/Scripts:${PATH}"
fi

note "正在專案內編譯 libmtp ${LIBMTP_VERSION}…"
(
  cd "${SOURCES}/libmtp-${LIBMTP_VERSION}"
  env \
    PATH="${PKG_TOOL_PATH}" \
    CONFIG_SITE=/dev/null \
    CPATH= C_INCLUDE_PATH= CPLUS_INCLUDE_PATH= LIBRARY_PATH= DYLD_LIBRARY_PATH= \
    MACOSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
    CC="${CC}" \
    CFLAGS="${COMMON_CFLAGS}" \
    CPPFLAGS="-I${PREFIX}/include/libusb-1.0" \
    LDFLAGS="${COMMON_LDFLAGS} -L${PREFIX}/lib" \
    PKG_CONFIG="${PKG_TOOL_NAME}" \
    PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig" \
    PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR= \
    MTPBRIDGE_PKGCONFIG_PREFIX="${PREFIX}" \
    MTPBRIDGE_PKGCONFIG_VERSION="${USB_PC_VERSION}" \
    ./configure \
      --prefix="${PREFIX}" \
      --with-udev="${PREFIX}/lib/udev" \
      --disable-static \
      --enable-shared \
      --disable-mtpz \
      --disable-doxygen \
      --disable-nls \
      --disable-silent-rules
  env MAKEFLAGS= CPATH= C_INCLUDE_PATH= CPLUS_INCLUDE_PATH= LIBRARY_PATH= DYLD_LIBRARY_PATH= \
    make -j"${CPU_COUNT}"
  env MAKEFLAGS= DESTDIR= CPATH= C_INCLUDE_PATH= CPLUS_INCLUDE_PATH= LIBRARY_PATH= DYLD_LIBRARY_PATH= \
    make install
)

# Preserve exact upstream license files when the corresponding source archive was used.
if [[ "${REUSE_SYSTEM_LIBUSB}" -eq 0 ]]; then
  cp "${SOURCES}/libusb-${LIBUSB_VERSION}/COPYING" "${VENDOR_ROOT}/licenses/libusb-LGPL-2.1.txt"
fi
cp "${SOURCES}/libmtp-${LIBMTP_VERSION}/COPYING" "${VENDOR_ROOT}/licenses/libmtp-LGPL-2.1.txt"
chmod 644 "${VENDOR_ROOT}/licenses/"*.txt

STAGE="${LOCAL_ROOT}/stage-local"
safe_remove_tree "${STAGE}"
mkdir -p "${STAGE}/include" "${STAGE}/lib"
LIBUSB_DYLIB="$(find_dylib_in_dir "${PREFIX}/lib" 'libusb-1.0' || true)"
LIBMTP_DYLIB="$(find_dylib_in_dir "${PREFIX}/lib" 'libmtp' || true)"
[[ -f "${PREFIX}/include/libmtp.h" ]] || fail "Local libmtp header was not installed."
[[ -f "${PREFIX}/include/libusb-1.0/libusb.h" ]] || fail "Local libusb header was not installed."
[[ -f "${LIBUSB_DYLIB}" && -f "${LIBMTP_DYLIB}" ]] || fail "Local dependency dylibs were not found."
cp "${PREFIX}/include/libmtp.h" "${STAGE}/include/libmtp.h"
cp "${PREFIX}/include/libusb-1.0/libusb.h" "${STAGE}/include/libusb.h"
cp -L "${LIBMTP_DYLIB}" "${STAGE}/lib/libmtp.dylib"
cp -L "${LIBUSB_DYLIB}" "${STAGE}/lib/libusb-1.0.dylib"
normalize_libraries "${STAGE}/lib" || fail "Could not normalize local arm64 dylibs."
has_only_portable_dependencies "${STAGE}/lib/libmtp.dylib" || fail "Local libmtp has a non-portable dependency."
has_only_portable_dependencies "${STAGE}/lib/libusb-1.0.dylib" || fail "Local libusb has a non-portable dependency."
bridge_compile_and_link "${STAGE}" || fail "The locally built dependencies failed the bridge link test."
replace_vendor_from_stage "${STAGE}"
if [[ "${REUSE_SYSTEM_LIBUSB}" -eq 1 ]]; then
  write_provenance \
    "project-local-libmtp-with-compatible-system-libusb" \
    "${LIBMTP_VERSION}" \
    "${USB_EFFECTIVE_VERSION}" \
    "libmtp was built inside ${LOCAL_ROOT} with macOS USB-reset safety patch; libusb ${SYSTEM_LIBUSB_DETAIL}"
else
  write_provenance \
    "project-local-build" \
    "${LIBMTP_VERSION}" \
    "${LIBUSB_VERSION}" \
    "both dependencies were downloaded and built inside ${LOCAL_ROOT}; libmtp macOS USB-reset safety patch applied"
fi
vendor_is_valid || fail "The staged local dependencies failed validation."

safe_remove_tree "${STAGE}"
if [[ -n "${SYSTEM_LIBUSB_STAGE}" && -d "${SYSTEM_LIBUSB_STAGE}" ]]; then
  safe_remove_tree "${SYSTEM_LIBUSB_STAGE}"
fi
if [[ "${MTPBRIDGE_KEEP_BUILD_CACHE:-0}" != "1" ]]; then
  safe_remove_tree "${SOURCES}"
  safe_remove_tree "${PREFIX}"
  mkdir -p "${SOURCES}" "${PREFIX}"
  note "已刪除解壓來源與編譯中間檔，只保留小型下載快取及 App 必要內容。"
fi

note "本地相依性準備完成；沒有安裝、升級或修改任何系統套件。"
