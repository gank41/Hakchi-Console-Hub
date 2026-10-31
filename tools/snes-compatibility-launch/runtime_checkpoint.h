#ifndef HAKCHI_RUNTIME_CHECKPOINT_H
#define HAKCHI_RUNTIME_CHECKPOINT_H
#include "save_completion.h"
#include "screenshot_completion.h"
#include <stdint.h>
typedef enum {HC_RT_INVALID,HC_RT_READY,HC_RT_SAVING,HC_RT_IMAGE_READY,HC_RT_IMAGING,HC_RT_REPORTED,HC_RT_FAILED} HCRuntimePhase;
typedef struct {HCSaveCompletion save;HCScreenshotCompletion image;HCRuntimePhase phase;int outstanding;} HCRuntimeCheckpoint;
#define HC_RUNTIME_CHECKPOINT_INITIALIZER {0}
/* Initialize with HC_RUNTIME_CHECKPOINT_INITIALIZER and call from the emulation
 * main thread. Never reinitialize a context with outstanding callbacks. Context and fd must remain alive until
 * all accepted tasks complete. Caller must verify the SAVE artifact before
 * requesting IMAGE. HC_RT_REPORTED means only receipt delivery, not file proof.
 * Caller ensures authenticated pipe, private paths, unique session and deadline. */
int hc_runtime_checkpoint_init(HCRuntimeCheckpoint *,int fd,const uint8_t session[16],uint64_t sequence,const char *state_path);
int hc_runtime_request_save(HCRuntimeCheckpoint *);
/* fd must reference the newly-created private empty file for this request.
 * The producer duplicates it; caller keeps its descriptor and prevents mutation. */
int hc_runtime_request_save_fd(HCRuntimeCheckpoint *,int fd);
int hc_runtime_request_image(HCRuntimeCheckpoint *);
/* fd must be a fresh private image file and remain stable through completion. */
int hc_runtime_request_image_fd(HCRuntimeCheckpoint *,int fd);
#endif
