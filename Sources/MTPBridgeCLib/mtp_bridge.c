#define _POSIX_C_SOURCE 200809L

#include "mtp_bridge.h"

#include <errno.h>
#include <fcntl.h>
#include <libmtp.h>
#include <libusb.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define MTP_BRIDGE_PROPERTY_SUPPORT_CACHE_CAPACITY 32
#define MTP_BRIDGE_PROPERTY_OPTIMISTIC_PROBE_LIMIT 8

typedef enum property_support_state {
    PROPERTY_SUPPORT_UNKNOWN = 0,
    PROPERTY_SUPPORT_UNSUPPORTED = 1,
    PROPERTY_SUPPORT_SUPPORTED = 2
} property_support_state_t;

typedef struct property_support_cache_entry {
    int32_t file_type;
    property_support_state_t state;
    bool capability_checked;
    unsigned int negative_probe_count;
} property_support_cache_entry_t;

struct mtp_bridge_session {
    LIBMTP_mtpdevice_t *device;
    uint32_t bus_location;
    uint8_t device_number;
    bool supports_partial_download;
    bool supports_partial_upload;
    bool supports_move;
    property_support_cache_entry_t date_created_support[MTP_BRIDGE_PROPERTY_SUPPORT_CACHE_CAPACITY];
    size_t date_created_support_count;
};

struct mtp_bridge_cancel {
    atomic_bool requested;
};

typedef struct progress_adapter {
    mtp_bridge_cancel_t *cancel_token;
    mtp_bridge_progress_fn callback;
    void *context;
    uint64_t base;
    uint64_t total_override;
} progress_adapter_t;

static pthread_once_t g_init_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t g_mtp_mutex = PTHREAD_MUTEX_INITIALIZER;

static void initialize_libmtp(void) {
    LIBMTP_Init();
}

static char *copy_string(const char *value) {
    return strdup(value != NULL ? value : "");
}

static bool parse_decimal_component(const char *value, size_t length, int *out_value) {
    if (value == NULL || out_value == NULL || length == 0) {
        return false;
    }
    int result = 0;
    for (size_t index = 0; index < length; index++) {
        if (value[index] < '0' || value[index] > '9') {
            return false;
        }
        result = result * 10 + (value[index] - '0');
    }
    *out_value = result;
    return true;
}

static bool is_leap_year(int year) {
    return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
}

static int days_in_month(int year, int month) {
    static const int lengths[] = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month < 1 || month > 12) {
        return 0;
    }
    if (month == 2 && is_leap_year(year)) {
        return 29;
    }
    return lengths[month - 1];
}

// Returns the number of days since 1970-01-01 for a valid civil date.
// Algorithm by Howard Hinnant, placed in the public domain.
static int64_t days_from_civil(int year, unsigned month, unsigned day) {
    year -= month <= 2;
    const int era = (year >= 0 ? year : year - 399) / 400;
    const unsigned year_of_era = (unsigned)(year - era * 400);
    const unsigned adjusted_month = month > 2 ? month - 3U : month + 9U;
    const unsigned day_of_year = (153U * adjusted_month + 2U) / 5U + day - 1U;
    const unsigned day_of_era = year_of_era * 365U + year_of_era / 4U - year_of_era / 100U + day_of_year;
    return (int64_t)era * 146097LL + (int64_t)day_of_era - 719468LL;
}

// Parses the MTP/PTP datetime form YYYYMMDDThhmmss[.s][Z|+hhmm|-hhmm].
// A timestamp without an explicit offset is interpreted in the Mac's local
// time zone, matching libmtp's treatment of DateModified.
static int64_t parse_mtp_datetime(const char *value) {
    if (value == NULL || strlen(value) < 15 || (value[8] != 'T' && value[8] != 't')) {
        return 0;
    }

    int year = 0;
    int month = 0;
    int day = 0;
    int hour = 0;
    int minute = 0;
    int second = 0;
    if (!parse_decimal_component(value, 4, &year) ||
        !parse_decimal_component(value + 4, 2, &month) ||
        !parse_decimal_component(value + 6, 2, &day) ||
        !parse_decimal_component(value + 9, 2, &hour) ||
        !parse_decimal_component(value + 11, 2, &minute) ||
        !parse_decimal_component(value + 13, 2, &second)) {
        return 0;
    }
    if (year < 1970 || month < 1 || month > 12 || day < 1 ||
        day > days_in_month(year, month) || hour > 23 || minute > 59 || second > 60) {
        return 0;
    }

    const char *cursor = value + 15;
    if (*cursor == '.') {
        cursor++;
        while (*cursor >= '0' && *cursor <= '9') {
            cursor++;
        }
    }

    if (*cursor == '\0') {
        struct tm local_time;
        memset(&local_time, 0, sizeof(local_time));
        local_time.tm_year = year - 1900;
        local_time.tm_mon = month - 1;
        local_time.tm_mday = day;
        local_time.tm_hour = hour;
        local_time.tm_min = minute;
        local_time.tm_sec = second;
        local_time.tm_isdst = -1;
        time_t timestamp = mktime(&local_time);
        return timestamp > 0 ? (int64_t)timestamp : 0;
    }

    int offset_seconds = 0;
    if (*cursor == 'Z' || *cursor == 'z') {
        cursor++;
    } else if (*cursor == '+' || *cursor == '-') {
        const int sign = *cursor == '+' ? 1 : -1;
        cursor++;
        int offset_hour = 0;
        int offset_minute = 0;
        if (!parse_decimal_component(cursor, 2, &offset_hour)) {
            return 0;
        }
        cursor += 2;
        if (*cursor == ':') {
            cursor++;
        }
        if (!parse_decimal_component(cursor, 2, &offset_minute)) {
            return 0;
        }
        cursor += 2;
        if (offset_hour > 23 || offset_minute > 59) {
            return 0;
        }
        offset_seconds = sign * (offset_hour * 3600 + offset_minute * 60);
    } else {
        return 0;
    }

    if (*cursor != '\0') {
        return 0;
    }

    const int64_t local_seconds = days_from_civil(year, (unsigned)month, (unsigned)day) * 86400LL +
        (int64_t)hour * 3600LL + (int64_t)minute * 60LL + second;
    const int64_t timestamp = local_seconds - offset_seconds;
    return timestamp > 0 ? timestamp : 0;
}

static property_support_cache_entry_t *date_created_cache_entry(
    mtp_bridge_session_t *session,
    LIBMTP_filetype_t file_type
) {
    for (size_t index = 0; index < session->date_created_support_count; index++) {
        if (session->date_created_support[index].file_type == (int32_t)file_type) {
            return &session->date_created_support[index];
        }
    }

    if (session->date_created_support_count >= MTP_BRIDGE_PROPERTY_SUPPORT_CACHE_CAPACITY) {
        return NULL;
    }

    property_support_cache_entry_t *entry =
        &session->date_created_support[session->date_created_support_count++];
    memset(entry, 0, sizeof(*entry));
    entry->file_type = (int32_t)file_type;
    entry->state = PROPERTY_SUPPORT_UNKNOWN;
    return entry;
}

