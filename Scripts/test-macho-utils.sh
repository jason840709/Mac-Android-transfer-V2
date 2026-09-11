#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=Scripts/macho-utils.sh
source "${ROOT}/Scripts/macho-utils.sh"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT INT TERM
FAKE_BIN="${TMP}/bin"
LOG="${TMP}/tool.log"
mkdir -p "${FAKE_BIN}"
: > "${LOG}"

cat > "${FAKE_BIN}/lipo" <<'TOOL'
#!/bin/bash
set -euo pipefail
log="${MTPBRIDGE_FAKE_LOG:?}"

mode_for() {
  sed -n 's/^ARCH_MODE=//p' "$1" | head -n 1
}

if [[ "${1:-}" == "-archs" ]]; then
  file="$2"
  mode="$(mode_for "${file}")"
  case "${mode}" in
    arm64) printf 'arm64\n' ;;
    verbose-arm64) printf 'Non-fat file: %s is architecture: arm64\n' "${file}" ;;
    archs-fail) exit 1 ;;
    universal) printf 'x86_64 arm64\n' ;;
    *) printf 'unknown architecture mode\n' >&2; exit 1 ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "-info" ]]; then
  file="$2"
  mode="$(mode_for "${file}")"
  case "${mode}" in
    arm64|verbose-arm64|archs-fail)
      printf 'Non-fat file: %s is architecture: arm64\n' "${file}"
      ;;
    universal)
      printf 'Architectures in the fat file: %s are: x86_64 arm64\n' "${file}"
      ;;
    *) exit 1 ;;
  esac
  exit 0
fi

input="$1"
shift
[[ "${1:-}" == "-thin" && "${2:-}" == "arm64" && "${3:-}" == "-output" && -n "${4:-}" ]] || {
  printf 'unexpected fake lipo invocation\n' >&2
  exit 1
}
output="$4"
{
  printf 'ARCH_MODE=arm64\n'
  tail -n +2 "${input}" || true
} > "${output}"
printf 'thin %s\n' "${input}" >> "${log}"
TOOL

cat > "${FAKE_BIN}/file" <<'TOOL'
#!/bin/bash
set -euo pipefail
library="${!#}"
mode="$(sed -n 's/^ARCH_MODE=//p' "${library}" | head -n 1)"
case "${mode}" in
  arm64|verbose-arm64|archs-fail) printf 'Mach-O 64-bit arm64 dynamically linked shared library\n' ;;
  universal) printf 'Mach-O universal binary with 2 architectures: [x86_64] [arm64]\n' ;;
  *) exit 1 ;;
esac
TOOL

cat > "${FAKE_BIN}/codesign" <<'TOOL'
#!/bin/bash
set -euo pipefail
log="${MTPBRIDGE_FAKE_LOG:?}"
case "${1:-}" in
  --remove-signature)
    library="$2"
    if [[ -f "${library}.signed" ]]; then
      rm -f "${library}.signed"
      : > "${library}.unsigned"
      printf 'remove-signature %s\n' "${library}" >> "${log}"
      exit 0
    fi
    printf '%s: code object is not signed at all\n' "${library}" >&2
    exit 1
    ;;
  -d)
    library="$2"
    [[ -f "${library}.signed" ]]
    ;;
  --force)
    library="${!#}"
    [[ -f "${library}.unsigned" ]] || {
      printf 'library was edited without first removing its signature\n' >&2
      exit 1
    }
    rm -f "${library}.unsigned"
    : > "${library}.signed"
    printf 'sign %s\n' "${library}" >> "${log}"
    ;;
  --verify)
    library="${!#}"
    [[ -f "${library}.signed" ]]
    printf 'verify %s\n' "${library}" >> "${log}"
    ;;
  *)
    printf 'unexpected fake codesign invocation\n' >&2
    exit 1
    ;;
esac
TOOL

