// Real FEL/RNDIS/SSH entry points; only their external USB/libssh2 boundary is fake.
#include <assert.h>
#include "../../USBBridge/src/fel_protocol.c"
#include "../../USBBridge/src/rndis.c"
#include "../../USBBridge/src/ssh_bridge.c"
static const hakchi_usb_identity_t *seen;
static int bound_calls, unbound_calls, resets, halts, closes, reset_result, halt_result;
static bool usb_available;
static hakchi_usb_device_t *stub_usb=(hakchi_usb_device_t *)(uintptr_t)1;
hakchi_usb_device_t *hakchi_usb_open_bound(const hakchi_usb_identity_t *e,hakchi_usb_error_t *error) { seen=e;bound_calls++;*error=HAKCHI_USB_ERROR_ACCESS;return usb_available?stub_usb:NULL; }
hakchi_usb_device_t *hakchi_usb_open_rndis_bound(const hakchi_usb_identity_t *e,hakchi_usb_error_t *error) { seen=e;bound_calls++;*error=HAKCHI_USB_ERROR_ACCESS;return NULL; }
hakchi_usb_device_t *hakchi_usb_open(uint16_t a,uint16_t b,hakchi_usb_error_t *e) { unbound_calls++;return NULL; }
hakchi_usb_device_t *hakchi_usb_open_rndis(uint16_t a,uint16_t b,hakchi_usb_error_t *e) { unbound_calls++;return NULL; }
hakchi_usb_error_t hakchi_usb_reset(hakchi_usb_device_t *d) { assert(d==stub_usb);resets++;return reset_result; }
hakchi_usb_error_t hakchi_usb_clear_halt(hakchi_usb_device_t *d,uint8_t endpoint) { assert(d==stub_usb);halts++;return halt_result; }
void hakchi_usb_close(hakchi_usb_device_t *d) { assert(d==stub_usb);closes++; }
int hakchi_usb_bulk_write(hakchi_usb_device_t *d,uint8_t e,const uint8_t *b,int n,int t) { assert(0);return -1; }
int hakchi_usb_bulk_read(hakchi_usb_device_t *d,uint8_t e,uint8_t *b,int n,int t) { assert(0);return -1; }
int libssh2_init(int flags) { return 0; }
static hakchi_usb_identity_t fel_identity(void) { return(hakchi_usb_identity_t){.registry_entry_id=9001,.location_id=123,.vendor_id=0x1f3a,.product_id=0xefe8,.device_version=0x2b3,.device_class=0,.require_empty_product=true}; }
static hakchi_usb_identity_t rndis_identity(void) { return(hakchi_usb_identity_t){.registry_entry_id=9002,.location_id=123,.vendor_id=0x04e8,.product_id=0x6863,.device_version=0x100,.device_class=224}; }
static void reset(void) { seen=NULL;bound_calls=unbound_calls=resets=halts=closes=reset_result=halt_result=0;usb_available=false; }
int main(void) {
    reset();hakchi_usb_identity_t e=fel_identity();usb_available=true;
    fel_device_t *f=fel_open_bound(&e);assert(f && seen==&e && bound_calls==1 && unbound_calls==0 && resets==1 && halts==2);
    fel_close(f);assert(closes==1);
    reset();usb_available=true;reset_result=HAKCHI_USB_ERROR_IO;
    assert(!fel_open_bound(&e));assert(resets==1 && halts==0 && closes==1);
    reset();usb_available=true;halt_result=HAKCHI_USB_ERROR_IO;
    assert(!fel_open_bound(&e));assert(resets==1 && halts==1 && closes==1);
    reset();assert(!fel_open_bound(&e));assert(bound_calls==1 && resets==0 && halts==0 && closes==0);
    reset();e=rndis_identity();assert(!fel_open_bound(&e));assert(bound_calls==0 && unbound_calls==0);
    puts("PASS: bound FEL passes exact identity, checks reset/halt failures and closes without protocol traffic");
    reset();e=rndis_identity();assert(!rndis_open_bound(&e));assert(seen==&e && bound_calls==1 && unbound_calls==0);
    reset();assert(!ssh_session_open_bound(&e,"169.254.13.38","169.254.13.37"));assert(seen==&e && bound_calls==1 && unbound_calls==0);
    reset();e=fel_identity();assert(!rndis_open_bound(&e));assert(!ssh_session_open_bound(&e,"169.254.13.38","169.254.13.37"));assert(bound_calls==0 && unbound_calls==0);
    puts("PASS: bound RNDIS and SSH propagate exact identity and never fall back on failure");
    puts("All bound native stack replay groups passed.");return 0;
}