static void check_date_created_capability_hint(
    mtp_bridge_session_t *session,
    LIBMTP_filetype_t file_type,
    property_support_cache_entry_t *entry
) {
    if (entry == NULL || entry->capability_checked) {
        return;
    }
    entry->capability_checked = true;

    int supported = LIBMTP_Is_Property_Supported(
        session->device,
        LIBMTP_PROPERTY_DateCreated,
        file_type
    );
    if (supported > 0) {
        entry->state = PROPERTY_SUPPORT_SUPPORTED;
    } else if (supported < 0) {
        // Some Android MTP implementations cannot answer the capability query.
        // Treat that response as a hint failure, not proof the property is absent.
        LIBMTP_Clear_Errorstack(session->device);
    }
    // A zero response is also only a hint: several devices still expose
    // DateCreated through GetObjectPropValue. The reader below probes a bounded
    // number of objects before caching an unsupported result.
}

static void prepare_error(mtp_bridge_error_t *error) {
    if (error == NULL) {
        return;
    }
    error->code = MTP_BRIDGE_OK;
    error->retryable = false;
    error->message = NULL;
}

static void set_error_message(
    mtp_bridge_error_t *error,
    mtp_bridge_status_t code,
    bool retryable,
    const char *format,
    ...
) {
    if (error == NULL) {
        return;
    }
    error->code = (int32_t)code;
    error->retryable = retryable;

    va_list arguments;
    va_start(arguments, format);
    va_list copy;
    va_copy(copy, arguments);
    int required = vsnprintf(NULL, 0, format, copy);
    va_end(copy);
    if (required < 0) {
        error->message = copy_string("Unknown error");
        va_end(arguments);
        return;
    }
    error->message = calloc((size_t)required + 1, 1);
    if (error->message != NULL) {
        (void)vsnprintf(error->message, (size_t)required + 1, format, arguments);
    }
    va_end(arguments);
}

static mtp_bridge_status_t bridge_status_for_libmtp_error(
    LIBMTP_error_number_t number,
    bool *retryable
) {
    *retryable = false;
    switch (number) {
        case LIBMTP_ERROR_NONE:
            return MTP_BRIDGE_OK;
        case LIBMTP_ERROR_PTP_LAYER:
            *retryable = true;
            return MTP_BRIDGE_ERROR_PROTOCOL;
        case LIBMTP_ERROR_USB_LAYER:
            *retryable = true;
            return MTP_BRIDGE_ERROR_USB;
        case LIBMTP_ERROR_MEMORY_ALLOCATION:
            return MTP_BRIDGE_ERROR_MEMORY;
        case LIBMTP_ERROR_NO_DEVICE_ATTACHED:
            *retryable = true;
            return MTP_BRIDGE_ERROR_NO_DEVICE;
        case LIBMTP_ERROR_STORAGE_FULL:
            return MTP_BRIDGE_ERROR_STORAGE_FULL;
        case LIBMTP_ERROR_CONNECTING:
            *retryable = true;
            return MTP_BRIDGE_ERROR_CONNECTING;
        case LIBMTP_ERROR_CANCELLED:
            return MTP_BRIDGE_ERROR_CANCELLED;
        case LIBMTP_ERROR_GENERAL:
        default:
            *retryable = true;
            return MTP_BRIDGE_ERROR_LIBRARY;
    }
}

static void set_device_error(
    mtp_bridge_session_t *session,
    mtp_bridge_error_t *error,
    mtp_bridge_status_t fallback_code,
    bool fallback_retryable,
    const char *fallback_message
) {
    if (error == NULL) {
        if (session != NULL && session->device != NULL) {
            LIBMTP_Clear_Errorstack(session->device);
        }
        return;
    }

    LIBMTP_error_t *entry = session != NULL && session->device != NULL
        ? LIBMTP_Get_Errorstack(session->device)
        : NULL;
    if (entry == NULL) {
        set_error_message(error, fallback_code, fallback_retryable, "%s", fallback_message);
        return;
    }

    size_t required = 1;
    mtp_bridge_status_t status = fallback_code;
    bool retryable = fallback_retryable;
    for (LIBMTP_error_t *cursor = entry; cursor != NULL; cursor = cursor->next) {
        required += strlen(cursor->error_text != NULL ? cursor->error_text : "libmtp error") + 3;
        bool item_retryable = false;
        mtp_bridge_status_t item_status = bridge_status_for_libmtp_error(cursor->errornumber, &item_retryable);
        if (item_status != MTP_BRIDGE_OK) {
            status = item_status;
            retryable = item_retryable;
        }
    }

    char *message = calloc(required, 1);
    if (message != NULL) {
        for (LIBMTP_error_t *cursor = entry; cursor != NULL; cursor = cursor->next) {
            if (message[0] != '\0') {
                strncat(message, "; ", required - strlen(message) - 1);
            }
            strncat(
                message,
                cursor->error_text != NULL ? cursor->error_text : "libmtp error",
                required - strlen(message) - 1
            );
        }
    }
    error->code = (int32_t)status;
    error->retryable = retryable;
    error->message = message != NULL ? message : copy_string(fallback_message);
    LIBMTP_Clear_Errorstack(session->device);
}

static int progress_callback(uint64_t sent, uint64_t total, void const *data) {
    progress_adapter_t *adapter = (progress_adapter_t *)data;
    if (adapter == NULL) {
        return 0;
    }
    if (adapter->cancel_token != NULL &&
        atomic_load_explicit(&adapter->cancel_token->requested, memory_order_relaxed)) {
        return 1;
    }
    if (adapter->callback == NULL) {
        return 0;
    }
    uint64_t effective_total = adapter->total_override > 0
        ? adapter->total_override
        : adapter->base + total;
    int result = adapter->callback(adapter->base + sent, effective_total, adapter->context);
    return result != 0 ? 1 : 0;
}

static bool cancellation_requested(const mtp_bridge_cancel_t *token) {
    return token != NULL && atomic_load_explicit(&token->requested, memory_order_relaxed);
}

