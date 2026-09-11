#include "mtp_device_watcher.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    mtp_device_presence_state_t state;

    mtp_device_presence_state_init(&state, 0);
    assert(state.has_mtp_device == 0);
    assert(mtp_device_presence_state_update(&state, 1) == 1);
    assert(state.has_mtp_device == 1);
    assert(mtp_device_presence_state_update(&state, 1) == 0);

    assert(mtp_device_presence_state_update(&state, 0) == 0);
    assert(state.has_mtp_device == 0);
    assert(mtp_device_presence_state_update(&state, 1) == 1);

    mtp_device_presence_state_init(&state, 1);
    assert(mtp_device_presence_state_update(&state, 1) == 0);
    assert(mtp_device_presence_state_update(&state, 0) == 0);
    assert(mtp_device_presence_state_update(&state, 1) == 1);

    /* Null state is safe and never launches. */
    assert(mtp_device_presence_state_update(NULL, 1) == 0);

    puts("Device watcher transition tests passed.");
    return 0;
}
