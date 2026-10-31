#include "fel_protocol.h"
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <limits.h>

/* Every handle owns authorization state; no global transport hooks. */
static int fel_invalidate(fel_device_t *dev, int error) {
    if (dev) { dev->board_verified = false; dev->dram_initialized = false; }
    return error;
}

static int fel_usb_write(fel_device_t *dev, const uint8_t *data, int length) {
    if (!dev || !data || length <= 0 || (!dev->transport.write && !dev->usb))
        return HAKCHI_USB_ERROR_INVALID_PARAM;
    int ret = dev->transport.write
        ? dev->transport.write(dev->transport_context, data, length)
        : hakchi_usb_bulk_write(dev->usb, FEL_EP_OUT, data, length, FEL_WRITE_TIMEOUT);
    if (ret < 0) return fel_invalidate(dev, ret);
    return ret == length ? ret : fel_invalidate(dev, HAKCHI_USB_ERROR_IO);
}

static int fel_usb_read(fel_device_t *dev, uint8_t *data, int length) {
    if (!dev || !data || length <= 0 || (!dev->transport.read && !dev->usb))
        return HAKCHI_USB_ERROR_INVALID_PARAM;
    memset(data, 0, (size_t)length);
    int ret = dev->transport.read
        ? dev->transport.read(dev->transport_context, data, length)
        : hakchi_usb_bulk_read(dev->usb, FEL_EP_IN, data, length, FEL_READ_TIMEOUT);
    if (ret < 0) return fel_invalidate(dev, ret);
    return ret == length ? ret : fel_invalidate(dev, HAKCHI_USB_ERROR_IO);
}

static int aw_ack(fel_device_t *dev) {
    aw_usb_response_t response = {0};
    int ret = fel_usb_read(dev, (uint8_t *)&response, sizeof(response));
    if (ret < 0) return ret;
    if (memcmp(response.signature, "AWUS", 4) != 0 || response.csw_status != 0)
        return fel_invalidate(dev, HAKCHI_USB_ERROR_IO);
    return HAKCHI_USB_OK;
}

static aw_usb_request_t aw_request(uint8_t command, uint32_t length) {
    aw_usb_request_t request = {0};
    memcpy(request.signature, "AWUC", 4);
    request.len = length; request.len2 = length;
    request.cmd_len = 0x0C; request.cmd = command;
    return request;
}

static int aw_write(fel_device_t *dev, const uint8_t *data, uint32_t length) {
    if (!data || !length || length > FEL_MAX_BULK_SIZE) return HAKCHI_USB_ERROR_INVALID_PARAM;
    aw_usb_request_t request = aw_request(AW_USB_WRITE, length);
    int ret = fel_usb_write(dev, (const uint8_t *)&request, sizeof(request));
    if (ret < 0) return ret;
    ret = fel_usb_write(dev, data, (int)length);
    if (ret < 0) return ret;
    return aw_ack(dev);
}

static int aw_read(fel_device_t *dev, uint8_t *data, uint32_t length) {
    if (!data || !length || length > FEL_MAX_BULK_SIZE) return HAKCHI_USB_ERROR_INVALID_PARAM;
    aw_usb_request_t request = aw_request(AW_USB_READ, length);
    int ret = fel_usb_write(dev, (const uint8_t *)&request, sizeof(request));
    if (ret < 0) return ret;
    ret = fel_usb_read(dev, data, (int)length);
    if (ret < 0) return ret;
    return aw_ack(dev);
}

static int fel_send_request(fel_device_t *dev, uint16_t command) {
    aw_fel_std_request_t request = {0}; request.cmd = command;
    return aw_write(dev, (const uint8_t *)&request, sizeof(request));
}

static int fel_send_message(fel_device_t *dev, uint16_t command, uint32_t address, uint32_t length) {
    aw_fel_message_t message = {0};
    message.cmd = command; message.address = address; message.len = length;
    return aw_write(dev, (const uint8_t *)&message, sizeof(message));
}

