#ifndef HAKCHI_SNES_CHECKPOINT_RECEIPT_H
#define HAKCHI_SNES_CHECKPOINT_RECEIPT_H
#include <stddef.h>
#include <stdint.h>
#define HC_CHECKPOINT_RECEIPT_BYTES 32
/* Inert protocol gate: caller authenticates the producer/pipe and independently
 * verifies each owned, fresh artifact before affirming it. Caller must generate
 * an unpredictable session and never reuse any (session, sequence) pair, even
 * after restarting; this component cannot detect cross-operation replay.
 * A receipt alone never
 * proves successful writes or console compatibility. One operation per object. */
typedef enum {HC_CP_INVALID,HC_CP_WAIT_SAVE,HC_CP_VERIFY_SAVE,HC_CP_WAIT_IMAGE,HC_CP_VERIFY_IMAGE,HC_CP_READY,HC_CP_FAILED} HCCheckpointPhase;
typedef enum {HC_CP_SAVE=1,HC_CP_IMAGE=2} HCCheckpointKind;
typedef struct {uint8_t session[16];uint64_t sequence;HCCheckpointPhase phase;} HCCheckpoint;
typedef struct {uint8_t bytes[HC_CHECKPOINT_RECEIPT_BYTES];size_t used;int done;} HCReceiptReader;
#define HC_RECEIPT_READER_INITIALIZER {{0},0,0}
/* Returns 0 for incomplete, 1 for exactly one accepted frame, -1 on error.
 * A caller must establish a bounded deadline and prohibit trailing frames. */
int hc_checkpoint_feed(HCReceiptReader *reader,HCCheckpoint *state,const uint8_t *bytes,size_t count);
/* Build a wire receipt; success=1 or failure=0. This function does not decide
 * whether a task succeeded and does not write to a pipe. */
int hc_checkpoint_encode(uint8_t output[HC_CHECKPOINT_RECEIPT_BYTES],const uint8_t session[16],uint64_t sequence,HCCheckpointKind kind,int success);
/* Sends one encoded receipt; successful pipe write is not an artifact proof. */
int hc_checkpoint_send(int fd,const uint8_t session[16],uint64_t sequence,HCCheckpointKind kind,int success);
int hc_checkpoint_init(HCCheckpoint *state,const uint8_t session[16],uint64_t sequence);
int hc_checkpoint_receipt(HCCheckpoint *state,const uint8_t *frame,size_t length);
/* Save verification must authenticate its session, identity and bytes externally. */
int hc_checkpoint_verified(HCCheckpoint *state,HCCheckpointKind kind,int valid);
/* The caller must also establish freshness/ownership of the supplied image. */
int hc_checkpoint_verify_image(HCCheckpoint *state,const uint8_t *bytes,size_t length,int fresh_owned);
#endif
