# 0.6.10 Android Root Upload Fix

## Symptom

Finder-to-phone uploads could fail immediately at 0 KB with:

`PTP Layer error 2009: send_file_object_info(): Could not send object info.; Error 2009: PTP Invalid Object Handle`

The failure was reproducible even after reinstalling an older app build when the destination was the root of an Android MTP storage.

## Root cause

The bridge previously translated its internal root sentinel (`MTP_BRIDGE_ROOT_OBJECT_ID`, `0xffffffff`) to parent ID `0` before calling `LIBMTP_Send_File_From_File_Descriptor`. libmtp's legacy SendObjectInfo path can forward that zero as an object handle. Android expects the explicit root parent sentinel in that path and can reject handle zero as `PTP Invalid Object Handle`.

## Fix

File upload metadata now preserves the explicit root sentinel:

`root -> 0xffffffff`

Subfolder uploads continue using the freshly resolved folder object handle. A fake-libmtp regression captures the actual parent ID handed to libmtp and requires root uploads to send `MTP_BRIDGE_ROOT_OBJECT_ID`.
