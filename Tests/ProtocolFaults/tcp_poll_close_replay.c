/* Real TCP engine; RNDIS boundary supplies one literal peer FIN. */
#include <assert.h>
#include "../../USBBridge/src/tcpip.c"
static uint8_t peer_frame[128];
static int peer_length;
static unsigned receives;
static bool received;
int rndis_send_packet(rndis_handle_t *h,const uint8_t *data,uint32_t length) { return (int)length; }
int rndis_recv_packet(rndis_handle_t *h,uint8_t *data,uint32_t capacity,int timeout_ms) {
    receives++;
    if (received) return 0;
    assert(capacity>=(uint32_t)peer_length); memcpy(data,peer_frame,(size_t)peer_length); received=true; return peer_length;
}
void rndis_get_host_mac(rndis_handle_t *h,uint8_t mac[6]) { memset(mac,1,6); }
static void connection(tcp_conn_t *c) {
    memset(c,0,sizeof(*c)); c->rndis=(rndis_handle_t *)(uintptr_t)1;
    c->state=TCP_STATE_ESTABLISHED;
    c->src_ip=tcp_ip_addr("169.254.13.38"); c->dst_ip=tcp_ip_addr("169.254.13.37");
    c->src_port=12000; c->dst_port=22; c->ack_num=100; c->seq_num=200;
}
static void fin(const tcp_conn_t *c,unsigned payload) {
    memset(peer_frame,0,sizeof(peer_frame));
    eth_header_t *eth=(eth_header_t *)peer_frame; eth->ethertype=htons(0x0800);
    ip_header_t *ip=(ip_header_t *)(peer_frame+14);
    ip->ver_ihl=0x45; ip->protocol=6; ip->total_len=htons((uint16_t)(40+payload)); ip->src_ip=c->dst_ip; ip->dst_ip=c->src_ip;
    tcp_header_t *tcp=(tcp_header_t *)(peer_frame+34);
    tcp->src_port=htons(22); tcp->dst_port=htons(12000); tcp->seq=htonl(100); tcp->ack=htonl(200); tcp->data_offset=0x50; tcp->flags=TCP_FIN|TCP_ACK;
    memcpy(peer_frame+54,"abc",payload); peer_length=(int)(54+payload); received=false; receives=0;
}
int main(void) {
    tcp_conn_t c; uint8_t output[8]={0};
    connection(&c); receives=0;
    assert(tcp_recv(&c,output,sizeof(output),0)==0 && receives==0);
    puts("PASS: real tcp_recv(0) does not poll USB when its ring is empty");
    connection(&c); fin(&c,0); tcp_poll(&c,100);
    assert(c.state==TCP_STATE_CLOSE_WAIT && receives==1);
    int closed=tcp_recv(&c,output,sizeof(output),0);
    if (closed!=TCP_ERROR_CLOSED) {
        fprintf(stderr,"FAIL: polled peer FIN became no-data/EAGAIN instead of close (got %d)\n",closed); return 1;
    }
    assert(receives==1);
    puts("PASS: bare FIN received by tcp_poll is surfaced by the next callback");
    connection(&c); fin(&c,3); tcp_poll(&c,100);
    assert(tcp_recv(&c,output,sizeof(output),0)==3 && memcmp(output,"abc",3)==0);
    assert(tcp_recv(&c,output,sizeof(output),0)==TCP_ERROR_CLOSED && receives==1);
    puts("PASS: buffered data is delivered before the peer close error");
    return 0;
}
