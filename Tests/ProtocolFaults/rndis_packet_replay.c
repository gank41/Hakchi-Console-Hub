/* Real RNDIS reader; only USB calls are replaced. No hardware is opened. */
#include <assert.h>
#include "../../USBBridge/src/rndis.c"

static unsigned usb_reads;
static uint8_t wire[16384];
static int wire_length;
static bool delivered;
static int control_result;
static unsigned control_calls;
static uint8_t control_reply[16];

hakchi_usb_device_t *hakchi_usb_open_rndis_bound(const hakchi_usb_identity_t *e, hakchi_usb_error_t *error) { abort(); }

hakchi_usb_device_t *hakchi_usb_open_rndis(uint16_t v, uint16_t p, hakchi_usb_error_t *e) { return NULL; }
void hakchi_usb_close(hakchi_usb_device_t *d) {}
bool hakchi_usb_device_exists(uint16_t v, uint16_t p) { return false; }
uint8_t hakchi_usb_get_pipe_in(hakchi_usb_device_t *d) { return 1; }
uint8_t hakchi_usb_get_pipe_out(hakchi_usb_device_t *d) { return 2; }
int hakchi_usb_control_transfer(hakchi_usb_device_t *d, uint8_t a, uint8_t b, uint16_t c, uint16_t e, uint8_t *f, uint16_t g, int h) {
    control_calls++; assert(g==16); memcpy(control_reply,f,16); return control_result<0 ? control_result : g;
}
int hakchi_usb_bulk_write_pipe(hakchi_usb_device_t *d, uint8_t p, const uint8_t *b, int n, int t) { return n; }
int hakchi_usb_bulk_read_pipe(hakchi_usb_device_t *d, uint8_t p, uint8_t *b, int cap, int t) {
    usb_reads++;
    if (delivered) return HAKCHI_USB_ERROR_TIMEOUT;
    assert(cap >= wire_length);
    memcpy(b, wire, (size_t)wire_length); delivered = true;
    return wire_length;
}
static void le32(uint8_t *p, uint32_t n) { for (unsigned i=0;i<4;i++) p[i]=(uint8_t)(n>>(i*8)); }
static int packet(int at, uint8_t value, uint32_t length, uint32_t padding) {
    uint8_t *p=wire+at; uint32_t total=44+length+padding;
    memset(p,0,total); le32(p,1); le32(p+4,total); le32(p+8,36); le32(p+12,length);
    memset(p+44,value,length); return at+(int)total;
}
int main(void) {
    uint8_t storage[16384], output[2048];
    rndis_handle_t h={0}; h.usb=(hakchi_usb_device_t *)(uintptr_t)1;
    h.recv_buf=storage; h.recv_buf_size=sizeof(storage);
    /* Literal Microsoft multipacket shape: first padded to an 8-byte boundary. */
    int next=packet(0,0x41,26,2); assert(next==72);
    wire_length=packet(next,0x42,16,0);
    assert(rndis_recv_packet(&h,output,sizeof(output),1)==26);
    assert(output[0]==0x41 && output[25]==0x41);
    int second=rndis_recv_packet(&h,output,sizeof(output),1);
    if (second!=16) {
        fprintf(stderr,"FAIL: second coalesced Ethernet frame lost (got %d, USB reads %u)\n",second,usb_reads);
        return 1;
    }
    assert(output[0]==0x42 && output[15]==0x42);
    assert(usb_reads==1);
    puts("PASS: coalesced RNDIS frames retained in order with one USB read");

    /* More than one kernel image of data must survive repeated coalesced reads. */
    uint64_t received=0;
    for (unsigned batch=0;batch<2048;batch++) {
        delivered=false;
        int end=packet(0,(uint8_t)batch,1024,4);
        wire_length=packet(end,(uint8_t)(batch+1),1024,0);
        for (unsigned part=0;part<2;part++) {
            memset(output,0,sizeof(output));
            assert(rndis_recv_packet(&h,output,sizeof(output),1)==1024);
            for (unsigned j=0;j<1024;j++) assert(output[j]==(uint8_t)(batch+part));
            received+=1024;
        }
    }
    assert(received==4194304);
    puts("PASS: 4 MiB stream preserved across coalesced transfers");

    /* Invalid headers must not overread, truncate Ethernet data or alter output. */
    const uint32_t invalid[][4]={
        {7,36,16,60}, {61,36,16,60}, {43,36,1,60},
        {60,0,16,60}, {60,35,16,60}, {60,UINT32_MAX,16,60},
        {60,36,UINT32_MAX,60}, {60,36,17,60}
    };
    for (unsigned i=0;i<sizeof(invalid)/sizeof(invalid[0]);i++) {
        memset(&h,0,sizeof(h)); h.usb=(hakchi_usb_device_t *)(uintptr_t)1;
        h.recv_buf=storage; h.recv_buf_size=sizeof(storage);
        delivered=false; wire_length=packet(0,0x33,16,0);
        le32(wire+4,invalid[i][0]); le32(wire+8,invalid[i][1]); le32(wire+12,invalid[i][2]);
        wire_length=(int)invalid[i][3]; memset(output,0xCC,sizeof(output));
        assert(rndis_recv_packet(&h,output,sizeof(output),1)==RNDIS_ERROR_PROTOCOL);
        for (unsigned j=0;j<sizeof(output);j++) assert(output[j]==0xCC);
    }
    delivered=false; wire_length=packet(0,0x33,26,0);
    memset(output,0xCC,sizeof(output));
    assert(rndis_recv_packet(&h,output,16,1)==RNDIS_ERROR_PROTOCOL);
    for (unsigned j=0;j<sizeof(output);j++) assert(output[j]==0xCC);
    puts("PASS: malformed lengths/offsets and undersized output fail without writes");

    memset(&h,0,sizeof(h)); h.usb=(hakchi_usb_device_t *)(uintptr_t)1;
    h.recv_buf=storage; h.recv_buf_size=sizeof(storage);
    delivered=false; wire_length=packet(0,0x44,20,0); wire[wire_length++]=0;
    assert(rndis_recv_packet(&h,output,sizeof(output),1)==20);
    unsigned prior_reads=usb_reads;
    assert(rndis_recv_packet(&h,output,sizeof(output),1)==0);
    assert(usb_reads==prior_reads);
    puts("PASS: optional USB zero-byte tail consumed without another USB read");
    /* Control records must make progress on success and on a failed response. */
    for (int fail=0;fail<2;fail++) {
        memset(&h,0,sizeof(h)); h.usb=(hakchi_usb_device_t *)(uintptr_t)1;
        h.recv_buf=storage; h.recv_buf_size=sizeof(storage); delivered=false;
        memset(wire,0,16); le32(wire,8); le32(wire+4,16); le32(wire+8,42);
        wire_length=packet(16,0x55,8,0); control_calls=0; control_result=fail?-1:0;
        if (fail) assert(rndis_recv_packet(&h,output,sizeof(output),1)==RNDIS_ERROR_USB);
        assert(rndis_recv_packet(&h,output,sizeof(output),1)==8);
        assert(output[0]==0x55 && output[7]==0x55 && control_calls==1);
        assert(control_reply[0]==8 && control_reply[3]==0x80 && control_reply[8]==42);
    }
    puts("PASS: keepalive success/failure cannot pin the cursor");
    memset(&h,0,sizeof(h)); h.usb=(hakchi_usb_device_t *)(uintptr_t)1;
    h.recv_buf=storage; h.recv_buf_size=sizeof(storage); delivered=false;
    memset(wire,0,16); le32(wire,0xABC); le32(wire+4,16);
    wire_length=packet(16,0x66,8,0);
    assert(rndis_recv_packet(&h,output,sizeof(output),1)==8 && output[0]==0x66);
    puts("PASS: unknown bounded records do not conceal following data");

    const unsigned pads[]={2,7,64,511};
    for (unsigned k=0;k<sizeof(pads)/sizeof(pads[0]);k++) {
        memset(&h,0,sizeof(h)); h.usb=(hakchi_usb_device_t *)(uintptr_t)1;
        h.recv_buf=storage; h.recv_buf_size=sizeof(storage); delivered=false;
        wire_length=packet(0,0x77,20,0); memset(wire+wire_length,0,pads[k]); wire_length+=(int)pads[k];
        assert(rndis_recv_packet(&h,output,sizeof(output),1)==20);
        assert(rndis_recv_packet(&h,output,sizeof(output),1)==0 && h.invalid_messages==0);
    }
    puts("PASS: legal USB zero padding is consumed without protocol errors");

    memset(&h,0,sizeof(h)); h.usb=(hakchi_usb_device_t *)(uintptr_t)1;
    h.recv_buf=storage; h.recv_buf_size=sizeof(storage); delivered=false;
    int tail=packet(0,0x88,20,0); wire_length=packet(tail,0x99,8,0); le32(wire+tail+4,0);
    assert(rndis_recv_packet(&h,output,sizeof(output),1)==20);
    memset(output,0xCC,sizeof(output));
    assert(rndis_recv_packet(&h,output,sizeof(output),1)==RNDIS_ERROR_PROTOCOL);
    assert(output[0]==0xCC);
    delivered=false; wire_length=packet(0,0xAA,8,0);
    assert(rndis_recv_packet(&h,output,sizeof(output),1)==8 && output[0]==0xAA);
    puts("PASS: malformed second record discarded; next transfer remains readable");
    return 0;
}
