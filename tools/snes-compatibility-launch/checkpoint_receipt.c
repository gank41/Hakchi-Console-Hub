#include "checkpoint_receipt.h"
#include "atomic_pipe.h"
#include "screenshot_png.h"
#include <string.h>
static int fail(HCCheckpoint *s) { if (s) s->phase=HC_CP_FAILED; return -1; }
int hc_checkpoint_init(HCCheckpoint *s,const uint8_t session[16],uint64_t sequence) {
 if (!s) return -1;
 uint8_t copy[16];
 if (!session) { memset(s,0,sizeof *s);return -1; }
 memcpy(copy,session,sizeof copy);memset(s,0,sizeof *s);
 unsigned nonzero=0;for (size_t i=0;i<sizeof copy;i++) nonzero |= copy[i];
 if (!nonzero || !sequence) return -1;
 memcpy(s->session,copy,sizeof copy);s->sequence=sequence;s->phase=HC_CP_WAIT_SAVE;return 0;
}
int hc_checkpoint_receipt(HCCheckpoint *s,const uint8_t *p,size_t n) {
 if (!s || !p || n!=HC_CHECKPOINT_RECEIPT_BYTES) return fail(s);
 if (s->phase!=HC_CP_WAIT_SAVE && s->phase!=HC_CP_WAIT_IMAGE) return fail(s);
 if (memcmp(p,"HKC1",4) || memcmp(p+4,s->session,16) || p[29] || p[30] || p[31]) return fail(s);
 uint64_t seq=0;for (size_t i=20;i<28;i++)seq=(seq<<8)|p[i];
 if (seq!=s->sequence) return fail(s);
 if (s->phase==HC_CP_WAIT_SAVE && p[28]==HC_CP_SAVE) s->phase=HC_CP_VERIFY_SAVE;
 else if (s->phase==HC_CP_WAIT_IMAGE && p[28]==HC_CP_IMAGE) s->phase=HC_CP_VERIFY_IMAGE;
 else return fail(s);
 return 0;
}
int hc_checkpoint_verified(HCCheckpoint *s,HCCheckpointKind kind,int valid) {
 if (!s || valid!=1) return fail(s);
 if (s->phase==HC_CP_VERIFY_SAVE && kind==HC_CP_SAVE) s->phase=HC_CP_WAIT_IMAGE;
 else return fail(s);
 return 0;
}

int hc_checkpoint_feed(HCReceiptReader *r,HCCheckpoint *s,const uint8_t *b,size_t n) {
 if (!r || !s || !b || !n || r->done || r->used > HC_CHECKPOINT_RECEIPT_BYTES ||
     n > HC_CHECKPOINT_RECEIPT_BYTES-r->used) return fail(s);
 if (s->phase!=HC_CP_WAIT_SAVE && s->phase!=HC_CP_WAIT_IMAGE) return fail(s);
 memcpy(r->bytes+r->used,b,n);r->used+=n;
 if (r->used < HC_CHECKPOINT_RECEIPT_BYTES) return 0;
 r->done=1;
 return hc_checkpoint_receipt(s,r->bytes,r->used)==0 ? 1 : -1;
}

int hc_checkpoint_encode(uint8_t out[32],const uint8_t x[16],uint64_t n,HCCheckpointKind k,int success) {
 if (!out || !x || !n || (k!=HC_CP_SAVE && k!=HC_CP_IMAGE) || (success!=0 && success!=1)) return -1;
 unsigned nonzero=0;for (size_t i=0;i<16;i++)nonzero|=x[i];if(!nonzero)return -1;
 uint8_t frame[32]={0};memcpy(frame,"HKC1",4);memcpy(frame+4,x,16);
 for(int i=27;i>=20;i--){frame[i]=(uint8_t)(n&0xff);n>>=8;}
 frame[28]=(uint8_t)k;frame[29]=success?0:1;memcpy(out,frame,sizeof frame);return 0;
}

int hc_checkpoint_send(int fd,const uint8_t x[16],uint64_t n,HCCheckpointKind k,int ok) {
 uint8_t frame[32];if(hc_checkpoint_encode(frame,x,n,k,ok)!=0)return -1;
 return hc_atomic_pipe_write(fd,frame,sizeof frame);
}

int hc_checkpoint_verify_image(HCCheckpoint *s,const uint8_t *p,size_t n,int fresh) {
 if (!s || s->phase!=HC_CP_VERIFY_IMAGE || fresh!=1 || hc_screenshot_png(p,n)!=0) return fail(s);
 s->phase=HC_CP_READY;return 0;
}
