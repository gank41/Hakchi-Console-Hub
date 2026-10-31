#define _POSIX_C_SOURCE 200809L
#include "child_process.h"
#include "control_pipe.h"
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <signal.h>
#include <spawn.h>
#include <stddef.h>
#include <sys/wait.h>
#include <unistd.h>

static int child_start(HCChild *c, const char *path, char *const argv[], char *const envp[], int report_fd, int target, int save_fd, int save_target, int image_fd, int image_target,int startup_fd,int startup_target,int exit_fd,int exit_target,int rom_fd,int rom_target,int confirm_fd,int confirm_target,int lock_fd,int lock_target) {
    if (!c || c->pid != -1 || c->input != -1 || !path || path[0] != '/' ||
        !argv || !argv[0] || !envp) { errno = EINVAL; return -1; }
    if (report_fd != -1 || target != -1) {
        struct stat st;
        int flags=fcntl(report_fd,F_GETFL), fdflags=fcntl(report_fd,F_GETFD);
        if (report_fd < 3 || target < 3 || target > 255 || report_fd == target ||
            flags == -1 || fdflags == -1 || (flags & O_ACCMODE) != O_WRONLY ||
            !(flags & O_NONBLOCK) || !(fdflags & FD_CLOEXEC) ||
            fstat(report_fd,&st) != 0 || !S_ISFIFO(st.st_mode)) { errno=EINVAL; return -1; }
        errno=0;
        if (fcntl(target,F_GETFD) != -1 || errno != EBADF) { errno=EINVAL; return -1; }
    }
    if (save_fd != -1 || save_target != -1 || image_fd != -1 || image_target != -1) {
        int sources[3]={report_fd,save_fd,image_fd};int targets[3]={target,save_target,image_target};
        struct stat a,b;
        if(report_fd<3 || save_fd<3 || image_fd<3 || fstat(save_fd,&a)!=0 || fstat(image_fd,&b)!=0 ||
           !S_ISREG(a.st_mode) || !S_ISREG(b.st_mode) || a.st_uid!=geteuid() || b.st_uid!=geteuid() ||
           (a.st_mode&0777)!=0600 || (b.st_mode&0777)!=0600 || a.st_nlink!=1 || b.st_nlink!=1 ||
           a.st_size!=0 || b.st_size!=0 || (a.st_dev==b.st_dev && a.st_ino==b.st_ino)) {errno=EINVAL;return -1;}
        for(int i=0;i<3;i++) {
            if(targets[i]<3 || targets[i]>255) {errno=EINVAL;return -1;}
            for(int j=0;j<3;j++) if(targets[i]==sources[j] || (i!=j && targets[i]==targets[j])) {errno=EINVAL;return -1;}
            errno=0;if(fcntl(targets[i],F_GETFD)!=-1 || errno!=EBADF) {errno=EINVAL;return -1;}
        }
        for(int i=1;i<3;i++) {
            int flags=fcntl(sources[i],F_GETFL),fdflags=fcntl(sources[i],F_GETFD);
            if(flags<0 || fdflags<0 || (flags&O_ACCMODE)!=O_RDWR || (flags&O_APPEND) || !(fdflags&FD_CLOEXEC)) {errno=EINVAL;return -1;}
        }
    }
    if(startup_fd!=-1||startup_target!=-1||exit_fd!=-1||exit_target!=-1){
        int sources[5]={report_fd,save_fd,image_fd,startup_fd,exit_fd};
        int targets[5]={target,save_target,image_target,startup_target,exit_target};
        struct stat pipes[3];int pipefds[3]={report_fd,startup_fd,exit_fd};
        for(int i=0;i<5;i++){
            if(sources[i]<3||targets[i]<3||targets[i]>255){errno=EINVAL;return -1;}
            for(int j=0;j<5;j++)if(targets[i]==sources[j]||(i!=j&&(targets[i]==targets[j]||sources[i]==sources[j]))){errno=EINVAL;return -1;}
            errno=0;if(fcntl(targets[i],F_GETFD)!=-1||errno!=EBADF){errno=EINVAL;return -1;}
        }
        for(int i=0;i<3;i++){
            int flags=fcntl(pipefds[i],F_GETFL),fdflags=fcntl(pipefds[i],F_GETFD);
            if(flags<0||fdflags<0||(flags&O_ACCMODE)!=O_WRONLY||!(flags&O_NONBLOCK)||!(fdflags&FD_CLOEXEC)||fstat(pipefds[i],&pipes[i])||!S_ISFIFO(pipes[i].st_mode)){errno=EINVAL;return -1;}
            for(int j=0;j<i;j++)if(pipes[i].st_dev==pipes[j].st_dev&&pipes[i].st_ino==pipes[j].st_ino){errno=EINVAL;return -1;}
        }
    }
    if(rom_fd!=-1||rom_target!=-1){
        int sources[6]={report_fd,save_fd,image_fd,startup_fd,exit_fd,rom_fd};
        int targets[6]={target,save_target,image_target,startup_target,exit_target,rom_target};
        struct stat rom,save,image;int flags=fcntl(rom_fd,F_GETFL),fdflags=fcntl(rom_fd,F_GETFD);
        if(save_fd==-1&&image_fd==-1&&startup_fd==-1&&exit_fd==-1){
            if(rom_fd<3||rom_target<3||rom_target>255||rom_target==rom_fd||flags<0||fdflags<0||
               (flags&O_ACCMODE)!=O_RDONLY||!(fdflags&FD_CLOEXEC)||fstat(rom_fd,&rom)||!S_ISREG(rom.st_mode)||
               rom.st_uid!=geteuid()||rom.st_nlink!=1||(rom.st_mode&0022)||rom.st_size<=0||rom.st_size>4*1024*1024+512){errno=EINVAL;return -1;}
            if(report_fd!=-1&&(rom_target==target||rom_target==report_fd||target==rom_fd||rom_fd==report_fd)){errno=EINVAL;return -1;}
            errno=0;if(fcntl(rom_target,F_GETFD)!=-1||errno!=EBADF){errno=EINVAL;return -1;}
        }else{
        if(startup_fd<3||exit_fd<3||rom_fd<3||rom_target<3||rom_target>255||flags<0||fdflags<0||
           (flags&O_ACCMODE)!=O_RDONLY||!(fdflags&FD_CLOEXEC)||fstat(rom_fd,&rom)||!S_ISREG(rom.st_mode)||
           rom.st_uid!=geteuid()||rom.st_nlink!=1||(rom.st_mode&0022)||rom.st_size<=0||rom.st_size>4*1024*1024+512||
           fstat(save_fd,&save)||fstat(image_fd,&image)||
           (rom.st_dev==save.st_dev&&rom.st_ino==save.st_ino)||(rom.st_dev==image.st_dev&&rom.st_ino==image.st_ino)){errno=EINVAL;return -1;}
        for(int i=0;i<6;i++)for(int j=0;j<6;j++)if(targets[i]==sources[j]||(i!=j&&(targets[i]==targets[j]||sources[i]==sources[j]))){errno=EINVAL;return -1;}
        errno=0;if(fcntl(rom_target,F_GETFD)!=-1||errno!=EBADF){errno=EINVAL;return -1;}
        }
    }
    if(confirm_fd!=-1||confirm_target!=-1){
        int sources[7]={report_fd,save_fd,image_fd,startup_fd,exit_fd,rom_fd,confirm_fd};
        int targets[7]={target,save_target,image_target,startup_target,exit_target,rom_target,confirm_target};
        struct stat p,other;int flags=fcntl(confirm_fd,F_GETFL),fdflags=fcntl(confirm_fd,F_GETFD);
        if(rom_fd<3||confirm_fd<3||confirm_target<3||confirm_target>255||flags<0||fdflags<0||
           (flags&O_ACCMODE)!=O_WRONLY||!(flags&O_NONBLOCK)||!(fdflags&FD_CLOEXEC)||fstat(confirm_fd,&p)||!S_ISFIFO(p.st_mode)){errno=EINVAL;return -1;}
        for(int i=0;i<7;i++)for(int j=0;j<7;j++)if(targets[i]==sources[j]||(i!=j&&(targets[i]==targets[j]||sources[i]==sources[j]))){errno=EINVAL;return -1;}
        int pipes[3]={report_fd,startup_fd,exit_fd};for(int i=0;i<3;i++)if(fstat(pipes[i],&other)||(p.st_dev==other.st_dev&&p.st_ino==other.st_ino)){errno=EINVAL;return -1;}
        errno=0;if(fcntl(confirm_target,F_GETFD)!=-1||errno!=EBADF){errno=EINVAL;return -1;}
    }
    if(lock_fd!=-1||lock_target!=-1){
        struct stat st;int flags=fcntl(lock_fd,F_GETFD);
        int sources[7]={report_fd,save_fd,image_fd,startup_fd,exit_fd,rom_fd,confirm_fd};
        int targets[7]={target,save_target,image_target,startup_target,exit_target,rom_target,confirm_target};
        if(lock_fd<3||lock_target<3||lock_target>255||lock_fd==lock_target||flags<0||!(flags&FD_CLOEXEC)||fstat(lock_fd,&st)||!S_ISDIR(st.st_mode)||st.st_uid!=geteuid()||(st.st_mode&0777)!=0700){errno=EINVAL;return -1;}
        for(int i=0;i<7;i++)if(lock_target==sources[i]||lock_target==targets[i]||lock_fd==sources[i]||lock_fd==targets[i]){errno=EINVAL;return -1;}
        errno=0;if(fcntl(lock_target,F_GETFD)!=-1||errno!=EBADF){errno=EBUSY;return -1;}
    }
    struct sigaction chld;
    if (sigaction(SIGCHLD, NULL, &chld) != 0) return -1;
    if (chld.sa_handler == SIG_IGN || (chld.sa_flags & SA_NOCLDWAIT)) {
        errno = EINVAL; return -1;
    }
    int p[2];
    if (hc_control_pipe(p) != 0) return -1;
    if ((report_fd != -1 && (target == p[0] || target == p[1])) ||
        (save_fd != -1 && (save_target==p[0] || save_target==p[1] || image_target==p[0] || image_target==p[1])) ||
        (startup_fd != -1 && (startup_target==p[0]||startup_target==p[1]||exit_target==p[0]||exit_target==p[1])) ||
        (rom_fd != -1 && (rom_target==p[0]||rom_target==p[1])) ||
        (confirm_fd != -1 && (confirm_target==p[0]||confirm_target==p[1])) ||
        (lock_fd != -1 && (lock_target==p[0]||lock_target==p[1]))) {
        close(p[0]); close(p[1]); errno=EINVAL; return -1;
    }
    posix_spawn_file_actions_t actions;
    int error = posix_spawn_file_actions_init(&actions);
    if (error) { close(p[0]); close(p[1]); errno = error; return -1; }
    if (report_fd != -1) {
        error = posix_spawn_file_actions_adddup2(&actions, report_fd, target);
        if (!error) error = posix_spawn_file_actions_addclose(&actions, report_fd);
    }
    if (!error && save_fd != -1) error=posix_spawn_file_actions_adddup2(&actions,save_fd,save_target);
    if (!error && save_fd != -1) error=posix_spawn_file_actions_adddup2(&actions,image_fd,image_target);
    if (!error && save_fd != -1) error=posix_spawn_file_actions_addclose(&actions,save_fd);
    if (!error && save_fd != -1) error=posix_spawn_file_actions_addclose(&actions,image_fd);
    if (!error && startup_fd != -1) error=posix_spawn_file_actions_adddup2(&actions,startup_fd,startup_target);
    if (!error && startup_fd != -1) error=posix_spawn_file_actions_adddup2(&actions,exit_fd,exit_target);
    if (!error && startup_fd != -1) error=posix_spawn_file_actions_addclose(&actions,startup_fd);
    if (!error && startup_fd != -1) error=posix_spawn_file_actions_addclose(&actions,exit_fd);
    if (!error && rom_fd != -1) error=posix_spawn_file_actions_adddup2(&actions,rom_fd,rom_target);
    if (!error && rom_fd != -1) error=posix_spawn_file_actions_addclose(&actions,rom_fd);
    if (!error && confirm_fd != -1) error=posix_spawn_file_actions_adddup2(&actions,confirm_fd,confirm_target);
    if (!error && confirm_fd != -1) error=posix_spawn_file_actions_addclose(&actions,confirm_fd);
    if (!error && lock_fd != -1) error=posix_spawn_file_actions_adddup2(&actions,lock_fd,lock_target);
    if (!error && lock_fd != -1) error=posix_spawn_file_actions_addclose(&actions,lock_fd);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, p[0], STDIN_FILENO);
    if (!error) error = posix_spawn_file_actions_addclose(&actions, p[0]);
    if (!error) error = posix_spawn_file_actions_addclose(&actions, p[1]);
    pid_t pid = -1;
    if (!error) error = posix_spawn(&pid, path, &actions, NULL, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    close(p[0]);
    if (error) { close(p[1]); errno = error; return -1; }
    c->pid = pid; c->input = p[1];
    return 0;
}
int hc_child_start(HCChild *c,const char *p,char *const a[],char *const e[]) {
    return child_start(c,p,a,e,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1);
}
int hc_child_start_rom(HCChild *c,const char *p,char *const a[],char *const e[],int fd,int target) {
    if(fd<0||target<0){errno=EINVAL;return -1;}
    return child_start(c,p,a,e,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,fd,target,-1,-1,-1,-1);
}
int hc_child_start_rom_reporting(HCChild *c,const char *p,char *const a[],char *const e[],int rom,int rt,int report,int report_target) {
    if(rom<0||rt<0||report<0||report_target<0){errno=EINVAL;return -1;}
    return child_start(c,p,a,e,report,report_target,-1,-1,-1,-1,-1,-1,-1,-1,rom,rt,-1,-1,-1,-1);
}
int hc_child_start_rom_reporting_lock(HCChild *c,const char *p,char *const a[],char *const e[],int rom,int rt,int report,int report_target,int lock,int lock_target) {
    if(rom<0||rt<0||report<0||report_target<0||lock<0||lock_target<0){errno=EINVAL;return -1;}
    return child_start(c,p,a,e,report,report_target,-1,-1,-1,-1,-1,-1,-1,-1,rom,rt,-1,-1,lock,lock_target);
}
int hc_child_start_rom_lock(HCChild *c,const char *p,char *const a[],char *const e[],int rom,int rt,int lock,int lock_target) {
    if(rom<0||rt<0||lock<0||lock_target<0){errno=EINVAL;return -1;}
    return child_start(c,p,a,e,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,rom,rt,-1,-1,lock,lock_target);
}
int hc_child_close_input(HCChild *c) {
    if (!c || c->pid != -1 || c->input < -1) { errno = EBUSY; return -1; }
    if (c->input == -1) return 0;
    int fd = c->input; c->input = -1;
    if (!close(fd)) return 0;
    int saved = errno; errno = 0;
    if (fcntl(fd, F_GETFD) != -1 || errno != EBADF) c->input = fd;
    errno = saved ? saved : EIO;
    return -1;
}
int hc_child_poll(HCChild *c, int *status) {
    if (!c || c->pid <= 0 || c->input < 0 || !status) { errno = EINVAL; return -1; }
    int child_status;
    pid_t result;
    unsigned attempts = 0;
    do { result = waitpid(c->pid, &child_status, WNOHANG); }
    while (result < 0 && errno == EINTR && ++attempts < 4);
    if (result == 0) return 0;
    if (result < 0) {
        if (errno == ECHILD) { c->pid = -1; (void)hc_child_close_input(c); errno = ECHILD; }
        return -1;
    }
    c->pid = -1;
    if (hc_child_close_input(c)) return -1;
    *status = child_status;
    return 1;
}
int hc_child_signal(HCChild *c, int sig) {
    if (!c || c->pid <= 0 || c->input < 0 || (sig != SIGTERM && sig != SIGKILL)) { errno = EINVAL; return -1; }
    return kill(c->pid, sig);
}

