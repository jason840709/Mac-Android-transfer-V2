#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MODEL="$ROOT/Sources/MTPBridgeCore/MTPModels.swift"
RESOLVER="$ROOT/Sources/MTPBridgeCore/RemoteFolderPathResolver.swift"
APP="$ROOT/Sources/MTPBridgeApp/AppModel.swift"
COORD="$ROOT/Sources/MTPBridgeApp/TransferCoordinator.swift"
for marker in 'public var parentPath: [String]?' 'parentPath: [String]? = nil'; do grep -Fq "$marker" "$MODEL" || { echo "ERROR: missing remote destination path marker: $marker" >&2; exit 1; }; done
for marker in 'resolveParentID(' 'resolveBreadcrumbs(' 'FilenamePolicy.collisionKey'; do grep -Fq "$marker" "$RESOLVER" || { echo "ERROR: missing path resolver marker: $marker" >&2; exit 1; }; done
grep -Fq 'parentPath: breadcrumbs.map(\.name)' "$APP" || { echo 'ERROR: uploads do not persist the current folder breadcrumb path.' >&2; exit 1; }
grep -Fq 'RemoteFolderPathResolver.resolveBreadcrumbs' "$APP" || { echo 'ERROR: reconnect does not rebind breadcrumb handles.' >&2; exit 1; }
grep -Fq 'RemoteFolderPathResolver.resolveParentID' "$COORD" || { echo 'ERROR: upload execution does not re-resolve the destination handle.' >&2; exit 1; }
grep -Fq 'error.upload_destination_changed' "$COORD" || { echo 'ERROR: missing destination-changed failure path.' >&2; exit 1; }
# Regression: never seed the upload root directly from the stale captured handle when a path is present.
if grep -Fq '[]: destination.parentObjectID' "$COORD"; then echo 'ERROR: stale captured parent handle is still used directly by upload.' >&2; exit 1; fi
printf 'Android Transfer V2 0.6.8 upload parent-handle rebinding contract passed.\n'
