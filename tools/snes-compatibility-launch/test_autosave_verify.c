#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "autosave_verify.h"
#include <assert.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
int main(void){char path[]="/tmp/hc-autosave-XXXXXX";int fd=mkstemp(path);assert(fd>=0);
 assert(fchmod(fd,0600)==0 && write(fd,"SAVE",4)==4);
 assert(hc_autosave_verify(path,geteuid(),"SAVE",4)==0);
 assert(hc_autosave_verify(path,geteuid(),"FAIL",4)<0);
 assert(hc_autosave_verify(path,geteuid(),"SAVE",3)<0);
 assert(hc_autosave_verify(path,geteuid()+1,"SAVE",4)<0);
 assert(fchmod(fd,0666)==0 && hc_autosave_verify(path,geteuid(),"SAVE",4)<0);
 assert(fchmod(fd,0600)==0);char linkname[]="/tmp/hc-autosave-link-XXXXXX";int f=mkstemp(linkname);assert(f>=0);close(f);assert(unlink(linkname)==0 && symlink(path,linkname)==0);
 assert(hc_autosave_verify(linkname,geteuid(),"SAVE",4)<0);
 assert(unlink(linkname)==0 && close(fd)==0 && unlink(path)==0);return 0;}
