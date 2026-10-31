// Exercises the production native USB opener; only external IOKit services are fake.
// Regressions: wildcard fallback, stale attachment, skipped descriptor check, seize,
// mutation before validation, and leaked/duplicated ownership on failed opens.
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "usb_device.h"

static CFMutableDictionaryRef props;
static uint64_t selected_id, actual_id;
static int lookup_count, fallback_count, service_releases, plugin_creates;
static int device_opens, device_closes, device_releases, seizes, configurations;
static int interface_opens, interface_closes, interface_releases, iterator_step;
static UInt16 readback_vendor, readback_product, readback_version;
static UInt8 readback_class;
static int count_calls, property_calls, alternate_calls, fail_count_at, fail_property_at, fail_alternate, nonstandard_pipes, two_interfaces, plugin_interface;
static int getter_fault, getter_mismatch, fail_open, fail_config, absent, plugin_fault;
static IOUSBDeviceInterface300 dev_table;
static IOUSBDeviceInterface300 *dev_ptr = &dev_table;
static IOUSBInterfaceInterface300 intf_table;
static IOUSBInterfaceInterface300 *intf_ptr = &intf_table;
static IOUSBInterfaceInterface300 *second_intf_ptr = &intf_table;
static IOCFPlugInInterface plugin_table;
static IOCFPlugInInterface *plugin_ptr = &plugin_table;
static IOUSBConfigurationDescriptor config = {.bConfigurationValue = 1};

static CFMutableDictionaryRef fake_id_matching(uint64_t id) {
    selected_id = id;
    return CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
}
static io_service_t fake_match(mach_port_t port, CFDictionaryRef dict) {
    (void)port; lookup_count++; CFRelease(dict); return absent ? 0 : 101;
}
static CFMutableDictionaryRef fake_general_matching(const char *name) {
    (void)name; fallback_count++;
    return CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
}
static kern_return_t fake_matching_services(mach_port_t port, CFDictionaryRef dict, io_iterator_t *iterator) {
    (void)port; (void)iterator; fallback_count++; CFRelease(dict); return kIOReturnNotFound;
}
static kern_return_t fake_registry_id(io_registry_entry_t entry, uint64_t *out) {
    assert(entry == 101); *out = actual_id; return KERN_SUCCESS;
}
static CFTypeRef fake_property(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options) {
    (void)allocator; (void)options; assert(entry == 101);
    CFTypeRef value = CFDictionaryGetValue(props,key); return value ? CFRetain(value) : NULL;
}
static kern_return_t fake_release(io_object_t object) {
    if (object == 101) service_releases++;
    else assert(object == 202 || object == 303 || object == 304);
    return KERN_SUCCESS;
}
static ULONG fake_plugin_release(void *self) { (void)self; return 0; }
static ULONG fake_device_release(void *self) { (void)self; device_releases++; return 0; }
static ULONG fake_interface_release(void *self) { (void)self; interface_releases++; return 0; }
static HRESULT fake_query(void *self, REFIID uuid, LPVOID *out) {
    (void)uuid; *out = self == &plugin_ptr ? &dev_ptr : NULL; return *out ? 0 : -1;
}
static HRESULT fake_intf_query(void *self, REFIID uuid, LPVOID *out) {
    (void)self; (void)uuid; *out = plugin_interface == 304 ? &second_intf_ptr : &intf_ptr; return 0;
}
static IOCFPlugInInterface intf_plugin_table;
static IOCFPlugInInterface *intf_plugin_ptr = &intf_plugin_table;
static kern_return_t fake_plugin(io_service_t service, CFUUIDRef type, CFUUIDRef pluginType,
                                IOCFPlugInInterface ***out, SInt32 *score) {
    (void)type; (void)pluginType; (void)score; plugin_creates++;
    if (plugin_fault) { *out = NULL; return kIOReturnError; }
    assert(service == 101 || service == 303 || service == 304);
    plugin_interface = service;
    *out = service == 101 ? &plugin_ptr : &intf_plugin_ptr; return KERN_SUCCESS;
}
static IOReturn fake_vendor(void *self, UInt16 *out) { (void)self; *out=getter_mismatch==1 ? 0x1234 : readback_vendor; return getter_fault==1 ? kIOReturnError : 0; }
static IOReturn fake_product(void *self, UInt16 *out) { (void)self; *out=getter_mismatch==2 ? 0x1234 : readback_product; return getter_fault==2 ? kIOReturnError : 0; }
static IOReturn fake_version(void *self, UInt16 *out) { (void)self; *out=getter_mismatch==3 ? 0x233 : readback_version; return getter_fault==3 ? kIOReturnError : 0; }
static IOReturn fake_class(void *self, UInt8 *out) { (void)self; *out=getter_mismatch==4 ? 42 : readback_class; return getter_fault==4 ? kIOReturnError : 0; }
static IOReturn fake_location(void *self, UInt32 *out) { (void)self; *out=getter_mismatch==5 ? 456 : 123; return getter_fault==5 ? kIOReturnError : 0; }
static IOReturn fake_open(void *self) { (void)self; device_opens++; return fail_open ? kIOReturnExclusiveAccess : 0; }
static IOReturn fake_seize(void *self) { (void)self; seizes++; return kIOReturnExclusiveAccess; }
static IOReturn fake_close(void *self) { (void)self; device_closes++; return 0; }
static IOReturn fake_config_desc(void *self, UInt8 index, IOUSBConfigurationDescriptorPtr *out) {
    (void)self; (void)index; *out=&config; return 0;
}
static IOReturn fake_config(void *self, UInt8 value) { (void)self; assert(value==1); configurations++; return fail_config ? kIOReturnError : 0; }
static IOReturn fake_intf_iterator(void *self, IOUSBFindInterfaceRequest *request, io_iterator_t *out) {
    (void)self; (void)request; *out=202; return 0;
}
static io_object_t fake_next(io_iterator_t iterator) {
    assert(iterator==202);int next=iterator_step++;
    return next==0 ? 303 : (next==1 && two_interfaces ? 304 : 0);
}
static IOReturn fake_intf_open(void *self) { (void)self; interface_opens++; return 0; }
static IOReturn fake_intf_close(void *self) { (void)self; interface_closes++; return 0; }
static IOReturn fake_endpoint_count(void *self, UInt8 *out) {
    *out=(two_interfaces && self==&intf_ptr) ? 1 : 2;count_calls++;
    return count_calls==fail_count_at ? kIOReturnError : 0;
}
static IOReturn fake_alternate(void *self, UInt8 alternate) {
    (void)self;assert(alternate==1);alternate_calls++;return fail_alternate ? kIOReturnError : 0;
}
static IOReturn fake_pipe(void *self, UInt8 pipe, UInt8 *direction, UInt8 *number,
                         UInt8 *transferType, UInt16 *size, UInt8 *interval) {
    (void)self; assert(pipe==1 || pipe==2); *direction=pipe==1 ? kUSBOut : kUSBIn;
    *number=nonstandard_pipes ? pipe+2 : pipe;
    *transferType=(two_interfaces && self==&intf_ptr) ? kUSBInterrupt : kUSBBulk;
    *size=512; *interval=0;property_calls++;
    return property_calls==fail_property_at ? kIOReturnError : 0;
}

