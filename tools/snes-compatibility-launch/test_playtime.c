#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "playtime.h"
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
int main(void){
 uint64_t value=7;char output[24];size_t length=99;
 assert(!hc_playtime_parse("0",1,&value)&&value==0);
 assert(!hc_playtime_parse("43",2,&value)&&value==43);
 assert(!hc_playtime_parse("43\n",3,&value)&&value==43);
 assert(!hc_playtime_parse("00043",5,&value)&&value==43);
 assert(!hc_playtime_parse("71",2,&value)&&value==71);
 assert(!hc_playtime_parse("18446744073709551615",20,&value)&&value==UINT64_MAX);
 const char *bad[]={"","-1","+1"," 1","1 ","1\r\n","1\n\n","18446744073709551616","999999999999999999999"};
 for(unsigned i=0;i<sizeof bad/sizeof bad[0];i++){value=7;assert(hc_playtime_parse(bad[i],strlen(bad[i]),&value)<0&&value==7);}
 HCPlaytimeInstant start={10,900000000},end={53,100000000};value=7;
 assert(!hc_playtime_accumulate(43,start,end,&value)&&value==85);
 end=(HCPlaytimeInstant){11,899999999};assert(!hc_playtime_accumulate(43,start,end,&value)&&value==43);
 end=(HCPlaytimeInstant){11,900000000};assert(!hc_playtime_accumulate(43,start,end,&value)&&value==44);
 value=7;
 end=(HCPlaytimeInstant){10,899999999};value=7;assert(hc_playtime_accumulate(0,start,end,&value)<0&&value==7);
 end=(HCPlaytimeInstant){11,1000000000};assert(hc_playtime_accumulate(0,start,end,&value)<0&&value==7);
 end=(HCPlaytimeInstant){12,900000000};assert(hc_playtime_accumulate(UINT64_MAX-1,start,end,&value)<0&&value==7);
 memset(output,'x',sizeof output);assert(!hc_playtime_format(43,output,sizeof output,&length)&&length==2&&!memcmp(output,"43",2));
 memset(output,'x',sizeof output);length=99;assert(hc_playtime_format(UINT64_MAX,output,19,&length)<0&&length==99&&output[0]=='x');
 assert(!hc_playtime_format(UINT64_MAX,output,20,&length)&&length==20&&!memcmp(output,"18446744073709551615",20));
 assert(!hc_playtime_parse(output,length,&value)&&value==UINT64_MAX);
 char path[]="/private/tmp/hc-playtime-file-XXXXXX";int writer=mkstemp(path);assert(writer>=0);
 assert(write(writer,"43",2)==2);assert(!fsync(writer));
 int reader=open(path,O_RDONLY|O_CLOEXEC);assert(reader>=0);
 value=7;assert(!hc_playtime_read(reader,&value)&&value==43);
 value=7;assert(hc_playtime_read(writer,&value)<0&&value==7);
 assert(!fcntl(reader,F_SETFD,0));assert(hc_playtime_read(reader,&value)<0&&value==7);assert(!fcntl(reader,F_SETFD,FD_CLOEXEC));
 assert(!fchmod(writer,0620));assert(hc_playtime_read(reader,&value)<0&&value==7);assert(!fchmod(writer,0600));
 char linked[sizeof path+8];assert(snprintf(linked,sizeof linked,"%s-link",path)>0);assert(!link(path,linked));
 assert(hc_playtime_read(reader,&value)<0&&value==7);assert(!unlink(linked));
 assert(!ftruncate(writer,0));value=7;assert(hc_playtime_read(reader,&value)<0&&value==7);
 assert(pwrite(writer,"18446744073709551616",20,0)==20);value=7;assert(hc_playtime_read(reader,&value)<0&&value==7);
 assert(!close(reader)&&!close(writer)&&!unlink(path));
 return 0;
}
