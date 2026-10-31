// Exercise the production bound constructor and stalled read without opening hardware.
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <assert.h>
static io_object_t next_fake(io_iterator_t iterator);
static kern_return_t release_fake(io_object_t object);
static kern_return_t plugin_fake(io_service_t service, CFUUIDRef type, CFUUIDRef plugin_type,
                                 IOCFPlugInInterface ***plugin, SInt32 *score);
#define IOIteratorNext next_fake
#define IOObjectRelease release_fake
#define IOCreatePlugInInterfaceForService plugin_fake
#include "../../USBBridge/src/usb_device.c"
#undef IOIteratorNext
#undef IOObjectRelease
#undef IOCreatePlugInInterfaceForService

static int clears, iteration;
static IOUSBInterfaceInterface300 interface_table;
static IOUSBInterfaceInterface300 *interface_pointer = &interface_table;
static IOCFPlugInInterface plugin_table;
static IOCFPlugInInterface *plugin_pointer = &plugin_table;
static IOReturn interface_open(void *self) { return kIOReturnSuccess; }
static IOReturn interface_close(void *self) { return kIOReturnSuccess; }
static ULONG release_interface(void *self) { return 0; }
static IOReturn iterator_create(void *self, IOUSBFindInterfaceRequest *request, io_iterator_t *iterator) { *iterator = 1; return kIOReturnSuccess; }
static IOReturn endpoints(void *self, UInt8 *count) { *count = 2; return kIOReturnSuccess; }
static IOReturn properties(void *self, UInt8 pipe, UInt8 *direction, UInt8 *number, UInt8 *type, UInt16 *packet, UInt8 *interval) {
    *direction = pipe == 1 ? kUSBOut : kUSBIn; *number = 1; *type = kUSBBulk; *packet = 64; *interval = 0; return kIOReturnSuccess;
}
static IOReturn stalled(void *self, UInt8 pipe, void *data, UInt32 *size, UInt32 no_data, UInt32 completion) { return kIOUSBPipeStalled; }
static IOReturn clear(void *self, UInt8 pipe) { clears++; return kIOReturnSuccess; }
static HRESULT query(void *self, REFIID type, LPVOID *result) { *result = &interface_pointer; return 0; }
static io_object_t next_fake(io_iterator_t iterator) { return iteration++ == 0 ? 42 : 0; }
static kern_return_t release_fake(io_object_t object) { return KERN_SUCCESS; }
static kern_return_t plugin_fake(io_service_t service, CFUUIDRef type, CFUUIDRef plugin_type, IOCFPlugInInterface ***plugin, SInt32 *score) {
    *plugin = &plugin_pointer; *score = 0; return KERN_SUCCESS;
}
int main(void) {
    assert(bound_product(CFSTR("Swift Hakchi SNES RAM Probe"), "Swift Hakchi SNES RAM Probe"));
    assert(!bound_product(CFSTR("Different product"), "Swift Hakchi SNES RAM Probe"));
    assert(!bound_product(NULL, "Swift Hakchi SNES RAM Probe"));
    assert(!bound_product(kCFBooleanTrue, "Swift Hakchi SNES RAM Probe"));
    interface_table.USBInterfaceOpen = interface_open; interface_table.USBInterfaceClose = interface_close;
    interface_table.Release = release_interface; interface_table.GetNumEndpoints = endpoints;
    interface_table.GetPipeProperties = properties; interface_table.ReadPipeTO = stalled;
    interface_table.ClearPipeStallBothEnds = clear;
    plugin_table.QueryInterface = query; plugin_table.Release = release_interface;
    IOUSBDeviceInterface300 device_table = {0}; IOUSBDeviceInterface300 *device = &device_table;
    device_table.CreateInterfaceIterator = iterator_create; device_table.USBDeviceClose = interface_close; device_table.Release = release_interface;
    for (int passive = 0; passive <= 1; passive++) {
        clears = iteration = 0; hakchi_usb_error_t error;
        hakchi_usb_device_t *opened = bound_interfaces(&device, false, passive, &error);
        assert(opened && error == HAKCHI_USB_OK);
        uint8_t bytes[64]; assert(hakchi_usb_bulk_read(opened, 0x81, bytes, sizeof(bytes), 100) == HAKCHI_USB_ERROR_PIPE);
        assert(clears == (passive ? 0 : 1));
        hakchi_usb_close(opened);
    }
    return 0;
}
