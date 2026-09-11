#ifndef MTP_BRIDGE_H
#define MTP_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MTP_BRIDGE_ROOT_OBJECT_ID UINT32_MAX

typedef struct mtp_bridge_session mtp_bridge_session_t;
typedef struct mtp_bridge_cancel mtp_bridge_cancel_t;

typedef enum mtp_bridge_status {
    MTP_BRIDGE_OK = 0,
    MTP_BRIDGE_ERROR_INVALID_ARGUMENT = 1,
    MTP_BRIDGE_ERROR_NO_DEVICE = 2,
    MTP_BRIDGE_ERROR_CONNECTING = 3,
    MTP_BRIDGE_ERROR_USB = 4,
    MTP_BRIDGE_ERROR_PROTOCOL = 5,
    MTP_BRIDGE_ERROR_IO = 6,
    MTP_BRIDGE_ERROR_STORAGE_FULL = 7,
    MTP_BRIDGE_ERROR_CANCELLED = 8,
    MTP_BRIDGE_ERROR_UNSUPPORTED = 9,
    MTP_BRIDGE_ERROR_NOT_FOUND = 10,
    MTP_BRIDGE_ERROR_VERIFICATION = 11,
    MTP_BRIDGE_ERROR_MEMORY = 12,
    MTP_BRIDGE_ERROR_LIBRARY = 13
} mtp_bridge_status_t;

typedef struct mtp_bridge_error {
    int32_t code;
    bool retryable;
    char *message;
} mtp_bridge_error_t;

typedef struct mtp_bridge_raw_device {
    uint32_t bus_location;
    uint8_t device_number;
    uint16_t vendor_id;
    uint16_t product_id;
    char *vendor;
    char *product;
} mtp_bridge_raw_device_t;

typedef struct mtp_bridge_device_list {
    mtp_bridge_raw_device_t *items;
    size_t count;
} mtp_bridge_device_list_t;

typedef struct mtp_bridge_device_info {
    char *manufacturer;
    char *model;
    char *serial_number;
    char *friendly_name;
    char *device_version;
    bool supports_partial_download;
    bool supports_partial_upload;
    bool supports_move;
} mtp_bridge_device_info_t;

typedef struct mtp_bridge_storage {
    uint32_t storage_id;
    char *name;
    char *volume_identifier;
    uint64_t capacity;
    uint64_t free_space;
    bool read_only;
} mtp_bridge_storage_t;

typedef struct mtp_bridge_storage_list {
    mtp_bridge_storage_t *items;
    size_t count;
} mtp_bridge_storage_list_t;

typedef struct mtp_bridge_object {
    uint32_t object_id;
    uint32_t parent_id;
    uint32_t storage_id;
    char *name;
    uint64_t size;
    int64_t creation_time;
    int64_t modification_time;
    int32_t file_type;
    bool is_folder;
} mtp_bridge_object_t;

typedef struct mtp_bridge_object_list {
    mtp_bridge_object_t *items;
    size_t count;
} mtp_bridge_object_list_t;

typedef int (*mtp_bridge_progress_fn)(
    uint64_t completed_bytes,
    uint64_t total_bytes,
    void *context
);

void mtp_bridge_error_init(mtp_bridge_error_t *error);
void mtp_bridge_error_clear(mtp_bridge_error_t *error);

mtp_bridge_cancel_t *mtp_bridge_cancel_create(void);
void mtp_bridge_cancel_destroy(mtp_bridge_cancel_t *token);
void mtp_bridge_cancel_request(mtp_bridge_cancel_t *token);
void mtp_bridge_cancel_reset(mtp_bridge_cancel_t *token);
bool mtp_bridge_cancel_is_requested(const mtp_bridge_cancel_t *token);

int32_t mtp_bridge_detect_devices(
    mtp_bridge_device_list_t *out_list,
    mtp_bridge_error_t *error
);
void mtp_bridge_device_list_clear(mtp_bridge_device_list_t *list);

/// Performs a lightweight USB enumeration without opening or claiming the MTP
/// interface. This remains responsive while a transfer owns the MTP session.
int32_t mtp_bridge_is_usb_device_present(
    uint32_t bus_location,
    uint8_t device_number,
    uint16_t vendor_id,
    uint16_t product_id,
    bool *out_present,
    mtp_bridge_error_t *error
);

mtp_bridge_session_t *mtp_bridge_open_device(
    uint32_t bus_location,
    uint8_t device_number,
    mtp_bridge_error_t *error
);
void mtp_bridge_close_device(mtp_bridge_session_t *session);

int32_t mtp_bridge_get_device_info(
    mtp_bridge_session_t *session,
    mtp_bridge_device_info_t *out_info,
    mtp_bridge_error_t *error
);
void mtp_bridge_device_info_clear(mtp_bridge_device_info_t *info);

int32_t mtp_bridge_get_storages(
    mtp_bridge_session_t *session,
    mtp_bridge_storage_list_t *out_list,
    mtp_bridge_error_t *error
);
void mtp_bridge_storage_list_clear(mtp_bridge_storage_list_t *list);

int32_t mtp_bridge_list_children(
    mtp_bridge_session_t *session,
    uint32_t storage_id,
    uint32_t parent_object_id,
    mtp_bridge_object_list_t *out_list,
    mtp_bridge_error_t *error
);
void mtp_bridge_object_list_clear(mtp_bridge_object_list_t *list);

/// Reads the optional MTP DateCreated property for one object. A successful
/// result of zero means the device does not expose a usable creation date.
int32_t mtp_bridge_get_object_creation_time(
    mtp_bridge_session_t *session,
    uint32_t object_id,
    int32_t file_type,
    int64_t *out_creation_time,
    mtp_bridge_error_t *error
);

int32_t mtp_bridge_create_folder(
    mtp_bridge_session_t *session,
    const char *name,
    uint32_t storage_id,
    uint32_t parent_object_id,
    uint32_t *out_object_id,
    mtp_bridge_error_t *error
);

int32_t mtp_bridge_rename_object(
    mtp_bridge_session_t *session,
    uint32_t object_id,
    const char *new_name,
    mtp_bridge_error_t *error
);

int32_t mtp_bridge_delete_object(
    mtp_bridge_session_t *session,
    uint32_t object_id,
    mtp_bridge_error_t *error
);

/// Downloads into local_path. When partial reads are supported, an existing file
/// is resumed from its current size. The caller should pass a temporary path and
/// atomically move it into place only after success.
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
);

/// Uploads a local file under a temporary remote name, verifies its size, then
/// swaps it into the final name. If existing_object_id is nonzero, the existing
/// object is first renamed to backup_name and restored if finalization fails.
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
);

#ifdef __cplusplus
}
#endif

#endif
