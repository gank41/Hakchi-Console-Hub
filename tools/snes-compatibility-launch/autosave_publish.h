#ifndef HAKCHI_AUTOSAVE_PUBLISH_H
#define HAKCHI_AUTOSAVE_PUBLISH_H
#include <stddef.h>
#include <sys/types.h>
/* Caller supplies stable, private same-filesystem directories and exclusively
 * controls every path and fd, and keeps expected bytes immutable through the
 * call. 0 means verified rename and directory sync;
 * -1 means no rename occurred; -2 means rename occurred but durability or
 * post-rename verification failed; -3 means no rename occurred but a rollback
 * link was created and needs inspection/cleanup. Existing state is linked as 'previous' in
 * workspace and must remain available until recovery/cleanup is authorized. */
int hc_autosave_publish(int parent,const char *destination,int workspace,const char *temporary,int source,uid_t owner,const void *expected,size_t length);
#endif
