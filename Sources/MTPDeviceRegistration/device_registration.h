#ifndef AndroidTransferV2_DeviceRegistration_h
#define AndroidTransferV2_DeviceRegistration_h

#ifdef __cplusplus
extern "C" {
#endif

int mtp_legacy_device_agent_set_enabled(int enabled);
int mtp_legacy_retired_device_agent_set_enabled(int enabled);
int mtp_legacy_retired_auto_launch_set_enabled(int enabled);

#ifdef __cplusplus
}
#endif

#endif
