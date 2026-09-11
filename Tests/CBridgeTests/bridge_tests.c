#define _POSIX_C_SOURCE 200809L

#include "mtp_bridge.h"
#include "fake_libmtp.h"

#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char *temporary_path(const char *suffix) {
    size_t length = strlen(suffix) + 32;
    char *path = calloc(length, 1);
    assert(path != NULL);
    snprintf(path, length, "/tmp/mtpbridge-test-XXXXXX%s", suffix);
    size_t suffix_length = strlen(suffix);
    char *template_end = path + strlen(path) - suffix_length;
    memmove(template_end, template_end + suffix_length, suffix_length + 1);
    int descriptor = mkstemp(path);
    assert(descriptor >= 0);
    close(descriptor);
    return path;
}

static void write_file(const char *path, const unsigned char *bytes, size_t size) {
    int descriptor = open(path, O_WRONLY | O_TRUNC);
    assert(descriptor >= 0);
    size_t offset = 0;
    while (offset < size) {
        ssize_t result = write(descriptor, bytes + offset, size - offset);
        assert(result > 0);
        offset += (size_t)result;
    }
    assert(close(descriptor) == 0);
}

static unsigned char *read_file(const char *path, size_t *out_size) {
    struct stat stat_value;
    assert(stat(path, &stat_value) == 0);
    assert(stat_value.st_size >= 0);
    size_t size = (size_t)stat_value.st_size;
    unsigned char *bytes = size > 0 ? malloc(size) : NULL;
    int descriptor = open(path, O_RDONLY);
    assert(descriptor >= 0);
    size_t offset = 0;
    while (offset < size) {
        ssize_t result = read(descriptor, bytes + offset, size - offset);
        assert(result > 0);
        offset += (size_t)result;
    }
    close(descriptor);
    *out_size = size;
    return bytes;
}

static mtp_bridge_session_t *open_fake(void) {
    mtp_bridge_error_t error;
    mtp_bridge_error_init(&error);
    mtp_bridge_session_t *session = mtp_bridge_open_device(7, 3, &error);
    assert(session != NULL);
    assert(error.code == MTP_BRIDGE_OK);
    mtp_bridge_error_clear(&error);
    return session;
}

