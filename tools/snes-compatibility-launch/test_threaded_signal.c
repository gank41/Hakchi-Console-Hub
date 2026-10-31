#define _POSIX_C_SOURCE 200809L
#include "control_pipe.h"
#include "control_command.h"
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>
int hc_forbidden_sigprocmask(int how,const sigset_t *set,sigset_t *old){(void)how;(void)set;(void)old;errno=EPERM;return -1;}
static void *send_closed(void *arg){int fd=*(int *)arg;assert(hc_control_command(fd,HC_COMMAND_QUIT)==-1 && errno==EPIPE);return NULL;}
int main(void){struct sigaction ignore={0};ignore.sa_handler=SIG_IGN;sigemptyset(&ignore.sa_mask);assert(sigaction(SIGPIPE,&ignore,NULL)==0);int p[2];assert(hc_control_pipe(p)==0);close(p[0]);pthread_t a,b;
 assert(!pthread_create(&a,NULL,send_closed,&p[1]));assert(!pthread_create(&b,NULL,send_closed,&p[1]));
 assert(!pthread_join(a,NULL));assert(!pthread_join(b,NULL));close(p[1]);return 0;}
