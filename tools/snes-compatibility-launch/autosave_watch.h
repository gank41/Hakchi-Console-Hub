#ifndef HAKCHI_AUTOSAVE_WATCH_H
#define HAKCHI_AUTOSAVE_WATCH_H
typedef enum {HC_AUTOSAVE_IDLE,HC_AUTOSAVE_ARMED,HC_AUTOSAVE_PENDING,HC_AUTOSAVE_SUCCEEDED,HC_AUTOSAVE_SKIPPED,HC_AUTOSAVE_FAILED,HC_AUTOSAVE_UNCERTAIN} HCAutosavePhase;
typedef struct {HCAutosavePhase phase;} HCAutosaveWatch;
#define HC_AUTOSAVE_WATCH_INITIALIZER {HC_AUTOSAVE_IDLE}
/* Main-thread-only and single-use. SUCCEEDED means the producer reported a
 * completed write; caller must independently verify bytes and safe publication
 * before treating it as a durable recovery point. */
int hc_autosave_begin(HCAutosaveWatch *);
int hc_autosave_admitted(HCAutosaveWatch *);
int hc_autosave_complete(HCAutosaveWatch *,int success);
int hc_autosave_skip(HCAutosaveWatch *);
int hc_autosave_fail(HCAutosaveWatch *);
/* Publication or cancellation needs recovery inspection. A rename may have
 * occurred, or the old file may still have a retained recovery hard link. */
int hc_autosave_uncertain(HCAutosaveWatch *);
#endif
