#ifndef MTPBRIDGE_FAKE_LIBMTP_H
#define MTPBRIDGE_FAKE_LIBMTP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>
#include "libmtp.h"

void fake_mtp_reset(void);
void fake_mtp_set_partial_failure(bool enabled);
void fake_mtp_set_usb_present(bool present);
void fake_mtp_set_date_created_supported(bool supported);
void fake_mtp_set_date_created_reported_supported(bool supported);
void fake_mtp_set_detect_result(LIBMTP_error_number_t result, int count);
uint32_t fake_mtp_add_file(
    uint32_t requested_id,
    uint32_t storage_id,
    uint32_t parent_id,
    const char *name,
    const unsigned char *bytes,
    size_t size,
    time_t modification_time
);
uint32_t fake_mtp_add_file_with_dates(
    uint32_t requested_id,
    uint32_t storage_id,
    uint32_t parent_id,
    const char *name,
    const unsigned char *bytes,
    size_t size,
    time_t creation_time,
    time_t modification_time
);
bool fake_mtp_object_exists(uint32_t object_id);
uint32_t fake_mtp_find_object(uint32_t storage_id, uint32_t parent_id, const char *name);
size_t fake_mtp_object_size(uint32_t object_id);
const unsigned char *fake_mtp_object_bytes(uint32_t object_id);
const char *fake_mtp_object_name(uint32_t object_id);
uint32_t fake_mtp_last_send_parent_id(void);
uint32_t fake_mtp_last_create_folder_parent_id(void);

#endif
