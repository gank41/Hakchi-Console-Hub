#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "child_process.h"
#include "control_command.h"
#include "control_pipe.h"
#include "checkpoint_receipt.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <sys/stat.h>
#include <unistd.h>

static int wait_for_exit(HCChild *child, int *status) {
    struct timespec pause = {0, 10000000};
    for (int i = 0; i < 500; ++i) {
        int result = hc_child_poll(child, status);
        if (result != 0) return result;
        nanosleep(&pause, NULL);
    }
    return 0;
}
int main(int argc, char **argv) {
    struct sigaction ignore_pipe = {0}; ignore_pipe.sa_handler=SIG_IGN;
    sigemptyset(&ignore_pipe.sa_mask); assert(sigaction(SIGPIPE,&ignore_pipe,NULL)==0);
    if (argc == 2 && strcmp(argv[1], "--probe") == 0) {
        char b;
        return ((fcntl(STDIN_FILENO, F_GETFL) & O_NONBLOCK) &&
                read(STDIN_FILENO, &b, 1) == -1 &&
                (errno == EAGAIN || errno == EWOULDBLOCK)) ? 0 : 1;
    }
    if (argc == 2 && strcmp(argv[1], "--rom-descriptor") == 0) {
        char data[4]={0}; return pread(210,data,3,0)==3 && !strcmp(data,"abc") ? 0 : 1;
    }
    if (argc == 2 && strcmp(argv[1], "--hang") == 0) { for (;;) pause(); }
    if (argc == 2 && strcmp(argv[1], "--fail") == 0) return 23;
    if (argc == 2 && strcmp(argv[1], "--receipt") == 0) {
        const uint8_t token[16]={1};
        return hc_checkpoint_send(200,token,17,HC_CP_SAVE,1)==0 ? 0 : 1;
    }
    if (argc == 2 && strcmp(argv[1], "--checkpoint-files") == 0) {
        const uint8_t token[16]={1};
        return pwrite(201,"SAVE",4,0)==4 && pwrite(202,"IMAGE",5,0)==5 &&
            hc_checkpoint_send(200,token,17,HC_CP_SAVE,1)==0 ? 0 : 1;
    }
    if (argc == 2 && strcmp(argv[1], "--read-command") == 0) {
        char buffer[16] = {0}; struct timespec delay = {0, 10000000};
        for (int i = 0; i < 300; ++i) {
            ssize_t n = read(STDIN_FILENO, buffer, sizeof buffer);
            if (n > 0) return n == 5 && memcmp(buffer, "QUIT\n", 5) == 0 ? 0 : 1;
            if (n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK)) return 1;
            nanosleep(&delay, NULL);
        }
        return 1;
    }
    HCChild child = HC_CHILD_INITIALIZER;
    struct sigaction saved_chld, ignored_chld = {0};
    ignored_chld.sa_handler = SIG_IGN; sigemptyset(&ignored_chld.sa_mask);
    assert(sigaction(SIGCHLD, &ignored_chld, &saved_chld) == 0);
    char *probe_ignored[] = {argv[0], "--probe", NULL};
    char *safe_env[] = {NULL};
    assert(hc_child_start(&child, argv[0], probe_ignored, safe_env) == -1);
    assert(child.pid == -1 && child.input == -1);
    ignored_chld.sa_handler = SIG_DFL; ignored_chld.sa_flags = SA_NOCLDWAIT;
    assert(sigaction(SIGCHLD, &ignored_chld, NULL) == 0);
    assert(hc_child_start(&child, argv[0], probe_ignored, safe_env) == -1);
    assert(child.pid == -1 && child.input == -1);
    assert(sigaction(SIGCHLD, &saved_chld, NULL) == 0);
    char *env[] = {NULL};
    char *bad[] = {"/missing/hakchi-test", NULL};
    assert(hc_child_start(&child, bad[0], bad, env) == -1);
    assert(child.pid == -1 && child.input == -1);
    char *probe[] = {argv[0], "--probe", NULL};
    assert(hc_child_start(&child, argv[0], probe, env) == 0);
    assert(child.pid > 0 && child.input >= 3);
    assert(hc_child_start(&child, argv[0], probe, env) == -1);
    int status = -1;
    assert(wait_for_exit(&child, &status) == 1);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    assert(child.pid == -1 && child.input == -1);
    assert(hc_child_poll(&child, &status) == -1);
    char *reader[] = {argv[0], "--read-command", NULL};
    assert(hc_child_start(&child, argv[0], reader, env) == 0);
    assert(hc_control_command(child.input, HC_COMMAND_QUIT) == 0);
    assert(wait_for_exit(&child, &status) == 1);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    int report[2];assert(hc_control_pipe(report)==0);
    char *reporter[] = {argv[0], "--receipt", NULL};
    assert(hc_child_start_reporting(&child,argv[0],reporter,env,report[1],report[1])==-1);
    assert(child.pid==-1 && child.input==-1);
    assert(hc_child_start_reporting(&child,argv[0],reporter,env,report[1],200)==0);
    close(report[1]);
    const uint8_t token[16]={1};HCCheckpoint cp;HCReceiptReader rr=HC_RECEIPT_READER_INITIALIZER;
    assert(hc_checkpoint_init(&cp,token,17)==0);
    uint8_t part[5];int ready=0;struct timespec delay={0,10000000};
    for(int i=0;i<500 && !ready;i++) {ssize_t count=read(report[0],part,sizeof part);
       if(count>0){ready=hc_checkpoint_feed(&rr,&cp,part,(size_t)count);assert(ready>=0);}
       else if(count<0 && (errno==EAGAIN || errno==EWOULDBLOCK))nanosleep(&delay,NULL);
       else assert(0);
    }
    assert(ready==1 && cp.phase==HC_CP_VERIFY_SAVE);close(report[0]);
    assert(wait_for_exit(&child,&status)==1 && WIFEXITED(status) && WEXITSTATUS(status)==0);
    char a[]="/tmp/hc-child-save-XXXXXX",b[]="/tmp/hc-child-image-XXXXXX";
    int save=mkstemp(a), image=mkstemp(b);assert(save>=0 && image>=0);
    assert(fchmod(save,0600)==0 && fchmod(image,0600)==0);
    assert(fcntl(save,F_SETFD,FD_CLOEXEC)==0 && fcntl(image,F_SETFD,FD_CLOEXEC)==0);
    int r[2];assert(hc_control_pipe(r)==0);char *files[]={argv[0],"--checkpoint-files",NULL};
    assert(hc_child_start_checkpoint(&child,argv[0],files,env,r[1],200,save,201,save,202)==-1);
    assert(hc_child_start_checkpoint(&child,argv[0],files,env,r[1],200,save,201,image,201)==-1);
    assert(hc_child_start_checkpoint(&child,argv[0],files,env,r[1],200,save,save,image,202)==-1);
    int alias=dup(save);assert(alias>=0 && fcntl(alias,F_SETFD,FD_CLOEXEC)==0);
    assert(hc_child_start_checkpoint(&child,argv[0],files,env,r[1],200,save,201,alias,202)==-1);close(alias);
    assert(fcntl(image,F_SETFD,0)==0);
    assert(hc_child_start_checkpoint(&child,argv[0],files,env,r[1],200,save,201,image,202)==-1);
    assert(fcntl(image,F_SETFD,FD_CLOEXEC)==0);
    int saveflags=fcntl(save,F_GETFL);assert(saveflags>=0 && fcntl(save,F_SETFL,saveflags|O_APPEND)==0);
    assert(hc_child_start_checkpoint(&child,argv[0],files,env,r[1],200,save,201,image,202)==-1);
    assert(fcntl(save,F_SETFL,saveflags)==0);
    struct sigaction default_pipe={0};default_pipe.sa_handler=SIG_DFL;sigemptyset(&default_pipe.sa_mask);
    assert(sigaction(SIGPIPE,&default_pipe,NULL)==0);
    assert(hc_child_start_checkpoint(&child,argv[0],files,env,r[1],200,save,201,image,202)==-1);
    assert(sigaction(SIGPIPE,&ignore_pipe,NULL)==0);
    assert(hc_child_start_checkpoint(&child,argv[0],files,env,r[1],200,save,201,image,202)==0);
    assert(wait_for_exit(&child,&status)==1 && WIFEXITED(status) && WEXITSTATUS(status)==0);
    char saved[5]={0},shot[6]={0};assert(pread(save,saved,4,0)==4 && !strcmp(saved,"SAVE"));
    assert(pread(image,shot,5,0)==5 && !strcmp(shot,"IMAGE"));
    assert(hc_child_start_checkpoint(&child,argv[0],files,env,r[1],200,save,201,image,202)==-1);
    uint8_t msg[32];assert(read(r[0],msg,sizeof msg)==32 && msg[28]==HC_CP_SAVE);
    close(r[0]);close(r[1]);close(save);close(image);assert(unlink(a)==0 && unlink(b)==0);
    char rompath[]="/tmp/hc-child-rom-XXXXXX";int writable=mkstemp(rompath);assert(writable>=0);
    assert(fchmod(writable,0600)==0 && write(writable,"abc",3)==3);
    int rom=open(rompath,O_RDONLY|O_CLOEXEC);assert(rom>=0);
    char *romargs[]={argv[0],"--rom-descriptor",NULL};
    assert(hc_child_start_rom(&child,argv[0],romargs,env,writable,210)==-1);
    assert(hc_child_start_rom(&child,argv[0],romargs,env,rom,rom)==-1);
    assert(hc_child_start_rom(&child,argv[0],romargs,env,rom,210)==0);
    assert(close(rom)==0); /* The inherited child descriptor remains valid. */
    assert(wait_for_exit(&child,&status)==1 && WIFEXITED(status) && WEXITSTATUS(status)==0);
    assert(close(writable)==0 && unlink(rompath)==0);
    char *fail[] = {argv[0], "--fail", NULL};
    assert(hc_child_start(&child, argv[0], fail, env) == 0);
    assert(wait_for_exit(&child, &status) == 1);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 23);
    assert(hc_child_start(&child, argv[0], fail, env) == 0);
    assert(waitpid(child.pid, &status, 0) > 0); /* Unexpected external reaper. */
    assert(hc_child_poll(&child, &status) == -1 && errno == ECHILD);
    assert(child.pid == -1 && child.input == -1);
    char *hang[] = {argv[0], "--hang", NULL};
    assert(hc_child_start(&child, argv[0], hang, env) == 0);
    assert(hc_child_poll(&child, &status) == 0);
    assert(hc_child_signal(&child, SIGUSR1) == -1);
    assert(hc_child_signal(&child, SIGTERM) == 0);
    assert(wait_for_exit(&child, &status) == 1);
    assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGTERM);
    assert(hc_child_signal(&child, SIGTERM) == -1);
    return 0;
}
