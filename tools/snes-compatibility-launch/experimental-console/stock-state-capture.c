#define _POSIX_C_SOURCE 200809L
#include "stock-state-capture.h"
#include "atomic_pipe.h"
#include "recovery-binding.h"
#include "nonce-sequence.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(HC_STOCK_STATE_ARCHIVE_TEST_HOOK) && defined(__arm__)
#error "State archive interruption injection is host-only"
#endif
#ifdef HC_STOCK_STATE_ARCHIVE_TEST_HOOK
extern void hc_test_state_archive_hook(int,HCStockStateArchive *);
#define HC_STATE_ARCHIVE_HOOK(stage) hc_test_state_archive_hook(stage,out)
#else
#define HC_STATE_ARCHIVE_HOOK(stage) ((void)0)
#endif
#define HC_STATE_MAX (16u*1024u*1024u)
static int game_valid(const HCStockGameSession *game){
 if(!game||!game->rom.ready||strnlen(game->game,sizeof game->game)!=11||memcmp(game->game,"CLV-U-",6)||strnlen(game->rom.sha256,sizeof game->rom.sha256)!=64)return 0;
 for(size_t i=6;i<11;i++)if(!((game->game[i]>='A'&&game->game[i]<='Z')||(game->game[i]>='0'&&game->game[i]<='9')))return 0;
 for(size_t i=0;i<64;i++)if(!((game->rom.sha256[i]>='0'&&game->rom.sha256[i]<='9')||(game->rom.sha256[i]>='a'&&game->rom.sha256[i]<='f')))return 0;
 return 1;
}
static int component(const char *s){
 if(!s||!s[0]||!strcmp(s,".")||!strcmp(s,".."))return 0;
 size_t n=0;for(;s[n]&&n<127;n++){unsigned char c=(unsigned char)s[n];
  if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='.'||c=='-'||c=='_'))return 0;}
 return !s[n]&&n>0;
}
static int same_file(const struct stat *a,const struct stat *b){
 if(a->st_dev!=b->st_dev||a->st_ino!=b->st_ino||a->st_uid!=b->st_uid||a->st_mode!=b->st_mode||a->st_nlink!=b->st_nlink||a->st_size!=b->st_size)return 0;
#ifdef __APPLE__
 return a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec&&a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec&&a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec&&a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
#else
 return a->st_mtim.tv_sec==b->st_mtim.tv_sec&&a->st_mtim.tv_nsec==b->st_mtim.tv_nsec&&a->st_ctim.tv_sec==b->st_ctim.tv_sec&&a->st_ctim.tv_nsec==b->st_ctim.tv_nsec;
#endif
}
static int resources(HCStockStateReceipt *s){
 struct stat p,d;int pf=fcntl(s->receipt,F_GETFL),pd=fcntl(s->receipt,F_GETFD),dd=fcntl(s->dir,F_GETFD);
 return pf>=0&&(pf&O_ACCMODE)==O_RDONLY&&(pf&O_NONBLOCK)&&pd>=0&&(pd&FD_CLOEXEC)&&dd>=0&&(dd&FD_CLOEXEC)&&
  !fstat(s->receipt,&p)&&S_ISFIFO(p.st_mode)&&p.st_dev==s->receipt_snapshot.st_dev&&p.st_ino==s->receipt_snapshot.st_ino&&
  !fstat(s->dir,&d)&&S_ISDIR(d.st_mode)&&d.st_dev==s->directory_snapshot.st_dev&&d.st_ino==s->directory_snapshot.st_ino&&d.st_uid==geteuid()&&(d.st_mode&0777)==0700;
}
static int input_same(HCStockStateReceipt *s,HCStockSaveSession *save){
 struct stat st;int flags=fcntl(save->child.input,F_GETFL),descriptor=fcntl(save->child.input,F_GETFD);
 return save->child.pid==s->child_pid&&save->child.input==s->input_fd&&flags>=0&&(flags&O_ACCMODE)==O_WRONLY&&(flags&O_NONBLOCK)&&descriptor>=0&&(descriptor&FD_CLOEXEC)&&
  !fstat(save->child.input,&st)&&S_ISFIFO(st.st_mode)&&st.st_dev==s->input_snapshot.st_dev&&st.st_ino==s->input_snapshot.st_ino;
}
static int identity(HCStockStateReceipt *s,HCStockSaveSession *save){
 return s&&game_valid(s->game)&&resources(s)&&save==&s->game->save&&save->phase==HC_STOCK_RUNNING&&save->child.pid>1&&save->child.input>=3&&
  s->epoch&&s->epoch==s->game->epoch&&!memcmp(s->token,s->game->token,16)&&!memcmp(s->game_code,s->game->game,sizeof s->game_code)&&
  !memcmp(s->rom_digest,s->game->rom.sha256,sizeof s->rom_digest)&&!hc_verified_launch_recheck(&s->game->rom)&&(s->phase!=2||input_same(s,save));
}
int hc_stock_state_receipt_init(HCStockStateReceipt *s,HCStockGameSession *game,int receipt,int dir,const char *name){
 struct stat p,d,existing;int flags=fcntl(receipt,F_GETFL),rf=fcntl(receipt,F_GETFD),df=fcntl(dir,F_GETFD);
 if(!s||s->phase||s->game||s->bytes||!game_valid(game)||!game->epoch||!component(name)||receipt<3||dir<3||receipt==dir||
    flags<0||(flags&O_ACCMODE)!=O_RDONLY||!(flags&O_NONBLOCK)||rf<0||!(rf&FD_CLOEXEC)||df<0||!(df&FD_CLOEXEC)||
    fstat(receipt,&p)||!S_ISFIFO(p.st_mode)||fstat(dir,&d)||!S_ISDIR(d.st_mode)||d.st_uid!=geteuid()||(d.st_mode&0777)!=0700||
    !fstatat(dir,name,&existing,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT||hc_verified_launch_recheck(&game->rom)||hc_checkpoint_init(&s->checkpoint,game->token,1)){errno=EINVAL;return -1;}
 s->game=game;s->receipt=receipt;s->dir=dir;s->receipt_snapshot=p;s->directory_snapshot=d;s->epoch=game->epoch;
 memcpy(s->token,game->token,16);memcpy(s->game_code,game->game,sizeof s->game_code);memcpy(s->rom_digest,game->rom.sha256,sizeof s->rom_digest);strcpy(s->name,name);s->phase=1;return 0;
}
static int begin(void *opaque,HCStockSaveSession *save){
 HCStockStateReceipt *s=opaque;struct stat item;unsigned char extra;static const unsigned char cmd[]="HC_STATE_SAVE 1\n";
 if(!identity(s,save)||s->phase!=1||!fstatat(s->dir,s->name,&item,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT){errno=EINVAL;return -1;}
 ssize_t n=read(s->receipt,&extra,1);if(n>=0||(errno!=EAGAIN&&errno!=EWOULDBLOCK)){s->phase=4;errno=EIO;return -1;}
 s->input_fd=save->child.input;s->child_pid=save->child.pid;
 if(fstat(s->input_fd,&s->input_snapshot)||!input_same(s,save)){s->phase=4;errno=EINVAL;return -1;}
 s->phase=2;if(hc_atomic_pipe_write(s->input_fd,cmd,sizeof cmd-1)){s->phase=4;return -1;}return 0;
}
static int read_exact(int fd,unsigned char *p,size_t n){
 for(size_t pos=0;pos<n;){ssize_t got=pread(fd,p+pos,n-pos,(off_t)pos);if(got<0&&errno==EINTR)continue;if(got<=0)return -1;pos+=(size_t)got;}return 0;
}
static int poll_state(void *opaque,HCStockSaveSession *save,uint64_t now){
 HCStockStateReceipt *s=opaque;unsigned char frame[32],extra,again[4096];struct stat a,b,named;int fd=-1;(void)now;
 if(!identity(s,save)||s->phase!=2){errno=EINVAL;return -1;}
 ssize_t n=read(s->receipt,frame,sizeof frame);if(n<0&&(errno==EINTR||errno==EAGAIN||errno==EWOULDBLOCK))return 0;
 if(n<=0)goto fail;int r=hc_checkpoint_feed(&s->reader,&s->checkpoint,frame,(size_t)n);if(!r)return 0;if(r<0)goto fail;
 n=read(s->receipt,&extra,1);if(n>=0||(errno!=EAGAIN&&errno!=EWOULDBLOCK))goto fail;
 /* Do not let an unexpected FIFO block the session owner past its deadline. */
 fd=openat(s->dir,s->name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
 if(fd<0||fstat(fd,&a)||!S_ISREG(a.st_mode)||a.st_uid!=geteuid()||a.st_nlink!=1||(a.st_mode&0022)||a.st_size<=0||(uint64_t)a.st_size>HC_STATE_MAX)goto fail;
 s->bytes=malloc((size_t)a.st_size);if(!s->bytes||read_exact(fd,s->bytes,(size_t)a.st_size))goto fail;
 for(size_t pos=0;pos<(size_t)a.st_size;){size_t part=(size_t)a.st_size-pos;if(part>sizeof again)part=sizeof again;
  ssize_t got=pread(fd,again,part,(off_t)pos);if(got<0&&errno==EINTR)continue;if(got<=0||memcmp(again,s->bytes+pos,(size_t)got))goto fail;pos+=(size_t)got;}
 if(fstat(fd,&b)||fstatat(s->dir,s->name,&named,AT_SYMLINK_NOFOLLOW)||!same_file(&a,&b)||!same_file(&a,&named)||
    !identity(s,save)||hc_checkpoint_verified(&s->checkpoint,HC_CP_SAVE,1))goto fail;
 if(close(fd)){fd=-1;goto fail;}s->length=(size_t)a.st_size;s->phase=3;return 1;
fail:
 if(fd>=0)close(fd);free(s->bytes);s->bytes=NULL;s->length=0;s->phase=4;errno=EIO;return -1;
}
HCStockScreenshotCapture hc_stock_state_receipt_capture(HCStockStateReceipt *s){HCStockScreenshotCapture result={s,begin,poll_state};return result;}
/* Compare the captured stage file to the receipt's in-memory bytes, holding
 * the same private directory and refusing links, replacement and mutation. */
static int state_snapshot_matches(HCStockStateReceipt *s){
 struct stat before,after,named,dir;unsigned char bytes[4096];int fd=-1,ok=0;
 if(!s||s->phase!=3||!s->bytes||!s->length||s->length>HC_STATE_MAX||
    s->checkpoint.phase!=HC_CP_WAIT_IMAGE||s->checkpoint.sequence!=1||!s->reader.done||
    fstat(s->dir,&dir)||dir.st_dev!=s->directory_snapshot.st_dev||dir.st_ino!=s->directory_snapshot.st_ino||
    !S_ISDIR(dir.st_mode)||dir.st_uid!=geteuid()||(dir.st_mode&0777)!=0700){errno=EINVAL;return -1;}
 fd=openat(s->dir,s->name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 if(fstat(fd,&before)||fstatat(s->dir,s->name,&named,AT_SYMLINK_NOFOLLOW)||!same_file(&before,&named)||
    !S_ISREG(before.st_mode)||before.st_uid!=geteuid()||before.st_nlink!=1||(before.st_mode&0022)||before.st_size!=(off_t)s->length)goto done;
 for(size_t pos=0;pos<s->length;){size_t part=s->length-pos;if(part>sizeof bytes)part=sizeof bytes;
  ssize_t n=pread(fd,bytes,part,(off_t)pos);if(n<0&&errno==EINTR)continue;if(n<=0||memcmp(bytes,s->bytes+pos,(size_t)n))goto done;pos+=(size_t)n;}
 if(fstat(fd,&after)||!same_file(&before,&after)||fstatat(s->dir,s->name,&named,AT_SYMLINK_NOFOLLOW)||!same_file(&before,&named))goto done;
 ok=1;
done: {int saved=errno;if(close(fd))ok=0;if(!ok){errno=saved?saved:EIO;return -1;}return 0;}
}
static int archive_matches(HCStockStateArchive *out,HCStockStateReceipt *s){
 struct stat first,last,named;unsigned char bytes[4096];int fd=-1,ok=0;
 if(!out||out->parent<3||!s||!s->bytes||!s->length){errno=EINVAL;return -1;}
 fd=openat(out->parent,"state-captured",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 if(fstat(fd,&first)||fstatat(out->parent,"state-captured",&named,AT_SYMLINK_NOFOLLOW)||!same_file(&first,&named)||
    !S_ISREG(first.st_mode)||first.st_uid!=geteuid()||(first.st_mode&0777)!=0600||first.st_nlink!=1||first.st_size!=(off_t)s->length)goto done;
 for(size_t pos=0;pos<s->length;){size_t part=s->length-pos;if(part>sizeof bytes)part=sizeof bytes;
  ssize_t n=pread(fd,bytes,part,(off_t)pos);if(n<0&&errno==EINTR)continue;if(n<=0||memcmp(bytes,s->bytes+pos,(size_t)n))goto done;pos+=(size_t)n;}
 if(fstat(fd,&last)||!same_file(&first,&last)||fstatat(out->parent,"state-captured",&named,AT_SYMLINK_NOFOLLOW)||!same_file(&first,&named))goto done;
 ok=1;
done: {int saved=errno;if(close(fd))ok=0;if(!ok){errno=saved?saved:EIO;return -1;}return 0;}
}
int hc_stock_state_archive_capture(HCStockStateArchive *out,HCStockStateReceipt *s,HCStockGameSession *game,HCConsoleRuntime *runtime,HCStockControlSession *control){
 struct stat st;HCNonceSequence seq=HC_NONCE_SEQUENCE_INITIALIZER;uint8_t nonce[16];char session[33],workspace[44],expected[44];
 static const char hex[]="0123456789abcdef";size_t n;
 if(!out||out->attempted||out->published||out->parent!=-1||out->target.ready||!s||!game||s->game!=game||!runtime||!runtime->claimed||runtime->workspace<3||
    !control||control->save!=&game->save||!control->state||control->state->context!=s||hc_stock_control_refresh_finished(control)||
    !game_valid(game)||game->save.child.pid!=-1||game->save.child.input!=-1||
    (game->save.phase!=HC_STOCK_REAPED_CLEAN&&game->save.phase!=HC_STOCK_REAPED_NO_SRAM)||
    !game->epoch||s->epoch!=game->epoch||memcmp(s->token,game->token,16)||memcmp(s->checkpoint.session,game->token,16)||
    memcmp(s->game_code,game->game,sizeof s->game_code)||memcmp(s->rom_digest,game->rom.sha256,sizeof s->rom_digest)||
    strcmp(runtime->request.game,game->game)||strcmp(runtime->request.digest,game->rom.sha256)||memcmp(runtime->request.session,game->token,16)||runtime->request.epoch!=game->epoch||
    hc_verified_launch_recheck(&game->rom)||state_snapshot_matches(s)){errno=EINVAL;return -1;}
 memcpy(expected,"checkpoint-",11);
 for(size_t i=0;i<16;i++){session[2*i]=hex[game->token[i]>>4];session[2*i+1]=hex[game->token[i]&15];expected[11+2*i]=session[2*i];expected[12+2*i]=session[2*i+1];}
 session[32]=0;expected[43]=0;n=strnlen(game->save.identity,sizeof game->save.identity);
 if(strcmp(runtime->workspace_name,expected)||n<12||n>=sizeof game->save.identity||strcmp(game->save.identity+n-12,"/battery.srm")||
    fstat(runtime->workspace,&st)||!S_ISDIR(st.st_mode)||st.st_uid!=geteuid()||(st.st_mode&0777)!=0700){errno=EINVAL;return -1;}
 int z=snprintf(out->path,sizeof out->path,"%.*s/sessions/%s/state-archive/state-captured",(int)(n-12),game->save.identity,expected);
 if(z<=0||(size_t)z>=sizeof out->path){errno=EINVAL;return -1;}
 if(hc_nonce_sequence_init(&seq))return -1;int r=hc_nonce_sequence_next(&seq,nonce),saved=errno;
 if(hc_nonce_sequence_destroy(&seq)&&!r){r=-1;saved=errno;}if(r){errno=saved;return -1;}
 if(!memcmp(nonce,game->token,16)){errno=EINVAL;return -1;}
 memcpy(workspace,"checkpoint-",11);for(size_t i=0;i<16;i++){workspace[11+2*i]=hex[nonce[i]>>4];workspace[12+2*i]=hex[nonce[i]&15];}workspace[43]=0;
 out->attempted=1;
 if(mkdirat(runtime->workspace,"state-archive",0700)||fsync(runtime->workspace))return -2;
 out->parent=openat(runtime->workspace,"state-archive",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(out->parent<0)return -2;
 HCSessionExpected region={out->parent,out->path,107};
 HC_STATE_ARCHIVE_HOOK(1);
 if(hc_session_validate_regions(&region,1)||hc_binding_create(out->parent,"state-binding",game->game,game->rom.sha256,game->token,game->epoch,&region,1))return -2;
 HC_STATE_ARCHIVE_HOOK(2);
 if(hciv2_create(out->parent,session,workspace,"state-captured",HCIV2_FINAL))return -2;
 HC_STATE_ARCHIVE_HOOK(3);
 if(hc_autosave_target_prepare(&out->target,out->parent,geteuid(),nonce,out->path,"state-captured")||
    state_snapshot_matches(s)||hc_autosave_target_write(&out->target,out->path,s->bytes,s->length))return -2;
 HCIV2Entry entries[16];size_t count=0;
 if(hc_binding_inventory(out->parent,"state-binding",game->game,game->rom.sha256,game->token,game->epoch,&region,1,0,entries,16,&count)||
    count!=1||strcmp(entries[0].workspace,workspace)||strcmp(entries[0].region,"state-captured")||entries[0].kind!=HCIV2_FINAL||!entries[0].workspace_present||
    state_snapshot_matches(s)||archive_matches(out,s)||hc_verified_launch_recheck(&game->rom)||hc_stock_control_refresh_finished(control))return -2;
 out->published=1;
 HC_STATE_ARCHIVE_HOOK(4);
 return 0;
}
int hc_stock_state_archive_recheck(HCStockStateArchive *out,HCStockStateReceipt *s,HCStockGameSession *game,HCConsoleRuntime *runtime,HCStockControlSession *control){
 struct stat parent,named,held;HCIV2Entry entries[16];size_t count=0,n;char expected[44],path[1024];static const char hex[]="0123456789abcdef";
 if(!out||!out->attempted||!out->published||out->parent<3||!out->target.ready||!out->target.consumed||!s||!game||s->game!=game||
    !runtime||!runtime->claimed||runtime->workspace<3||!control||control->save!=&game->save||!control->state||control->state->context!=s||
    hc_stock_control_refresh_finished(control)||!game_valid(game)||!game->epoch||s->epoch!=game->epoch||
    memcmp(s->token,game->token,16)||memcmp(s->checkpoint.session,game->token,16)||memcmp(s->game_code,game->game,sizeof s->game_code)||
    memcmp(s->rom_digest,game->rom.sha256,sizeof s->rom_digest)||strcmp(runtime->request.game,game->game)||strcmp(runtime->request.digest,game->rom.sha256)||
    memcmp(runtime->request.session,game->token,16)||runtime->request.epoch!=game->epoch||game->save.child.pid!=-1||game->save.child.input!=-1||
    hc_verified_launch_recheck(&game->rom)||state_snapshot_matches(s)){errno=EINVAL;return -1;}
 memcpy(expected,"checkpoint-",11);for(size_t i=0;i<16;i++){expected[11+2*i]=hex[game->token[i]>>4];expected[12+2*i]=hex[game->token[i]&15];}expected[43]=0;
 n=strnlen(game->save.identity,sizeof game->save.identity);
 if(strcmp(runtime->workspace_name,expected)||n<12||n>=sizeof game->save.identity||strcmp(game->save.identity+n-12,"/battery.srm")){errno=EINVAL;return -1;}
 int z=snprintf(path,sizeof path,"%.*s/sessions/%s/state-archive/state-captured",(int)(n-12),game->save.identity,expected);
 if(z<=0||(size_t)z>=sizeof path||strcmp(path,out->path)||strcmp(path,out->target.identity)||
    fstat(out->parent,&parent)||fstat(out->target.parent,&held)||fstatat(runtime->workspace,"state-archive",&named,AT_SYMLINK_NOFOLLOW)||
    !S_ISDIR(parent.st_mode)||!S_ISDIR(named.st_mode)||parent.st_uid!=geteuid()||(parent.st_mode&0777)!=0700||
    parent.st_dev!=held.st_dev||parent.st_ino!=held.st_ino||parent.st_dev!=named.st_dev||parent.st_ino!=named.st_ino){errno=EINVAL;return -1;}
 HCSessionExpected region={out->parent,path,107};
 if(hc_binding_inventory(out->parent,"state-binding",game->game,game->rom.sha256,game->token,game->epoch,&region,1,0,entries,16,&count)||
    count!=1||strcmp(entries[0].workspace,out->target.workspace_name)||strcmp(entries[0].region,"state-captured")||
    entries[0].kind!=HCIV2_FINAL||!entries[0].workspace_present||archive_matches(out,s)){errno=EINVAL;return -1;}
 return 0;
}
int hc_stock_state_archive_encode(HCStockStateArchive *archive,HCStockStateReceipt *state,HCStockGameSession *game,HCConsoleRuntime *runtime,HCStockControlSession *control,HCStateBytes *out){
 HCStateBytes encoded=HC_STATE_BYTES_INITIALIZER,decoded=HC_STATE_BYTES_INITIALIZER;
 if(!out||out->data||out->length||hc_stock_state_archive_recheck(archive,state,game,runtime,control)){errno=EINVAL;return -1;}
 if(hc_state_gzip_encode(state->bytes,state->length,&encoded))return -1;
 if(hc_state_decode(encoded.data,encoded.length,&decoded)||decoded.length!=state->length||
    memcmp(decoded.data,state->bytes,state->length)||hc_stock_state_archive_recheck(archive,state,game,runtime,control)){
  int saved=errno?errno:EIO;hc_state_bytes_clear(&decoded);hc_state_bytes_clear(&encoded);errno=saved;return -1;
 }
 hc_state_bytes_clear(&decoded);*out=encoded;return 0;
}
int hc_stock_state_archive_close(HCStockStateArchive *out){
 if(!out||!out->attempted){errno=EINVAL;return -1;}
 if(out->target.ready&&hc_autosave_target_close(&out->target))return -1;
 if(out->parent>=0){if(close(out->parent))return -1;out->parent=-1;}
 out->published=0;return 0;
}
void hc_stock_state_receipt_clear(HCStockStateReceipt *s){if(s){free(s->bytes);*s=(HCStockStateReceipt)HC_STOCK_STATE_RECEIPT_INITIALIZER;}}
