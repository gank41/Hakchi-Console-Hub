#ifndef HC_STARTUP_STATUS_H
#define HC_STARTUP_STATUS_H
#include <stddef.h>
#include <stdint.h>

#define HC_STARTUP_FRAME_SIZE 32u
enum { HC_STARTUP_OK=1, HC_STARTUP_FAILED=2 };
typedef struct {
 uint8_t expected_session[16], frame[HC_STARTUP_FRAME_SIZE];
 uint64_t expected_epoch;
 size_t used;
 int phase;
} HCStartupReader;
#define HC_STARTUP_READER_INIT {0}

/* Isolated, one-frame protocol on a DEDICATED report channel. The caller
 * creates a unique unpredictable session and nonzero epoch, authenticates
 * the producer and exclusively owns both ends. The receiver must apply a
 * deadline and call eof only after actual channel EOF. An OK report is only
 * the child's assertion: it does not prove initialization, game identity,
 * save validity, safe cleanup, durable storage, or authentication. The
 * channel must not be reused for checkpoint receipts or further records. */
int hc_startup_encode(uint8_t out[HC_STARTUP_FRAME_SIZE],const uint8_t session[16],uint64_t epoch,int status);
int hc_startup_reader_init(HCStartupReader *,const uint8_t session[16],uint64_t epoch);
/* Returns 0 while awaiting EOF, -1 on malformed/trailing/duplicate input.
 * Zero-byte reads are EOF and must use hc_startup_eof, not this function. */
int hc_startup_feed(HCStartupReader *,const void *,size_t);
/* Called exactly once on actual EOF; returns OK/FAILED or -1 for incomplete,
 * invalid, duplicate or repeated EOF. Both status values require caller review. */
int hc_startup_eof(HCStartupReader *);
/* One nonblocking atomic write to a pipe. Caller must ignore SIGPIPE process-
 * wide before threads/spawn and preserve disposition and fd ownership. Error
 * is ambiguous; the receiver must also handle EOF, timeout and child failure. */
int hc_startup_send(int fd,const uint8_t session[16],uint64_t epoch,int status);
#endif
