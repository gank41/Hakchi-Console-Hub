/* Isolated fault injection into the real C implementation. No IOKit is linked. */
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include "fel_protocol.h"

static bool fail_allocation;
static void *fault_malloc(size_t count) { return fail_allocation ? NULL : malloc(count); }
#define malloc fault_malloc
#include "../../USBBridge/src/fel_protocol.c"
#undef malloc

/* A mistakenly reached production USB path must fail the test, never open hardware. */
hakchi_usb_device_t *hakchi_usb_open_bound(const hakchi_usb_identity_t *e, hakchi_usb_error_t *error) { abort(); }

hakchi_usb_device_t *hakchi_usb_open(uint16_t v, uint16_t p, hakchi_usb_error_t *e) { abort(); }
void hakchi_usb_close(hakchi_usb_device_t *d) { abort(); }
hakchi_usb_error_t hakchi_usb_reset(hakchi_usb_device_t *d) { abort(); }
hakchi_usb_error_t hakchi_usb_clear_halt(hakchi_usb_device_t *d, uint8_t e) { abort(); }
int hakchi_usb_bulk_write(hakchi_usb_device_t *d, uint8_t e, const uint8_t *b, int n, int t) { abort(); }
int hakchi_usb_bulk_read(hakchi_usb_device_t *d, uint8_t e, uint8_t *b, int n, int t) { abort(); }

static int writes;
static int wire_write(void *context, const uint8_t *bytes, int count) { writes++; return count; }
static int wire_read(void *context, uint8_t *bytes, int count) {
    memset(bytes, 0, count);
    if (count == sizeof(aw_usb_response_t)) memcpy(bytes, "AWUS", 4);
    return count;
}
int main(void) {
    fel_transport_t transport = {.write = wire_write, .read = wire_read};
    fel_device_t *device = fel_open_transport(&transport, NULL);
    assert(device);
    /* Establish prior authorization to isolate post-request allocation failure. */
    device->board_verified = true;
    device->dram_initialized = true;
    uint8_t bytes[3] = {0};
    fail_allocation = true;
    assert(fel_read_memory(device, FES1_BASE_M, bytes, sizeof(bytes), NULL, NULL) == HAKCHI_USB_ERROR_OTHER);
    assert(!device->board_verified && !device->dram_initialized);
    int before = writes;
    assert(fel_exec(device, UBOOT_BASE_M) == HAKCHI_USB_ERROR_INVALID_PARAM);
    assert(writes == before);
    fel_close(device);
    puts("FEL allocation fault: authorization revoked; no subsequent RUN emitted.");
}
