#!/bin/bash
set -euo pipefail

SOURCE_DIR="${SRCROOT}/Vendor/lib"
DESTINATION_DIR="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"

for library in libmtp.dylib libusb-1.0.dylib; do
  if [[ ! -f "${SOURCE_DIR}/${library}" ]]; then
    echo "error: Missing Vendor/lib/${library}. Run ./Scripts/bootstrap-macos.sh first."
    exit 1
  fi
done

mkdir -p "${DESTINATION_DIR}"
for library in libmtp.dylib libusb-1.0.dylib; do
  ditto "${SOURCE_DIR}/${library}" "${DESTINATION_DIR}/${library}"
  chmod 755 "${DESTINATION_DIR}/${library}"
  if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" && "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]]; then
    sign_arguments=(
      --force
      --sign "${EXPANDED_CODE_SIGN_IDENTITY}"
      --options runtime
    )
    if [[ "${CONFIGURATION:-Debug}" == "Release" && "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]]; then
      sign_arguments+=(--timestamp)
    else
      sign_arguments+=(--timestamp=none)
    fi
    /usr/bin/codesign "${sign_arguments[@]}" "${DESTINATION_DIR}/${library}"
  fi
done
