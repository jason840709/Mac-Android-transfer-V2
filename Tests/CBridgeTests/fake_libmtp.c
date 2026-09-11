#define _POSIX_C_SOURCE 200809L

#include "libmtp.h"
#include "libusb.h"
#include "fake_libmtp.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_OBJECTS 64

typedef struct fake_object {
    bool active;
    uint32_t id;
    uint32_t parent_id;
    uint32_t storage_id;
    char *name;
    unsigned char *bytes;
    size_t size;
    time_t creation_time;
    time_t modification_time;
    LIBMTP_filetype_t type;
} fake_object_t;

static fake_object_t g_objects[MAX_OBJECTS];
static uint32_t g_next_id = 1000;
static LIBMTP_error_t *g_error = NULL;
static LIBMTP_devicestorage_t g_storage;
static LIBMTP_mtpdevice_t g_device;
static bool g_fail_partial_reads = false;
static bool g_usb_present = true;
static bool g_date_created_reported_supported = true;
static bool g_date_created_readable = true;
static LIBMTP_error_number_t g_detect_result = LIBMTP_ERROR_NONE;
static int g_detect_count = 1;
static uint32_t g_last_send_parent_id = 0;
static uint32_t g_last_create_folder_parent_id = 0;

struct libusb_context { int unused; };
struct libusb_device { int unused; };
static struct libusb_context g_libusb_context;
static struct libusb_device g_libusb_device;

static char *duplicate(const char *value) {
    return strdup(value != NULL ? value : "");
}

static void clear_object(fake_object_t *object) {
    if (object == NULL) {
        return;
    }
    free(object->name);
    free(object->bytes);
    memset(object, 0, sizeof(*object));
}

static fake_object_t *find_object(uint32_t id) {
    for (size_t index = 0; index < MAX_OBJECTS; index++) {
        if (g_objects[index].active && g_objects[index].id == id) {
            return &g_objects[index];
        }
    }
    return NULL;
}

static fake_object_t *allocate_object(uint32_t requested_id) {
    for (size_t index = 0; index < MAX_OBJECTS; index++) {
        if (!g_objects[index].active) {
            fake_object_t *object = &g_objects[index];
            memset(object, 0, sizeof(*object));
            object->active = true;
            object->id = requested_id != 0 ? requested_id : g_next_id++;
            return object;
        }
    }
    return NULL;
}

static LIBMTP_file_t *copy_metadata(const fake_object_t *object) {
    if (object == NULL) {
        return NULL;
    }
    LIBMTP_file_t *metadata = calloc(1, sizeof(*metadata));
    if (metadata == NULL) {
        return NULL;
    }
    metadata->item_id = object->id;
    metadata->parent_id = object->parent_id;
    metadata->storage_id = object->storage_id;
    metadata->filename = duplicate(object->name);
    metadata->filesize = object->size;
    metadata->modificationdate = object->modification_time;
    metadata->filetype = object->type;
    return metadata;
}

void fake_mtp_reset(void) {
    for (size_t index = 0; index < MAX_OBJECTS; index++) {
        clear_object(&g_objects[index]);
    }
    g_next_id = 1000;
    g_error = NULL;
    g_fail_partial_reads = false;
    g_usb_present = true;
    g_date_created_reported_supported = true;
    g_date_created_readable = true;
    g_detect_result = LIBMTP_ERROR_NONE;
    g_detect_count = 1;
    g_last_send_parent_id = 0;
    g_last_create_folder_parent_id = 0;
    memset(&g_storage, 0, sizeof(g_storage));
    g_storage.id = 1;
    g_storage.AccessCapability = 0;
    g_storage.MaxCapacity = 1024ULL * 1024ULL * 1024ULL;
    g_storage.FreeSpaceInBytes = 768ULL * 1024ULL * 1024ULL;
    g_storage.StorageDescription = "Internal storage";
    g_storage.VolumeIdentifier = "FAKE-VOLUME";
    memset(&g_device, 0, sizeof(g_device));
    g_device.storage = &g_storage;
}

void fake_mtp_set_partial_failure(bool enabled) {
    g_fail_partial_reads = enabled;
}

void fake_mtp_set_usb_present(bool present) {
    g_usb_present = present;
}

void fake_mtp_set_date_created_supported(bool supported) {
    g_date_created_reported_supported = supported;
    g_date_created_readable = supported;
}

void fake_mtp_set_date_created_reported_supported(bool supported) {
    g_date_created_reported_supported = supported;
}

void fake_mtp_set_detect_result(LIBMTP_error_number_t result, int count) {
    g_detect_result = result;
    g_detect_count = count;
}

