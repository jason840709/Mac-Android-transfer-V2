#!/bin/bash
# Shared Mach-O helpers for project-local dependency staging.
# This file is sourced by prepare-local-dependencies.sh and its regression tests.

mtpbridge_macho_error() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

mtpbridge_macho_dependency_paths_from_otool_output() {
  # otool -L prints the inspected binary path as a header on line 1. That
  # header is not a dependency and may legitimately live below /Users while a
  # project-local App is being built. Only subsequent load-command lines are
  # dependency paths. Preserve spaces inside a path by trimming the version
  # annotation rather than taking awk's first whitespace-delimited field.
  LC_ALL=C awk '
    # Apple otool indents every dependency/load-command row. The display
    # header (and any diagnostic text) is not indented, so ignore it without
    # relying on the header always being physical line 1.
    /^[[:space:]]/ {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+\(compatibility version.*$/, "", line)
      if (length(line) > 0) {
        print line
      }
    }
  '
}

mtpbridge_macho_arch_tokens() {
  LC_ALL=C awk '
    {
      for (i = 1; i <= NF; i++) {
        token = $i
        sub(/^[^[:alnum:]_]+/, "", token)
        sub(/[^[:alnum:]_]+$/, "", token)
        if (token == "i386" || token == "x86_64" || token == "x86_64h" ||
            token == "armv6" || token == "armv7" || token == "armv7f" ||
            token == "armv7k" || token == "armv7s" || token == "arm64" ||
            token == "arm64e" || token == "arm64_32" || token == "ppc" ||
            token == "ppc64") {
          if (!seen[token]++) {
            print token
          }
        }
      }
    }
  '
}

mtpbridge_macho_architectures() {
  local library="$1"
  local lipo_tool="${MTPBRIDGE_LIPO:-lipo}"
  local file_tool="${MTPBRIDGE_FILE_TOOL:-file}"
  local output=""
  local architectures=""

  if output="$("${lipo_tool}" -archs "${library}" 2>&1)"; then
    architectures="$(printf '%s\n' "${output}" | mtpbridge_macho_arch_tokens)"
  fi

  # Some cctools/CLT combinations provide a verbose single-architecture result
  # only through -info, or emit noncanonical text from -archs. Parse both forms.
  if [[ -z "${architectures}" ]] && output="$("${lipo_tool}" -info "${library}" 2>&1)"; then
    architectures="$(printf '%s\n' "${output}" | mtpbridge_macho_arch_tokens)"
  fi

  # file(1) is a final read-only probe. It is never used to thin a binary; it
  # merely prevents a valid thin arm64 Mach-O from being rejected by a brittle
  # lipo output-format assumption.
  if [[ -z "${architectures}" ]]; then
    if [[ -x "${file_tool}" ]] || command -v "${file_tool}" >/dev/null 2>&1; then
      output="$("${file_tool}" -b "${library}" 2>&1 || true)"
      architectures="$(printf '%s\n' "${output}" | mtpbridge_macho_arch_tokens)"
    fi
  fi

  if [[ -z "${architectures}" ]]; then
    mtpbridge_macho_error "Could not determine Mach-O architectures for ${library}. lipo output: ${output:-<empty>}"
    return 1
  fi

  printf '%s\n' "${architectures}"
}

mtpbridge_thin_to_arm64() {
  local library="$1"
  local lipo_tool="${MTPBRIDGE_LIPO:-lipo}"
  local architectures=""
  local verified=""
  local architecture=""
  local count=0
  local has_arm64=0
  local temporary="${library}.arm64.$$"

  [[ -f "${library}" ]] || {
    mtpbridge_macho_error "Mach-O library does not exist: ${library}"
    return 1
  }

  architectures="$(mtpbridge_macho_architectures "${library}")" || return 1
  while IFS= read -r architecture; do
    [[ -n "${architecture}" ]] || continue
    count=$((count + 1))
    if [[ "${architecture}" == "arm64" ]]; then
      has_arm64=1
    fi
  done <<< "${architectures}"

  if [[ "${has_arm64}" -ne 1 ]]; then
    mtpbridge_macho_error "${library} does not contain the required arm64 slice (found: ${architectures//$'\n'/, })."
    return 1
  fi

  chmod u+w "${library}" || {
    mtpbridge_macho_error "Could not make the project-local copy writable: ${library}"
    return 1
  }

  # Do not invoke lipo -thin for an already-thin arm64 file. Besides being
  # unnecessary, several toolchain versions reject -thin on a non-fat input.
  if [[ "${count}" -gt 1 ]]; then
    rm -f "${temporary}"
    if ! "${lipo_tool}" "${library}" -thin arm64 -output "${temporary}"; then
      rm -f "${temporary}"
      mtpbridge_macho_error "lipo could not extract the arm64 slice from ${library}."
      return 1
    fi
    chmod u+w "${temporary}" || true
    mv -f "${temporary}" "${library}" || {
      rm -f "${temporary}"
      mtpbridge_macho_error "Could not replace ${library} with its arm64 slice."
      return 1
    }
  fi

  verified="$(mtpbridge_macho_architectures "${library}")" || return 1
  if [[ "${verified}" != "arm64" ]]; then
    mtpbridge_macho_error "Architecture normalization did not produce a thin arm64 library: ${library} (found: ${verified//$'\n'/, })."
    return 1
  fi
}