int hc_child_start_reporting(HCChild *c,const char *p,char *const a[],char *const e[],int f,int t) {
    if (f < 0 || t < 0) { errno=EINVAL; return -1; }
    return child_start(c,p,a,e,f,t,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1);
}
int hc_child_start_checkpoint(HCChild *c,const char *p,char *const a[],char *const e[],int r,int rt,int s,int st,int i,int it) {
    struct sigaction pipe_action;
    if(r<0 || rt<0 || s<0 || st<0 || i<0 || it<0) {errno=EINVAL;return -1;}
    if(sigaction(SIGPIPE,NULL,&pipe_action)!=0 || pipe_action.sa_handler!=SIG_IGN) {errno=EINVAL;return -1;}
    return child_start(c,p,a,e,r,rt,s,st,i,it,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1);
}
int hc_child_start_supervised(HCChild *c,const char *p,char *const a[],char *const e[],int r,int rt,int s,int st,int i,int it,int start,int start_t,int exitfd,int exit_t) {
    struct sigaction pipe_action;
    if(r<0||rt<0||s<0||st<0||i<0||it<0||start<0||start_t<0||exitfd<0||exit_t<0){errno=EINVAL;return -1;}
    if(sigaction(SIGPIPE,NULL,&pipe_action)!=0||pipe_action.sa_handler!=SIG_IGN){errno=EINVAL;return -1;}
    return child_start(c,p,a,e,r,rt,s,st,i,it,start,start_t,exitfd,exit_t,-1,-1,-1,-1,-1,-1);
}