cat > "${FAKE_BIN}/install_name_tool" <<'TOOL'
#!/bin/bash
set -euo pipefail
log="${MTPBRIDGE_FAKE_LOG:?}"
case "${1:-}" in
  -id)
    new_id="$2"
    library="$3"
    [[ -f "${library}.unsigned" ]] || {
      printf 'signature was not removed before -id\n' >&2
      exit 1
    }
    printf '%s\n' "${new_id}" > "${library}.id"
    printf 'id %s %s\n' "${library}" "${new_id}" >> "${log}"
    ;;
  -change)
    old_path="$2"
    new_path="$3"
    library="$4"
    [[ -f "${library}.unsigned" ]] || {
      printf 'signature was not removed before -change\n' >&2
      exit 1
    }
    awk -v old="${old_path}" -v new="${new_path}" '{ if ($0 == old) print new; else print }' \
      "${library}.deps" > "${library}.deps.new"
    mv -f "${library}.deps.new" "${library}.deps"
    printf 'change %s %s %s\n' "${library}" "${old_path}" "${new_path}" >> "${log}"
    ;;
  *)
    printf 'unexpected fake install_name_tool invocation\n' >&2
    exit 1
    ;;
esac
TOOL

cat > "${FAKE_BIN}/otool" <<'TOOL'
#!/bin/bash
set -euo pipefail
mode="$1"
library="$2"
case "${mode}" in
  -D)
    printf '%s:\n' "${library}"
    cat "${library}.id"
    ;;
  -L)
    printf '%s:\n' "${library}"
    printf '\t%s (compatibility version 1.0.0, current version 1.0.0)\n' "$(cat "${library}.id")"
    while IFS= read -r dependency; do
      [[ -n "${dependency}" ]] || continue
      printf '\t%s (compatibility version 1.0.0, current version 1.0.0)\n' "${dependency}"
    done < "${library}.deps"
    ;;
  *)
    printf 'unexpected fake otool invocation\n' >&2
    exit 1
    ;;
esac
TOOL

chmod 755 "${FAKE_BIN}/"*
export MTPBRIDGE_FAKE_LOG="${LOG}"
export MTPBRIDGE_LIPO="${FAKE_BIN}/lipo"
export MTPBRIDGE_FILE_TOOL="${FAKE_BIN}/file"
export MTPBRIDGE_CODESIGN="${FAKE_BIN}/codesign"
export MTPBRIDGE_INSTALL_NAME_TOOL="${FAKE_BIN}/install_name_tool"
export MTPBRIDGE_OTOOL="${FAKE_BIN}/otool"

make_arch_fixture() {
  local path="$1"
  local mode="$2"
  printf 'ARCH_MODE=%s\npayload\n' "${mode}" > "${path}"
}

# Regression for the 0.2.1 failure: the first line of `otool -L` is the
# inspected binary's display path, not a load command. A normal App under
# /Users must pass when all actual dependencies are relocatable.
USER_PATH_SAMPLE="${TMP}/otool-user-path.txt"
cat > "${USER_PATH_SAMPLE}" <<'OTOOL_USER_PATH'
otool: warning: synthetic diagnostic before the display header
/Users/example/Downloads/MTPBridge-0.2.1-source/MTPBridge/dist/.MTPBridge.app.staging/Contents/MacOS/MTPBridge:
	@rpath/libmtp.dylib (compatibility version 14.0.0, current version 14.0.0)
	@rpath/libusb-1.0.dylib (compatibility version 7.0.0, current version 7.0.0)
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1356.0.0)
	/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit (compatibility version 45.0.0, current version 2685.60.104)
OTOOL_USER_PATH
PARSED_USER_PATH="$(mtpbridge_macho_dependency_paths_from_otool_output < "${USER_PATH_SAMPLE}")"
cat > "${TMP}/otool-user-path.expected" <<'EXPECTED_DEPENDENCIES'
@rpath/libmtp.dylib
@rpath/libusb-1.0.dylib
/usr/lib/libSystem.B.dylib
/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit
EXPECTED_DEPENDENCIES
printf '%s\n' "${PARSED_USER_PATH}" > "${TMP}/otool-user-path.actual"
cmp -s "${TMP}/otool-user-path.expected" "${TMP}/otool-user-path.actual" \
  || fail "otool dependency parsing included the inspected /Users path or damaged dependency rows."
