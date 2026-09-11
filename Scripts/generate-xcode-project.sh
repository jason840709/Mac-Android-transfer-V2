#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${ROOT}"

if ! command -v xcodegen >/dev/null 2>&1; then
  printf '%s\n' \
    'ERROR: xcodegen is not installed.' \
    'It is optional and is never installed or upgraded automatically.' \
    'The normal double-click installer does not need XcodeGen.' >&2
  exit 1
fi

printf 'Using existing XcodeGen without updating it: %s\n' "$(command -v xcodegen)"
xcodegen generate --spec project.yml
printf 'Generated: %s\n' "${ROOT}/MTPBridge.xcodeproj"