static void test_detection_and_listing(void) {
    fake_mtp_reset();
    const unsigned char sample[] = "hello";
    const time_t creation_time = 1700000000;
    uint32_t file_id = fake_mtp_add_file_with_dates(
        42,
        1,
        MTP_BRIDGE_ROOT_OBJECT_ID,
        "hello.txt",
        sample,
        5,
        creation_time,
        1700001000
    );
    assert(file_id == 42);

    mtp_bridge_error_t error;
    mtp_bridge_error_init(&error);
    mtp_bridge_device_list_t devices;
    assert(mtp_bridge_detect_devices(&devices, &error) == MTP_BRIDGE_OK);
    assert(devices.count == 1);
    assert(strcmp(devices.items[0].product, "Fake Android") == 0);
    mtp_bridge_device_list_clear(&devices);

    bool present = false;
    assert(mtp_bridge_is_usb_device_present(7, 3, 0x18D1, 0x4EE1, &present, &error) == MTP_BRIDGE_OK);
    assert(present);
    fake_mtp_set_usb_present(false);
    assert(mtp_bridge_is_usb_device_present(7, 3, 0x18D1, 0x4EE1, &present, &error) == MTP_BRIDGE_OK);
    assert(!present);
    fake_mtp_set_usb_present(true);

    mtp_bridge_session_t *session = open_fake();
    mtp_bridge_device_info_t info;
    assert(mtp_bridge_get_device_info(session, &info, &error) == MTP_BRIDGE_OK);
    assert(strcmp(info.friendly_name, "Test Phone") == 0);
    assert(info.supports_partial_download);
    mtp_bridge_device_info_clear(&info);

    mtp_bridge_storage_list_t storages;
    assert(mtp_bridge_get_storages(session, &storages, &error) == MTP_BRIDGE_OK);
    assert(storages.count == 1);
    assert(storages.items[0].storage_id == 1);
    mtp_bridge_storage_list_clear(&storages);

    mtp_bridge_object_list_t objects;
    assert(mtp_bridge_list_children(session, 1, MTP_BRIDGE_ROOT_OBJECT_ID, &objects, &error) == MTP_BRIDGE_OK);
    assert(objects.count == 1);
    assert(objects.items[0].object_id == 42);
    assert(strcmp(objects.items[0].name, "hello.txt") == 0);
    // Directory listing stays fast and does not query DateCreated per item.
    assert(objects.items[0].creation_time == 0);
    int32_t file_type = objects.items[0].file_type;
    mtp_bridge_object_list_clear(&objects);

    int64_t resolved_creation_time = 0;
    assert(mtp_bridge_get_object_creation_time(
        session,
        file_id,
        file_type,
        &resolved_creation_time,
        &error
    ) == MTP_BRIDGE_OK);
    assert(resolved_creation_time == creation_time);
    mtp_bridge_error_clear(&error);
    mtp_bridge_close_device(session);

    // Some Android devices incorrectly report DateCreated as unsupported while
    // still returning it. The bridge treats the capability response as a hint
    // and performs bounded optimistic reads.
    fake_mtp_set_date_created_reported_supported(false);
    session = open_fake();
    resolved_creation_time = 0;
    assert(mtp_bridge_get_object_creation_time(
        session,
        file_id,
        file_type,
        &resolved_creation_time,
        &error
    ) == MTP_BRIDGE_OK);
    assert(resolved_creation_time == creation_time);
    mtp_bridge_error_clear(&error);
    mtp_bridge_close_device(session);

    // Unsupported DateCreated remains a successful, explicit no-value result.
    fake_mtp_set_date_created_supported(false);
    session = open_fake();
    resolved_creation_time = -1;
    assert(mtp_bridge_get_object_creation_time(
        session,
        file_id,
        file_type,
        &resolved_creation_time,
        &error
    ) == MTP_BRIDGE_OK);
    assert(resolved_creation_time == 0);
    mtp_bridge_error_clear(&error);
    mtp_bridge_close_device(session);
}

static void test_resumable_download(void) {
    fake_mtp_reset();
    const unsigned char remote[] = "abcdefghijklmnopqrstuvwxyz";
    uint32_t object_id = fake_mtp_add_file(77, 1, MTP_BRIDGE_ROOT_OBJECT_ID, "alphabet.txt", remote, 26, 4321);
    assert(object_id == 77);

    char *path = temporary_path("");
    write_file(path, remote, 7);
    mtp_bridge_session_t *session = open_fake();
    mtp_bridge_cancel_t *cancel = mtp_bridge_cancel_create();
    assert(cancel != NULL);
    uint64_t resumed_from = 0;
    mtp_bridge_error_t error;
    mtp_bridge_error_init(&error);
    int32_t status = mtp_bridge_download_object(
        session,
        object_id,
        26,
        path,
        true,
        5,
        cancel,
        NULL,
        NULL,
        &resumed_from,
        &error
    );
    assert(status == MTP_BRIDGE_OK);
    assert(resumed_from == 7);

    size_t local_size = 0;
    unsigned char *local = read_file(path, &local_size);
    assert(local_size == 26);
    assert(memcmp(local, remote, 26) == 0);
    free(local);
    unlink(path);
    free(path);
    mtp_bridge_error_clear(&error);
    mtp_bridge_cancel_destroy(cancel);
    mtp_bridge_close_device(session);
}