[[ -z "$(printf '%s\n' "${PARSED_USER_PATH}" | mtpbridge_nonportable_dependencies)" ]] \
  || fail "A portable App under /Users was falsely rejected as non-relocatable."

# The header must be ignored, but a genuine user-specific load command must
# still be rejected and reported exactly.
cat >> "${USER_PATH_SAMPLE}" <<'OTOOL_BAD_DEPENDENCY'
	/Users/example/build/libbad.dylib (compatibility version 1.0.0, current version 1.0.0)
OTOOL_BAD_DEPENDENCY
BAD_PARSED="$(mtpbridge_macho_dependency_paths_from_otool_output < "${USER_PATH_SAMPLE}")"
BAD_FOUND="$(printf '%s\n' "${BAD_PARSED}" | mtpbridge_nonportable_dependencies)"
[[ "${BAD_FOUND}" == '/Users/example/build/libbad.dylib' ]] \
  || fail "A genuine non-relocatable dependency was not detected precisely."

HOMEBREW_FOUND="$(printf '%s\n' '/opt/homebrew/opt/libexample/lib/libexample.dylib' | mtpbridge_nonportable_dependencies)"
[[ "${HOMEBREW_FOUND}" == '/opt/homebrew/opt/libexample/lib/libexample.dylib' ]] \
  || fail "A Homebrew load command was not rejected by the portable-dependency allowlist."

# Regression: verbose output for a thin arm64 file must not cause lipo -thin.
VERBOSE_FIXTURE="${TMP}/verbose-arm64.dylib"
make_arch_fixture "${VERBOSE_FIXTURE}" verbose-arm64
mtpbridge_thin_to_arm64 "${VERBOSE_FIXTURE}"
if grep -Fq "thin ${VERBOSE_FIXTURE}" "${LOG}"; then
  fail "A thin arm64 library was unnecessarily passed to lipo -thin."
fi

# Regression: if -archs is unavailable/noncanonical, -info/file probing still
# accepts a valid thin arm64 Mach-O without mutating it.
FALLBACK_FIXTURE="${TMP}/fallback-arm64.dylib"
make_arch_fixture "${FALLBACK_FIXTURE}" archs-fail
mtpbridge_thin_to_arm64 "${FALLBACK_FIXTURE}"
if grep -Fq "thin ${FALLBACK_FIXTURE}" "${LOG}"; then
  fail "The fallback architecture probe unnecessarily thinned an arm64 file."
fi

# Universal input should be reduced to one arm64 slice.
UNIVERSAL_FIXTURE="${TMP}/universal.dylib"
make_arch_fixture "${UNIVERSAL_FIXTURE}" universal
mtpbridge_thin_to_arm64 "${UNIVERSAL_FIXTURE}"
[[ "$(sed -n 's/^ARCH_MODE=//p' "${UNIVERSAL_FIXTURE}" | head -n 1)" == "arm64" ]] \
  || fail "Universal fixture was not converted to arm64."
grep -Fq "thin ${UNIVERSAL_FIXTURE}" "${LOG}" \
  || fail "Universal fixture did not invoke lipo -thin."

# Full normalization test. The fake install_name_tool deliberately refuses to
# edit a signed file, proving that signature removal happens before load-command
# changes and that both dylibs are re-signed afterwards.
STAGE="${TMP}/stage"
mkdir -p "${STAGE}"
USB="${STAGE}/libusb-1.0.dylib"
MTP="${STAGE}/libmtp.dylib"
make_arch_fixture "${USB}" verbose-arm64
make_arch_fixture "${MTP}" verbose-arm64
printf '/private/project/.local/prefix/lib/libusb-1.0.0.dylib\n' > "${USB}.id"
printf '/usr/lib/libobjc.A.dylib\n/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit\n' > "${USB}.deps"
printf '/private/project/.local/prefix/lib/libmtp.9.dylib\n' > "${MTP}.id"
printf '/usr/lib/libiconv.2.dylib\n/private/project/.local/prefix/lib/libusb-1.0.0.dylib\n/usr/lib/libSystem.B.dylib\n' > "${MTP}.deps"
: > "${USB}.signed"
: > "${MTP}.signed"

