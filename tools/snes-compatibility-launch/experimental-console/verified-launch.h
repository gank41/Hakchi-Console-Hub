#ifndef HC_VERIFIED_LAUNCH_H
#define HC_VERIFIED_LAUNCH_H
#include "bound-session.h"
#include <sys/stat.h>
/* Caller authenticates game/expected digest and retains exclusive directory
 * control through launch and recovery. The descriptor pins the ROM; the actual
 * emulator must consume that same verified file or enforce an equivalent
 * immutable handoff. These checks do not authorize console writes or launch. */
typedef struct {int ready,rom_fd,parent;struct stat snapshot;char name[128],sha256[65];} HCVerifiedLaunch;
#define HC_VERIFIED_LAUNCH_INITIALIZER {0}
/* A failed call can leave a session binding or registered owner. Preserve
 * those records and inspect them; do not automatically retry or remove them. */
int hc_verified_rom_open(HCVerifiedLaunch *,int,const char *,uid_t,const char *);
int hc_verified_launch_prepare(HCVerifiedLaunch *,HCSessionOwner *,int,const char *,uid_t,const char *,const char *,const HCSessionExpected *,size_t,HCSessionRetention,const uint8_t[16],uint64_t,int,const char *);
int hc_verified_launch_prepare_inherited(HCVerifiedLaunch *,HCSessionOwner *,int,const char *,int,uid_t,const char *,const char *,const HCSessionExpected *,size_t,HCSessionRetention,const uint8_t[16],uint64_t,int,const char *);
int hc_verified_launch_recheck(HCVerifiedLaunch *);
/* Caller excludes concurrent descriptor-table use; failed closes retain an
 * open descriptor and ready state for retry. A partially closed launch cannot
 * be used for another launch or recovery and must only be cleaned up. */
int hc_verified_launch_close(HCVerifiedLaunch *);
#endif