static void test_nonresumable_download_truncates_exact_destination(void) {
    fake_mtp_reset();
    const unsigned char remote[] = "exact-file-promise";
    uint32_t object_id = fake_mtp_add_file(
        80,
        1,
        MTP_BRIDGE_ROOT_OBJECT_ID,
        "promise.txt",
        remote,
        sizeof(remote) - 1,
        4321
    );
    assert(object_id == 80);

    char *path = temporary_path("");
    const unsigned char stale[] = "stale bytes that must not survive";
    write_file(path, stale, sizeof(stale) - 1);
    mtp_bridge_session_t *session = open_fake();
    mtp_bridge_cancel_t *cancel = mtp_bridge_cancel_create();
    mtp_bridge_error_t error;
    mtp_bridge_error_init(&error);
    uint64_t resumed_from = UINT64_MAX;
    int32_t status = mtp_bridge_download_object(
        session,
        object_id,
        sizeof(remote) - 1,
        path,
        false,
        4,
        cancel,
        NULL,
        NULL,
        &resumed_from,
        &error
    );
    assert(status == MTP_BRIDGE_OK);
    assert(resumed_from == 0);

    size_t local_size = 0;
    unsigned char *local = read_file(path, &local_size);
    assert(local_size == sizeof(remote) - 1);
    assert(memcmp(local, remote, sizeof(remote) - 1) == 0);
    free(local);
    unlink(path);
    free(path);
    mtp_bridge_error_clear(&error);
    mtp_bridge_cancel_destroy(cancel);
    mtp_bridge_close_device(session);
}

static void test_partial_capability_failure_falls_back_to_full_download(void) {
    fake_mtp_reset();
    fake_mtp_set_partial_failure(true);
    const unsigned char remote[] = "fallback-download-payload";
    uint32_t object_id = fake_mtp_add_file(79, 1, MTP_BRIDGE_ROOT_OBJECT_ID, "fallback.bin", remote, sizeof(remote) - 1, 4321);
    assert(object_id == 79);

    char *path = temporary_path("");
    const unsigned char stale_partial[] = "stale";
    write_file(path, stale_partial, sizeof(stale_partial) - 1);
    mtp_bridge_session_t *session = open_fake();
    mtp_bridge_cancel_t *cancel = mtp_bridge_cancel_create();
    mtp_bridge_error_t error;
    mtp_bridge_error_init(&error);
    uint64_t resumed_from = UINT64_MAX;
    int32_t status = mtp_bridge_download_object(
        session,
        object_id,
        sizeof(remote) - 1,
        path,
        true,
        4,
        cancel,
        NULL,
        NULL,
        &resumed_from,
        &error
    );
    assert(status == MTP_BRIDGE_OK);
    assert(resumed_from == 0);

    size_t local_size = 0;
    unsigned char *local = read_file(path, &local_size);
    assert(local_size == sizeof(remote) - 1);
    assert(memcmp(local, remote, sizeof(remote) - 1) == 0);
    free(local);
    unlink(path);
    free(path);
    mtp_bridge_error_clear(&error);
    mtp_bridge_cancel_destroy(cancel);
    mtp_bridge_close_device(session);
}

static int cancel_after_first_chunk(uint64_t completed, uint64_t total, void *context) {
    (void)total;
    int *calls = context;
    (*calls)++;
    return completed > 0 ? 1 : 0;
}

static void test_cancelled_download_keeps_partial(void) {
    fake_mtp_reset();
    const unsigned char remote[] = "0123456789ABCDEFGHIJ";
    uint32_t object_id = fake_mtp_add_file(78, 1, MTP_BRIDGE_ROOT_OBJECT_ID, "cancel.bin", remote, 20, 4321);
    char *path = temporary_path("");
    mtp_bridge_session_t *session = open_fake();
    mtp_bridge_cancel_t *cancel = mtp_bridge_cancel_create();
    mtp_bridge_error_t error;
    mtp_bridge_error_init(&error);
    int calls = 0;
    int32_t status = mtp_bridge_download_object(
        session,
        object_id,
        20,
        path,
        true,
        4,
        cancel,
        cancel_after_first_chunk,
        &calls,
        NULL,
        &error
    );
    assert(status == MTP_BRIDGE_ERROR_CANCELLED);
    assert(calls == 1);
    struct stat stat_value;
    assert(stat(path, &stat_value) == 0);
    assert(stat_value.st_size == 4);
    unlink(path);
    free(path);
    mtp_bridge_error_clear(&error);
    mtp_bridge_cancel_destroy(cancel);
    mtp_bridge_close_device(session);
}


