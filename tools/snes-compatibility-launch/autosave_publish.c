#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "autosave_publish.h"
#include "owned_directory.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static int component(const char *s){if(!s||!s[0]||!strcmp(s,".")||!strcmp(s,".."))return 0;size_t n=0;while(s[n]&&n<128){unsigned char c=(unsigned char)s[n++];if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_'||c=='.'))return 0;}return n<128;}
static int directory(int fd,uid_t uid,struct stat *s){return fstat(fd,s)==0&&S_ISDIR(s->st_mode)&&s->st_uid==uid&&(s->st_mode&0077)==0;}
int hc_autosave_publish(int parent,const char *destination,int workspace,const char *temporary,int source,uid_t owner,const void *expected,size_t length){
 struct stat p,w,src,entry,old,again;int had_old=0;
 if(!component(destination)||!component(temporary)||!strcmp(temporary,"previous")||
    !directory(parent,owner,&p)||!directory(workspace,owner,&w)||p.st_dev!=w.st_dev||p.st_ino==w.st_ino||
    hc_verify_checkpoint_file(source,owner,expected,length)!=0||fstat(source,&src)!=0||
    fstatat(workspace,temporary,&entry,AT_SYMLINK_NOFOLLOW)!=0||!S_ISREG(entry.st_mode)||
    entry.st_dev!=src.st_dev||entry.st_ino!=src.st_ino){errno=EINVAL;return -1;}
 if(fstatat(parent,destination,&old,AT_SYMLINK_NOFOLLOW)==0){
  if(!S_ISREG(old.st_mode)||old.st_uid!=owner||old.st_nlink!=1||(old.st_mode&0022)||
     (old.st_dev==src.st_dev&&old.st_ino==src.st_ino)){errno=EACCES;return -1;}
  int oldfd=openat(parent,destination,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
  if(oldfd<0)return -1;
  if(fstat(oldfd,&again)!=0||!S_ISREG(again.st_mode)||again.st_uid!=owner||again.st_nlink!=1||
     (again.st_mode&0022)||again.st_dev!=old.st_dev||again.st_ino!=old.st_ino||fsync(oldfd)!=0){
     int saved=errno;close(oldfd);errno=saved?saved:EIO;return -1;
  }
  if(close(oldfd)!=0)return -1;
  if(linkat(parent,destination,workspace,"previous",0)!=0)return -1;
  had_old=1;
  if(fstatat(workspace,"previous",&again,AT_SYMLINK_NOFOLLOW)!=0||again.st_dev!=old.st_dev||again.st_ino!=old.st_ino||fsync(workspace)!=0)return -3;
 }else if(errno!=ENOENT)return -1;
 /* Do not overwrite a destination changed since the check. The caller also
  * provides exclusive directory access; these checks are not a race lock. */
 if(had_old){if(fstatat(parent,destination,&again,AT_SYMLINK_NOFOLLOW)!=0||again.st_dev!=old.st_dev||again.st_ino!=old.st_ino){errno=EIO;return -3;}}
 else {if(fstatat(parent,destination,&again,AT_SYMLINK_NOFOLLOW)==0||errno!=ENOENT){errno=EEXIST;return -1;}}
#ifdef HC_AUTOSAVE_TEST_INJECT
 extern int hc_test_pre_rename_failure;
 if(hc_test_pre_rename_failure){errno=EIO;return had_old?-3:-1;}
#endif
 if(renameat(workspace,temporary,parent,destination)!=0)return had_old?-3:-1;
#ifdef HC_AUTOSAVE_TEST_AFTER_RENAME
 { extern void hc_test_after_autosave_rename(int); hc_test_after_autosave_rename(source); }
#endif
#ifdef HC_AUTOSAVE_TEST_INJECT
 extern int hc_test_post_rename_failure;
 if(hc_test_post_rename_failure){errno=EIO;return -2;}
#endif
 if(fsync(parent)!=0||fsync(workspace)!=0||fstatat(parent,destination,&again,AT_SYMLINK_NOFOLLOW)!=0||again.st_dev!=src.st_dev||again.st_ino!=src.st_ino||hc_verify_checkpoint_file(source,owner,expected,length)!=0){errno=EIO;return -2;}
 return 0;
}