mtpbridge_normalize_libraries "${STAGE}"

[[ "$(cat "${USB}.id")" == '@rpath/libusb-1.0.dylib' ]] \
  || fail "libusb ID was not normalized."
[[ "$(cat "${MTP}.id")" == '@rpath/libmtp.dylib' ]] \
  || fail "libmtp ID was not normalized."
grep -Fxq '@rpath/libusb-1.0.dylib' "${MTP}.deps" \
  || fail "libmtp dependency was not rewritten to @rpath."
if grep -Fq '/private/project/.local/prefix' "${MTP}.deps"; then
  fail "A project-specific dependency path survived normalization."
fi
[[ -f "${USB}.signed" && -f "${MTP}.signed" ]] \
  || fail "Normalized dylibs were not re-signed."
[[ ! -e "${USB}.unsigned" && ! -e "${MTP}.unsigned" ]] \
  || fail "A normalized dylib was left in an unsigned editing state."

grep -Fq "remove-signature ${USB}" "${LOG}" || fail "libusb signature was not removed."
grep -Fq "remove-signature ${MTP}" "${LOG}" || fail "libmtp signature was not removed."
grep -Fq "sign ${USB}" "${LOG}" || fail "libusb was not re-signed."
grep -Fq "sign ${MTP}" "${LOG}" || fail "libmtp was not re-signed."


# Regression: otool -L prints the inspected file path as its first line. A local
# App normally lives under /Users, but that display header is not a dependency.
HEADER_DIR="${TMP}/Users/example/Downloads/MTPBridge/dist/MTPBridge.app/Contents/MacOS"
mkdir -p "${HEADER_DIR}"
HEADER_FIXTURE="${HEADER_DIR}/MTPBridge"
make_arch_fixture "${HEADER_FIXTURE}" arm64
printf '@rpath/libmtp.dylib\n' > "${HEADER_FIXTURE}.id"
printf '@rpath/libusb-1.0.dylib\n/usr/lib/libSystem.B.dylib\n/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit\n' \
  > "${HEADER_FIXTURE}.deps"
parsed_dependencies="$(mtpbridge_otool_dependencies "${HEADER_FIXTURE}")"
if grep -Fq "${HEADER_FIXTURE}:" <<<"${parsed_dependencies}"; then
  fail "The otool display header leaked into parsed dependency rows."
fi
if grep -Fq '/Users/' <<<"$(printf '%s\n' "${parsed_dependencies}" | mtpbridge_nonportable_dependencies)"; then
  fail "A /Users build path was reported even though it appeared only in the otool header."
fi
for expected_dependency in \
  '@rpath/libmtp.dylib' \
  '@rpath/libusb-1.0.dylib' \
  '/usr/lib/libSystem.B.dylib' \
  '/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit'
do
  grep -Fxq "${expected_dependency}" <<<"${parsed_dependencies}" \
    || fail "Parsed dependency list is missing: ${expected_dependency}"
done

portable_fixture="$(printf '%s\n' "${parsed_dependencies}" | mtpbridge_nonportable_dependencies)"
[[ -z "${portable_fixture}" ]] || fail "Portable dependency rows were rejected: ${portable_fixture}"
nonportable_fixture="$(printf '%s\n' '/Users/example/private/libbad.dylib' '/opt/homebrew/lib/libbad.dylib' | mtpbridge_nonportable_dependencies)"
grep -Fxq '/Users/example/private/libbad.dylib' <<<"${nonportable_fixture}" \
  || fail "The dependency allowlist did not reject a /Users path."
grep -Fxq '/opt/homebrew/lib/libbad.dylib' <<<"${nonportable_fixture}" \
  || fail "The dependency allowlist did not reject a Homebrew path."

printf 'Mach-O normalization regression tests passed.\n'
