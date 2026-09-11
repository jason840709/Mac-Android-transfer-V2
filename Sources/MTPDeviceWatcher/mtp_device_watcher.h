#ifndef MTP_DEVICE_WATCHER_H
#define MTP_DEVICE_WATCHER_H

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*mtp_device_inserted_callback)(void *context);

typedef struct {
    int has_mtp_device;
} mtp_device_presence_state_t;

void mtp_device_presence_state_init(mtp_device_presence_state_t *state, int initially_present);
int mtp_device_presence_state_update(mtp_device_presence_state_t *state, int currently_present);

/*
 * Runs the macOS USB hot-plug watcher on the current thread. Returns only on
 * setup failure. The callback fires only on a stable absent -> present MTP
 * transition, never merely because the hidden watcher starts at login.
 */
int mtp_device_watcher_run(mtp_device_inserted_callback callback, void *context);

#ifdef __cplusplus
}
#endif

#endif
