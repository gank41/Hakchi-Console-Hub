#define _GNU_SOURCE
#ifdef NDEBUG
#error Tests require assertions enabled with -UNDEBUG
#endif
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>
#if !defined(__arm__)
#error Run this test only inside the isolated Linux ARM VM
#endif
#ifndef PTRACE_SET_SYSCALL
#define PTRACE_SET_SYSCALL 23
#endif
struct regs { uint32_t r[18]; };
struct param { uint32_t buffer,length,offset,flags,oob_buffer,oob_length,badblocks; };
struct info { char magic[8];uint32_t size,page,per_block,blocks; };
static void memory(pid_t child,uint32_t address,void *buffer,size_t count,int write) {
    struct iovec local={buffer,count},remote={(void *)(uintptr_t)address,count};
    ssize_t n=write?process_vm_writev(child,&local,1,&remote,1,0):process_vm_readv(child,&local,1,&remote,1,0);
    assert(n==(ssize_t)count);
}
static void child_string(pid_t child,uint32_t address,char out[32]) {
    memory(child,address,out,31,0);out[31]=0;
    assert(memchr(out,0,32));
}
static void run(const char *helper,const char *mode,const char *count,int expected,unsigned expected_reads,size_t expected_bytes) {
    int output=open("/tmp/helper-output",O_CREAT|O_TRUNC|O_RDWR,0600);assert(output>=0);
    pid_t child=fork();assert(child>=0);
    if(!child) {
        assert(dup2(output,1)==1);close(output);
        assert(ptrace(PTRACE_TRACEME,0,0,0)==0);raise(SIGSTOP);
        if(!strcmp(count,"geometry")) execl(helper,helper,"geometry",(char *)0);
        else execl(helper,helper,"read-active",count,(char *)0);
        _exit(99);
    }
    close(output);int status;assert(waitpid(child,&status,0)==child && WIFSTOPPED(status));
    assert(ptrace(PTRACE_SETOPTIONS,child,0,PTRACE_O_TRACESYSGOOD|PTRACE_O_EXITKILL)==0);
    int entering=1,override=0,nandfd=-1;long result=0;uint32_t syscall_number=0;
    unsigned opens=0,geometry=0,reads=0,writes=0;
    struct param request;struct regs registers;
    unsigned char block[131072];
    while(1) {
        assert(ptrace(PTRACE_SYSCALL,child,0,0)==0);
        assert(waitpid(child,&status,0)==child);
        if(WIFEXITED(status)) { assert(WEXITSTATUS(status)==expected);break; }
        assert(WIFSTOPPED(status));
        int sig=WSTOPSIG(status);
        if(sig==SIGTRAP || sig==SIGSTOP) continue;
        assert(sig==(SIGTRAP|0x80));
        assert(ptrace(PTRACE_GETREGS,child,0,&registers)==0);
        if(entering) {
            override=0;syscall_number=registers.r[7];
            if(syscall_number==5) {
                char path[32];child_string(child,registers.r[0],path);
                assert(!strcmp(path,"/dev/nanda") && registers.r[1]==0x20800);
                ++opens;
                if(!strcmp(mode,"open-error")) { override=1;result=-2; }
            } else if(syscall_number==54) {
                assert((int)registers.r[0]==nandfd && nandfd>=0);
                memory(child,registers.r[2],&request,sizeof request,0);
                assert(!request.oob_buffer && !request.oob_length && !request.badblocks);
                if(registers.r[1]==0x7679) {
                    assert(!geometry++ && request.length==24 && !request.offset && !request.flags);
                    struct info info={{'h','a','k','c','h','i',0,0},24,2048,64,4096};
                    if(!strcmp(mode,"bad-geometry")) info.page=4096;
                    if(!strcmp(mode,"bad-magic")) info.magic[0]='x';
                    memory(child,request.buffer,&info,sizeof info,1);result=0;
                    if(!strcmp(mode,"geometry-short")) request.length--;
                    if(!strcmp(mode,"geometry-pointer")) request.buffer+=4;
                    if(!strcmp(mode,"geometry-flags")) request.flags=1;
                } else {
                    assert(registers.r[1]==0x767c); /* Any write/erase/unknown ioctl fails the test. */
                    assert(request.length==131072 && request.flags==1);
                    assert(request.offset==0x600000+reads*131072 && request.offset<=0xce0000);
                    ++reads;request.flags=0;result=0;
                    if(!strcmp(mode,"read-error")) result=-5;
                    else if(!strcmp(mode,"bad-block") && reads==2) request.badblocks=1;
                    else {
                        memset(block,(int)(request.offset/131072),sizeof block);
                        memory(child,request.buffer,block,sizeof block,1);
                    }
                    if(!strcmp(mode,"changed-reply")) request.length--;
                    if(!strcmp(mode,"tagged-block")) request.flags=1;
                    if(!strcmp(mode,"unknown-flags")) request.flags=2;
                }
                memory(child,registers.r[2],&request,sizeof request,1);override=1;
            } else if(syscall_number==4) {
                assert(registers.r[0]==1);++writes;
                if(!strcmp(mode,"output-error")) { override=1;result=-28; }
            }
            if(override) assert(ptrace(PTRACE_SET_SYSCALL,child,0,(void *)(intptr_t)-1)==0);
        } else {
            if(syscall_number==5 && !override) nandfd=(int)registers.r[0];
            if(override) { registers.r[0]=(uint32_t)result;assert(ptrace(PTRACE_SETREGS,child,0,&registers)==0); }
        }
        entering=!entering;
    }
    assert(reads==expected_reads);
    struct stat st;assert(stat("/tmp/helper-output",&st)==0 && (size_t)st.st_size==expected_bytes);
    if(expected_bytes==24) {
        FILE *file=fopen("/tmp/helper-output","rb");assert(file);
        struct info info;assert(fread(&info,1,sizeof info,file)==sizeof info && fgetc(file)==EOF);fclose(file);
        assert(!memcmp(info.magic,"hakchi\0\0",8) && info.size==24 && info.page==2048 && info.per_block==64 && info.blocks==4096);
        assert(reads==0 && geometry==1 && writes==1);
    } else if(expected_bytes) {
        FILE *file=fopen("/tmp/helper-output","rb");assert(file);
        for(size_t offset=0;offset<expected_bytes;offset+=sizeof block) {
            assert(fread(block,1,sizeof block,file)==sizeof block);
            for(size_t j=0;j<sizeof block;++j) assert(block[j]==0x30+offset/sizeof block);
        }
        assert(fgetc(file)==EOF);fclose(file);
    }
    if(!strcmp(mode,"invalid")) assert(opens==0 && geometry==0 && writes==0);
    else assert(opens==1);
    if(!strcmp(mode,"output-error")) assert(reads==1 && writes==1);
    printf("ARM_HELPER_CASE_OK:%s:%s\n",mode,count);
}
int main(int argc,char **argv) {
    assert(argc==2);
    run(argv[1],"geometry","geometry",0,0,24);
    run(argv[1],"bad-geometry","geometry",1,0,0);
    run(argv[1],"bad-magic","geometry",2,0,0);
    run(argv[1],"geometry-short","geometry",2,0,0);
    run(argv[1],"geometry-pointer","geometry",2,0,0);
    run(argv[1],"geometry-flags","geometry",2,0,0);
    run(argv[1],"invalid","0",1,0,0);
    run(argv[1],"invalid","57",1,0,0);
    run(argv[1],"invalid","18446744073709551615",1,0,0);
    run(argv[1],"invalid","-1",1,0,0);
    run(argv[1],"open-error","1",2,0,0);
    run(argv[1],"bad-geometry","1",1,0,0);
    run(argv[1],"bad-magic","1",2,0,0);
    run(argv[1],"read-error","1",2,1,0);
    run(argv[1],"bad-block","3",2,2,131072);
    run(argv[1],"changed-reply","1",2,1,0);
    run(argv[1],"output-error","2",2,1,0);
    run(argv[1],"tagged-block","1",0,1,131072);
    run(argv[1],"unknown-flags","2",2,1,0);
    run(argv[1],"success","56",0,56,7340032);
    puts("ARM_HELPER_ALL_CASES_PASSED");return 0;
}
