#define _GNU_SOURCE
#ifdef NDEBUG
#error Assertions must remain enabled
#endif
#include "bounded_replace.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>
#ifndef __arm__
#error Isolated ARM Linux only
#endif
#ifndef PTRACE_SET_SYSCALL
#define PTRACE_SET_SYSCALL 23
#endif
struct regs {uint32_t r[18];};
struct param {uint32_t buffer,length,offset,flags,oob_buffer,oob_length,badblocks;};
struct info {char magic[8];uint32_t size,page,per,blocks;};
static unsigned char disk[BW_BYTES],block[BN_UNIT];
static const char *expected_sha="0d74ab86c4e3b4995ab3a72b1b66223cc0525a93987ef595faff7ee62f3ab86a",*target_sha="9e42160e1a03179cd6dbbd66844cb50021f2bbce5953a956081f09d1e4641104",*geometry_sha="b1a704aee2cd0b03566e43d269a2f26d2a49b75acbc4d0477ef202cec52157a6";
static const char nonce[]="11111111-1111-1111-1111-111111111111";
static void memory(pid_t child,uint32_t address,void *bytes,size_t count,int put) {
    struct iovec local={bytes,count},remote={(void *)(uintptr_t)address,count};
    assert((put ? process_vm_writev(child,&local,1,&remote,1,0):process_vm_readv(child,&local,1,&remote,1,0))==(ssize_t)count);
}
static void make_input(const char *fault) {
    FILE *f=fopen("/tmp/write-input","wb");assert(f);
    struct info g={{'h','a','k','c','h','i',0,0},24,2048,64,4096};if(!strcmp(fault,"invalid-reviewed-geometry")) g.page=4096;assert(fwrite(&g,1,24,f)==24);
    memset(block,0x35,sizeof block);
    for(unsigned i=0;i<56;++i) assert(fwrite(block,1,sizeof block,f)==sizeof block);
    for(unsigned i=0;i<56;++i) {
        memset(block,i==0?0xa5:i==55?0x77:0x35,sizeof block);assert(fwrite(block,1,sizeof block,f)==sizeof block);
    }
    if(!strcmp(fault,"target-bytes")) {assert(fseek(f,24+BW_BYTES,SEEK_SET)==0 && fputc(0,f)!=EOF);}
    if(!strcmp(fault,"preimage-bytes")) {assert(fseek(f,24,SEEK_SET)==0 && fputc(0,f)!=EOF);}
    if(!strcmp(fault,"geometry-bytes")) {assert(fseek(f,12,SEEK_SET)==0 && fputc(1,f)!=EOF);}
    if(!strcmp(fault,"trailing")) assert(fputc(0,f)!=EOF);
    assert(fclose(f)==0);
    if(!strcmp(fault,"short")) assert(truncate("/tmp/write-input",24+2*BW_BYTES-1)==0);
}
static void run(const char *helper,const char *fault,int verify,int expected_exit,int expected_writes) {
    make_input(fault);memset(disk,0x35,sizeof disk);
    if(!strcmp(fault,"late-mismatch")) disk[BW_BYTES-1]^=1;
    int input=open("/tmp/write-input",O_RDONLY),output=open("/tmp/write-output",O_CREAT|O_TRUNC|O_RDWR,0600);assert(input>=0 && output>=0);
    pid_t child=fork();assert(child>=0);
    if(!child) {
        assert(dup2(input,0)==0 && dup2(output,1)==1);close(input);close(output);
        assert(ptrace(PTRACE_TRACEME,0,0,0)==0);raise(SIGSTOP);
        execl(helper,helper,verify?"verify-active":"replace-active",!strcmp(fault,"digest")?"0000000000000000000000000000000000000000000000000000000000000000":expected_sha,!strcmp(fault,"target-digest")?"0000000000000000000000000000000000000000000000000000000000000000":target_sha,!strcmp(fault,"geometry-digest")?"0000000000000000000000000000000000000000000000000000000000000000":!strcmp(fault,"invalid-reviewed-geometry")?"6928e50fe81910d72d87f20b1b66ec6fccdf4bc8be2c0703824d428179f66ca9":geometry_sha,!strcmp(fault,"nonce")?"bad":nonce,(char *)0);_exit(99);
    }
    close(input);close(output);int status;assert(waitpid(child,&status,0)==child && WIFSTOPPED(status));
    assert(ptrace(PTRACE_SETOPTIONS,child,0,PTRACE_O_TRACESYSGOOD|PTRACE_O_EXITKILL)==0);
    struct regs r;struct param q;uint32_t call=0;int entering=1,override=0,nandfd=-1;long result=0;
    unsigned opens=0,geometries=0,reads=0,writes=0,flushes=0;uint32_t address=0;
    while(1) {
        assert(ptrace(PTRACE_SYSCALL,child,0,0)==0 && waitpid(child,&status,0)==child);
        if(WIFEXITED(status)) {if(WEXITSTATUS(status)!=expected_exit) fprintf(stderr,"case=%s expected=%d actual=%d\n",fault,expected_exit,WEXITSTATUS(status));assert(WEXITSTATUS(status)==expected_exit);break;}
        assert(WIFSTOPPED(status));int sig=WSTOPSIG(status);if(sig==SIGTRAP || sig==SIGSTOP) continue;assert(sig==(SIGTRAP|0x80));
        assert(ptrace(PTRACE_GETREGS,child,0,&r)==0);
        if(entering) {
            call=r.r[7];override=0;address=r.r[2];
            if(call==5 || call==322) {
                char path[32];uint32_t path_address=call==5?r.r[0]:r.r[1],flags=call==5?r.r[1]:r.r[2];
                memory(child,path_address,path,31,0);path[31]=0;assert(!strcmp(path,"/dev/nanda"));
                assert((flags & ~0x8000u)==(verify?0x20800u:0x20802u));++opens;
            } else if(call==397 && (int)r.r[0]==nandfd) {
                override=1;result=-38; /* Target kernel3.4 has no statx: exercise musl fallback. */
            } else if(call==197 && (int)r.r[0]==nandfd) {
                unsigned char st[104]={0};uint32_t mode=!strcmp(fault,"not-block")?S_IFREG:S_IFBLK;memcpy(st+16,&mode,4);
                memory(child,r.r[1],st,sizeof st,1);override=1;result=0;
            } else if(call==118 && (int)r.r[0]==nandfd) {
                ++flushes;override=1;result=!strcmp(fault,"flush")?-5:0;
            } else if(call==6 && (int)r.r[0]==nandfd && !strcmp(fault,"close-error")) {override=1;result=-5;
            } else if(call==4 && r.r[0]==1 && !strcmp(fault,"receipt-error")) {override=1;result=-28;
            } else if(call==54 && (int)r.r[0]==nandfd) {
                memory(child,address,&q,sizeof q,0);assert(!q.oob_buffer && !q.oob_length && !q.badblocks);
                if(r.r[1]==0x7679) {
                    assert(!geometries++ && q.length==24 && !q.offset && !q.flags);
                    struct info g={{'h','a','k','c','h','i',0,0},24,2048,64,4096};
                    if(!strcmp(fault,"geometry")) g.blocks=8192;
                    memory(child,q.buffer,&g,sizeof g,1);
                    if(!strcmp(fault,"geometry-reply")) q.length--;
                    result=0;
                } else {
                    assert(q.offset>=0x600000 && q.offset<=0xce0000 && q.offset%131072==0 && q.length==131072 && q.flags==1);
                    uint32_t offset=q.offset-0x600000;result=0;
                    if(r.r[1]==0x767c) {
                        ++reads;
                        if(!strcmp(fault,"recheck") && reads==57) disk[0]^=1;
                        memory(child,q.buffer,disk+offset,131072,1);
                        if(!strcmp(fault,"read-error") && reads==56) result=-5;
                        if(!strcmp(fault,"read-bad") && reads==56) q.badblocks=1;
                        if(!strcmp(fault,"read-reply")) q.offset+=131072;
                        if(!strcmp(fault,"read-flags")) q.flags=2;
                        if(!strcmp(fault,"known-tag")) q.flags=1;
                    } else {
                        assert(r.r[1]==0x767d && !verify && reads>=57 && flushes>0 && writes<2);
                        assert(q.offset==(writes==0?0x600000u:0xce0000u));++writes;
                        memory(child,q.buffer,block,131072,0);for(unsigned i=0;i<131072;++i) assert(block[i]==(writes==1?0xa5:0x77));
                        memcpy(disk+offset,block,131072);
                        if(!strcmp(fault,"write-error")) result=-5;
                        if(!strcmp(fault,"write-bad")) q.badblocks=1;
                        if(!strcmp(fault,"write-reply")) q.length--;
                        if(!strcmp(fault,"write-flags")) q.flags=2;
                        if(!strcmp(fault,"write-oob")) q.oob_buffer=4;
                        if(!strcmp(fault,"readback")) disk[offset]^=1;
                    }
                }
                if(strcmp(fault,"known-tag") && strcmp(fault,"read-flags") && strcmp(fault,"write-flags")) q.flags=0;
                memory(child,address,&q,sizeof q,1);override=1;
            }
            if(override) assert(ptrace(PTRACE_SET_SYSCALL,child,0,(void *)(intptr_t)-1)==0);
        } else {
            if((call==5 || call==322) && !override) nandfd=(int)r.r[0];
            if(override) {r.r[0]=(uint32_t)result;assert(ptrace(PTRACE_SETREGS,child,0,&r)==0);}
        }
        entering=!entering;
    }
    assert(writes==(unsigned)expected_writes);
    if(!strcmp(fault,"digest") || !strcmp(fault,"nonce") || !strcmp(fault,"short") || !strcmp(fault,"trailing") || !strcmp(fault,"target-digest") || !strcmp(fault,"geometry-digest") || !strcmp(fault,"target-bytes") || !strcmp(fault,"preimage-bytes") || !strcmp(fault,"geometry-bytes") || !strcmp(fault,"invalid-reviewed-geometry")) assert(opens==0 && geometries==0 && reads==0 && flushes==0);
    else assert(opens==1);
    FILE *f=fopen("/tmp/write-output","rb");assert(f);char text[256]={0};size_t count=fread(text,1,255,f);assert(fgetc(f)==EOF);fclose(f);
    if(expected_exit==0) {
        char wanted[256];snprintf(wanted,sizeof wanted,"SWIFTHAKCHI_SNES_WRITE_%s_V1 %s %s\n",verify?"PREFLIGHT":"VERIFIED",nonce,target_sha);assert(count==strlen(wanted) && !strcmp(text,wanted));
        for(unsigned i=0;i<BW_BYTES;++i) assert(disk[i]==(verify?0x35:i<BN_UNIT?0xa5:i>=BW_BYTES-BN_UNIT?0x77:0x35));
        assert(reads==(verify?56u:116u));
    } else assert(count==0);
    printf("ARM_WRITER_CASE_OK:%s:%s\n",fault,verify?"verify":"replace");
}
int main(int argc,char **argv) {
    assert(argc==2);
    run(argv[1],"success",1,0,0);run(argv[1],"success",0,0,2);
    run(argv[1],"digest",0,1,0);run(argv[1],"nonce",0,1,0);run(argv[1],"short",0,1,0);run(argv[1],"trailing",0,1,0);
    run(argv[1],"not-block",0,2,0);run(argv[1],"geometry",0,1,0);run(argv[1],"geometry-reply",0,2,0);run(argv[1],"flush",0,2,0);
    run(argv[1],"late-mismatch",0,3,0);run(argv[1],"recheck",0,3,0);
    run(argv[1],"read-error",0,2,0);run(argv[1],"read-bad",0,2,0);run(argv[1],"read-reply",0,2,0);run(argv[1],"read-flags",0,2,0);
    run(argv[1],"write-error",0,2,1);run(argv[1],"write-bad",0,2,1);run(argv[1],"write-reply",0,2,1);run(argv[1],"write-flags",0,2,1);
    run(argv[1],"readback",0,3,1);run(argv[1],"known-tag",0,0,2);
    run(argv[1],"target-digest",0,1,0);run(argv[1],"geometry-digest",0,1,0);run(argv[1],"target-bytes",0,1,0);
    run(argv[1],"preimage-bytes",0,1,0);run(argv[1],"geometry-bytes",0,1,0);run(argv[1],"invalid-reviewed-geometry",0,1,0);
    run(argv[1],"close-error",0,2,2);run(argv[1],"receipt-error",0,2,2);run(argv[1],"write-oob",0,2,1);
    puts("ARM_WRITER_ALL_CASES_PASSED");return 0;
}
