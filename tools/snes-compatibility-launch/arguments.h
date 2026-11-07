#ifndef HAKCHI_SNES_LAUNCH_ARGUMENTS_H
#define HAKCHI_SNES_LAUNCH_ARGUMENTS_H
/* Validated launch metadata only: no pathname is opened and no command runs. */
#define HC_ARGUMENT_BYTES 1024
typedef enum {
 HC_TITLE,HC_VIDEO,HC_WAIT,HC_START,HC_FINISH,HC_SRAM,HC_SCREENSHOT,
 HC_ROLLBACK_OUT,HC_ROLLBACK_MODE,HC_SAVE,HC_ROLLBACK_IN,HC_LOAD,
 HC_LOAD_TIME,HC_SAVE_TIME,HC_FRAME,HC_OPTION_COUNT
} HCLaunchOption;
typedef struct {
 unsigned present;
 int wait_fd,start_fd,finish_fd;
 char values[HC_OPTION_COUNT][HC_ARGUMENT_BYTES];
} HCLaunchArguments;
int hc_launch_arguments(int argc,const char *const argv[],const char *game_code,HCLaunchArguments *output);
/* Derive RetroArch SRAM and RTC paths from a validated manager request.
 * These names are not authorization to open files. Caller must separately
 * authenticate, pin and exclusively control the parent and contents. */
typedef struct {char sram[HC_ARGUMENT_BYTES],rtc[HC_ARGUMENT_BYTES];} HCGameSavePaths;
/* Exact manager-selected paths, as metadata only. Volatile paths do not imply
 * durable storage, ownership, completion or authorization to open them. */
typedef struct {int have_save,have_image,have_load;char save[HC_ARGUMENT_BYTES],image[HC_ARGUMENT_BYTES],load[HC_ARGUMENT_BYTES];} HCManagerCheckpointPaths;
/* Normalized menu time paths are metadata, not authority to read or write. */
typedef struct {int have_load,have_save;char load[HC_ARGUMENT_BYTES],save[HC_ARGUMENT_BYTES];} HCManagerTimePaths;
int hc_launch_save_paths(int argc,const char *const argv[],const char *game_code,HCGameSavePaths *output);
/* Independent compatibility-emulator SRAM/RTC names, keyed by game and exact
 * ROM digest. Names alone neither create nor authenticate any directory. */
#define HC_COMPATIBILITY_ENGINE_ID "snes9x2010-fe690dd3-armhf-glibc223"
#define HC_COMPATIBILITY_CORE_SHA256 "ea4fab232ce2479c61099240d20196172051027fb7f55a9eabf2c5d9c4342286"
int hc_launch_isolated_save_paths(int argc,const char *const argv[],const char *game_code,const char *rom_sha256,HCGameSavePaths *output);
/* Caller supplies an independently trusted canonical profile root. */
int hc_launch_isolated_save_paths_at_root(int,const char *const [],const char *,const char *,const char *,HCGameSavePaths *);
/* Parse an experimental menu contract only. This does not authorize or start a game. */
typedef struct {
 char game[12], rom_name[69], digest[65];
 HCGameSavePaths saves;
 HCManagerCheckpointPaths checkpoint;
 HCManagerTimePaths time;
 HCLaunchArguments manager;
} HCCompatibilityMenuCommand;
int hc_parse_compatibility_menu_command(int argc,const char *const argv[],HCCompatibilityMenuCommand *output);
#endif
