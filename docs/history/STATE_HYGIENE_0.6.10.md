# Android 傳輸 V2 0.6.10 — State Hygiene and Root Upload Safety

0.6.10 advances the persistent transfer queue to schema version 3. Legacy unfinished uploads that do not carry a stable destination breadcrumb are never replayed with a captured MTP object handle. Paused jobs remain paused across relaunches instead of being silently requeued.

The installer/migration path backs up the existing transfer queue and Android Transfer V2 preferences before resetting incompatible active legacy jobs and removing only this app's obsolete auto-launch preference keys. It also attempts to stop obsolete Android Transfer V2 helper labels. Google Android File Transfer is not unregistered or deleted.

The upload bridge now preserves `MTP_BRIDGE_ROOT_OBJECT_ID` (`0xffffffff`) when sending a file to a storage root. Android's legacy SendObjectInfo path can reject parent handle `0` with PTP response `0x2009` (Invalid Object Handle), so root uploads must not translate the sentinel to zero.

Transfer controls also gain a real paused state. Pausing an ordinary persistent transfer exposes Resume, Terminate, and Delete Transfer actions. Terminate leaves a cancelled history row; Delete Transfer removes the transfer job/history entry. Finder file-promise exports remain ephemeral and are cancelled rather than paused so Finder is never left waiting on a suspended promise.