int hc_child_start_verified(HCChild *c,const char *p,char *const a[],char *const e[],int r,int rt,int s,int st,int i,int it,int start,int start_t,int exitfd,int exit_t,int rom,int rom_t){
    struct sigaction pipe_action;
    if(r<0||rt<0||s<0||st<0||i<0||it<0||start<0||start_t<0||exitfd<0||exit_t<0||rom<0||rom_t<0){errno=EINVAL;return -1;}
    if(sigaction(SIGPIPE,NULL,&pipe_action)!=0||pipe_action.sa_handler!=SIG_IGN){errno=EINVAL;return -1;}
    return child_start(c,p,a,e,r,rt,s,st,i,it,start,start_t,exitfd,exit_t,rom,rom_t,-1,-1,-1,-1);
}

int hc_child_start_confirmed(HCChild *c,const char *p,char *const a[],char *const e[],int r,int rt,int s,int st,int i,int it,int start,int start_t,int exitfd,int exit_t,int rom,int rom_t,int confirm,int confirm_t){
 struct sigaction pipe_action;
 if(r<0||rt<0||s<0||st<0||i<0||it<0||start<0||start_t<0||exitfd<0||exit_t<0||rom<0||rom_t<0||confirm<0||confirm_t<0){errno=EINVAL;return -1;}
 if(sigaction(SIGPIPE,NULL,&pipe_action)!=0||pipe_action.sa_handler!=SIG_IGN){errno=EINVAL;return -1;}
 return child_start(c,p,a,e,r,rt,s,st,i,it,start,start_t,exitfd,exit_t,rom,rom_t,confirm,confirm_t,-1,-1);
}
int hc_child_start_confirmed_lock(HCChild *c,const char *p,char *const a[],char *const e[],int r,int rt,int s,int st,int i,int it,int start,int start_t,int exitfd,int exit_t,int rom,int rom_t,int confirm,int confirm_t,int lock,int lock_target){
 struct sigaction pipe_action;
 if(r<0||rt<0||s<0||st<0||i<0||it<0||start<0||start_t<0||exitfd<0||exit_t<0||rom<0||rom_t<0||confirm<0||confirm_t<0||lock<0||lock_target<0){errno=EINVAL;return -1;}
 if(sigaction(SIGPIPE,NULL,&pipe_action)!=0||pipe_action.sa_handler!=SIG_IGN){errno=EINVAL;return -1;}
 return child_start(c,p,a,e,r,rt,s,st,i,it,start,start_t,exitfd,exit_t,rom,rom_t,confirm,confirm_t,lock,lock_target);
}