uint32_t fake_mtp_add_file(
    uint32_t requested_id,
    uint32_t storage_id,
    uint32_t parent_id,
    const char *name,
    const unsigned char *bytes,
    size_t size,
    time_t modification_time
) {
    return fake_mtp_add_file_with_dates(
        requested_id,
        storage_id,
        parent_id,
        name,
        bytes,
        size,
        0,
        modification_time
    );
}

uint32_t fake_mtp_add_file_with_dates(
    uint32_t requested_id,
    uint32_t storage_id,
    uint32_t parent_id,
    const char *name,
    const unsigned char *bytes,
    size_t size,
    time_t creation_time,
    time_t modification_time
) {
    fake_object_t *object = allocate_object(requested_id);
    if (object == NULL) {
        return 0;
    }
    object->storage_id = storage_id;
    object->parent_id = parent_id;
    object->name = duplicate(name);
    object->size = size;
    object->creation_time = creation_time;
    object->modification_time = modification_time;
    object->type = LIBMTP_FILETYPE_UNKNOWN;
    if (size > 0) {
        object->bytes = malloc(size);
        if (object->bytes == NULL) {
            clear_object(object);
            return 0;
        }
        memcpy(object->bytes, bytes, size);
    }
    return object->id;
}

bool fake_mtp_object_exists(uint32_t object_id) {
    return find_object(object_id) != NULL;
}

uint32_t fake_mtp_find_object(uint32_t storage_id, uint32_t parent_id, const char *name) {
    for (size_t index = 0; index < MAX_OBJECTS; index++) {
        fake_object_t *object = &g_objects[index];
        if (object->active && object->storage_id == storage_id && object->parent_id == parent_id &&
            strcmp(object->name, name) == 0) {
            return object->id;
        }
    }
    return 0;
}

size_t fake_mtp_object_size(uint32_t object_id) {
    fake_object_t *object = find_object(object_id);
    return object != NULL ? object->size : 0;
}

const unsigned char *fake_mtp_object_bytes(uint32_t object_id) {
    fake_object_t *object = find_object(object_id);
    return object != NULL ? object->bytes : NULL;
}

const char *fake_mtp_object_name(uint32_t object_id) {
    fake_object_t *object = find_object(object_id);
    return object != NULL ? object->name : NULL;
}

int libusb_init(libusb_context **context) {
    if (context != NULL) {
        *context = &g_libusb_context;
    }
    return LIBUSB_SUCCESS;
}

void libusb_exit(libusb_context *context) {
    (void)context;
}

ssize_t libusb_get_device_list(libusb_context *context, libusb_device ***list) {
    (void)context;
    if (list == NULL) {
        return -1;
    }
    size_t count = g_usb_present ? 1U : 0U;
    *list = calloc(count + 1U, sizeof(**list));
    if (*list == NULL) {
        return -1;
    }
    if (g_usb_present) {
        (*list)[0] = &g_libusb_device;
    }
    return (ssize_t)count;
}

void libusb_free_device_list(libusb_device **list, int unref_devices) {
    (void)unref_devices;
    free(list);
}

uint8_t libusb_get_bus_number(libusb_device *device) {
    (void)device;
    return 7;
}

uint8_t libusb_get_device_address(libusb_device *device) {
    (void)device;
    return 3;
}

int libusb_get_device_descriptor(
    libusb_device *device,
    struct libusb_device_descriptor *descriptor
) {
    (void)device;
    if (descriptor == NULL) {
        return -1;
    }
    memset(descriptor, 0, sizeof(*descriptor));
    descriptor->idVendor = 0x18D1;
    descriptor->idProduct = 0x4EE1;
    return LIBUSB_SUCCESS;
}

void LIBMTP_Init(void) {
    // Tests reset the fake explicitly so pthread_once does not erase fixtures.
}

LIBMTP_error_number_t LIBMTP_Detect_Raw_Devices(LIBMTP_raw_device_t **devices, int *count) {
    if (devices == NULL || count == NULL) {
        return LIBMTP_ERROR_GENERAL;
    }
    *devices = NULL;
    *count = 0;
    if (g_detect_result != LIBMTP_ERROR_NONE) {
        return g_detect_result;
    }
    if (g_detect_count <= 0) {
        return LIBMTP_ERROR_NONE;
    }
    *devices = calloc((size_t)g_detect_count, sizeof(**devices));
    if (*devices == NULL) {
        return LIBMTP_ERROR_MEMORY_ALLOCATION;
    }
    for (int index = 0; index < g_detect_count; index++) {
        (*devices)[index].bus_location = 7;
        (*devices)[index].devnum = (uint8_t)(3 + index);
        (*devices)[index].device_entry.vendor = "Fake Vendor";
        (*devices)[index].device_entry.product = "Fake Android";
        (*devices)[index].device_entry.vendor_id = 0x18D1;
        (*devices)[index].device_entry.product_id = 0x4EE1;
    }
    *count = g_detect_count;
    return LIBMTP_ERROR_NONE;
}

