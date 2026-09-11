#include "mtp_device_watcher.h"

#include <stddef.h>

void mtp_device_presence_state_init(mtp_device_presence_state_t *state, int initially_present) {
    if (state == NULL) {
        return;
    }
    state->has_mtp_device = initially_present ? 1 : 0;
}

int mtp_device_presence_state_update(mtp_device_presence_state_t *state, int currently_present) {
    if (state == NULL) {
        return 0;
    }
    const int normalized = currently_present ? 1 : 0;
    const int should_launch = normalized && !state->has_mtp_device;
    state->has_mtp_device = normalized;
    return should_launch;
}

#if defined(__APPLE__)

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <libmtp.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

#define WATCHER_RETRY_COUNT 12
#define WATCHER_RETRY_NS 100000000L
#define WATCHER_REMOVAL_RETRY_COUNT 10

static mtp_device_presence_state_t g_presence_state;
static mtp_device_inserted_callback g_callback = NULL;
static void *g_callback_context = NULL;

static void sleep_retry_interval(void) {
    struct timespec interval;
    interval.tv_sec = 0;
    interval.tv_nsec = WATCHER_RETRY_NS;
    while (nanosleep(&interval, &interval) != 0) {
        /* Retry the remaining interval if a signal interrupted the sleep. */
    }
}

static int detect_any_mtp_device(void) {
    LIBMTP_raw_device_t *devices = NULL;
    int count = 0;
    const LIBMTP_error_number_t result = LIBMTP_Detect_Raw_Devices(&devices, &count);
    free(devices);

    if (result == LIBMTP_ERROR_NONE) {
        return count > 0 ? 1 : 0;
    }
    if (result == LIBMTP_ERROR_NO_DEVICE_ATTACHED) {
        return 0;
    }
    return -1;
}

static int detect_mtp_device_pair(uint16_t vendor_id, uint16_t product_id) {
    LIBMTP_raw_device_t *devices = NULL;
    int count = 0;
    const LIBMTP_error_number_t result = LIBMTP_Detect_Raw_Devices(&devices, &count);
    if (result == LIBMTP_ERROR_NO_DEVICE_ATTACHED) {
        free(devices);
        return 0;
    }
    if (result != LIBMTP_ERROR_NONE) {
        free(devices);
        return -1;
    }

    int matched = 0;
    for (int index = 0; index < count; index++) {
        const LIBMTP_device_entry_t entry = devices[index].device_entry;
        if (entry.vendor_id == vendor_id && entry.product_id == product_id) {
            matched = 1;
            break;
        }
    }
    free(devices);
    return matched;
}

static int read_u16_property(io_service_t service, CFStringRef key, uint16_t *value) {
    if (value == NULL) {
        return 0;
    }
    CFTypeRef property = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (property == NULL || CFGetTypeID(property) != CFNumberGetTypeID()) {
        if (property != NULL) {
            CFRelease(property);
        }
        return 0;
    }

    int32_t number = 0;
    const Boolean ok = CFNumberGetValue((CFNumberRef)property, kCFNumberSInt32Type, &number);
    CFRelease(property);
    if (!ok || number < 0 || number > UINT16_MAX) {
        return 0;
    }
    *value = (uint16_t)number;
    return 1;
}

static void drain_iterator_silently(io_iterator_t iterator) {
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        IOObjectRelease(service);
    }
}

static void handle_matched_devices(void *refcon, io_iterator_t iterator) {
    (void)refcon;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        uint16_t vendor_id = 0;
        uint16_t product_id = 0;
        const int has_ids =
            read_u16_property(service, CFSTR("idVendor"), &vendor_id) &&
            read_u16_property(service, CFSTR("idProduct"), &product_id);

        if (has_ids) {
            int is_mtp = 0;
            for (int attempt = 0; attempt < WATCHER_RETRY_COUNT; attempt++) {
                const int result = detect_mtp_device_pair(vendor_id, product_id);
                if (result == 1) {
                    is_mtp = 1;
                    break;
                }
                if (attempt + 1 < WATCHER_RETRY_COUNT) {
                    sleep_retry_interval();
                }
            }
            if (is_mtp && mtp_device_presence_state_update(&g_presence_state, 1)) {
                if (g_callback != NULL) {
                    g_callback(g_callback_context);
                }
            }
        }
        IOObjectRelease(service);
    }
}

