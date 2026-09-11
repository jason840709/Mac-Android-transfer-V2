#include "mtp_bridge.h"
#include <stdio.h>

int main(void) {
    mtp_bridge_error_t error;
    mtp_bridge_error_init(&error);
    mtp_bridge_device_list_t devices = {0};
    int32_t status = mtp_bridge_detect_devices(&devices, &error);
    if (status != MTP_BRIDGE_OK) {
        fprintf(stderr, "Detection failed: %s\n", error.message != NULL ? error.message : "unknown error");
        mtp_bridge_error_clear(&error);
        return 1;
    }
    printf("Detected %zu MTP device(s).\n", devices.count);
    for (size_t index = 0; index < devices.count; index++) {
        const mtp_bridge_raw_device_t *device = &devices.items[index];
        printf(
            "[%zu] bus=%u device=%u vid=%04x pid=%04x %s %s\n",
            index,
            device->bus_location,
            device->device_number,
            device->vendor_id,
            device->product_id,
            device->vendor != NULL ? device->vendor : "",
            device->product != NULL ? device->product : ""
        );
    }
    mtp_bridge_device_list_clear(&devices);
    mtp_bridge_error_clear(&error);
    return 0;
}
