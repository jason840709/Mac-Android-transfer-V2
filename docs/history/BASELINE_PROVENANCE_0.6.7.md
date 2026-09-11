# Baseline provenance: Android 傳輸 V2 0.6.7

0.6.7 uses the user-validated `0.6.3-readable-ui-r2` tree as its transfer/UI baseline. That baseline includes the 0.6.0 Finder exact-destination fix, visible table headers, transfer-shelf behavior, restored muted palette, light-violet storage bar, and small/medium/large text sizing.

`Tests/Compatibility/v063-readable-ui-r2-preserved.sha256` locks 33 stable files. The only intentional change inside that list is one additional `device_registration.h` include in `MTPBridge-Bridging-Header.h`; the preservation verifier removes exactly that line before comparing the old hash.

The 0.6.7 device-insertion implementation lives in new/replaced DeviceInsertion service, registration bridge, hidden helper, build/audit scripts and helper configuration.
