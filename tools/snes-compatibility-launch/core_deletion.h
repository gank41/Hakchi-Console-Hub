#ifndef HAKCHI_CORE_DELETION_H
#define HAKCHI_CORE_DELETION_H
#include <sys/types.h>
#include <stdint.h>
typedef struct {int parent,file,phase;uid_t owner;uint64_t device,inode,size,sequence;int64_t msec,mnsec,csec,cnsec;uint8_t session[16],digest[32];char name[128];} HCCoreDeletion;
#define HC_CORE_DELETION_INITIALIZER {0}
/* Caller authenticates the allowed core directory and user deletion request,
 * keeps parent and core contents stable/exclusive and retains this object until
 * completion. The caller generates a fresh unpredictable session and sequence.
 * Metadata, SHA-256 and operation identity are rechecked; caller authenticates the
 * matching unload completion. A request alone is not completion. */
int hc_core_deletion_prepare(HCCoreDeletion *,int parent,const char *name,uid_t owner,const uint8_t session[16],uint64_t sequence);
/* 0 deleted and directory synced, -1 no deletion, -2 deleted but sync failed. */
int hc_core_deletion_commit(HCCoreDeletion *,const uint8_t session[16],uint64_t sequence,int unloaded);
int hc_core_deletion_close(HCCoreDeletion *);
#endif
