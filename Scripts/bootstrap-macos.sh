#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
exec "${ROOT}/Scripts/prepare-local-dependencies.sh" "$@"
