#import "device_registration.h"
#import <ServiceManagement/ServiceManagement.h>

static int set_login_item_enabled(CFStringRef identifier, int enabled) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    Boolean result = SMLoginItemSetEnabled(identifier, enabled ? true : false);
#pragma clang diagnostic pop
    return result ? 1 : 0;
}

int mtp_legacy_device_agent_set_enabled(int enabled) {
    return set_login_item_enabled(CFSTR("io.github.mtpbridge.DeviceInsertionAgentV2"), enabled);
}

int mtp_legacy_retired_device_agent_set_enabled(int enabled) {
    return set_login_item_enabled(CFSTR("io.github.mtpbridge.DeviceInsertionAgent"), enabled);
}

int mtp_legacy_retired_auto_launch_set_enabled(int enabled) {
    return set_login_item_enabled(CFSTR("io.github.mtpbridge.MTPAutoLaunch"), enabled);
}