static void handle_terminated_devices(void *refcon, io_iterator_t iterator) {
    (void)refcon;
    int observed_termination = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        observed_termination = 1;
        IOObjectRelease(service);
    }
    if (!observed_termination) {
        return;
    }

    /*
     * Give macOS/libmtp a short moment to converge after USB removal. If a
     * different MTP device remains connected, presence correctly stays true.
     */
    for (int attempt = 0; attempt < WATCHER_REMOVAL_RETRY_COUNT; attempt++) {
        const int present = detect_any_mtp_device();
        if (present == 0) {
            (void)mtp_device_presence_state_update(&g_presence_state, 0);
            return;
        }
        if (present == 1) {
            if (attempt + 1 < WATCHER_REMOVAL_RETRY_COUNT) {
                sleep_retry_interval();
                continue;
            }
            (void)mtp_device_presence_state_update(&g_presence_state, 1);
            return;
        }
        if (attempt + 1 < WATCHER_REMOVAL_RETRY_COUNT) {
            sleep_retry_interval();
        }
    }
}

int mtp_device_watcher_run(mtp_device_inserted_callback callback, void *context) {
    if (callback == NULL) {
        return -1;
    }

    LIBMTP_Init();
    int initial_presence = detect_any_mtp_device();
    if (initial_presence < 0) {
        initial_presence = 0;
    }
    mtp_device_presence_state_init(&g_presence_state, initial_presence);
    g_callback = callback;
    g_callback_context = context;

    IONotificationPortRef notification_port = IONotificationPortCreate(kIOMainPortDefault);
    if (notification_port == NULL) {
        return -2;
    }
    CFRunLoopSourceRef run_loop_source = IONotificationPortGetRunLoopSource(notification_port);
    if (run_loop_source == NULL) {
        IONotificationPortDestroy(notification_port);
        return -3;
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), run_loop_source, kCFRunLoopDefaultMode);

    io_iterator_t matched_iterator = IO_OBJECT_NULL;
    CFMutableDictionaryRef matched_dictionary = IOServiceMatching("IOUSBHostDevice");
    if (matched_dictionary == NULL) {
        IONotificationPortDestroy(notification_port);
        return -4;
    }
    kern_return_t kr = IOServiceAddMatchingNotification(
        notification_port,
        kIOMatchedNotification,
        matched_dictionary,
        handle_matched_devices,
        NULL,
        &matched_iterator
    );
    if (kr != KERN_SUCCESS) {
        IONotificationPortDestroy(notification_port);
        return -5;
    }
    /* Arm the iterator without treating already-connected phones as inserts. */
    drain_iterator_silently(matched_iterator);

    io_iterator_t terminated_iterator = IO_OBJECT_NULL;
    CFMutableDictionaryRef terminated_dictionary = IOServiceMatching("IOUSBHostDevice");
    if (terminated_dictionary == NULL) {
        IOObjectRelease(matched_iterator);
        IONotificationPortDestroy(notification_port);
        return -6;
    }
    kr = IOServiceAddMatchingNotification(
        notification_port,
        kIOTerminatedNotification,
        terminated_dictionary,
        handle_terminated_devices,
        NULL,
        &terminated_iterator
    );
    if (kr != KERN_SUCCESS) {
        IOObjectRelease(matched_iterator);
        IONotificationPortDestroy(notification_port);
        return -7;
    }
    drain_iterator_silently(terminated_iterator);

    CFRunLoopRun();

    IOObjectRelease(matched_iterator);
    IOObjectRelease(terminated_iterator);
    IONotificationPortDestroy(notification_port);
    return 0;
}

#else

int mtp_device_watcher_run(mtp_device_inserted_callback callback, void *context) {
    (void)callback;
    (void)context;
    return -1;
}

#endif
