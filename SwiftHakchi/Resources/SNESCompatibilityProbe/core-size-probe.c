#define _POSIX_C_SOURCE 200809L
/* Isolated candidate only. The caller must authenticate and pin the core and
 * ROM, control their paths and scratch directory, bound runtime, and verify
 * the response. This program does not authorize save writes or gameplay. */
#include <libretro.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static const char *scratch;
static bool environment(unsigned cmd, void *data) {
 switch(cmd) {
 case RETRO_ENVIRONMENT_GET_CAN_DUPE: *(bool *)data=true;return true;
 case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
 case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY: *(const char **)data=scratch;return true;
 case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
 case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
 case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:
 case RETRO_ENVIRONMENT_SET_VARIABLES: return true;
 case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE: *(bool *)data=false;return true;
 case RETRO_ENVIRONMENT_GET_LANGUAGE: *(unsigned *)data=0;return true;
 default:return false;
 }
}
static void video(const void *data,unsigned w,unsigned h,size_t pitch) {(void)data;(void)w;(void)h;(void)pitch;}
static void audio(int16_t l,int16_t r) {(void)l;(void)r;}
static size_t audio_batch(const int16_t *samples,size_t frames) {(void)samples;return frames;}
static void input_poll(void) {}
static int16_t input_state(unsigned p,unsigned d,unsigned i,unsigned id) {(void)p;(void)d;(void)i;(void)id;return 0;}
#define LOAD(name) do { *(void **)(&name)=dlsym(lib,#name); if(!name)goto done; } while(0)
int main(int argc,char **argv) {
 void *lib=NULL;unsigned char *rom=NULL;int result=1, initialized=0,loaded=0;char *end=NULL;struct stat st;
 void (*retro_set_environment)(retro_environment_t)=NULL;
 void (*retro_set_video_refresh)(retro_video_refresh_t)=NULL;
 void (*retro_set_audio_sample)(retro_audio_sample_t)=NULL;
 void (*retro_set_audio_sample_batch)(retro_audio_sample_batch_t)=NULL;
 void (*retro_set_input_poll)(retro_input_poll_t)=NULL;
 void (*retro_set_input_state)(retro_input_state_t)=NULL;
 void (*retro_init)(void)=NULL;void (*retro_deinit)(void)=NULL;
 void (*retro_get_system_info)(struct retro_system_info *)=NULL;
 bool (*retro_load_game)(const struct retro_game_info *)=NULL;
 void (*retro_unload_game)(void)=NULL;size_t (*retro_get_memory_size)(unsigned)=NULL;
 void *(*retro_get_memory_data)(unsigned)=NULL;
 if(argc!=4||argv[1][0]!='/'||argv[3][0]!='/')return 2;
 errno=0;long fd=strtol(argv[2],&end,10);if(errno||!argv[2][0]||*end||fd<3||fd>1024)return 2;
 int flags=fcntl((int)fd,F_GETFL);
 if(flags<0||(flags&O_ACCMODE)!=O_RDONLY||fstat((int)fd,&st)||!S_ISREG(st.st_mode)||st.st_size<=0||st.st_size>8*1024*1024)return 2;
 rom=malloc((size_t)st.st_size);if(!rom)return 1;
 size_t pos=0;while(pos<(size_t)st.st_size){ssize_t n=pread((int)fd,rom+pos,(size_t)st.st_size-pos,(off_t)pos);if(n<0&&errno==EINTR)continue;if(n<=0)goto done;pos+=(size_t)n;}
 scratch=argv[3];lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!lib)goto done;
 LOAD(retro_set_environment);LOAD(retro_set_video_refresh);LOAD(retro_set_audio_sample);LOAD(retro_set_audio_sample_batch);LOAD(retro_set_input_poll);LOAD(retro_set_input_state);
 LOAD(retro_init);LOAD(retro_deinit);LOAD(retro_get_system_info);LOAD(retro_load_game);LOAD(retro_unload_game);LOAD(retro_get_memory_size);LOAD(retro_get_memory_data);
 retro_set_environment(environment);retro_set_video_refresh(video);retro_set_audio_sample(audio);retro_set_audio_sample_batch(audio_batch);retro_set_input_poll(input_poll);retro_set_input_state(input_state);
 retro_init();initialized=1;struct retro_system_info info={0};retro_get_system_info(&info);if(info.need_fullpath)goto done;
 struct retro_game_info game={0};game.data=rom;game.size=pos;
 if(!retro_load_game(&game))goto done;loaded=1;
 /* The current session does not yet stage or restore separate clock data. */
 if(retro_get_memory_size(RETRO_MEMORY_RTC)!=0){fputs("This game needs clock-save support that is not ready yet.\n",stderr);result=3;goto done;}
 size_t size=retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);if(size>4u*1024u*1024u||(size&&!retro_get_memory_data(RETRO_MEMORY_SAVE_RAM)))goto done;
 if(printf("%zu\n",size)<0||fflush(stdout))goto done;result=0;
done:
 if(loaded)retro_unload_game();if(initialized)retro_deinit();if(lib)dlclose(lib);free(rom);return result;
}
