#!/bin/bash
# Minimal project-local pkg-config compatibility shim.
# Used only when neither pkg-config nor pkgconf already exists on the Mac.
set -euo pipefail

PREFIX="${MTPBRIDGE_PKGCONFIG_PREFIX:-}"
PACKAGE_VERSION="${MTPBRIDGE_PKGCONFIG_VERSION:-1.0.30}"
if [[ -z "${PREFIX}" ]]; then
  echo "local-pkg-config: MTPBRIDGE_PKGCONFIG_PREFIX is required" >&2
  exit 2
fi

want_exists=0
want_cflags=0
want_cflags_i=0
want_libs=0
want_libs_l=0
want_libs_L=0
want_modversion=0
want_version=0
atleast_check=0
variable=""
package_text=""

for argument in "$@"; do
  case "${argument}" in
    --exists) want_exists=1 ;;
    --cflags) want_cflags=1 ;;
    --cflags-only-I) want_cflags_i=1 ;;
    --cflags-only-other) ;;
    --libs) want_libs=1 ;;
    --libs-only-l) want_libs_l=1 ;;
    --libs-only-L) want_libs_L=1 ;;
    --libs-only-other) ;;
    --modversion) want_modversion=1 ;;
    --version) want_version=1 ;;
    --atleast-pkgconfig-version|--atleast-pkgconfig-version=*) atleast_check=1 ;;
    --variable=*) variable="${argument#--variable=}" ;;
    --define-variable=*|--print-errors|--short-errors|--silence-errors|--static) ;;
    --*) ;;
    *) package_text="${package_text} ${argument}" ;;
  esac
done

if [[ "${atleast_check}" -eq 1 ]]; then
  exit 0
fi
if [[ "${want_version}" -eq 1 ]]; then
  printf '%s\n' '0.29.2-mtpbridge-local'
  exit 0
fi

case "${package_text}" in
  *libusb-1.0*) ;;
  *)
    echo "local-pkg-config: only libusb-1.0 is available in the isolated prefix" >&2
    exit 1
    ;;
esac

if [[ ! -f "${PREFIX}/include/libusb-1.0/libusb.h" || ! -d "${PREFIX}/lib" ]]; then
  echo "local-pkg-config: isolated libusb prefix is incomplete: ${PREFIX}" >&2
  exit 1
fi

if [[ "${want_exists}" -eq 1 ]]; then
  exit 0
fi
if [[ -n "${variable}" ]]; then
  case "${variable}" in
    prefix|exec_prefix) printf '%s\n' "${PREFIX}" ;;
    libdir) printf '%s\n' "${PREFIX}/lib" ;;
    includedir) printf '%s\n' "${PREFIX}/include" ;;
    pc_path) printf '%s\n' "${PREFIX}/lib/pkgconfig" ;;
    *) printf '\n' ;;
  esac
  exit 0
fi
if [[ "${want_modversion}" -eq 1 ]]; then
  printf '%s\n' "${PACKAGE_VERSION}"
  exit 0
fi

output=""
append_output() {
  if [[ -n "${output}" ]]; then
    output="${output} $1"
  else
    output="$1"
  fi
}

if [[ "${want_cflags}" -eq 1 || "${want_cflags_i}" -eq 1 ]]; then
  append_output "-I${PREFIX}/include/libusb-1.0"
fi
if [[ "${want_libs}" -eq 1 || "${want_libs_L}" -eq 1 ]]; then
  append_output "-L${PREFIX}/lib"
fi
if [[ "${want_libs}" -eq 1 || "${want_libs_l}" -eq 1 ]]; then
  append_output "-lusb-1.0"
fi
printf '%s\n' "${output}"