mtpbridge_codesign_remove_for_edit() {
  local library="$1"
  local codesign_tool="${MTPBRIDGE_CODESIGN:-/usr/bin/codesign}"
  local output=""

  # Modern Apple-Silicon linkers commonly emit a linker/ad-hoc signature even
  # for local dylibs. Remove it from the copied file before changing load
  # commands, then create a fresh ad-hoc signature after normalization.
  if output="$("${codesign_tool}" --remove-signature "${library}" 2>&1)"; then
    return 0
  fi

  # An unsigned object legitimately has nothing to remove. A still-detectable
  # signature means removal failed and editing it would leave an ambiguous file.
  if "${codesign_tool}" -d "${library}" >/dev/null 2>&1; then
    mtpbridge_macho_error "Could not remove the existing code signature from ${library}: ${output:-unknown codesign error}"
    return 1
  fi

  return 0
}

mtpbridge_install_name_edit() {
  local install_name_tool="${MTPBRIDGE_INSTALL_NAME_TOOL:-install_name_tool}"
  local output=""

  if ! output="$("${install_name_tool}" "$@" 2>&1)"; then
    mtpbridge_macho_error "install_name_tool failed for $*: ${output:-no diagnostic was produced}"
    return 1
  fi

  if [[ -n "${output}" ]]; then
    printf '%s\n' "${output}"
  fi
}

mtpbridge_otool_id() {
  local library="$1"
  local otool_tool="${MTPBRIDGE_OTOOL:-otool}"
  local output=""
  local identifier=""

  if ! output="$("${otool_tool}" -D "${library}" 2>&1)"; then
    mtpbridge_macho_error "otool could not read the dylib ID from ${library}: ${output:-no diagnostic was produced}"
    return 1
  fi
  identifier="$(printf '%s\n' "${output}" | awk 'NR > 1 && NF { print $1; exit }')"
  if [[ -z "${identifier}" ]]; then
    mtpbridge_macho_error "No LC_ID_DYLIB value was found in ${library}."
    return 1
  fi
  printf '%s\n' "${identifier}"
}

mtpbridge_otool_dependencies() {
  local library="$1"
  local otool_tool="${MTPBRIDGE_OTOOL:-otool}"
  local output=""

  if ! output="$("${otool_tool}" -L "${library}" 2>&1)"; then
    mtpbridge_macho_error "otool could not read dependencies from ${library}: ${output:-no diagnostic was produced}"
    return 1
  fi
  printf '%s\n' "${output}" | mtpbridge_macho_dependency_paths_from_otool_output
}

