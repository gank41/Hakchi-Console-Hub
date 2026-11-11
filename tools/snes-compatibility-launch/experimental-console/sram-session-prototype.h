#ifndef HC_SRAM_SESSION_PROTOTYPE_H
#define HC_SRAM_SESSION_PROTOTYPE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "autosave_target.h"
typedef int (*HCSramPublish)(void *,const char *,const void *,size_t);
typedef bool (*HCSramValidate)(void *,const char *);
typedef int (*HCSramWorkerLease)(void *,const char *);
typedef struct {const char *path;unsigned type;size_t size;} HCSramRegion;
/* The callback runs synchronously on the frontend main thread; it must not
 * re-enter content, core or save lifecycle operations. Region paths are
 * borrowed only until it returns. The owner authenticates the game and paths
 * and retains every bound target and context even if it later returns an error,
 * until an eventual supervisor resolves recovery. No rollback is implied. */
typedef int (*HCSramPrepare)(void *,uint64_t,const HCSramRegion *,size_t);
int hc_register_sram_preparer(HCSramPrepare,void *);
int hc_prepare_sram_startup(void);
int hc_frontend_bind_sram_session(HCAutosaveTarget **,size_t,HCSramPublish,HCSramValidate,HCSramWorkerLease,HCSramWorkerLease,void *);
#endif
