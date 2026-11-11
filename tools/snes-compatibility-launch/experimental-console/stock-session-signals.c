#define _POSIX_C_SOURCE 200809L
#include "stock-session-signals.h"
#include "ram-menu-term.h"
#include <errno.h>
#include <signal.h>
#include <stddef.h>
int hc_stock_session_signals_install(void){
 struct sigaction pipe_before,term_before,child_before,ignored={0};
 if(sigaction(SIGPIPE,NULL,&pipe_before)||sigaction(SIGTERM,NULL,&term_before)||sigaction(SIGCHLD,NULL,&child_before))return -1;
 if((pipe_before.sa_handler!=SIG_DFL&&pipe_before.sa_handler!=SIG_IGN)||
    (term_before.sa_handler!=SIG_DFL&&term_before.sa_handler!=SIG_IGN)||
    child_before.sa_handler!=SIG_DFL||(child_before.sa_flags&SA_NOCLDWAIT)){errno=EBUSY;return -1;}
 ignored.sa_handler=SIG_IGN;if(sigemptyset(&ignored.sa_mask)||sigaction(SIGPIPE,&ignored,NULL))return -1;
 if(hc_ram_menu_term_install()){
  int saved=errno;if(sigaction(SIGPIPE,&pipe_before,NULL))saved=EIO;errno=saved;return -1;
 }
 return 0;
}
