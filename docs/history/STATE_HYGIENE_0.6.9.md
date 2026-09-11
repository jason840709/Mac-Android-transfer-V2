# Android 傳輸 V2 0.6.9 — Persistent State Hygiene

This release fixes cross-version state contamination discovered by the read-only state audit.

## Queue migration

Older releases stored `transfers.json` as an unversioned array and automatically re-queued every nonterminal job at launch. Upload destinations persisted MTP object handles that are only meaningful to the USB/MTP session that created them.

0.6.9 introduces queue schema version 2. The installer backs up an unversioned queue and preserves terminal history, but active legacy jobs are not replayed. The app also refuses to resume any persisted upload that lacks a destination breadcrumb (`parentPath`). New jobs keep the breadcrumb and resolve a fresh parent handle before every upload attempt.

Backups are written under `.local/state-backups/` by the installer and under the sandbox `Application Support/MTPBridge/StateBackups/` by the in-app migration.

## Device-agent registration migration

Several experimental helper designs used the same main bundle identity across releases. ServiceManagement can therefore keep an older hidden helper registered after a newer source tree is launched.

0.6.9 records the build that registered the current `DeviceInsertionAgent`, compares a running helper's bundle URL/build with the helper embedded in the current main app, and unregisters stale ServiceManagement state before registering the current helper.

The installer also stops only retired Android Transfer V2 helper labels before launching the new app. It does not stop or unregister Google's Android File Transfer Agent.

## Manual repair command

`清理舊版本狀態.command` is backup-first. It clears Android Transfer V2's transfer queue and stops only Android Transfer V2 helper processes/launchd labels. It does not delete phone files, Homebrew packages, or Google Android File Transfer.