static int write_all(int descriptor, const unsigned char *bytes, size_t length) {
    size_t written = 0;
    while (written < length) {
        ssize_t result = write(descriptor, bytes + written, length - written);
        if (result < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (result == 0) {
            errno = EIO;
            return -1;
        }
        written += (size_t)result;
    }
    return 0;
}

void mtp_bridge_error_init(mtp_bridge_error_t *error) {
    prepare_error(error);
}

void mtp_bridge_error_clear(mtp_bridge_error_t *error) {
    if (error == NULL) {
        return;
    }
    free(error->message);
    error->message = NULL;
    error->code = MTP_BRIDGE_OK;
    error->retryable = false;
}

mtp_bridge_cancel_t *mtp_bridge_cancel_create(void) {
    mtp_bridge_cancel_t *token = calloc(1, sizeof(*token));
    if (token != NULL) {
        atomic_init(&token->requested, false);
    }
    return token;
}

void mtp_bridge_cancel_destroy(mtp_bridge_cancel_t *token) {
    free(token);
}

void mtp_bridge_cancel_request(mtp_bridge_cancel_t *token) {
    if (token != NULL) {
        atomic_store_explicit(&token->requested, true, memory_order_relaxed);
    }
}

void mtp_bridge_cancel_reset(mtp_bridge_cancel_t *token) {
    if (token != NULL) {
        atomic_store_explicit(&token->requested, false, memory_order_relaxed);
    }
}

bool mtp_bridge_cancel_is_requested(const mtp_bridge_cancel_t *token) {
    return cancellation_requested(token);
}

int32_t mtp_bridge_detect_devices(
    mtp_bridge_device_list_t *out_list,
    mtp_bridge_error_t *error
) {
    prepare_error(error);
    if (out_list == NULL) {
        set_error_message(error, MTP_BRIDGE_ERROR_INVALID_ARGUMENT, false, "Device list is required");
        return MTP_BRIDGE_ERROR_INVALID_ARGUMENT;
    }
    out_list->items = NULL;
    out_list->count = 0;

    pthread_once(&g_init_once, initialize_libmtp);
    pthread_mutex_lock(&g_mtp_mutex);

    LIBMTP_raw_device_t *raw_devices = NULL;
    int count = 0;
    LIBMTP_error_number_t result = LIBMTP_Detect_Raw_Devices(&raw_devices, &count);
    if (result == LIBMTP_ERROR_NO_DEVICE_ATTACHED || count == 0) {
        free(raw_devices);
        pthread_mutex_unlock(&g_mtp_mutex);
        return MTP_BRIDGE_OK;
    }
    if (result != LIBMTP_ERROR_NONE) {
        bool retryable = false;
        mtp_bridge_status_t status = bridge_status_for_libmtp_error(result, &retryable);
        set_error_message(error, status, retryable, "Unable to enumerate MTP devices (libmtp error %d)", result);
        free(raw_devices);
        pthread_mutex_unlock(&g_mtp_mutex);
        return status;
    }

    out_list->items = calloc((size_t)count, sizeof(*out_list->items));
    if (out_list->items == NULL) {
        free(raw_devices);
        set_error_message(error, MTP_BRIDGE_ERROR_MEMORY, false, "Unable to allocate the device list");
        pthread_mutex_unlock(&g_mtp_mutex);
        return MTP_BRIDGE_ERROR_MEMORY;
    }
    out_list->count = (size_t)count;
    for (int index = 0; index < count; index++) {
        LIBMTP_raw_device_t *source = &raw_devices[index];
        mtp_bridge_raw_device_t *destination = &out_list->items[index];
        destination->bus_location = source->bus_location;
        destination->device_number = source->devnum;
        destination->vendor_id = source->device_entry.vendor_id;
        destination->product_id = source->device_entry.product_id;
        destination->vendor = copy_string(source->device_entry.vendor);
        destination->product = copy_string(source->device_entry.product);
        if (destination->vendor == NULL || destination->product == NULL) {
            free(raw_devices);
            pthread_mutex_unlock(&g_mtp_mutex);
            mtp_bridge_device_list_clear(out_list);
            set_error_message(error, MTP_BRIDGE_ERROR_MEMORY, false, "Unable to copy the device list");
            return MTP_BRIDGE_ERROR_MEMORY;
        }
    }
    free(raw_devices);
    pthread_mutex_unlock(&g_mtp_mutex);
    return MTP_BRIDGE_OK;
}


int32_t mtp_bridge_is_usb_device_present(
    uint32_t bus_location,
    uint8_t device_number,
    uint16_t vendor_id,
    uint16_t product_id,
    bool *out_present,
    mtp_bridge_error_t *error
) {
    prepare_error(error);
    if (out_present == NULL) {
        set_error_message(error, MTP_BRIDGE_ERROR_INVALID_ARGUMENT, false, "Presence result is required");
        return MTP_BRIDGE_ERROR_INVALID_ARGUMENT;
    }
    *out_present = false;

    libusb_context *context = NULL;
    int init_result = libusb_init(&context);
    if (init_result != LIBUSB_SUCCESS) {
        set_error_message(
            error,
            MTP_BRIDGE_ERROR_USB,
            true,
            "Unable to initialize lightweight USB monitoring (libusb error %d)",
            init_result
        );
        return MTP_BRIDGE_ERROR_USB;
    }

    libusb_device **devices = NULL;
    ssize_t count = libusb_get_device_list(context, &devices);
    if (count < 0) {
        libusb_exit(context);
        set_error_message(
            error,
            MTP_BRIDGE_ERROR_USB,
            true,
            "Unable to enumerate USB devices (libusb error %ld)",
            (long)count
        );
        return MTP_BRIDGE_ERROR_USB;
    }

    for (ssize_t index = 0; index < count; index++) {
        libusb_device *device = devices[index];
        if ((uint32_t)libusb_get_bus_number(device) != bus_location ||
            libusb_get_device_address(device) != device_number) {
            continue;
        }
        struct libusb_device_descriptor descriptor;
        if (libusb_get_device_descriptor(device, &descriptor) != LIBUSB_SUCCESS) {
            continue;
        }
        if (descriptor.idVendor == vendor_id && descriptor.idProduct == product_id) {
            *out_present = true;
            break;
        }
    }

    libusb_free_device_list(devices, 1);
    libusb_exit(context);
    return MTP_BRIDGE_OK;
}

void mtp_bridge_device_list_clear(mtp_bridge_device_list_t *list) {
    if (list == NULL) {
        return;
    }
    for (size_t index = 0; index < list->count; index++) {
        free(list->items[index].vendor);
        free(list->items[index].product);
    }
    free(list->items);
    list->items = NULL;
    list->count = 0;
}

mtp_bridge_session_t *mtp_bridge_open_device(
    uint32_t bus_location,
    uint8_t device_number,
    mtp_bridge_error_t *error
) {
    prepare_error(error);
    pthread_once(&g_init_once, initialize_libmtp);
    pthread_mutex_lock(&g_mtp_mutex);

    LIBMTP_raw_device_t *raw_devices = NULL;
    int count = 0;
    LIBMTP_error_number_t detection = LIBMTP_Detect_Raw_Devices(&raw_devices, &count);
    if (detection != LIBMTP_ERROR_NONE || count == 0) {
        bool retryable = true;
        mtp_bridge_status_t status = detection == LIBMTP_ERROR_NO_DEVICE_ATTACHED
            ? MTP_BRIDGE_ERROR_NO_DEVICE
            : bridge_status_for_libmtp_error(detection, &retryable);
        set_error_message(error, status, retryable, "The selected Android device is no longer available");
        free(raw_devices);
        pthread_mutex_unlock(&g_mtp_mutex);
        return NULL;
    }

    LIBMTP_raw_device_t *selected = NULL;
    for (int index = 0; index < count; index++) {
        if (raw_devices[index].bus_location == bus_location && raw_devices[index].devnum == device_number) {
            selected = &raw_devices[index];
            break;
        }
    }
    if (selected == NULL) {
        set_error_message(error, MTP_BRIDGE_ERROR_NO_DEVICE, true, "The selected Android device moved or disconnected");
        free(raw_devices);
        pthread_mutex_unlock(&g_mtp_mutex);
        return NULL;
    }

    LIBMTP_mtpdevice_t *device = LIBMTP_Open_Raw_Device_Uncached(selected);
    free(raw_devices);
    if (device == NULL) {
        set_error_message(
            error,
            MTP_BRIDGE_ERROR_CONNECTING,
            true,
            "Unable to open the MTP session. Unlock the phone and select File transfer / Android Auto."
        );
        pthread_mutex_unlock(&g_mtp_mutex);
        return NULL;
    }

    mtp_bridge_session_t *session = calloc(1, sizeof(*session));
    if (session == NULL) {
        LIBMTP_Release_Device(device);
        set_error_message(error, MTP_BRIDGE_ERROR_MEMORY, false, "Unable to allocate an MTP session");
        pthread_mutex_unlock(&g_mtp_mutex);
        return NULL;
    }
    session->device = device;
    session->bus_location = bus_location;
    session->device_number = device_number;
    session->supports_partial_download = LIBMTP_Check_Capability(device, LIBMTP_DEVICECAP_GetPartialObject) != 0;
    session->supports_partial_upload = LIBMTP_Check_Capability(device, LIBMTP_DEVICECAP_SendPartialObject) != 0;
    session->supports_move = LIBMTP_Check_Capability(device, LIBMTP_DEVICECAP_MoveObject) != 0;

    pthread_mutex_unlock(&g_mtp_mutex);
    return session;
}

void mtp_bridge_close_device(mtp_bridge_session_t *session) {
    if (session == NULL) {
        return;
    }
    pthread_mutex_lock(&g_mtp_mutex);
    if (session->device != NULL) {
        LIBMTP_Release_Device(session->device);
        session->device = NULL;
    }
    pthread_mutex_unlock(&g_mtp_mutex);
    free(session);
}

int32_t mtp_bridge_get_device_info(
    mtp_bridge_session_t *session,
    mtp_bridge_device_info_t *out_info,
    mtp_bridge_error_t *error
) {
    prepare_error(error);
    if (session == NULL || session->device == NULL || out_info == NULL) {
        set_error_message(error, MTP_BRIDGE_ERROR_INVALID_ARGUMENT, false, "An open MTP session is required");
        return MTP_BRIDGE_ERROR_INVALID_ARGUMENT;
    }
    memset(out_info, 0, sizeof(*out_info));
    pthread_mutex_lock(&g_mtp_mutex);

    char *manufacturer = LIBMTP_Get_Manufacturername(session->device);
    char *model = LIBMTP_Get_Modelname(session->device);
    char *serial = LIBMTP_Get_Serialnumber(session->device);
    char *friendly = LIBMTP_Get_Friendlyname(session->device);
    char *version = LIBMTP_Get_Deviceversion(session->device);

    out_info->manufacturer = copy_string(manufacturer);
    out_info->model = copy_string(model);
    out_info->serial_number = copy_string(serial);
    out_info->friendly_name = copy_string(friendly);
    out_info->device_version = copy_string(version);
    out_info->supports_partial_download = session->supports_partial_download;
    out_info->supports_partial_upload = session->supports_partial_upload;
    out_info->supports_move = session->supports_move;

    LIBMTP_FreeMemory(manufacturer);
    LIBMTP_FreeMemory(model);
    LIBMTP_FreeMemory(serial);
    LIBMTP_FreeMemory(friendly);
    LIBMTP_FreeMemory(version);
    pthread_mutex_unlock(&g_mtp_mutex);

    if (out_info->manufacturer == NULL || out_info->model == NULL || out_info->serial_number == NULL ||
        out_info->friendly_name == NULL || out_info->device_version == NULL) {
        mtp_bridge_device_info_clear(out_info);
        set_error_message(error, MTP_BRIDGE_ERROR_MEMORY, false, "Unable to copy device information");
        return MTP_BRIDGE_ERROR_MEMORY;
    }
    return MTP_BRIDGE_OK;
}

void mtp_bridge_device_info_clear(mtp_bridge_device_info_t *info) {
    if (info == NULL) {
        return;
    }
    free(info->manufacturer);
    free(info->model);
    free(info->serial_number);
    free(info->friendly_name);
    free(info->device_version);
    memset(info, 0, sizeof(*info));
}

int32_t mtp_bridge_get_storages(
    mtp_bridge_session_t *session,
    mtp_bridge_storage_list_t *out_list,
    mtp_bridge_error_t *error
) {
    prepare_error(error);
    if (session == NULL || session->device == NULL || out_list == NULL) {
        set_error_message(error, MTP_BRIDGE_ERROR_INVALID_ARGUMENT, false, "An open MTP session is required");
        return MTP_BRIDGE_ERROR_INVALID_ARGUMENT;
    }
    out_list->items = NULL;
    out_list->count = 0;
    pthread_mutex_lock(&g_mtp_mutex);

    if (LIBMTP_Get_Storage(session->device, LIBMTP_STORAGE_SORTBY_NOTSORTED) != 0) {
        set_device_error(session, error, MTP_BRIDGE_ERROR_PROTOCOL, true, "Unable to read device storage");
        pthread_mutex_unlock(&g_mtp_mutex);
        return error != NULL ? error->code : MTP_BRIDGE_ERROR_PROTOCOL;
    }

    size_t count = 0;
    for (LIBMTP_devicestorage_t *storage = session->device->storage; storage != NULL; storage = storage->next) {
        count++;
    }
    if (count == 0) {
        set_error_message(error, MTP_BRIDGE_ERROR_NOT_FOUND, true, "The device did not expose any MTP storage");
        pthread_mutex_unlock(&g_mtp_mutex);
        return MTP_BRIDGE_ERROR_NOT_FOUND;
    }

    out_list->items = calloc(count, sizeof(*out_list->items));
    if (out_list->items == NULL) {
        set_error_message(error, MTP_BRIDGE_ERROR_MEMORY, false, "Unable to allocate the storage list");
        pthread_mutex_unlock(&g_mtp_mutex);
        return MTP_BRIDGE_ERROR_MEMORY;
    }
    out_list->count = count;
    size_t index = 0;
    for (LIBMTP_devicestorage_t *storage = session->device->storage; storage != NULL; storage = storage->next) {
        mtp_bridge_storage_t *destination = &out_list->items[index++];
        destination->storage_id = storage->id;
        destination->name = copy_string(
            storage->StorageDescription != NULL && storage->StorageDescription[0] != '\0'
                ? storage->StorageDescription
                : "Internal storage"
        );
        destination->volume_identifier = copy_string(storage->VolumeIdentifier);
        destination->capacity = storage->MaxCapacity;
        destination->free_space = storage->FreeSpaceInBytes;
        destination->read_only = storage->AccessCapability != 0;
        if (destination->name == NULL || destination->volume_identifier == NULL) {
            pthread_mutex_unlock(&g_mtp_mutex);
            mtp_bridge_storage_list_clear(out_list);
            set_error_message(error, MTP_BRIDGE_ERROR_MEMORY, false, "Unable to copy the storage list");
            return MTP_BRIDGE_ERROR_MEMORY;
        }
    }
    pthread_mutex_unlock(&g_mtp_mutex);
    return MTP_BRIDGE_OK;
}

void mtp_bridge_storage_list_clear(mtp_bridge_storage_list_t *list) {
    if (list == NULL) {
        return;
    }
    for (size_t index = 0; index < list->count; index++) {
        free(list->items[index].name);
        free(list->items[index].volume_identifier);
    }
    free(list->items);
    list->items = NULL;
    list->count = 0;
}

int32_t mtp_bridge_list_children(
    mtp_bridge_session_t *session,
    uint32_t storage_id,
    uint32_t parent_object_id,
    mtp_bridge_object_list_t *out_list,
    mtp_bridge_error_t *error
) {
    prepare_error(error);
    if (session == NULL || session->device == NULL || out_list == NULL) {
        set_error_message(error, MTP_BRIDGE_ERROR_INVALID_ARGUMENT, false, "An open MTP session is required");
        return MTP_BRIDGE_ERROR_INVALID_ARGUMENT;
    }
    out_list->items = NULL;
    out_list->count = 0;
    pthread_mutex_lock(&g_mtp_mutex);

    LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(session->device, storage_id, parent_object_id);
    if (files == NULL) {
        LIBMTP_error_t *stack = LIBMTP_Get_Errorstack(session->device);
        if (stack != NULL) {
            set_device_error(session, error, MTP_BRIDGE_ERROR_PROTOCOL, true, "Unable to list this folder");
            pthread_mutex_unlock(&g_mtp_mutex);
            return error != NULL ? error->code : MTP_BRIDGE_ERROR_PROTOCOL;
        }
        pthread_mutex_unlock(&g_mtp_mutex);
        return MTP_BRIDGE_OK;
    }

    size_t count = 0;
    for (LIBMTP_file_t *cursor = files; cursor != NULL; cursor = cursor->next) {
        count++;
    }
    out_list->items = calloc(count, sizeof(*out_list->items));
    if (out_list->items == NULL) {
        while (files != NULL) {
            LIBMTP_file_t *next = files->next;
            files->next = NULL;
            LIBMTP_destroy_file_t(files);
            files = next;
        }
        set_error_message(error, MTP_BRIDGE_ERROR_MEMORY, false, "Unable to allocate the folder listing");
        pthread_mutex_unlock(&g_mtp_mutex);
        return MTP_BRIDGE_ERROR_MEMORY;
    }
    out_list->count = count;

    size_t index = 0;
    while (files != NULL) {
        LIBMTP_file_t *next = files->next;
        files->next = NULL;
        mtp_bridge_object_t *destination = &out_list->items[index++];
        destination->object_id = files->item_id;
        destination->parent_id = files->parent_id;
        destination->storage_id = files->storage_id;
        destination->name = copy_string(files->filename);
        destination->size = files->filesize;
        // Keep folder listing fast. DateCreated is fetched lazily for the browser
        // after names/sizes/modification dates are already visible. Internal
        // transfer scans therefore do not pay one extra MTP round trip per item.
        destination->creation_time = 0;
        destination->modification_time = (int64_t)files->modificationdate;
        destination->file_type = (int32_t)files->filetype;
        destination->is_folder = files->filetype == LIBMTP_FILETYPE_FOLDER;
        LIBMTP_destroy_file_t(files);
        files = next;
        if (destination->name == NULL) {
            while (files != NULL) {
                LIBMTP_file_t *remaining = files->next;
                files->next = NULL;
                LIBMTP_destroy_file_t(files);
                files = remaining;
            }
            pthread_mutex_unlock(&g_mtp_mutex);
            mtp_bridge_object_list_clear(out_list);
            set_error_message(error, MTP_BRIDGE_ERROR_MEMORY, false, "Unable to copy the folder listing");
            return MTP_BRIDGE_ERROR_MEMORY;
        }
    }
    pthread_mutex_unlock(&g_mtp_mutex);
    return MTP_BRIDGE_OK;
}


int32_t mtp_bridge_get_object_creation_time(
    mtp_bridge_session_t *session,
    uint32_t object_id,
    int32_t file_type,
    int64_t *out_creation_time,
    mtp_bridge_error_t *error
) {
    prepare_error(error);
    if (session == NULL || session->device == NULL || out_creation_time == NULL) {
        set_error_message(
            error,
            MTP_BRIDGE_ERROR_INVALID_ARGUMENT,
            false,
            "An open MTP session and creation-time result are required"
        );
        return MTP_BRIDGE_ERROR_INVALID_ARGUMENT;
    }
    *out_creation_time = 0;

    pthread_mutex_lock(&g_mtp_mutex);
    const LIBMTP_filetype_t typed_file_type = (LIBMTP_filetype_t)file_type;
    property_support_cache_entry_t *entry =
        date_created_cache_entry(session, typed_file_type);
    check_date_created_capability_hint(session, typed_file_type, entry);
    if (entry != NULL && entry->state == PROPERTY_SUPPORT_UNSUPPORTED) {
        pthread_mutex_unlock(&g_mtp_mutex);
        return MTP_BRIDGE_OK;
    }

    char *created = LIBMTP_Get_String_From_Object(
        session->device,
        object_id,
        LIBMTP_PROPERTY_DateCreated
    );
    if (created != NULL) {
        *out_creation_time = parse_mtp_datetime(created);
        free(created);
        if (entry != NULL) {
            entry->state = PROPERTY_SUPPORT_SUPPORTED;
            entry->negative_probe_count = 0;
        }
    } else {
        // DateCreated is optional metadata. A missing value must not turn folder
        // browsing into a protocol failure. A device that reports the property as
        // supported may legitimately omit it on individual objects, so only an
        // unknown capability is downgraded after several bounded probes.
        LIBMTP_Clear_Errorstack(session->device);
        if (entry != NULL && entry->state == PROPERTY_SUPPORT_UNKNOWN) {
            entry->negative_probe_count++;
            if (entry->negative_probe_count >= MTP_BRIDGE_PROPERTY_OPTIMISTIC_PROBE_LIMIT) {
                entry->state = PROPERTY_SUPPORT_UNSUPPORTED;
            }
        }
    }
    pthread_mutex_unlock(&g_mtp_mutex);
    return MTP_BRIDGE_OK;
}

void mtp_bridge_object_list_clear(mtp_bridge_object_list_t *list) {
    if (list == NULL) {
        return;
    }
    for (size_t index = 0; index < list->count; index++) {
        free(list->items[index].name);
    }
    free(list->items);
    list->items = NULL;
    list->count = 0;
}

int32_t mtp_bridge_create_folder(
    mtp_bridge_session_t *session,
    const char *name,
    uint32_t storage_id,
    uint32_t parent_object_id,
    uint32_t *out_object_id,
    mtp_bridge_error_t *error
) {
    prepare_error(error);
    if (session == NULL || session->device == NULL || name == NULL || out_object_id == NULL) {
        set_error_message(error, MTP_BRIDGE_ERROR_INVALID_ARGUMENT, false, "Folder name and open session are required");
        return MTP_BRIDGE_ERROR_INVALID_ARGUMENT;
    }
    *out_object_id = 0;
    char *mutable_name = copy_string(name);
    if (mutable_name == NULL) {
        set_error_message(error, MTP_BRIDGE_ERROR_MEMORY, false, "Unable to copy the folder name");
        return MTP_BRIDGE_ERROR_MEMORY;
    }
    pthread_mutex_lock(&g_mtp_mutex);
    /*
     * LIBMTP_Create_Folder documents 0xffffffff as the root parent. Passing
     * handle 0 is not equivalent on Android's MTP server and can make
     * SendObjectInfo fail with PTP_RC_InvalidObjectHandle (0x2009). Keep the
     * bridge root sentinel intact, just as the file-upload path does.
     */
    uint32_t protocol_parent_id = parent_object_id == MTP_BRIDGE_ROOT_OBJECT_ID
        ? MTP_BRIDGE_ROOT_OBJECT_ID
        : parent_object_id;
    uint32_t object_id = LIBMTP_Create_Folder(session->device, mutable_name, protocol_parent_id, storage_id);
    free(mutable_name);
    if (object_id == 0) {
        set_device_error(session, error, MTP_BRIDGE_ERROR_PROTOCOL, true, "Unable to create the folder");
        pthread_mutex_unlock(&g_mtp_mutex);
        return error != NULL ? error->code : MTP_BRIDGE_ERROR_PROTOCOL;
    }
    *out_object_id = object_id;
    pthread_mutex_unlock(&g_mtp_mutex);
    return MTP_BRIDGE_OK;
}

int32_t mtp_bridge_rename_object(
    mtp_bridge_session_t *session,
    uint32_t object_id,
    const char *new_name,
    mtp_bridge_error_t *error
) {
    prepare_error(error);
    if (session == NULL || session->device == NULL || new_name == NULL) {
        set_error_message(error, MTP_BRIDGE_ERROR_INVALID_ARGUMENT, false, "Object name and open session are required");
        return MTP_BRIDGE_ERROR_INVALID_ARGUMENT;
    }
    char *mutable_name = copy_string(new_name);
    if (mutable_name == NULL) {
        set_error_message(error, MTP_BRIDGE_ERROR_MEMORY, false, "Unable to copy the object name");
        return MTP_BRIDGE_ERROR_MEMORY;
    }
    pthread_mutex_lock(&g_mtp_mutex);
    int result = LIBMTP_Set_Object_Filename(session->device, object_id, mutable_name);
    free(mutable_name);
    if (result != 0) {
        set_device_error(session, error, MTP_BRIDGE_ERROR_PROTOCOL, true, "Unable to rename the object");
        pthread_mutex_unlock(&g_mtp_mutex);
        return error != NULL ? error->code : MTP_BRIDGE_ERROR_PROTOCOL;
    }
    pthread_mutex_unlock(&g_mtp_mutex);
    return MTP_BRIDGE_OK;
}

int32_t mtp_bridge_delete_object(
    mtp_bridge_session_t *session,
    uint32_t object_id,
    mtp_bridge_error_t *error
) {
    prepare_error(error);
    if (session == NULL || session->device == NULL) {
        set_error_message(error, MTP_BRIDGE_ERROR_INVALID_ARGUMENT, false, "An open MTP session is required");
        return MTP_BRIDGE_ERROR_INVALID_ARGUMENT;
    }
    pthread_mutex_lock(&g_mtp_mutex);
    if (LIBMTP_Delete_Object(session->device, object_id) != 0) {
        set_device_error(session, error, MTP_BRIDGE_ERROR_PROTOCOL, true, "Unable to delete the object");
        pthread_mutex_unlock(&g_mtp_mutex);
        return error != NULL ? error->code : MTP_BRIDGE_ERROR_PROTOCOL;
    }
    pthread_mutex_unlock(&g_mtp_mutex);
    return MTP_BRIDGE_OK;
}

int32_t mtp_bridge_download_object(
    mtp_bridge_session_t *session,
    uint32_t object_id,
    uint64_t expected_size,
    const char *local_path,
    bool allow_resume,
    uint32_t chunk_bytes,
    mtp_bridge_cancel_t *cancel_token,
    mtp_bridge_progress_fn progress,
    void *progress_context,
    uint64_t *out_resumed_from,
    mtp_bridge_error_t *error
) {
    prepare_error(error);
    if (out_resumed_from != NULL) {
        *out_resumed_from = 0;
    }
    if (session == NULL || session->device == NULL || local_path == NULL) {
        set_error_message(error, MTP_BRIDGE_ERROR_INVALID_ARGUMENT, false, "Download path and open session are required");
        return MTP_BRIDGE_ERROR_INVALID_ARGUMENT;
    }
    if (cancellation_requested(cancel_token)) {
        set_error_message(error, MTP_BRIDGE_ERROR_CANCELLED, false, "Transfer cancelled");
        return MTP_BRIDGE_ERROR_CANCELLED;
    }

    const bool use_partial = allow_resume && session->supports_partial_download && expected_size > 0;
    int flags = O_CREAT | O_WRONLY;
    if (!use_partial) {
        flags |= O_TRUNC;
    }
    int descriptor = open(local_path, flags, 0600);
    if (descriptor < 0) {
        set_error_message(error, MTP_BRIDGE_ERROR_IO, true, "Unable to open local file: %s", strerror(errno));
        return MTP_BRIDGE_ERROR_IO;
    }

    struct stat file_stat;
    uint64_t offset = 0;
    if (use_partial && fstat(descriptor, &file_stat) == 0 && file_stat.st_size > 0) {
        offset = (uint64_t)file_stat.st_size;
        if (offset > expected_size) {
            if (ftruncate(descriptor, 0) != 0) {
                int saved_errno = errno;
                close(descriptor);
                set_error_message(error, MTP_BRIDGE_ERROR_IO, true, "Unable to reset partial file: %s", strerror(saved_errno));
                return MTP_BRIDGE_ERROR_IO;
            }
            offset = 0;
        }
    }
    if (out_resumed_from != NULL) {
        *out_resumed_from = offset;
    }

    if (offset == expected_size && expected_size > 0) {
        close(descriptor);
        if (progress != NULL) {
            (void)progress(expected_size, expected_size, progress_context);
        }
        return MTP_BRIDGE_OK;
    }

    if (lseek(descriptor, (off_t)offset, SEEK_SET) < 0) {
        int saved_errno = errno;
        close(descriptor);
        set_error_message(error, MTP_BRIDGE_ERROR_IO, true, "Unable to seek partial file: %s", strerror(saved_errno));
        return MTP_BRIDGE_ERROR_IO;
    }

    pthread_mutex_lock(&g_mtp_mutex);
    bool requires_full_download = !use_partial;
    if (use_partial) {
        uint32_t effective_chunk = chunk_bytes == 0 ? (8U * 1024U * 1024U) : chunk_bytes;
        while (offset < expected_size) {
            if (cancellation_requested(cancel_token)) {
                close(descriptor);
                set_error_message(error, MTP_BRIDGE_ERROR_CANCELLED, false, "Transfer cancelled");
                pthread_mutex_unlock(&g_mtp_mutex);
                return MTP_BRIDGE_ERROR_CANCELLED;
            }
            uint64_t remaining = expected_size - offset;
            uint32_t requested = remaining < effective_chunk ? (uint32_t)remaining : effective_chunk;
            unsigned char *data = NULL;
            unsigned int received = 0;
            int result = LIBMTP_GetPartialObject(
                session->device,
                object_id,
                offset,
                requested,
                &data,
                &received
            );
            if (result != 0) {
                // Some Android implementations advertise GetPartialObject but fail every
                // request. Disable it for this session and safely restart only this file.
                LIBMTP_FreeMemory(data);
                LIBMTP_Clear_Errorstack(session->device);
                session->supports_partial_download = false;
                if (ftruncate(descriptor, 0) != 0 || lseek(descriptor, 0, SEEK_SET) < 0) {
                    int saved_errno = errno;
                    close(descriptor);
                    set_error_message(error, MTP_BRIDGE_ERROR_IO, true, "Unable to restart the local file: %s", strerror(saved_errno));
                    pthread_mutex_unlock(&g_mtp_mutex);
                    return MTP_BRIDGE_ERROR_IO;
                }
                if (out_resumed_from != NULL) {
                    *out_resumed_from = 0;
                }
                requires_full_download = true;
                break;
            }
            if (received == 0 || data == NULL) {
                LIBMTP_FreeMemory(data);
                close(descriptor);
                set_error_message(error, MTP_BRIDGE_ERROR_IO, true, "The device returned an empty chunk before the file was complete");
                pthread_mutex_unlock(&g_mtp_mutex);
                return MTP_BRIDGE_ERROR_IO;
            }
            if (received > requested || (uint64_t)received > remaining) {
                LIBMTP_FreeMemory(data);
                close(descriptor);
                set_error_message(error, MTP_BRIDGE_ERROR_PROTOCOL, true, "The device returned more data than requested");
                pthread_mutex_unlock(&g_mtp_mutex);
                return MTP_BRIDGE_ERROR_PROTOCOL;
            }
            if (write_all(descriptor, data, received) != 0) {
                int saved_errno = errno;
                LIBMTP_FreeMemory(data);
                close(descriptor);
                set_error_message(error, MTP_BRIDGE_ERROR_IO, true, "Unable to write the local file: %s", strerror(saved_errno));
                pthread_mutex_unlock(&g_mtp_mutex);
                return MTP_BRIDGE_ERROR_IO;
            }
            LIBMTP_FreeMemory(data);
            offset += received;
            if (progress != NULL && progress(offset, expected_size, progress_context) != 0) {
                if (cancel_token != NULL) {
                    atomic_store_explicit(&cancel_token->requested, true, memory_order_relaxed);
                }
                close(descriptor);
                set_error_message(error, MTP_BRIDGE_ERROR_CANCELLED, false, "Transfer cancelled");
                pthread_mutex_unlock(&g_mtp_mutex);
                return MTP_BRIDGE_ERROR_CANCELLED;
            }
        }
    }

    if (requires_full_download) {
        progress_adapter_t adapter = {
            .cancel_token = cancel_token,
            .callback = progress,
            .context = progress_context,
            .base = 0,
            .total_override = expected_size
        };
        int result = LIBMTP_Get_File_To_File_Descriptor(
            session->device,
            object_id,
            descriptor,
            progress_callback,
            &adapter
        );
        if (result != 0) {
            close(descriptor);
            if (cancellation_requested(cancel_token)) {
                set_error_message(error, MTP_BRIDGE_ERROR_CANCELLED, false, "Transfer cancelled");
                LIBMTP_Clear_Errorstack(session->device);
                pthread_mutex_unlock(&g_mtp_mutex);
                return MTP_BRIDGE_ERROR_CANCELLED;
            }
            set_device_error(session, error, MTP_BRIDGE_ERROR_PROTOCOL, true, "Unable to download the MTP object");
            pthread_mutex_unlock(&g_mtp_mutex);
            return error != NULL ? error->code : MTP_BRIDGE_ERROR_PROTOCOL;
        }
    }

    // close(2) completes the userspace write and reports buffered-write errors.
    // An unconditional fsync(2) here made every download appear stalled at 100%
    // while macOS forced the entire file to durable storage. Swift verifies the
    // resulting size; normal downloads then atomically place their partial file,
    // while Finder file promises already write to the exact destination URL.
    if (close(descriptor) != 0) {
        int saved_errno = errno;
        set_error_message(error, MTP_BRIDGE_ERROR_IO, true, "Unable to close the local file: %s", strerror(saved_errno));
        pthread_mutex_unlock(&g_mtp_mutex);
        return MTP_BRIDGE_ERROR_IO;
    }
    pthread_mutex_unlock(&g_mtp_mutex);
    return MTP_BRIDGE_OK;
}

int32_t mtp_bridge_upload_file_atomic(
    mtp_bridge_session_t *session,
    const char *local_path,
    uint32_t storage_id,
    uint32_t parent_object_id,
    const char *temporary_name,
    const char *final_name,
    uint32_t existing_object_id,
    const char *backup_name,
    mtp_bridge_cancel_t *cancel_token,
    mtp_bridge_progress_fn progress,
    void *progress_context,
    uint32_t *out_object_id,
    mtp_bridge_error_t *error
) {
    prepare_error(error);
    if (out_object_id != NULL) {
        *out_object_id = 0;
    }
    if (session == NULL || session->device == NULL || local_path == NULL || temporary_name == NULL ||
        final_name == NULL || out_object_id == NULL || (existing_object_id != 0 && backup_name == NULL)) {
        set_error_message(error, MTP_BRIDGE_ERROR_INVALID_ARGUMENT, false, "Upload arguments and open session are required");
        return MTP_BRIDGE_ERROR_INVALID_ARGUMENT;
    }
    if (cancellation_requested(cancel_token)) {
        set_error_message(error, MTP_BRIDGE_ERROR_CANCELLED, false, "Transfer cancelled");
        return MTP_BRIDGE_ERROR_CANCELLED;
    }

    int descriptor = open(local_path, O_RDONLY);
    if (descriptor < 0) {
        set_error_message(error, MTP_BRIDGE_ERROR_IO, false, "Unable to open local file: %s", strerror(errno));
        return MTP_BRIDGE_ERROR_IO;
    }
    struct stat file_stat;
    if (fstat(descriptor, &file_stat) != 0 || file_stat.st_size < 0) {
        int saved_errno = errno;
        close(descriptor);
        set_error_message(error, MTP_BRIDGE_ERROR_IO, false, "Unable to inspect local file: %s", strerror(saved_errno));
        return MTP_BRIDGE_ERROR_IO;
    }
    uint64_t local_size = (uint64_t)file_stat.st_size;

    LIBMTP_file_t *metadata = LIBMTP_new_file_t();
    if (metadata == NULL) {
        close(descriptor);
        set_error_message(error, MTP_BRIDGE_ERROR_MEMORY, false, "Unable to allocate upload metadata");
        return MTP_BRIDGE_ERROR_MEMORY;
    }
    metadata->filename = copy_string(temporary_name);
    metadata->filesize = local_size;
    metadata->modificationdate = file_stat.st_mtime;
    metadata->filetype = LIBMTP_FILETYPE_UNKNOWN;
    /*
     * Keep the MTP root sentinel explicit. libmtp accepts 0 for the root in
     * its public API, but its legacy SendObjectInfo path forwards that 0 as
     * an object handle. Android treats handle 0 as invalid there and expects
     * MTP_PARENT_ROOT (0xffffffff). Passing the explicit sentinel works for
     * both SendObjectInfo and SendObjectPropList paths.
     */
    metadata->parent_id = parent_object_id == MTP_BRIDGE_ROOT_OBJECT_ID
        ? MTP_BRIDGE_ROOT_OBJECT_ID
        : parent_object_id;
    metadata->storage_id = storage_id;
    if (metadata->filename == NULL) {
        LIBMTP_destroy_file_t(metadata);
        close(descriptor);
        set_error_message(error, MTP_BRIDGE_ERROR_MEMORY, false, "Unable to copy upload metadata");
        return MTP_BRIDGE_ERROR_MEMORY;
    }

    progress_adapter_t adapter = {
        .cancel_token = cancel_token,
        .callback = progress,
        .context = progress_context,
        .base = 0,
        .total_override = local_size
    };

    pthread_mutex_lock(&g_mtp_mutex);
    int send_result = LIBMTP_Send_File_From_File_Descriptor(
        session->device,
        descriptor,
        metadata,
        progress_callback,
        &adapter
    );
    close(descriptor);
    uint32_t uploaded_id = metadata->item_id;
    LIBMTP_destroy_file_t(metadata);

    if (send_result != 0) {
        const bool was_cancelled = cancellation_requested(cancel_token);
        if (was_cancelled) {
            LIBMTP_Clear_Errorstack(session->device);
            set_error_message(error, MTP_BRIDGE_ERROR_CANCELLED, false, "Transfer cancelled");
        } else {
            set_device_error(session, error, MTP_BRIDGE_ERROR_PROTOCOL, true, "Unable to upload the MTP object");
        }
        const int32_t saved_code = was_cancelled
            ? MTP_BRIDGE_ERROR_CANCELLED
            : (error != NULL ? error->code : MTP_BRIDGE_ERROR_PROTOCOL);
        if (uploaded_id != 0) {
            (void)LIBMTP_Delete_Object(session->device, uploaded_id);
            LIBMTP_Clear_Errorstack(session->device);
        }
        pthread_mutex_unlock(&g_mtp_mutex);
        return saved_code;
    }
    if (uploaded_id == 0) {
        set_error_message(error, MTP_BRIDGE_ERROR_VERIFICATION, true, "The device accepted the upload but returned no object identifier");
        pthread_mutex_unlock(&g_mtp_mutex);
        return MTP_BRIDGE_ERROR_VERIFICATION;
    }

    LIBMTP_file_t *verification = LIBMTP_Get_Filemetadata(session->device, uploaded_id);
    if (verification == NULL || verification->filesize != local_size) {
        if (verification != NULL) {
            verification->next = NULL;
            LIBMTP_destroy_file_t(verification);
        }
        (void)LIBMTP_Delete_Object(session->device, uploaded_id);
        LIBMTP_Clear_Errorstack(session->device);
        set_error_message(
            error,
            MTP_BRIDGE_ERROR_VERIFICATION,
            true,
            "Upload verification failed (local: %llu bytes)",
            (unsigned long long)local_size
        );
        pthread_mutex_unlock(&g_mtp_mutex);
        return MTP_BRIDGE_ERROR_VERIFICATION;
    }
    verification->next = NULL;
    LIBMTP_destroy_file_t(verification);

    bool existing_was_renamed = false;
    if (existing_object_id != 0) {
        char *mutable_backup = copy_string(backup_name);
        const bool backup_name_allocated = mutable_backup != NULL;
        const int backup_result = backup_name_allocated
            ? LIBMTP_Set_Object_Filename(session->device, existing_object_id, mutable_backup)
            : -1;
        free(mutable_backup);
        if (backup_result != 0) {
            if (!backup_name_allocated) {
                set_error_message(error, MTP_BRIDGE_ERROR_MEMORY, false, "Unable to allocate the backup filename");
            } else {
                set_device_error(session, error, MTP_BRIDGE_ERROR_PROTOCOL, true, "Unable to preserve the existing destination before replacement");
            }
            const int32_t saved_code = error != NULL ? error->code : MTP_BRIDGE_ERROR_PROTOCOL;
            (void)LIBMTP_Delete_Object(session->device, uploaded_id);
            LIBMTP_Clear_Errorstack(session->device);
            pthread_mutex_unlock(&g_mtp_mutex);
            return saved_code;
        }
        existing_was_renamed = true;
    }

    char *mutable_final = copy_string(final_name);
    const bool final_name_allocated = mutable_final != NULL;
    const int rename_result = final_name_allocated
        ? LIBMTP_Set_Object_Filename(session->device, uploaded_id, mutable_final)
        : -1;
    free(mutable_final);
    if (rename_result != 0) {
        if (!final_name_allocated) {
            set_error_message(error, MTP_BRIDGE_ERROR_MEMORY, false, "Unable to allocate the final filename");
        } else {
            set_device_error(session, error, MTP_BRIDGE_ERROR_PROTOCOL, true, "Unable to finalize the uploaded filename");
        }
        const int32_t saved_code = error != NULL ? error->code : MTP_BRIDGE_ERROR_PROTOCOL;
        if (existing_was_renamed) {
            char *restore_name = copy_string(final_name);
            if (restore_name != NULL) {
                (void)LIBMTP_Set_Object_Filename(session->device, existing_object_id, restore_name);
                free(restore_name);
            }
        }
        (void)LIBMTP_Delete_Object(session->device, uploaded_id);
        LIBMTP_Clear_Errorstack(session->device);
        pthread_mutex_unlock(&g_mtp_mutex);
        return saved_code;
    }

    if (existing_was_renamed) {
        if (LIBMTP_Delete_Object(session->device, existing_object_id) != 0) {
            // The new object is already valid. Keep success and leave the hidden backup
            // rather than reporting failure and encouraging a duplicate retry.
            LIBMTP_Clear_Errorstack(session->device);
        }
    }

    *out_object_id = uploaded_id;
    pthread_mutex_unlock(&g_mtp_mutex);
    return MTP_BRIDGE_OK;
}