mtpbridge_dependency_is_portable() {
  local dependency="$1"

  # Final App binaries may load embedded libraries through dyld-relative paths
  # and Apple-provided libraries/frameworks through their canonical roots.
  # Any other absolute path would bind the App to the build machine.
  case "${dependency}" in
    @rpath/*|@loader_path/*|@executable_path/*|/usr/lib/*|/System/Library/*|/Library/Apple/System/Library/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

mtpbridge_nonportable_dependencies() {
  local dependency=""

  while IFS= read -r dependency; do
    [[ -n "${dependency}" ]] || continue
    if ! mtpbridge_dependency_is_portable "${dependency}"; then
      printf '%s\n' "${dependency}"
    fi
  done
  return 0
}

mtpbridge_codesign_adhoc() {
  local library="$1"
  local codesign_tool="${MTPBRIDGE_CODESIGN:-/usr/bin/codesign}"
  local output=""

  if ! output="$("${codesign_tool}" --force --sign - --timestamp=none "${library}" 2>&1)"; then
    mtpbridge_macho_error "Could not create a fresh ad-hoc signature for ${library}: ${output:-no diagnostic was produced}"
    return 1
  fi
  if ! output="$("${codesign_tool}" --verify --strict "${library}" 2>&1)"; then
    mtpbridge_macho_error "The normalized dylib failed code-signature verification: ${library}: ${output:-no diagnostic was produced}"
    return 1
  fi
}

mtpbridge_normalize_libusb_library() {
  local usb="$1"
  local usb_target='@rpath/libusb-1.0.dylib'
  local current_id=""

  [[ -f "${usb}" ]] || {
    mtpbridge_macho_error "Missing staged libusb: ${usb}"
    return 1
  }

  mtpbridge_thin_to_arm64 "${usb}" || return 1
  mtpbridge_codesign_remove_for_edit "${usb}" || return 1

  current_id="$(mtpbridge_otool_id "${usb}")" || return 1
  if [[ "${current_id}" != "${usb_target}" ]]; then
    mtpbridge_install_name_edit -id "${usb_target}" "${usb}" || return 1
  fi

  mtpbridge_codesign_adhoc "${usb}" || return 1
  current_id="$(mtpbridge_otool_id "${usb}")" || return 1
  [[ "${current_id}" == "${usb_target}" ]] || {
    mtpbridge_macho_error "Unexpected normalized libusb ID: ${current_id}"
    return 1
  }
}

mtpbridge_normalize_libraries() {
  local directory="$1"
  local usb="${directory}/libusb-1.0.dylib"
  local mtp="${directory}/libmtp.dylib"
  local usb_target='@rpath/libusb-1.0.dylib'
  local mtp_target='@rpath/libmtp.dylib'
  local current_id=""
  local dependencies=""
  local dependency=""
  local found_libusb=0
  local found_portable_libusb=0

  [[ -f "${mtp}" ]] || {
    mtpbridge_macho_error "Missing staged libmtp: ${mtp}"
    return 1
  }

  mtpbridge_normalize_libusb_library "${usb}" || return 1
  mtpbridge_thin_to_arm64 "${mtp}" || return 1
  mtpbridge_codesign_remove_for_edit "${mtp}" || return 1

  current_id="$(mtpbridge_otool_id "${mtp}")" || return 1
  if [[ "${current_id}" != "${mtp_target}" ]]; then
    mtpbridge_install_name_edit -id "${mtp_target}" "${mtp}" || return 1
  fi

  dependencies="$(mtpbridge_otool_dependencies "${mtp}")" || return 1
  while IFS= read -r dependency; do
    [[ -n "${dependency}" ]] || continue
    case "${dependency}" in
      *libusb-1.0*.dylib)
        found_libusb=1
        if [[ "${dependency}" != "${usb_target}" ]]; then
          mtpbridge_install_name_edit -change "${dependency}" "${usb_target}" "${mtp}" || return 1
        fi
        ;;
    esac
  done <<< "${dependencies}"

  if [[ "${found_libusb}" -ne 1 ]]; then
    mtpbridge_macho_error "libmtp does not declare a dynamic libusb dependency: ${mtp}"
    return 1
  fi

  mtpbridge_codesign_adhoc "${mtp}" || return 1

  current_id="$(mtpbridge_otool_id "${mtp}")" || return 1
  [[ "${current_id}" == "${mtp_target}" ]] || {
    mtpbridge_macho_error "Unexpected normalized libmtp ID: ${current_id}"
    return 1
  }

  dependencies="$(mtpbridge_otool_dependencies "${mtp}")" || return 1
  while IFS= read -r dependency; do
    [[ -n "${dependency}" ]] || continue
    case "${dependency}" in
      "${usb_target}") found_portable_libusb=1 ;;
      *libusb-1.0*.dylib)
        mtpbridge_macho_error "libmtp still references a nonportable libusb path: ${dependency}"
        return 1
        ;;
    esac
  done <<< "${dependencies}"

  if [[ "${found_portable_libusb}" -ne 1 ]]; then
    mtpbridge_macho_error "libmtp did not retain the expected ${usb_target} dependency after normalization."
    return 1
  fi
}

