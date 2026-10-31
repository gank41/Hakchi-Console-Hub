#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "core_deletion.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef HC_CORE_TEST_INJECT
int hc_test_core_unlink_failure,hc_test_core_sync_failure;
#endif
int main(void){char dir[]="/tmp/hc-core-delete-XXXXXX";assert(mkdtemp(dir));int parent=open(dir,O_RDONLY|O_DIRECTORY|O_CLOEXEC);assert(parent>=0);
 int file=openat(parent,"core.so",O_RDWR|O_CREAT|O_EXCL,0600);assert(file>=0&&write(file,"CORE",4)==4);close(file);
 uint8_t session[16]={4},other[16]={5};HCCoreDeletion deletion=HC_CORE_DELETION_INITIALIZER;assert(hc_core_deletion_prepare(&deletion,parent,"core.so",geteuid(),session,7)==0);
 assert(hc_core_deletion_commit(&deletion,session,7,0)<0);assert(hc_core_deletion_commit(&deletion,other,7,1)<0);assert(hc_core_deletion_commit(&deletion,session,8,1)<0);assert(faccessat(parent,"core.so",F_OK,0)==0);
 assert(hc_core_deletion_commit(&deletion,session,7,1)==0);assert(faccessat(parent,"core.so",F_OK,0)<0);assert(hc_core_deletion_commit(&deletion,session,7,1)<0);assert(hc_core_deletion_close(&deletion)==0);
 file=openat(parent,"core.so",O_RDWR|O_CREAT|O_EXCL,0600);assert(file>=0);close(file);HCCoreDeletion changed=HC_CORE_DELETION_INITIALIZER;
 assert(hc_core_deletion_prepare(&changed,parent,"core.so",geteuid(),session,8)==0);assert(renameat(parent,"core.so",parent,"old.so")==0);
 file=openat(parent,"core.so",O_RDWR|O_CREAT|O_EXCL,0600);assert(file>=0);close(file);assert(hc_core_deletion_commit(&changed,session,8,1)<0);
 assert(faccessat(parent,"core.so",F_OK,0)==0);assert(hc_core_deletion_close(&changed)==0);
 HCCoreDeletion rewritten=HC_CORE_DELETION_INITIALIZER;assert(hc_core_deletion_prepare(&rewritten,parent,"core.so",geteuid(),session,9)==0);
 file=openat(parent,"core.so",O_WRONLY);assert(file>=0&&write(file,"X",1)==1);close(file);assert(hc_core_deletion_commit(&rewritten,session,9,1)<0);
 assert(hc_core_deletion_close(&rewritten)==0);
 file=openat(parent,"core.so",O_WRONLY|O_TRUNC);assert(file>=0&&write(file,"AAAA",4)==4);close(file);
 HCCoreDeletion same_size=HC_CORE_DELETION_INITIALIZER;assert(hc_core_deletion_prepare(&same_size,parent,"core.so",geteuid(),session,13)==0);
 file=openat(parent,"core.so",O_WRONLY);assert(file>=0&&pwrite(file,"BBBB",4,0)==4);struct stat altered;assert(fstat(file,&altered)==0);close(file);
 /* Simulate a coarse-timestamp filesystem; content digest must still differ. */
#ifdef __APPLE__
 same_size.msec=altered.st_mtimespec.tv_sec;same_size.mnsec=altered.st_mtimespec.tv_nsec;same_size.csec=altered.st_ctimespec.tv_sec;same_size.cnsec=altered.st_ctimespec.tv_nsec;
#else
 same_size.msec=altered.st_mtim.tv_sec;same_size.mnsec=altered.st_mtim.tv_nsec;same_size.csec=altered.st_ctim.tv_sec;same_size.cnsec=altered.st_ctim.tv_nsec;
#endif
 assert(hc_core_deletion_commit(&same_size,session,13,1)<0 && hc_core_deletion_close(&same_size)==0);
#ifdef HC_CORE_TEST_INJECT
 HCCoreDeletion errors=HC_CORE_DELETION_INITIALIZER;assert(hc_core_deletion_prepare(&errors,parent,"core.so",geteuid(),session,10)==0);
 hc_test_core_unlink_failure=1;assert(hc_core_deletion_commit(&errors,session,10,1)==-1 && faccessat(parent,"core.so",F_OK,0)==0);
 hc_test_core_unlink_failure=0;hc_test_core_sync_failure=1;assert(hc_core_deletion_commit(&errors,session,10,1)==-2 && faccessat(parent,"core.so",F_OK,0)<0);
 assert(hc_core_deletion_commit(&errors,session,10,1)<0 && hc_core_deletion_close(&errors)==0);
 file=openat(parent,"core.so",O_RDWR|O_CREAT|O_EXCL,0600);assert(file>=0);close(file);
#endif
 assert(linkat(parent,"core.so",parent,"hard.so",0)==0);HCCoreDeletion hard=HC_CORE_DELETION_INITIALIZER;
 assert(hc_core_deletion_prepare(&hard,parent,"core.so",geteuid(),session,11)<0);assert(unlinkat(parent,"hard.so",0)==0);
 assert(symlinkat("core.so",parent,"link.so")==0);assert(hc_core_deletion_prepare(&hard,parent,"link.so",geteuid(),session,12)<0);assert(unlinkat(parent,"link.so",0)==0);
 assert(unlinkat(parent,"core.so",0)==0&&unlinkat(parent,"old.so",0)==0);close(parent);assert(rmdir(dir)==0);return 0;}
