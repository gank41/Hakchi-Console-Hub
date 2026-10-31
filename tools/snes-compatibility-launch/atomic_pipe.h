#ifndef HAKCHI_SNES_ATOMIC_PIPE_H
#define HAKCHI_SNES_ATOMIC_PIPE_H
#include <stddef.h>
#include <stdint.h>
/* Internal nonblocking pipe write, maximum 32 bytes. Caller owns fd and must
 * establish and preserve process-wide SIGPIPE=SIG_IGN before any writers run;
 * this helper checks but never changes signal disposition. A
 * failed/ambiguous write must never be repeated without a new transaction. */
int hc_atomic_pipe_write(int fd,const uint8_t *bytes,size_t length);
#endif
