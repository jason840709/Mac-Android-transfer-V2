# 0.6.11 Folder Upload Root Fix

libmtp documents the `LIBMTP_Create_Folder` parent argument as the parent folder object ID, or `0xffffffff` for the storage root. The bridge previously converted its own root sentinel to `0` before calling libmtp.

Android's MTP server can interpret parent handle `0` as an invalid object handle during `SendObjectInfo`, producing:

```text
PTP Layer error 2009: LIBMTP_Create_Folder: Could not send object info.
PTP Invalid Object Handle
```

0.6.11 preserves `MTP_BRIDGE_ROOT_OBJECT_ID` (`UINT32_MAX`) for root folder creation. Nested folder creation continues to pass the actual parent object ID returned by the device.

The regression suite records the parent supplied to `LIBMTP_Create_Folder`, rejects parent `0` in the fake Android implementation, and verifies a root folder plus a child folder.
