#ifndef HC_TRANSITION_TESTING
#define _POSIX_C_SOURCE 200809L
#endif
#include "transitions.h"
#include <stddef.h>
#ifdef HC_TRANSITION_TESTING
#define is_eventfd hc_test_is_eventfd
#define wait_counter hc_test_wait_counter
#define notify_counter hc_test_notify_counter
#else
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
_Static_assert(sizeof(uint64_t)==8,"Clover uses 64-bit event counters");
static int is_eventfd(int fd){
    char path[64],value[64];
    int n=snprintf(path,sizeof path,"/proc/self/fd/%d",fd);
    if(n<=0 || n>=(int)sizeof path)return 0;
    ssize_t size=readlink(path,value,sizeof value);
    const char expected[]="anon_inode:[eventfd]";
    return size==(ssize_t)(sizeof expected-1) && !memcmp(value,expected,sizeof expected-1);
}
static int64_t milliseconds(void){
    struct timespec t;
    if(clock_gettime(CLOCK_MONOTONIC,&t)!=0)return -1;
    return (int64_t)t.tv_sec*1000+t.tv_nsec/1000000;
}
/* The verified original manager is the sole peer for each semaphore role.
 * Never change shared eventfd status flags or close the manager's descriptors.
 */
static int counter_io(int fd,int timeout,uint64_t *value,int output){
    int64_t now=milliseconds();
    if(now<0 || timeout<=0 || timeout>5000)return -1;
    const int64_t deadline=now+timeout;
    while((now=milliseconds())>=0 && now<deadline){
        struct pollfd p={.fd=fd,.events=output?POLLOUT:POLLIN,.revents=0};
        int result=poll(&p,1,(int)(deadline-now));
        if(result<0 && errno==EINTR)continue;
        if(result<=0 || (p.revents&(POLLERR|POLLHUP|POLLNVAL)) || !(p.revents&p.events))return -1;
        ssize_t count=output ? write(fd,value,sizeof *value):read(fd,value,sizeof *value);
        if(count<0 && (errno==EINTR || errno==EAGAIN))continue;
        return count==(ssize_t)sizeof *value ? 0:-1;
    }
    return -1;
}
static int wait_counter(int fd,int timeout,uint64_t *value){return counter_io(fd,timeout,value,0);}
static int notify_counter(int fd){uint64_t value=1;return counter_io(fd,5000,&value,1);}
#endif
static int refuse(HCTransition *s){if(s)s->phase=HC_FAILED;return -1;}
int hc_transition_init(HCTransition *s,int w,int a,int f){
    if(!s)return -1;
    s->wait=w;s->start=a;s->finish=f;s->phase=HC_FAILED;
    if(w<3 || w>255 || a<3 || a>255 || f<3 || f>255 || w==a || w==f || a==f)return -1;
    if(!is_eventfd(w) || !is_eventfd(a) || !is_eventfd(f))return -1;
    s->phase=HC_INITIAL;return 0;
}
int hc_transition_before_first_frame(HCTransition *s){
    uint64_t value=0;
    if(!s || s->phase!=HC_INITIAL || !is_eventfd(s->wait) || wait_counter(s->wait,5000,&value)!=0 || value!=1)return refuse(s);
    s->phase=HC_RUNNING;return 0;
}
int hc_transition_begin_exit(HCTransition *s){
    if(!s || s->phase!=HC_RUNNING || !is_eventfd(s->start) || notify_counter(s->start)!=0)return refuse(s);
    s->phase=HC_EXITING;return 0;
}
int hc_transition_finish_exit(HCTransition *s){
    if(!s || s->phase!=HC_EXITING || !is_eventfd(s->finish) || notify_counter(s->finish)!=0)return refuse(s);
    s->phase=HC_COMPLETE;return 0;
}
