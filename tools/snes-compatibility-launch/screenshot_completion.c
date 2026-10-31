#include "screenshot_completion.h"
#include "checkpoint_receipt.h"
#include <stdbool.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
extern bool hakchi_screenshot_completion_ok(const void *data);
int hc_screenshot_completion_init(HCScreenshotCompletion *c,int fd,const uint8_t session[16],uint64_t sequence) {
 uint8_t frame[HC_CHECKPOINT_RECEIPT_BYTES];struct stat st;
 if (!c || fd<3 || hc_checkpoint_encode(frame,session,sequence,HC_CP_IMAGE,1)!=0) return -1;
 int flags=fcntl(fd,F_GETFL);
 if(flags==-1 || (flags&O_ACCMODE)!=O_WRONLY || !(flags&O_NONBLOCK) || fstat(fd,&st)!=0 || !S_ISFIFO(st.st_mode)) return -1;
 HCScreenshotCompletion next={.fd=fd,.sequence=sequence,.attempted=0,.delivery=-1,.reported_success=-1};
 memcpy(next.session,session,sizeof next.session);*c=next;return 0;
}
void hc_screenshot_completion_callback(void *task_data,void *user_data,const char *error) {
 HCScreenshotCompletion *c=user_data;
 if(!c || c->attempted) return;
 c->attempted=1;
 int success=error==NULL && hakchi_screenshot_completion_ok(task_data);
 c->reported_success=success;
 c->delivery=hc_checkpoint_send(c->fd,c->session,c->sequence,HC_CP_IMAGE,success);
}
