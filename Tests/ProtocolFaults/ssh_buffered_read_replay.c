/* Exercise the real SSH read loops and real recv callback. The libssh2 channel
   and TCP boundary model buffered stdout plus an empty stderr stream. */
#include <assert.h>
#include <time.h>
#include <stdlib.h>
static int replay_clock_gettime(clockid_t which, struct timespec *value);
static void *replay_malloc(size_t size);
static void *replay_realloc(void *pointer, size_t size);
#define clock_gettime replay_clock_gettime
#define malloc replay_malloc
#define realloc replay_realloc
#include "../../USBBridge/src/ssh_bridge.c"
#undef clock_gettime
#undef malloc
#undef realloc

static uint64_t elapsed;
static size_t delivered_bytes;
static size_t image_size=2826240;
static size_t fail_after=SIZE_MAX, stall_after=SIZE_MAX, largest_allocation;
static bool extra_stage, stage_delivered;
static int close_calls;
static const char stage_text[]="SWIFTHAKCHI_STARTUP_STAGE_V1 reading-text\n";
static void *replay_malloc(size_t size) { if(size>largest_allocation) largest_allocation=size; return malloc(size); }
static void *replay_realloc(void *pointer,size_t size) { if(size>largest_allocation) largest_allocation=size; return realloc(pointer,size); }
static ssh_session_t *current;
static int payload_stream;
static bool idle;
static bool receive_error;
static bool delayed_exit_status;
static bool channel_closed;
static int close_error;
static int replay_clock_gettime(clockid_t which, struct timespec *value) {
    value->tv_sec=(time_t)(elapsed/1000); value->tv_nsec=(long)(elapsed%1000)*1000000; return 0;
}
int tcp_recv(tcp_conn_t *c,uint8_t *buf,uint32_t len,int timeout_ms) {
    elapsed+=(uint64_t)timeout_ms; return 0; // no new wire data: stdout is already buffered in libssh2
}
void tcp_poll(tcp_conn_t *c,int timeout_ms) { elapsed+=(uint64_t)timeout_ms; }
LIBSSH2_CHANNEL *libssh2_channel_open_ex(LIBSSH2_SESSION *s,const char *type,unsigned int type_len,unsigned int window,unsigned int packet,const char *message,unsigned int message_len) { return (LIBSSH2_CHANNEL *)(uintptr_t)2; }
int libssh2_channel_process_startup(LIBSSH2_CHANNEL *c,const char *request,unsigned int request_len,const char *message,unsigned int message_len) { return 0; }
void libssh2_session_set_timeout(LIBSSH2_SESSION *s,long timeout) {}
void libssh2_session_set_blocking(LIBSSH2_SESSION *s,int blocking) {}
int libssh2_channel_get_exit_status(LIBSSH2_CHANNEL *c) { return delayed_exit_status && channel_closed ? 37 : 0; }
int libssh2_channel_eof(LIBSSH2_CHANNEL *c) { return !idle && delivered_bytes==image_size; }
int libssh2_channel_close(LIBSSH2_CHANNEL *c) { channel_closed=true; close_calls++; return close_error; }
int libssh2_channel_free(LIBSSH2_CHANNEL *c) { return 0; }
int libssh2_channel_send_eof(LIBSSH2_CHANNEL *c) { return 0; }
ssize_t libssh2_channel_write_ex(LIBSSH2_CHANNEL *c,int stream,const char *bytes,size_t length) { return (ssize_t)length; }
ssize_t libssh2_channel_read_ex(LIBSSH2_CHANNEL *c,int stream,char *buf,size_t capacity) {
    if(extra_stage && stream==1 && !stage_delivered) {
        assert(capacity>=sizeof(stage_text)-1); memcpy(buf,stage_text,sizeof(stage_text)-1);stage_delivered=true;return sizeof(stage_text)-1;
    }
    if(delivered_bytes>=fail_after) return LIBSSH2_ERROR_SOCKET_RECV;
    if(delivered_bytes>=stall_after) return LIBSSH2_ERROR_EAGAIN;
    if (receive_error) return LIBSSH2_ERROR_SOCKET_RECV;
    if (!idle && stream==payload_stream && delivered_bytes<image_size) {
        size_t count=image_size-delivered_bytes;
        if (count>2048) count=2048;
        if (count>capacity) count=capacity;
        memset(buf,0x5A,count); delivered_bytes+=count; return (ssize_t)count;
    }
    void *context=current;
    assert(ssh_recv_cb(0,buf,capacity,0,&context)<0);
    return LIBSSH2_ERROR_EAGAIN;
}
int main(void) {
    for (int stream=0;stream<2;stream++) {
    payload_stream=stream;
    for (int with_stdin=0;with_stdin<2;with_stdin++) {
        elapsed=0; delivered_bytes=0;
        ssh_session_t s={0}; s.ssh=(LIBSSH2_SESSION *)(uintptr_t)1; s.tcp=(tcp_conn_t *)(uintptr_t)1;
        current=&s; ssh_exec_result_t result={0}; uint8_t input=7;
        int status=with_stdin ? ssh_exec_stdin(&s,"synthetic",&input,1,&result,60000) : ssh_exec(&s,"synthetic",&result,60000);
        uint32_t count=stream?result.stderr_len:result.stdout_len;
        const char *bytes=stream?result.stderr_buf:result.stdout_buf;
        if (status || count!=image_size) {
            fprintf(stderr,"FAIL: buffered output throttled by empty stderr: mode=%s status=%d bytes=%u elapsed=%llu ms\n",with_stdin?"stdin":"exec",status,count,(unsigned long long)elapsed);
            ssh_result_free(&result); return 1;
        }
        for (size_t i=0;i<image_size;i++) assert((unsigned char)bytes[i]==0x5A);
        assert(elapsed<60000);
        ssh_result_free(&result);
        printf("PASS: %s drains 2826240 buffered %s bytes within existing 60-second deadline (%llu simulated ms)\n",with_stdin?"stdin exec":"exec",stream?"stderr":"stdout",(unsigned long long)elapsed);
    }
    }
    elapsed=0; delivered_bytes=0; idle=true;
    ssh_session_t s={0}; s.ssh=(LIBSSH2_SESSION *)(uintptr_t)1; s.tcp=(tcp_conn_t *)(uintptr_t)1; current=&s;
    ssh_exec_result_t result={0};
    assert(ssh_exec(&s,"idle synthetic",&result,1000)==-5);
    assert(result.stdout_len==0 && result.stderr_len==0 && elapsed>=1000 && elapsed<=1100);
    ssh_result_free(&result);
    puts("PASS: idle channel still times out without busy-spinning or false completion");
    elapsed=0; receive_error=true;
    assert(ssh_exec(&s,"failed synthetic",&result,1000)==LIBSSH2_ERROR_SOCKET_RECV);
    assert(result.stdout_len==0 && result.stderr_len==0);
    ssh_result_free(&result);
    puts("PASS: transport read errors are preserved");
    receive_error=false; idle=false; delayed_exit_status=true;
    for (int with_stdin=0;with_stdin<2;with_stdin++) {
        elapsed=0; delivered_bytes=image_size; channel_closed=false;
        ssh_exec_result_t status_result={0}; uint8_t input=7;
        int status=with_stdin ? ssh_exec_stdin(&s,"late status",&input,1,&status_result,1000) : ssh_exec(&s,"late status",&status_result,1000);
        assert(status==0 && status_result.exit_code==37);
        ssh_result_free(&status_result);
    }
    puts("PASS: remote exit status is read only after channel close");
    close_error=-66;
    for (int with_stdin=0;with_stdin<2;with_stdin++) {
        elapsed=0; delivered_bytes=image_size; channel_closed=false;
        ssh_exec_result_t status_result={0}; uint8_t input=7;
        int status=with_stdin ? ssh_exec_stdin(&s,"close error",&input,1,&status_result,1000) : ssh_exec(&s,"close error",&status_result,1000);
        assert(status==-66 && status_result.exit_code==-1);
        ssh_result_free(&status_result);
    }
    puts("PASS: channel-close failures cannot report command success");
    close_error=0; delayed_exit_status=false;
    for(int stream=0;stream<2;stream++) {
        size_t limit=stream?16384:12*1024*1024;
        payload_stream=stream; image_size=limit+1; delivered_bytes=0; elapsed=0; largest_allocation=0; close_calls=0;
        ssh_exec_result_t bounded={0};
        assert(ssh_exec_bounded(&s,"bounded",&bounded,1000,12*1024*1024,16384)==-7);
        assert((stream?bounded.stderr_len:bounded.stdout_len)==limit);
        assert(delivered_bytes==limit+1 && largest_allocation<=12*1024*1024+1 && close_calls==1);
        assert((stream?bounded.stderr_buf:bounded.stdout_buf)[limit]=='\0');
        ssh_result_free(&bounded);
    }
    puts("PASS: bounded streams stop after their limit probe without allocating beyond caps");
    for(int fault=0;fault<3;fault++) {
        payload_stream=0; image_size=fault==2?2048:10000; delivered_bytes=0;elapsed=0;close_calls=0;
        extra_stage=true;stage_delivered=false;fail_after=fault==0?2048:SIZE_MAX;stall_after=fault==1?2048:SIZE_MAX;close_error=fault==2?-66:0;
        ssh_exec_result_t partial={0};
        int status=ssh_exec_bounded(&s,"partial",&partial,1000,12*1024*1024,16384);
        assert(status==(fault==0?LIBSSH2_ERROR_SOCKET_RECV:(fault==1?-5:-66)));
        assert(partial.stdout_len==2048 && partial.stderr_len==sizeof(stage_text)-1 && close_calls==1);
        assert(memcmp(partial.stderr_buf,stage_text,sizeof(stage_text)-1)==0);
        if(fault==2) assert(partial.exit_code==-1);
        ssh_result_free(&partial);
    }
    puts("PASS: bounded partial stdout/stderr survives read errors, timeout and close failure");
    return 0;
}
