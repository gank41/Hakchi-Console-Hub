#ifndef HAKCHI_AUTOSAVE_VERIFY_H
#define HAKCHI_AUTOSAVE_VERIFY_H
#include <sys/types.h>
#include <stddef.h>
/* Verify exactly the serialized bytes after the writer closes. Caller must
 * establish a trusted private parent and prevent concurrent replacement and
 * writes for the entire operation. This checks final-component links and
 * ownership, but does not authenticate parent components or a VFS backend. */
int hc_autosave_verify(const char *path,uid_t owner,const void *expected,size_t length);
#endif