LIBMTP_mtpdevice_t *LIBMTP_Open_Raw_Device_Uncached(LIBMTP_raw_device_t *device) {
    if (device == NULL || device->bus_location != 7 || device->devnum != 3) {
        return NULL;
    }
    return &g_device;
}

void LIBMTP_Release_Device(LIBMTP_mtpdevice_t *device) {
    (void)device;
}

int LIBMTP_Check_Capability(LIBMTP_mtpdevice_t *device, LIBMTP_devicecap_t capability) {
    (void)device;
    return capability == LIBMTP_DEVICECAP_GetPartialObject || capability == LIBMTP_DEVICECAP_MoveObject;
}

char *LIBMTP_Get_Manufacturername(LIBMTP_mtpdevice_t *device) {
    (void)device;
    return duplicate("Fake Vendor");
}

char *LIBMTP_Get_Modelname(LIBMTP_mtpdevice_t *device) {
    (void)device;
    return duplicate("Fake Android");
}

char *LIBMTP_Get_Serialnumber(LIBMTP_mtpdevice_t *device) {
    (void)device;
    return duplicate("FAKE-SERIAL");
}

char *LIBMTP_Get_Friendlyname(LIBMTP_mtpdevice_t *device) {
    (void)device;
    return duplicate("Test Phone");
}

char *LIBMTP_Get_Deviceversion(LIBMTP_mtpdevice_t *device) {
    (void)device;
    return duplicate("1.0");
}

void LIBMTP_FreeMemory(void *pointer) {
    free(pointer);
}

LIBMTP_error_t *LIBMTP_Get_Errorstack(LIBMTP_mtpdevice_t *device) {
    (void)device;
    return g_error;
}

void LIBMTP_Clear_Errorstack(LIBMTP_mtpdevice_t *device) {
    (void)device;
    g_error = NULL;
}

int LIBMTP_Get_Storage(LIBMTP_mtpdevice_t *device, int sort) {
    (void)sort;
    device->storage = &g_storage;
    return 0;
}

LIBMTP_file_t *LIBMTP_Get_Files_And_Folders(
    LIBMTP_mtpdevice_t *device,
    uint32_t storage_id,
    uint32_t parent_id
) {
    (void)device;
    LIBMTP_file_t *head = NULL;
    LIBMTP_file_t **tail = &head;
    for (size_t index = 0; index < MAX_OBJECTS; index++) {
        fake_object_t *object = &g_objects[index];
        if (!object->active || object->storage_id != storage_id || object->parent_id != parent_id) {
            continue;
        }
        LIBMTP_file_t *copy = copy_metadata(object);
        if (copy == NULL) {
            break;
        }
        *tail = copy;
        tail = &copy->next;
    }
    return head;
}

int LIBMTP_Is_Property_Supported(
    LIBMTP_mtpdevice_t *device,
    LIBMTP_property_t property,
    LIBMTP_filetype_t file_type
) {
    (void)device;
    (void)file_type;
    return property == LIBMTP_PROPERTY_DateCreated && g_date_created_reported_supported ? 1 : 0;
}

char *LIBMTP_Get_String_From_Object(
    LIBMTP_mtpdevice_t *device,
    uint32_t object_id,
    LIBMTP_property_t property
) {
    (void)device;
    if (property != LIBMTP_PROPERTY_DateCreated || !g_date_created_readable) {
        return NULL;
    }
    fake_object_t *object = find_object(object_id);
    if (object == NULL || object->creation_time <= 0) {
        return NULL;
    }
    struct tm utc_time;
    if (gmtime_r(&object->creation_time, &utc_time) == NULL) {
        return NULL;
    }
    char buffer[32];
    if (strftime(buffer, sizeof(buffer), "%Y%m%dT%H%M%SZ", &utc_time) == 0) {
        return NULL;
    }
    return duplicate(buffer);
}

LIBMTP_file_t *LIBMTP_Get_Filemetadata(LIBMTP_mtpdevice_t *device, uint32_t object_id) {
    (void)device;
    return copy_metadata(find_object(object_id));
}

LIBMTP_file_t *LIBMTP_new_file_t(void) {
    return calloc(1, sizeof(LIBMTP_file_t));
}

