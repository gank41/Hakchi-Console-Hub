#ifndef HAKCHI_SNES_OWNED_DIRECTORY_H
#define HAKCHI_SNES_OWNED_DIRECTORY_H
#include <sys/types.h>
#include <stdint.h>
#include <stddef.h>
/* Opens one safe ASCII child directory relative to a trusted parent descriptor.
 * Checks each descriptor's directory type, expected owner and write permissions;
 * rejects links and path components. Returns an owned close-on-exec descriptor
 * or -1. Never creates or modifies files. The caller must establish the parent's
 * origin, filesystem, lifetime, and protection from privileged concurrent changes;
 * these checks do not validate a mount, game identity, or save file contents. */
int hc_open_owned_directory(int parent, const char *name, uid_t owner);
/* Opens an existing, singly linked, bounded regular file read-only. The caller
 * must prevent concurrent replacement while this opens: the precheck cannot
 * prevent side effects if a privileged actor races it with a device node.
 * Metadata and size checks do not authenticate content or freeze later writes;
 * the caller must bound reads and verify content before acting on it. */
int hc_open_owned_file(int parent, const char *name, uid_t owner, off_t max_size);
/* Create a new private session directory. nonce must come from a secure random
 * source, never be reused, and contain at least one nonzero byte. The parent
 * must already be a private directory owned by owner. The caller must keep the
 * parent and new directory protected against replacement, including by other
 * processes with the same user ID. Returns an owned descriptor and name; on
 * failure it does not remove any directory created during the attempt. */
int hc_create_checkpoint_workspace(int parent, uid_t owner,
                                   const uint8_t nonce[16], char name[44]);
/* Creates a new file without following or replacing an existing entry. Caller
 * owns the returned read/write descriptor and must keep the directory private
 * throughout use, check writes, fsync and verify contents before publication. */
int hc_create_checkpoint_file(int workspace, uid_t owner, const char *name);
/* Flush and compare an exclusively held temporary file to the exact serialized
 * state. The caller must prevent concurrent modifications and retain the file
 * descriptor through publication; this does not validate a directory entry or
 * prove persistence after power loss. The comparison is bounded to 128 MiB. */
int hc_verify_checkpoint_file(int fd, uid_t owner, const void *expected, size_t size);
/* Write once to a new empty private regular file through its descriptor, then
 * flush and verify exact bytes. A failed write leaves the file incomplete; it
 * must not be published or retried. Caller prevents concurrent mutation. */
int hc_write_checkpoint_file(int fd, uid_t owner, const void *bytes, size_t size);
#endif
