#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "isolated_saves.h"
#include "arguments.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int valid_hash(const char *sha){
 if(!sha||strnlen(sha,65)!=64)return 0;
 for(size_t i=0;i<64;i++)if(!((sha[i]>='0'&&sha[i]<='9')||(sha[i]>='a'&&sha[i]<='f')))return 0;
 return 1;
}
static int private_child(int parent,uid_t uid,const char *name){
 struct stat before,after;int created=0;
 if(mkdirat(parent,name,0700)==0)created=1;
 else if(errno!=EEXIST)return -1;
 if(fstatat(parent,name,&before,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(before.st_mode)||before.st_uid!=uid||(before.st_mode&0777)!=0700){errno=EACCES;return -1;}
 int child=openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(child<0)return -1;
 if(fstat(child,&after)||!S_ISDIR(after.st_mode)||after.st_uid!=uid||(after.st_mode&0777)!=0700||before.st_dev!=after.st_dev||before.st_ino!=after.st_ino||
    (created&&fsync(parent))){int saved=errno;close(child);errno=saved?saved:EIO;return -1;}
 return child;
}
int hc_open_isolated_save_directory(int game,uid_t uid,const char *sha){
 struct stat st;int flags=fcntl(game,F_GETFD);
 if(!valid_hash(sha)||flags<0||!(flags&FD_CLOEXEC)||fstat(game,&st)||!S_ISDIR(st.st_mode)||st.st_uid!=uid||(st.st_mode&0022)){errno=EINVAL;return -1;}
 int top=private_child(game,uid,"hakchi");if(top<0)return -1;
 int engine=private_child(top,uid,HC_COMPATIBILITY_ENGINE_ID);
 if(engine<0){int saved=errno;close(top);errno=saved;return -1;}
 int result=private_child(engine,uid,sha);int saved=errno;
 int close_engine=close(engine),close_top=close(top);
 if(close_engine||close_top){if(result>=0)close(result);errno=EIO;return -1;}
 if(result<0)errno=saved;return result;
}