void LIBMTP_destroy_file_t(LIBMTP_file_t *file) {
    if (file == NULL) {
        return;
    }
    free(file->filename);
    free(file);
}

uint32_t LIBMTP_Create_Folder(
    LIBMTP_mtpdevice_t *device,
    char *name,
    uint32_t parent_id,
    uint32_t storage_id
) {
    (void)device;
    g_last_create_folder_parent_id = parent_id;
    /* Android's MTP server rejects object handle 0 for a root association. */
    if (parent_id == 0) {
        return 0;
    }
    fake_object_t *object = allocate_object(0);
    if (object == NULL) {
        return 0;
    }
    object->storage_id = storage_id;
    object->parent_id = parent_id;
    object->name = duplicate(name);
    object->type = LIBMTP_FILETYPE_FOLDER;
    return object->id;
}

int LIBMTP_Set_Object_Filename(LIBMTP_mtpdevice_t *device, uint32_t object_id, char *name) {
    (void)device;
    fake_object_t *object = find_object(object_id);
    if (object == NULL || name == NULL) {
        return -1;
    }
    char *copy = duplicate(name);
    if (copy == NULL) {
        return -1;
    }
    free(object->name);
    object->name = copy;
    return 0;
}

int LIBMTP_Delete_Object(LIBMTP_mtpdevice_t *device, uint32_t object_id) {
    (void)device;
    fake_object_t *object = find_object(object_id);
    if (object == NULL) {
        return -1;
    }
    clear_object(object);
    return 0;
}

int LIBMTP_GetPartialObject(
    LIBMTP_mtpdevice_t *device,
    uint32_t object_id,
    uint64_t offset,
    uint32_t requested,
    unsigned char **data,
    unsigned int *received
) {
    (void)device;
    if (g_fail_partial_reads) {
        return -1;
    }
    fake_object_t *object = find_object(object_id);
    if (object == NULL || data == NULL || received == NULL || offset > object->size) {
        return -1;
    }
    size_t available = object->size - (size_t)offset;
    size_t count = available < requested ? available : requested;
    *data = count > 0 ? malloc(count) : NULL;
    if (count > 0 && *data == NULL) {
        return -1;
    }
    if (count > 0) {
        memcpy(*data, object->bytes + offset, count);
    }
    *received = (unsigned int)count;
    return 0;
}


uint32_t fake_mtp_last_send_parent_id(void) {
    return g_last_send_parent_id;
}

uint32_t fake_mtp_last_create_folder_parent_id(void) {
    return g_last_create_folder_parent_id;
}
int LIBMTP_Get_File_To_File_Descriptor(
    LIBMTP_mtpdevice_t *device,
    uint32_t object_id,
    int descriptor,
    LIBMTP_progressfunc_t progress,
    void const * const data
) {
    (void)device;
    fake_object_t *object = find_object(object_id);
    if (object == NULL) {
        return -1;
    }
    size_t written = 0;
    while (written < object->size) {
        ssize_t result = write(descriptor, object->bytes + written, object->size - written);
        if (result <= 0) {
            return -1;
        }
        written += (size_t)result;
    }
    return progress != NULL && progress(object->size, object->size, data) != 0 ? -1 : 0;
}

int LIBMTP_Send_File_From_File_Descriptor(
    LIBMTP_mtpdevice_t *device,
    int descriptor,
    LIBMTP_file_t *metadata,
    LIBMTP_progressfunc_t progress,
    void const * const data
) {
    (void)device;
    if (metadata == NULL || metadata->filename == NULL) {
        return -1;
    }
    fake_object_t *object = allocate_object(0);
    if (object == NULL) {
        return -1;
    }
    g_last_send_parent_id = metadata->parent_id;
    object->storage_id = metadata->storage_id;
    object->parent_id = metadata->parent_id;
    object->name = duplicate(metadata->filename);
    object->size = (size_t)metadata->filesize;
    object->modification_time = metadata->modificationdate;
    object->type = metadata->filetype;
    if (object->size > 0) {
        object->bytes = malloc(object->size);
        if (object->bytes == NULL) {
            clear_object(object);
            return -1;
        }
    }

    size_t read_count = 0;
    while (read_count < object->size) {
        ssize_t result = read(descriptor, object->bytes + read_count, object->size - read_count);
        if (result <= 0) {
            clear_object(object);
            return -1;
        }
        read_count += (size_t)result;
        if (progress != NULL && progress(read_count, object->size, data) != 0) {
            metadata->item_id = object->id;
            return -1;
        }
    }
    metadata->item_id = object->id;
    return 0;
}
