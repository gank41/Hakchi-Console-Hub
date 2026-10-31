#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "autosave_target.h"
#include "autosave_publish.h"
#include "owned_directory.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static int component(const char *s){if(!s||!s[0]||!strcmp(s,".")||!strcmp(s,".."))return 0;size_t n=0;while(s[n]&&n<128){unsigned char c=(unsigned char)s[n++];if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_'||c=='.'))return 0;}return n<128;}
int hc_autosave_target_init(HCAutosaveTarget *t,int parent,int workspace,int temp,uid_t uid,const char *identity,const char *destination,const char *name){
 struct stat p,w,f,e,mapped;int flags=fcntl(temp,F_GETFL);int pf=fcntl(parent,F_GETFD),wf=fcntl(workspace,F_GETFD),tf=fcntl(temp,F_GETFD);size_t n;
 if(!t||t->ready||!identity||identity[0]!='/'||!component(destination)||!component(name)||!strcmp(name,"previous")){errno=EINVAL;return -1;}
 n=strnlen(identity,sizeof t->identity);if(n>=sizeof t->identity){errno=EINVAL;return -1;}
 const char *last=strrchr(identity,'/');
 if(!last||strcmp(last+1,destination)||flags<0||(flags&O_ACCMODE)!=O_RDWR||(flags&O_APPEND)||
    pf<0||wf<0||tf<0||!(pf&FD_CLOEXEC)||!(wf&FD_CLOEXEC)||!(tf&FD_CLOEXEC)||
    fstat(parent,&p)!=0||fstat(workspace,&w)!=0||fstat(temp,&f)!=0||fstatat(workspace,name,&e,AT_SYMLINK_NOFOLLOW)!=0||
    !S_ISDIR(p.st_mode)||!S_ISDIR(w.st_mode)||p.st_uid!=uid||w.st_uid!=uid||(p.st_mode&0077)||(w.st_mode&0077)||
    p.st_dev!=w.st_dev||p.st_ino==w.st_ino||!S_ISREG(f.st_mode)||f.st_uid!=uid||(f.st_mode&0777)!=0600||f.st_nlink!=1||f.st_size!=0||
    f.st_dev!=e.st_dev||f.st_ino!=e.st_ino){errno=EINVAL;return -1;}
 /* Confirm the absolute save identity currently resolves to this held parent.
  * Exclusive parent/path control is still required throughout the operation. */
 char dirname[1024];size_t parent_len=(size_t)(last-identity);
 if(!parent_len)parent_len=1;
 memcpy(dirname,identity,parent_len);dirname[parent_len]='\0';
 int mapped_fd=open(dirname,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
 if(mapped_fd<0)return -1;
 int matched=fstat(mapped_fd,&mapped)==0 && mapped.st_dev==p.st_dev && mapped.st_ino==p.st_ino;
 close(mapped_fd);if(!matched){errno=EINVAL;return -1;}
 HCAutosaveTarget next=HC_AUTOSAVE_TARGET_INITIALIZER;next.parent=parent;next.workspace=workspace;next.temporary=temp;next.owner=uid;
 memcpy(next.identity,identity,n+1);strcpy(next.destination,destination);strcpy(next.temp_name,name);next.ready=1;*t=next;return 0;
}
int hc_autosave_target_write(HCAutosaveTarget *t,const char *identity,const void *bytes,size_t size){
 if(!t||!t->ready||t->consumed||!identity||strcmp(t->identity,identity)){errno=EINVAL;return -1;}
 t->consumed=1;if(hc_write_checkpoint_file(t->temporary,t->owner,bytes,size)!=0)return -1;
 return hc_autosave_publish(t->parent,t->destination,t->workspace,t->temp_name,t->temporary,t->owner,bytes,size);
}
int hc_autosave_target_prepare(HCAutosaveTarget *t,int parent,uid_t uid,const uint8_t nonce[16],const char *identity,const char *destination){
 struct stat held,mapped;char dirname[1024],name[44];size_t n;
 if(!t||t->ready||!nonce||!identity||identity[0]!='/'||!component(destination)){errno=EINVAL;return -1;}
 n=strnlen(identity,sizeof dirname);if(n>=sizeof dirname){errno=EINVAL;return -1;}
 const char *last=strrchr(identity,'/');if(!last||strcmp(last+1,destination)){errno=EINVAL;return -1;}
 size_t len=(size_t)(last-identity);if(!len)len=1;memcpy(dirname,identity,len);dirname[len]='\0';
 int mappedfd=open(dirname,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(mappedfd<0)return -1;
 int match=fstat(parent,&held)==0&&fstat(mappedfd,&mapped)==0&&held.st_dev==mapped.st_dev&&held.st_ino==mapped.st_ino;
 close(mappedfd);if(!match){errno=EINVAL;return -1;}
 int workspace=hc_create_checkpoint_workspace(parent,uid,nonce,name);if(workspace<0)return -1;
 if(fsync(parent)!=0){close(workspace);return -1;}
 int temp=hc_create_checkpoint_file(workspace,uid,"save.tmp");if(temp<0){close(workspace);return -1;}
 if(fsync(workspace)!=0){close(temp);close(workspace);return -1;}
 if(hc_autosave_target_init(t,parent,workspace,temp,uid,identity,destination,"save.tmp")!=0){close(temp);close(workspace);return -1;}
 t->owns_fds=1;memcpy(t->workspace_name,name,sizeof name);return 0;
}
int hc_autosave_target_close(HCAutosaveTarget *t){
 if(!t||!t->ready||!t->owns_fds||t->busy){errno=EINVAL;return -1;}
 int a=close(t->temporary),b=close(t->workspace);t->ready=0;t->owns_fds=0;
 return a==0&&b==0?0:-1;
}
int hc_autosave_target_acquire(HCAutosaveTarget *t){if(!t||!t->ready||t->busy||t->consumed){errno=EINVAL;return -1;}t->busy=1;return 0;}
int hc_autosave_target_release(HCAutosaveTarget *t){if(!t||!t->ready||!t->busy){errno=EINVAL;return -1;}t->busy=0;return 0;}
