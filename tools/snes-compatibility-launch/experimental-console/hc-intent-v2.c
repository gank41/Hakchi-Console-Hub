#define _GNU_SOURCE 1
#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "hc-intent-v2.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#define MAX_ENTRIES 4096
#define RECORD_CAP 256
static int component(const char *s,size_t max){size_t i=0;if(!s)return 0;for(;i<max&&s[i];i++){unsigned char c=(unsigned char)s[i];if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_'||c=='.'))return 0;}return i>0&&i<max&&!s[i]&&strcmp(s,".")&&strcmp(s,"..");}
static int workspace_ok(const char *s){if(!s||strnlen(s,44)!=43||memcmp(s,"checkpoint-",11))return 0;for(size_t i=11;i<43;i++)if(!((s[i]>='0'&&s[i]<='9')||(s[i]>='a'&&s[i]<='f')))return 0;return 1;}
static int parent_ok(int fd){struct stat st;int flags=fcntl(fd,F_GETFD);return flags>=0&&(flags&FD_CLOEXEC)&&fstat(fd,&st)==0&&S_ISDIR(st.st_mode)&&st.st_uid==geteuid()&&(st.st_mode&0777)==0700;}
static uint64_t hash(const char *s,size_t n){uint64_t h=UINT64_C(14695981039346656037);for(size_t i=0;i<n;i++){h^=(unsigned char)s[i];h*=UINT64_C(1099511628211);}return h;}
static int record(char *out,size_t cap,const char *session,const char *workspace,const char *region,HCIV2Kind kind){if(!component(session,96)||!workspace_ok(workspace)||!component(region,64)||(kind!=HCIV2_PERIODIC&&kind!=HCIV2_FINAL))return -1;int n=snprintf(out,cap,"HCI2\n%s\n%s\n%s\n%c\n",session,workspace,region,kind==HCIV2_PERIODIC?'P':'F');if(n<0||(size_t)n>=cap)return -1;int m=snprintf(out+n,cap-(size_t)n,"%016llx\n",(unsigned long long)hash(out,(size_t)n));return m==17?n+m:-1;}
static int verify(int parent,const char *name,const char *session,HCIV2Entry *out){char buf[RECORD_CAP],copy[RECORD_CAP],canonical[RECORD_CAP],*fields[6],*save=NULL;struct stat e,s;size_t used=0;if(strlen(name)!=40||memcmp(name,"intent2-",8))return -1;
 if(fstatat(parent,name,&e,AT_SYMLINK_NOFOLLOW)!=0||!S_ISREG(e.st_mode)||e.st_uid!=geteuid()||(e.st_mode&0777)!=0600||e.st_nlink!=1||e.st_size<=0||e.st_size>=RECORD_CAP)return -1;
 int fd=openat(parent,name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;if(fstat(fd,&s)!=0||!S_ISREG(s.st_mode)||s.st_dev!=e.st_dev||s.st_ino!=e.st_ino||s.st_size!=e.st_size||s.st_uid!=e.st_uid||s.st_nlink!=1||(s.st_mode&0777)!=0600){close(fd);return -1;}
 while(used<(size_t)e.st_size){ssize_t n=read(fd,buf+used,(size_t)e.st_size-used);if(n<0&&errno==EINTR)continue;if(n<=0){close(fd);return -1;}used+=(size_t)n;}if(close(fd)!=0||memchr(buf,0,used))return -1;buf[used]='\0';memcpy(copy,buf,used+1);
 for(size_t i=0;i<6;i++){fields[i]=strtok_r(i?NULL:copy,"\n",&save);if(!fields[i])return -1;}if(strtok_r(NULL,"\n",&save)||strcmp(fields[0],"HCI2")||strcmp(fields[1],session)||!workspace_ok(fields[2])||memcmp(fields[2]+11,name+8,32)||strlen(fields[4])!=1)return -1;
 HCIV2Kind k=fields[4][0]=='P'?HCIV2_PERIODIC:fields[4][0]=='F'?HCIV2_FINAL:0;int len=record(canonical,sizeof canonical,fields[1],fields[2],fields[3],k);if(len<0||(size_t)len!=used||memcmp(buf,canonical,used))return -1;if(out){memset(out,0,sizeof *out);strcpy(out->session,fields[1]);strcpy(out->workspace,fields[2]);strcpy(out->region,fields[3]);out->kind=k;}return 0;}
static int scan(int parent,const char *session,size_t *count,size_t *total){if(!count||!component(session,96)||!parent_ok(parent)){errno=EINVAL;return -1;}int fd=openat(parent,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;DIR *d=fdopendir(fd);if(!d){close(fd);return -1;}size_t seen=0,valid=0;int ok=1;struct dirent *e;for(;;){errno=0;e=readdir(d);if(!e){if(errno)ok=0;break;}if(++seen>MAX_ENTRIES){ok=0;break;}if(!strncmp(e->d_name,"intent",6)){if(strncmp(e->d_name,"intent2-",8)||verify(parent,e->d_name,session,NULL)!=0){ok=0;break;}valid++;}}if(closedir(d)!=0)ok=0;if(!ok){errno=EIO;return -1;}*count=valid;if(total)*total=seen;return 0;}
int hciv2_scan(int parent,const char *session,size_t *count){return scan(parent,session,count,NULL);}
int hciv2_inventory(int parent,const char *session,HCIV2Entry *entries,size_t capacity,size_t *count){
 if(!count||(!entries&&capacity)||!component(session,96)||!parent_ok(parent)){errno=EINVAL;return -1;}
 HCIV2Entry *temporary=calloc(MAX_ENTRIES,sizeof(*temporary));if(!temporary)return -1;
 int fd=openat(parent,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0){free(temporary);return -1;}
 DIR *dir=fdopendir(fd);if(!dir){int saved=errno;close(fd);free(temporary);errno=saved;return -1;}
 size_t seen=0,used=0;int ok=1;struct dirent *entry;
 for(;;){errno=0;entry=readdir(dir);if(!entry){if(errno)ok=0;break;}if(++seen>MAX_ENTRIES){ok=0;break;}if(!strncmp(entry->d_name,"intent",6)){
  if(strncmp(entry->d_name,"intent2-",8)||verify(parent,entry->d_name,session,&temporary[used])!=0){ok=0;break;}
  struct stat workspace;if(fstatat(parent,temporary[used].workspace,&workspace,AT_SYMLINK_NOFOLLOW)==0){
   if(!S_ISDIR(workspace.st_mode)||workspace.st_uid!=geteuid()||(workspace.st_mode&0777)!=0700){ok=0;break;}temporary[used].workspace_present=1;
  }else if(errno!=ENOENT){ok=0;break;}used++;
 }else if(!strncmp(entry->d_name,"checkpoint-",11)){
  char intent[41];struct stat workspace;
  if(!workspace_ok(entry->d_name)||fstatat(parent,entry->d_name,&workspace,AT_SYMLINK_NOFOLLOW)!=0||!S_ISDIR(workspace.st_mode)||workspace.st_uid!=geteuid()||(workspace.st_mode&0777)!=0700){ok=0;break;}
  memcpy(intent,"intent2-",8);memcpy(intent+8,entry->d_name+11,33);if(verify(parent,intent,session,NULL)!=0){ok=0;break;}
 }}
 if(closedir(dir)!=0)ok=0;if(!ok){free(temporary);errno=EIO;return -1;}if(used>capacity){free(temporary);errno=ENOSPC;return -1;}
 if(used)memcpy(entries,temporary,used*sizeof(*entries));*count=used;free(temporary);return 0;
}
int hciv2_create(int parent,const char *session,const char *workspace,const char *region,HCIV2Kind kind){char data[RECORD_CAP],name[41];struct stat existing;size_t count,total;int len=record(data,sizeof data,session,workspace,region,kind);if(len<0||!parent_ok(parent)){errno=EINVAL;return -1;}if(scan(parent,session,&count,&total)!=0)return -1;if(total>=MAX_ENTRIES-1){errno=EOVERFLOW;return -1;}if(fstatat(parent,workspace,&existing,AT_SYMLINK_NOFOLLOW)==0){errno=EEXIST;return -1;}if(errno!=ENOENT)return -1;memcpy(name,"intent2-",8);memcpy(name+8,workspace+11,33);
 int fd=openat(parent,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return -1;int ok=fchmod(fd,0600)==0;size_t off=0;while(ok&&off<(size_t)len){ssize_t n=write(fd,data+off,(size_t)len-off);if(n<0&&errno==EINTR)continue;if(n<=0){ok=0;break;}off+=(size_t)n;}if(ok&&fsync(fd)!=0)ok=0;if(close(fd)!=0)ok=0;if(fsync(parent)!=0)ok=0;if(!ok){errno=EIO;return -2;}return 0;}

int hciv2_remove_confirmed_orphan(int parent,const char *session,const char *workspace,const char *region,HCIV2Kind kind){
 char name[41];HCIV2Entry entry;struct stat before,after,remaining;
 if(!parent_ok(parent)||!component(session,96)||!workspace_ok(workspace)||!component(region,64)||
    (kind!=HCIV2_PERIODIC&&kind!=HCIV2_FINAL)){errno=EINVAL;return -1;}
 memcpy(name,"intent2-",8);memcpy(name+8,workspace+11,33);
 if(verify(parent,name,session,&entry)||strcmp(entry.workspace,workspace)||strcmp(entry.region,region)||entry.kind!=kind||
    fstatat(parent,name,&before,AT_SYMLINK_NOFOLLOW)){errno=EPROTO;return -1;}
 if(fstatat(parent,workspace,&remaining,AT_SYMLINK_NOFOLLOW)==0){errno=EBUSY;return -1;}
 if(errno!=ENOENT)return -1;
 if(fstatat(parent,name,&after,AT_SYMLINK_NOFOLLOW)||!S_ISREG(after.st_mode)||before.st_dev!=after.st_dev||before.st_ino!=after.st_ino){errno=EIO;return -1;}
 if(unlinkat(parent,name,0))return -1;
 if(fsync(parent)){errno=EIO;return -2;}
 return 0;
}

int hciv2_remove_retired(int parent,const char *session,const char *workspace,const char *region){
 return hciv2_remove_confirmed_orphan(parent,session,workspace,region,HCIV2_PERIODIC);
}
