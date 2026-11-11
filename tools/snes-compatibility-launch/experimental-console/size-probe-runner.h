#ifndef HC_SIZE_PROBE_RUNNER_H
#define HC_SIZE_PROBE_RUNNER_H
#include "verified-launch.h"
#include <sys/types.h>
#include <stddef.h>
/* Caller verifies hashes against its own trust source and keeps all paths,
 * descriptors and scratch private and exclusively controlled, prevents other
 * threads or handlers from reaping this child, maintains non-auto-reaping
 * SIGCHLD handling, and closes or marks unrelated descriptors close-on-exec. A reaped probe is not proof of target driver or
 * core-option equivalence, nor authorization to write saves or start gameplay. */
enum { HC_SIZE_PROBE_NO_REASON, HC_SIZE_PROBE_CLOCK_REQUIRED };
typedef struct {pid_t pid;int output,complete,failed,verified,consumed,reason;HCVerifiedLaunch *program,*core,*rom;char bytes[32];size_t used,size;unsigned long long deadline_ms;} HCSizeProbe;
#define HC_SIZE_PROBE_INITIALIZER {-1,-1,0,0,0,0,0,NULL,NULL,NULL,{0},0,0,0}
int hc_size_probe_start(HCSizeProbe *,HCVerifiedLaunch *,const char *,HCVerifiedLaunch *,const char *,HCVerifiedLaunch *,const char *);
/* 0 pending, 1 result, -1 failure. While pending, failed means the result
 * is rejected; cancel promptly. The ten-second deadline requests termination,
 * but the caller must continue polling until the child is reaped. */
int hc_size_probe_poll(HCSizeProbe *,size_t *);
/* Cancel requests termination; the caller must continue polling to reap. */
int hc_size_probe_cancel(HCSizeProbe *);
#endif
