#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "isolated_saves.h"
#include "arguments.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
int main(void){
 const char *sha="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
 const char *other="1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
 char root[]="/tmp/hc-isolated-XXXXXX";assert(mkdtemp(root));
 int game=open(root,O_RDONLY|O_DIRECTORY|O_CLOEXEC);assert(game>=0);
 int native=openat(game,"cartridge.sram",O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600);assert(native>=0&&write(native,"native",6)==6&&!close(native));
 assert(hc_open_isolated_save_directory(game,geteuid(),"bad")<0);
 struct stat st;assert(fstatat(game,"hakchi",&st,AT_SYMLINK_NOFOLLOW)<0);
 int a=hc_open_isolated_save_directory(game,geteuid(),sha);assert(a>=0&&fcntl(a,F_GETFD)&FD_CLOEXEC);
 assert(!fstat(a,&st)&&S_ISDIR(st.st_mode)&&(st.st_mode&0777)==0700);
 int existing=openat(a,"battery.srm",O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600);assert(existing>=0&&write(existing,"compat",6)==6&&!close(existing));
 int b=hc_open_isolated_save_directory(game,geteuid(),sha);struct stat first,second;
 assert(b>=0&&!fstat(a,&first)&&!fstat(b,&second)&&first.st_dev==second.st_dev&&first.st_ino==second.st_ino);
 existing=openat(b,"battery.srm",O_RDONLY|O_NOFOLLOW|O_CLOEXEC);char saved[6];assert(existing>=0&&read(existing,saved,6)==6&&!memcmp(saved,"compat",6)&&!close(existing));assert(!unlinkat(a,"battery.srm",0));
 int c=hc_open_isolated_save_directory(game,geteuid(),other);assert(c>=0&&!fstat(c,&second)&&first.st_ino!=second.st_ino);
 native=openat(game,"cartridge.sram",O_RDONLY|O_CLOEXEC);char value[6];assert(native>=0&&read(native,value,6)==6&&!memcmp(value,"native",6)&&!close(native));
 close(a);close(b);close(c);
 int top=openat(game,"hakchi",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);assert(top>=0);
 int engine=openat(top,HC_COMPATIBILITY_ENGINE_ID,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);assert(engine>=0);
 assert(!unlinkat(engine,sha,AT_REMOVEDIR)&&!unlinkat(engine,other,AT_REMOVEDIR));
 assert(!symlinkat("/tmp",engine,sha));assert(hc_open_isolated_save_directory(game,geteuid(),sha)<0);assert(!unlinkat(engine,sha,0));
 assert(!fchmod(engine,0755));assert(hc_open_isolated_save_directory(game,geteuid(),sha)<0);assert(!fchmod(engine,0700));
 assert(!unlinkat(top,HC_COMPATIBILITY_ENGINE_ID,AT_REMOVEDIR));close(engine);close(top);
 assert(!unlinkat(game,"hakchi",AT_REMOVEDIR)&&!unlinkat(game,"cartridge.sram",0));close(game);assert(!rmdir(root));
 puts("PASS: isolated save directories, identity, native preservation and link refusal");
}
