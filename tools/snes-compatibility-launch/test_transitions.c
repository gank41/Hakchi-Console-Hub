/* Host-only behavioral harness, never included in the ARM runtime. */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static int valid[256],fail_wait,fail_notify;
static uint64_t counter;
static char calls[16];static unsigned call_count;
static void record(char c){assert(call_count<sizeof calls-1);calls[call_count++]=c;calls[call_count]=0;}
static int hc_test_is_eventfd(int fd){return fd>=0 && fd<256 && valid[fd];}
static int hc_test_wait_counter(int fd,int timeout,uint64_t *value){assert(fd==28 && timeout==5000);record('W');*value=counter;return fail_wait?-1:0;}
static int hc_test_notify_counter(int fd){assert(fd==31 || fd==33);record(fd==31?'S':'F');return fail_notify?-1:0;}
#define HC_TRANSITION_TESTING 1
#include "transitions.c"
static void reset(void){memset(valid,0,sizeof valid);valid[28]=valid[31]=valid[33]=1;fail_wait=fail_notify=0;counter=1;call_count=0;calls[0]=0;}
int main(void){
    HCTransition t;
    reset();assert(hc_transition_init(&t,28,31,33)==0);assert(!strcmp(calls,""));
    assert(hc_transition_before_first_frame(&t)==0 && t.phase==HC_RUNNING);assert(!strcmp(calls,"W"));
    assert(hc_transition_begin_exit(&t)==0 && t.phase==HC_EXITING);assert(!strcmp(calls,"WS"));
    assert(hc_transition_finish_exit(&t)==0 && t.phase==HC_COMPLETE);assert(!strcmp(calls,"WSF"));
    assert(hc_transition_finish_exit(&t)!=0 && t.phase==HC_FAILED);assert(!strcmp(calls,"WSF"));
    for(int bad=0;bad<6;bad++){
        reset();int w=28,a=31,f=33;
        if(bad==0)w=2;if(bad==1)a=256;if(bad==2)f=31;if(bad==3)valid[28]=0;if(bad==4)valid[31]=0;if(bad==5)valid[33]=0;
        assert(hc_transition_init(&t,w,a,f)!=0 && t.phase==HC_FAILED);assert(!strcmp(calls,""));
    }
    for(int bad=0;bad<4;bad++){
        reset();assert(hc_transition_init(&t,28,31,33)==0);
        if(bad==0)fail_wait=1;if(bad==1)counter=2;if(bad==2)counter=0;if(bad==3)valid[28]=0;
        assert(hc_transition_before_first_frame(&t)!=0 && t.phase==HC_FAILED);assert(strchr(calls,'S')==NULL);
    }
    reset();assert(hc_transition_init(&t,28,31,33)==0);assert(hc_transition_begin_exit(&t)!=0);assert(!strcmp(calls,""));
    reset();assert(hc_transition_init(&t,28,31,33)==0);assert(hc_transition_finish_exit(&t)!=0);assert(!strcmp(calls,""));
    reset();assert(hc_transition_init(&t,28,31,33)==0);assert(hc_transition_before_first_frame(&t)==0);fail_notify=1;
    assert(hc_transition_begin_exit(&t)!=0 && t.phase==HC_FAILED);assert(hc_transition_begin_exit(&t)!=0);assert(!strcmp(calls,"WS"));
    reset();assert(hc_transition_init(&t,28,31,33)==0);assert(hc_transition_before_first_frame(&t)==0);assert(hc_transition_begin_exit(&t)==0);valid[33]=0;
    assert(hc_transition_finish_exit(&t)!=0 && t.phase==HC_FAILED);assert(!strcmp(calls,"WS"));
    assert(hc_transition_init(NULL,28,31,33)!=0);assert(hc_transition_before_first_frame(NULL)!=0);
    puts("PASS: Clover wait-before-frame, ordered exit signals, foreign descriptors, timeout/bad counters, lost notifications, duplicate calls and changed descriptor type refusal");
    return 0;
}
