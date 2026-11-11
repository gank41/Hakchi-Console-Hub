/* Host-only manager simulation: no eventfd, device or hardware proof. */
#ifdef __arm__
#error "Host-only transition simulation"
#endif
#include "transitions.h"
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
int hc_transition_init(HCTransition *t,int w,int a,int f){if(!t||w<3||a<3||f<3||w==a||w==f||a==f)return -1;*t=(HCTransition){w,a,f,HC_INITIAL};return 0;}
int hc_transition_before_first_frame(HCTransition *t){if(!t||t->phase!=HC_INITIAL)return -1;fputs("HC-MANAGER-WAIT\n",stderr);if(getenv("HC_ENTRY_MANAGER_SIGNAL_DURING_WAIT")){if(raise(SIGTERM))return -1;fputs("HC-MANAGER-WAIT-SIGNAL\n",stderr);}if(getenv("HC_ENTRY_SELECTED_TAMPER_DURING_WAIT")){const char *p=getenv("HC_ENTRY_SELECTED_STATE_PARENT");int d=p?open(p,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC):-1;if(d<0)return -1;int f=openat(d,"savestate",O_WRONLY|O_NOFOLLOW|O_CLOEXEC);if(f<0||pwrite(f,"X",1,0)!=1||close(f)||close(d))return -1;}t->phase=HC_RUNNING;return 0;}
int hc_transition_begin_exit(HCTransition *t){if(!t||t->phase!=HC_RUNNING)return -1;fputs("HC-MANAGER-START\n",stderr);t->phase=HC_EXITING;return 0;}
int hc_transition_finish_exit(HCTransition *t){if(!t||t->phase!=HC_EXITING)return -1;fputs("HC-MANAGER-FINISH\n",stderr);t->phase=HC_COMPLETE;return 0;}
