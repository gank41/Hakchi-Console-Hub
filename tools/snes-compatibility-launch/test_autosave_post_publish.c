#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "autosave_publish.h"
#include <assert.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

void hc_test_after_autosave_rename(int fd) { assert(pwrite(fd,"BAD",3,0)==3); }

int main(void) {
 char dir[]="/tmp/hc-publish-after-XXXXXX"; assert(mkdtemp(dir));
 int parent=open(dir,O_RDONLY|O_DIRECTORY); assert(parent>=0);
 assert(!mkdirat(parent,"work",0700)); int work=openat(parent,"work",O_RDONLY|O_DIRECTORY); assert(work>=0);
 int old=openat(parent,"state",O_CREAT|O_EXCL|O_RDWR,0600);assert(old>=0&&write(old,"OLD",3)==3);
 int source=openat(work,"new",O_CREAT|O_EXCL|O_RDWR,0600);assert(source>=0&&write(source,"NEW",3)==3);
 assert(hc_autosave_publish(parent,"state",work,"new",source,geteuid(),"NEW",3)==-2);
 char b[3];int backup=openat(work,"previous",O_RDONLY);assert(backup>=0&&read(backup,b,3)==3&&!memcmp(b,"OLD",3));
 int current=openat(parent,"state",O_RDONLY);assert(current>=0&&read(current,b,3)==3&&!memcmp(b,"BAD",3));close(current);
 close(backup);close(old);close(source);assert(!unlinkat(work,"previous",0));assert(!unlinkat(parent,"state",0));
 source=openat(work,"new",O_CREAT|O_EXCL|O_RDWR,0600);assert(source>=0&&write(source,"NEW",3)==3);
 assert(hc_autosave_publish(parent,"state",work,"new",source,geteuid(),"NEW",3)==-2);
 assert(faccessat(work,"previous",F_OK,0)<0);current=openat(parent,"state",O_RDONLY);assert(current>=0&&read(current,b,3)==3&&!memcmp(b,"BAD",3));
 close(current);close(source);assert(!unlinkat(parent,"state",0));close(work);assert(!unlinkat(parent,"work",AT_REMOVEDIR));close(parent);assert(!rmdir(dir));return 0;
}