static int fel_read_status(fel_device_t *dev) {
    aw_fel_status_t status = {0};
    int ret = aw_read(dev, (uint8_t *)&status, sizeof(status));
    if (ret < 0) return ret;
    return status.state == 0 ? HAKCHI_USB_OK : fel_invalidate(dev, HAKCHI_USB_ERROR_IO);
}

static fel_device_t *fel_open_usb(hakchi_usb_device_t *usb, bool checked) {
    if (!usb) return NULL;
    int status = hakchi_usb_reset(usb);
    if (checked && status != HAKCHI_USB_OK) { hakchi_usb_close(usb); return NULL; }
    status = hakchi_usb_clear_halt(usb, FEL_EP_OUT);
    if (checked && status != HAKCHI_USB_OK) { hakchi_usb_close(usb); return NULL; }
    status = hakchi_usb_clear_halt(usb, FEL_EP_IN);
    if (checked && status != HAKCHI_USB_OK) { hakchi_usb_close(usb); return NULL; }
    fel_device_t *device = calloc(1, sizeof(*device));
    if (!device) { hakchi_usb_close(usb); return NULL; }
    device->usb = usb;
    return device;
}
fel_device_t *fel_open(void) {
    hakchi_usb_error_t error;
    return fel_open_usb(hakchi_usb_open(FEL_VID, FEL_PID, &error), false);
}
fel_device_t *fel_open_bound(const hakchi_usb_identity_t *e) {
    if (!e || !e->registry_entry_id || !e->location_id || e->vendor_id != FEL_VID
        || e->product_id != FEL_PID || e->device_version != 0x02b3 || e->device_class != 0
        || !e->require_empty_product) return NULL;
    hakchi_usb_error_t error;
    return fel_open_usb(hakchi_usb_open_bound(e, &error), true);
}

fel_device_t *fel_open_transport(const fel_transport_t *transport, void *context) {
    if (!transport || !transport->read || !transport->write) return NULL;
    fel_device_t *device = calloc(1, sizeof(*device));
    if (!device) return NULL;
    device->transport = *transport; device->transport_context = context;
    return device;
}

void fel_close(fel_device_t *dev) {
    if (!dev) return;
    if (dev->usb) hakchi_usb_close(dev->usb);
    free(dev);
}

int fel_verify_device(fel_device_t *dev, aw_fel_verify_response_t *response) {
    if (!dev) return HAKCHI_USB_ERROR_INVALID_PARAM;
    fel_invalidate(dev, 0);
    if (!response) return HAKCHI_USB_ERROR_INVALID_PARAM;
    memset(response, 0, sizeof(*response));
    int ret = fel_send_request(dev, FEL_VERIFY_DEVICE);
    if (ret < 0) return ret;
    ret = aw_read(dev, (uint8_t *)response, sizeof(*response));
    if (ret < 0) return ret;
    if (memcmp(response->magic, "AWUSBFEX", 8) != 0)
        return fel_invalidate(dev, HAKCHI_USB_ERROR_IO);
    ret = fel_read_status(dev);
    if (ret < 0) return ret;
    dev->board_verified = response->board == EXPECTED_BOARD_ID;
    return HAKCHI_USB_OK;
}

static int memory_range(fel_device_t *dev, uint32_t address, uint32_t length, uint32_t *aligned) {
    if (!dev || !dev->board_verified || !length || length > FEL_MAX_TRANSFER_SIZE || (address & 3u))
        return HAKCHI_USB_ERROR_INVALID_PARAM;
    uint64_t padded = ((uint64_t)length + 3u) & ~UINT64_C(3);
    uint64_t end = (uint64_t)address + padded;
    if (padded > FEL_MAX_TRANSFER_SIZE || end > UINT64_C(0x100000000) ||
        (end > DRAM_BASE && !dev->dram_initialized))
        return HAKCHI_USB_ERROR_INVALID_PARAM;
    *aligned = (uint32_t)padded;
    return HAKCHI_USB_OK;
}