#define IORegistryEntryIDMatching fake_id_matching
#define IOServiceGetMatchingService fake_match
#define IOServiceMatching fake_general_matching
#define IOServiceGetMatchingServices fake_matching_services
#define IORegistryEntryGetRegistryEntryID fake_registry_id
#define IORegistryEntryCreateCFProperty fake_property
#define IOObjectRelease fake_release
#define IOCreatePlugInInterfaceForService fake_plugin
#define IOIteratorNext fake_next
#include "../../USBBridge/src/usb_device.c"

static void number(CFStringRef key, int64_t n) {
    CFNumberRef value=CFNumberCreate(NULL,kCFNumberSInt64Type,&n);
    CFDictionarySetValue(props,key,value); CFRelease(value);
}
static hakchi_usb_identity_t identity(void) {
    return (hakchi_usb_identity_t){.registry_entry_id=9001,.location_id=123,.vendor_id=0x1f3a,
        .product_id=0xefe8,.device_version=0x2b3,.device_class=0,.require_empty_product=true};
}
static void reset(void) {
    if (props) CFRelease(props);
    props=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    number(CFSTR("idVendor"),0x1f3a); number(CFSTR("idProduct"),0xefe8);
    number(CFSTR("bcdDevice"),0x2b3); number(CFSTR("bDeviceClass"),0); number(CFSTR("locationID"),123);
    selected_id=0; actual_id=9001;
    count_calls=property_calls=alternate_calls=fail_count_at=fail_property_at=fail_alternate=nonstandard_pipes=two_interfaces=plugin_interface=0;
    lookup_count=fallback_count=service_releases=plugin_creates=0;
    device_opens=device_closes=device_releases=seizes=configurations=0;
    interface_opens=interface_closes=interface_releases=iterator_step=0;
    getter_fault=getter_mismatch=fail_open=fail_config=absent=plugin_fault=0;
    readback_vendor=0x1f3a;readback_product=0xefe8;readback_version=0x2b3;readback_class=0;
    dev_table=(IOUSBDeviceInterface300){.Release=fake_device_release,.GetDeviceVendor=fake_vendor,
        .GetDeviceProduct=fake_product,.GetDeviceReleaseNumber=fake_version,.GetDeviceClass=fake_class,
        .GetLocationID=fake_location,.USBDeviceOpen=fake_open,.USBDeviceOpenSeize=fake_seize,
        .USBDeviceClose=fake_close,.GetConfigurationDescriptorPtr=fake_config_desc,.SetConfiguration=fake_config,
        .CreateInterfaceIterator=fake_intf_iterator};
    intf_table=(IOUSBInterfaceInterface300){.Release=fake_interface_release,.USBInterfaceOpen=fake_intf_open,
        .USBInterfaceClose=fake_intf_close,.SetAlternateInterface=fake_alternate,.GetNumEndpoints=fake_endpoint_count,.GetPipeProperties=fake_pipe};
    plugin_table=(IOCFPlugInInterface){.QueryInterface=fake_query,.Release=fake_plugin_release};
    intf_plugin_table=(IOCFPlugInInterface){.QueryInterface=fake_intf_query,.Release=fake_plugin_release};
}
static void refused(hakchi_usb_identity_t expected) {
    hakchi_usb_error_t error=HAKCHI_USB_OK;
    assert(hakchi_usb_open_bound(&expected,&error)==NULL);
    assert(error!=HAKCHI_USB_OK && fallback_count==0 && device_opens==0 && configurations==0 && seizes==0 && interface_opens==0);
    if (lookup_count && !absent) assert(service_releases==1);
    if (plugin_creates && !plugin_fault) assert(device_releases==1);
}
static hakchi_usb_identity_t rndis_identity(void) {
    return (hakchi_usb_identity_t){.registry_entry_id=9001,.location_id=123,.vendor_id=0x04e8,
        .product_id=0x6863,.device_version=0x100,.device_class=224};
}
static void reset_rndis(void) {
    reset();readback_vendor=0x04e8;readback_product=0x6863;readback_version=0x100;readback_class=224;
    number(CFSTR("idVendor"),0x04e8);number(CFSTR("idProduct"),0x6863);
    number(CFSTR("bcdDevice"),0x100);number(CFSTR("bDeviceClass"),224);
    CFDictionarySetValue(props,CFSTR("USB Product Name"),CFSTR("classic"));
}
int main(void) {
    reset(); hakchi_usb_identity_t e=identity(); hakchi_usb_error_t error;
    hakchi_usb_device_t *opened=hakchi_usb_open_bound(&e,&error);
    assert(opened && error==0 && selected_id==9001 && lookup_count==1 && fallback_count==0 && seizes==0);
    assert(device_opens==1 && configurations==1 && interface_opens==1 && service_releases==1);
    hakchi_usb_close(opened);
    assert(device_closes==1 && device_releases==1 && interface_closes==1 && interface_releases==1);
    puts("PASS: exact registry service opens, owns and closes only its checked interface");
    reset(); e=identity();e.registry_entry_id=0;refused(e);assert(lookup_count==0);
    reset(); e=identity();e.location_id=0;refused(e);assert(lookup_count==0);
    reset(); absent=1;refused(identity());
    reset(); actual_id=9002;refused(identity());
    puts("PASS: missing/zero/stale attachment identity never falls back or opens USB");
    CFStringRef keys[]={CFSTR("idVendor"),CFSTR("idProduct"),CFSTR("bcdDevice"),CFSTR("bDeviceClass"),CFSTR("locationID")};
    for(int i=0;i<5;i++) {
        reset();CFDictionaryRemoveValue(props,keys[i]);refused(identity());
        reset();number(keys[i],999);refused(identity());
        reset();CFDictionarySetValue(props,keys[i],CFSTR("0"));refused(identity());
        reset();CFDictionarySetValue(props,keys[i],kCFBooleanFalse);refused(identity());
    }
    reset();CFDictionarySetValue(props,CFSTR("USB Product Name"),CFSTR("CLV-S-NESY"));refused(identity());
    reset();number(CFSTR("USB Product Name"),0);refused(identity());
    puts("PASS: malformed/missing/mismatched registry descriptors and product fail before plug-in/USB action");
    for(int i=1;i<=5;i++){reset();getter_fault=i;refused(identity());}
    for(int i=1;i<=5;i++){reset();getter_mismatch=i;refused(identity());}
    puts("PASS: cached handle descriptors are checked before device open");
    reset();fail_open=1;assert(hakchi_usb_open_bound(&(hakchi_usb_identity_t){.registry_entry_id=9001,.location_id=123,.vendor_id=0x1f3a,.product_id=0xefe8,.device_version=0x2b3,.device_class=0,.require_empty_product=true},&error)==NULL);
    assert(seizes==0 && fallback_count==0 && configurations==0 && device_releases==1 && device_closes==0);
    reset();fail_config=1;e=identity();assert(hakchi_usb_open_bound(&e,&error)==NULL);
    assert(interface_opens==0 && device_closes==1 && device_releases==1 && seizes==0);
    reset();plugin_fault=1;refused(identity());
    puts("PASS: open/configuration/plug-in failures release owned resources without seize or interface traffic");
    reset_rndis();e=rndis_identity();opened=hakchi_usb_open_rndis_bound(&e,&error);
    assert(opened && error==0 && selected_id==9001 && lookup_count==1 && fallback_count==0 && seizes==0);
    assert(device_opens==1 && configurations==1 && interface_opens==1 && service_releases==1);
    hakchi_usb_close(opened);assert(device_closes==1 && device_releases==1 && interface_closes==1 && interface_releases==1);
    reset_rndis();actual_id=9002;e=rndis_identity();assert(!hakchi_usb_open_rndis_bound(&e,&error));assert(device_opens==0 && fallback_count==0 && service_releases==1);
    for(int i=1;i<=5;i++) {
        reset_rndis();getter_fault=i;e=rndis_identity();assert(!hakchi_usb_open_rndis_bound(&e,&error));
        assert(device_opens==0 && seizes==0 && configurations==0 && device_releases==1 && service_releases==1);
    }
    reset_rndis();fail_open=1;e=rndis_identity();assert(!hakchi_usb_open_rndis_bound(&e,&error));assert(seizes==0 && configurations==0 && device_releases==1);
    reset_rndis();fail_config=1;e=rndis_identity();assert(!hakchi_usb_open_rndis_bound(&e,&error));assert(interface_opens==0 && device_closes==1 && device_releases==1);
    puts("PASS: RNDIS uses the exact service/getter checks and fails without seize or fallback");
    reset();e=identity();nonstandard_pipes=1;fail_alternate=1;
    assert(!hakchi_usb_open_bound(&e,&error));
    assert(alternate_calls==1 && device_closes==1 && interface_closes==1 && device_releases==1 && interface_releases==1);
    puts("PASS: failed alternate setting cannot fall through to a successful bound open");
    for(int late=0;late<2;late++) {
        reset();e=identity();nonstandard_pipes=late;
        fail_count_at=late ? 2 : 1;
        assert(!hakchi_usb_open_bound(&e,&error));
        assert(device_closes==1 && interface_closes==1 && device_releases==1 && interface_releases==1);
        reset();e=identity();nonstandard_pipes=late;
        fail_property_at=late ? 3 : 1;
        assert(!hakchi_usb_open_bound(&e,&error));
        assert(device_closes==1 && interface_closes==1 && device_releases==1 && interface_releases==1);
        reset_rndis();e=rndis_identity();two_interfaces=late;
        fail_count_at=late ? 2 : 1;
        assert(!hakchi_usb_open_rndis_bound(&e,&error));
        assert(device_closes==1 && device_releases==1 && interface_closes==1+late && interface_releases==1+late);
        reset_rndis();e=rndis_identity();two_interfaces=late;
        fail_property_at=late ? 2 : 1;
        assert(!hakchi_usb_open_rndis_bound(&e,&error));
        assert(device_closes==1 && device_releases==1 && interface_closes==1+late && interface_releases==1+late);
    }
    puts("PASS: early and late endpoint getter failures stop both bound paths and close all owned interfaces");
    reset_rndis();e=rndis_identity();two_interfaces=1;
    opened=hakchi_usb_open_rndis_bound(&e,&error);assert(opened && interface_opens==2);
    hakchi_usb_close(opened);assert(device_closes==1 && device_releases==1 && interface_closes==2 && interface_releases==2);
    puts("PASS: successful bound RNDIS owns and closes its control and data interfaces");
    CFRelease(props);puts("All bound USB replay groups passed.");return 0;
}
