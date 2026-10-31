#ifndef HAKCHI_SNES_TRANSITIONS_H
#define HAKCHI_SNES_TRANSITIONS_H
/* Original Clover protocol: wait before first frame; start/finish on exit.
 * Borrowed descriptors only. Caller must preserve their lifetime, keep three
 * distinct underlying EFD_SEMAPHORE eventfds, and retain exclusive ownership of
 * its read/write roles with the checked original manager as the sole peer.
 * Number/type checks do not prove underlying identity or detect eventfd aliases.
 * Poll deadlines assume that role ownership; shared status flags are unchanged.
 * No pathname, child command, save or NAND operation.
 */
#include <stdint.h>
typedef enum {HC_INITIAL,HC_RUNNING,HC_EXITING,HC_COMPLETE,HC_FAILED} HCTransitionPhase;
typedef struct {int wait,start,finish;HCTransitionPhase phase;} HCTransition;
int hc_transition_init(HCTransition *,int wait_fd,int start_fd,int finish_fd);
int hc_transition_before_first_frame(HCTransition *);
int hc_transition_begin_exit(HCTransition *);
int hc_transition_finish_exit(HCTransition *);
#endif
