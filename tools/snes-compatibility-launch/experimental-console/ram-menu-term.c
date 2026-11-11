#define _POSIX_C_SOURCE 200809L
#include "ram-menu-term.h"
#include <errno.h>
#include <signal.h>
static volatile sig_atomic_t requested;
static int installed;
static void request_reset(int signal_number){int saved=errno;(void)signal_number;requested=1;errno=saved;}
int hc_ram_menu_term_install(void){
 struct sigaction old,action={0};
 if(installed || sigaction(SIGTERM,0,&old) || (old.sa_handler!=SIG_DFL && old.sa_handler!=SIG_IGN)){errno=EBUSY;return -1;}
 sigset_t term,previous,enabled;
 if(sigemptyset(&term) || sigaddset(&term,SIGTERM) || sigprocmask(SIG_BLOCK,&term,&previous))return -1;
 action.sa_handler=request_reset;action.sa_flags=0;
 if(sigemptyset(&action.sa_mask) || sigaction(SIGTERM,&action,0)){
  int saved=errno;(void)sigprocmask(SIG_SETMASK,&previous,0);errno=saved;return -1;
 }
 enabled=previous;
 if(sigdelset(&enabled,SIGTERM) || sigprocmask(SIG_SETMASK,&enabled,0)){
  int saved=errno;(void)sigaction(SIGTERM,&old,0);(void)sigprocmask(SIG_SETMASK,&previous,0);errno=saved;return -1;
 }
 installed=1;return 0;
}
int hc_ram_menu_term_requested(void){return requested!=0;}