static void test_folder_creation_preserves_root_parent(void) {
    fake_mtp_reset();
    mtp_bridge_session_t *session = open_fake();
    mtp_bridge_error_t error;
    mtp_bridge_error_init(&error);

    uint32_t root_folder_id = 0;
    int32_t status = mtp_bridge_create_folder(
        session,
        "root-folder",
        1,
        MTP_BRIDGE_ROOT_OBJECT_ID,
        &root_folder_id,
        &error
    );
    assert(status == MTP_BRIDGE_OK);
    assert(root_folder_id != 0);
    assert(fake_mtp_last_create_folder_parent_id() == MTP_BRIDGE_ROOT_OBJECT_ID);
    assert(fake_mtp_find_object(1, MTP_BRIDGE_ROOT_OBJECT_ID, "root-folder") == root_folder_id);

    uint32_t nested_folder_id = 0;
    status = mtp_bridge_create_folder(
        session,
        "nested-folder",
        1,
        root_folder_id,
        &nested_folder_id,
        &error
    );
    assert(status == MTP_BRIDGE_OK);
    assert(nested_folder_id != 0);
    assert(fake_mtp_last_create_folder_parent_id() == root_folder_id);
    assert(fake_mtp_find_object(1, root_folder_id, "nested-folder") == nested_folder_id);

    mtp_bridge_error_clear(&error);
    mtp_bridge_close_device(session);
}

static void test_atomic_upload_replaces_existing(void) {
    fake_mtp_reset();
    const unsigned char old_bytes[] = "old";
    uint32_t old_id = fake_mtp_add_file(90, 1, 0, "target.bin", old_bytes, 3, 100);
    assert(old_id == 90);

    const unsigned char new_bytes[] = "new payload";
    char *path = temporary_path("");
    write_file(path, new_bytes, sizeof(new_bytes) - 1);

    mtp_bridge_session_t *session = open_fake();
    mtp_bridge_cancel_t *cancel = mtp_bridge_cancel_create();
    mtp_bridge_error_t error;
    mtp_bridge_error_init(&error);
    uint32_t uploaded_id = 0;
    int32_t status = mtp_bridge_upload_file_atomic(
        session,
        path,
        1,
        MTP_BRIDGE_ROOT_OBJECT_ID,
        ".mtpbridge-upload-test",
        "target.bin",
        old_id,
        ".mtpbridge-backup-test",
        cancel,
        NULL,
        NULL,
        &uploaded_id,
        &error
    );
    assert(status == MTP_BRIDGE_OK);
    assert(fake_mtp_last_send_parent_id() == MTP_BRIDGE_ROOT_OBJECT_ID);
    assert(uploaded_id != 0);
    assert(!fake_mtp_object_exists(old_id));
    assert(strcmp(fake_mtp_object_name(uploaded_id), "target.bin") == 0);
    assert(fake_mtp_object_size(uploaded_id) == sizeof(new_bytes) - 1);
    assert(memcmp(fake_mtp_object_bytes(uploaded_id), new_bytes, sizeof(new_bytes) - 1) == 0);
    assert(fake_mtp_find_object(1, 0, ".mtpbridge-backup-test") == 0);

    unlink(path);
    free(path);
    mtp_bridge_error_clear(&error);
    mtp_bridge_cancel_destroy(cancel);
    mtp_bridge_close_device(session);
}

int main(void) {
    test_detection_and_listing();
    test_resumable_download();
    test_nonresumable_download_truncates_exact_destination();
    test_partial_capability_failure_falls_back_to_full_download();
    test_cancelled_download_keeps_partial();
    test_atomic_upload_replaces_existing();
    test_folder_creation_preserves_root_parent();
    puts("C bridge tests passed (10 scenarios including exact nonresumable file-promise writes and Android-root file/folder uploads).");
    return 0;
}
