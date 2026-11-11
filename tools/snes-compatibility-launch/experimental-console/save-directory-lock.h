#ifndef HC_SAVE_DIRECTORY_LOCK_H
#define HC_SAVE_DIRECTORY_LOCK_H
#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

/* Advisory lock shared by participating supervisors and recovery. It does
 * not stop nonparticipants or descendants after the owner exits. The caller
 * still authenticates ancestry and excludes every other writer. */
static int hc_save_directory_lock(int parent,uid_t uid){
 struct stat source,held;
 if(fstat(parent,&source)||!S_ISDIR(source.st_mode)||source.st_uid!=uid||(source.st_mode&0777)!=0700){errno=EINVAL;return -1;}
 int fd=openat(parent,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 if(fstat(fd,&held)||held.st_dev!=source.st_dev||held.st_ino!=source.st_ino||held.st_uid!=uid||(held.st_mode&0777)!=0700||flock(fd,LOCK_EX|LOCK_NB)){
  int saved=errno;close(fd);errno=saved?saved:EIO;return -1;
 }
 return fd;
}
/* Caller retains and authenticates its existing directory lock and excludes
 * descriptor-table races. The duplicate shares the same open-file lock, so
 * either owner may close its descriptor without unlocking the other. */
static inline int hc_save_directory_borrow_lock(int parent,int locked,uid_t uid){
 struct stat source,held,again;int flags=fcntl(locked,F_GETFL),fdflags=fcntl(locked,F_GETFD);
 if(parent<3||locked<3||flags<0||fdflags<0||(flags&O_ACCMODE)!=O_RDONLY||!(fdflags&FD_CLOEXEC)||
    fstat(parent,&source)||fstat(locked,&held)||!S_ISDIR(source.st_mode)||!S_ISDIR(held.st_mode)||
    source.st_uid!=uid||held.st_uid!=uid||(source.st_mode&0777)!=0700||(held.st_mode&0777)!=0700||
    source.st_dev!=held.st_dev||source.st_ino!=held.st_ino){errno=EINVAL;return -1;}
 int copy=fcntl(locked,F_DUPFD_CLOEXEC,3);if(copy<0)return -1;
 if(fstat(copy,&again)||again.st_dev!=held.st_dev||again.st_ino!=held.st_ino||again.st_uid!=held.st_uid||again.st_mode!=held.st_mode||flock(copy,LOCK_EX|LOCK_NB)){
  int saved=errno;close(copy);errno=saved?saved:EIO;return -1;
 }
 return copy;
}
#endif