int fel_write_memory(fel_device_t *dev, uint32_t address, const uint8_t *data, uint32_t length,
                     void (*progress)(uint32_t, uint32_t, void *), void *context) {
    uint32_t aligned = 0;
    if (!data) return HAKCHI_USB_ERROR_INVALID_PARAM;
    int ret = memory_range(dev, address, length, &aligned);
    if (ret < 0) return ret;
    uint8_t *padded = NULL;
    if (aligned != length) {
        padded = calloc(1, aligned);
        if (!padded) return HAKCHI_USB_ERROR_OTHER;
        memcpy(padded, data, length); data = padded;
    }
    uint32_t position = 0;
    while (position < aligned) {
        uint32_t chunk = aligned - position;
        if (chunk > FEL_MAX_BULK_SIZE) chunk = FEL_MAX_BULK_SIZE;
        ret = fel_send_message(dev, FEL_DOWNLOAD, address + position, chunk);
        if (ret < 0) break;
        ret = aw_write(dev, data + position, chunk);
        if (ret < 0) break;
        ret = fel_read_status(dev);
        if (ret < 0) break;
        position += chunk;
        if (progress) progress(position < length ? position : length, length, context);
    }
    free(padded);
    return ret;
}

int fel_read_memory(fel_device_t *dev, uint32_t address, uint8_t *buffer, uint32_t length,
                    void (*progress)(uint32_t, uint32_t, void *), void *context) {
    uint32_t aligned = 0;
    if (!buffer) return HAKCHI_USB_ERROR_INVALID_PARAM;
    int ret = memory_range(dev, address, length, &aligned);
    if (ret < 0) return ret;
    uint32_t position = 0;
    while (position < aligned) {
        uint32_t chunk = aligned - position;
        if (chunk > FEL_MAX_BULK_SIZE) chunk = FEL_MAX_BULK_SIZE;
        ret = fel_send_message(dev, FEL_UPLOAD, address + position, chunk);
        if (ret < 0) return ret;
        if (position + chunk <= length) {
            ret = aw_read(dev, buffer + position, chunk);
        } else {
            uint8_t *tail = malloc(chunk);
            if (!tail) return fel_invalidate(dev, HAKCHI_USB_ERROR_OTHER);
            ret = aw_read(dev, tail, chunk);
            if (ret == HAKCHI_USB_OK) memcpy(buffer + position, tail, length - position);
            free(tail);
        }
        if (ret < 0) return ret;
        ret = fel_read_status(dev);
        if (ret < 0) return ret;
        position += chunk;
        if (progress) progress(position < length ? position : length, length, context);
    }
    return HAKCHI_USB_OK;
}

int fel_exec(fel_device_t *dev, uint32_t address) {
    uint32_t ignored;
    int ret = memory_range(dev, address, 4, &ignored);
    if (ret < 0) return ret;
    ret = fel_send_message(dev, FEL_RUN, address, 0);
    if (ret < 0) return ret;
    return fel_read_status(dev);
}

int fel_init_dram(fel_device_t *dev, const uint8_t *fes1, uint32_t length) {
    if (!dev || !dev->board_verified || !fes1 || length < 0x80 || length > FES1_MAX_SIZE)
        return HAKCHI_USB_ERROR_INVALID_PARAM;
    if (dev->dram_initialized) return HAKCHI_USB_OK;
    int ret = fel_write_memory(dev, FES1_BASE_M, fes1, length, NULL, NULL);
    if (ret < 0) return ret;
    uint8_t *readback = malloc(length);
    if (!readback) return HAKCHI_USB_ERROR_OTHER;
    ret = fel_read_memory(dev, FES1_BASE_M, readback, length, NULL, NULL);
    if (ret == HAKCHI_USB_OK && memcmp(readback, fes1, length) != 0)
        ret = fel_invalidate(dev, HAKCHI_USB_ERROR_IO);
    free(readback);
    if (ret < 0) return ret;
    ret = fel_exec(dev, FES1_BASE_M);
    if (ret < 0) return ret;
    if (dev->transport.wait_us) dev->transport.wait_us(dev->transport_context, 2000000);
    else usleep(2000000);
    dev->dram_initialized = true;
    return HAKCHI_USB_OK;
}
