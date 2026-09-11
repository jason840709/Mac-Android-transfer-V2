# Android File Transfer MTP ownership audit

This note records static binary evidence from the legacy Android File Transfer application used during compatibility analysis. The inspected bundle contained compiled binaries rather than source code.

## Background Agent

Bundle ID: `com.google.android.mtpagent`. `LSBackgroundOnly = 1`.

Observed calls/symbol references include:

- `IOServiceAddMatchingNotification`
- `IOServiceAddInterestNotification`
- `LIBMTP_Init`
- `LIBMTP_Detect_Raw_Devices`
- `launchApplication:`

The Agent disassembly does **not** contain a call to `LIBMTP_Open_Raw_Device_Uncached` or another `LIBMTP_Open*` entry point.

## Visible viewer

Bundle ID: `com.google.android.mtpviewer`.

Observed calls include:

- `LIBMTP_Detect_Raw_Devices`
- `LIBMTP_Open_Raw_Device_Uncached`
- `LIBMTP_Get_Storage`
- `LIBMTP_Get_Files_And_Folders`
- `LIBMTP_Get_File_To_File`
- `LIBMTP_Release_Device`

## Product implication

The old Agent is an insertion observer / launcher. The visible viewer is the process that opens and owns the persistent MTP session. Android Transfer V2 should therefore block only on the old viewer, not on the Agent by itself.
