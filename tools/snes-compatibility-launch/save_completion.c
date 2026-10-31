#include "save_completion.h"
#include "checkpoint_receipt.h"
#include <stdbool.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
extern bool hakchi_save_completion_ok(const void *data,const char *error);
extern bool hakchi_save_completion_matches(const void *data,const char *expected);
extern void hakchi_save_completion_dispose(void *data);
static int valid_path(const char *p) {
 if(!p || p[0]!='/' || !p[1])return 0;
 size_t n=1,start=1;
 while(n<HC_SAVE_PATH_MAX && p[n]) {
  unsigned char c=(unsigned char)p[n];
  if(c=='/') {
   size_t count=n-start;
   if(!count || (count==1 && p[start]=='.') || (count==2 && p[start]=='.' && p[start+1]=='.'))return 0;
   start=n+1;
  } else if(!((c>='A'&&c<='Z')||(c>='a'&&c<='z')||(c>='0'&&c<='9')||c=='_'||c=='-'||c=='.'))return 0;
  n++;
 }
 if(n>=HC_SAVE_PATH_MAX || n==start || (n-start==1 && p[start]=='.') ||
    (n-start==2 && p[start]=='.' && p[start+1]=='.'))return 0;
 return 1;
}
int hc_save_completion_init(HCSaveCompletion *c,int fd,const uint8_t session[16],uint64_t sequence,const char *expected) {
 uint8_t frame[HC_CHECKPOINT_RECEIPT_BYTES];struct stat st;
 if(!c || fd<3 || !valid_path(expected) || hc_checkpoint_encode(frame,session,sequence,HC_CP_SAVE,1)!=0)return -1;
 int flags=fcntl(fd,F_GETFL);
 if(flags==-1 || (flags&O_ACCMODE)!=O_WRONLY || !(flags&O_NONBLOCK) || fstat(fd,&st)!=0 || !S_ISFIFO(st.st_mode))return -1;
 HCSaveCompletion next={.fd=fd,.sequence=sequence,.attempted=0,.delivery=-1,.reported_success=-1};
 memcpy(next.session,session,sizeof next.session);memcpy(next.expected,expected,strlen(expected)+1);*c=next;return 0;
}
void hc_save_completion_callback(void *task_data,void *user_data,const char *error) {
 HCSaveCompletion *c=user_data;
 if(!c || c->attempted) { hakchi_save_completion_dispose(task_data); return; }
 c->attempted=1;
 int success=hakchi_save_completion_ok(task_data,error) && hakchi_save_completion_matches(task_data,c->expected);
 c->reported_success=success;
 c->delivery=hc_checkpoint_send(c->fd,c->session,c->sequence,HC_CP_SAVE,success);
 hakchi_save_completion_dispose(task_data);
}
