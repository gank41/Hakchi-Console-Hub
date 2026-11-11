#define _POSIX_C_SOURCE 200809L
/* Host-only fault injection for the real stock-session publication test. */
#ifdef __arm__
#error "Host-only interruption fixture"
#endif
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
void hc_test_save_prepare_after_binding(void){
 const char *point=getenv("HC_ENTRY_INJECT_PUBLICATION_CRASH");
 if(point&&!strcmp(point,"prepare"))_exit(93);
}
int hc_test_crash_rename(int olddir,const char *oldname,int newdir,const char *newname){
 const char *time_point=getenv("HC_ENTRY_INJECT_TIME_RENAME");
 if(time_point&&!strcmp(newname,"state.time")){
  if(!strcmp(time_point,"before"))_exit(101);
  int result=renameat(olddir,oldname,newdir,newname);
  if(!result&&!strcmp(time_point,"after"))_exit(102);
  return result;
 }
 const char *point=getenv("HC_ENTRY_INJECT_PUBLICATION_CRASH");
 if(point&&!strcmp(newname,"battery.srm")){
  if(!strcmp(point,"before"))_exit(91);
  int result=renameat(olddir,oldname,newdir,newname);
  if(!result&&!strcmp(point,"after"))_exit(92);
  return result;
 }
 return renameat(olddir,oldname,newdir,newname);
}
