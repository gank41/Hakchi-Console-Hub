#ifndef HAKCHI_SNES_SAVE_COMPLETION_H
#define HAKCHI_SNES_SAVE_COMPLETION_H
#include <stdint.h>
#define HC_SAVE_PATH_MAX 1024
/* Caller validates the expected path and binds a unique request to the actual
 * save task, owns this context/descriptor until callback, and enforces timeout.
 * Receipt is task status only: independently verify owned file and durability. */
typedef struct {int fd;uint8_t session[16];uint64_t sequence;int attempted,delivery,reported_success;char expected[HC_SAVE_PATH_MAX];} HCSaveCompletion;
int hc_save_completion_init(HCSaveCompletion *,int,const uint8_t session[16],uint64_t,const char *expected);
void hc_save_completion_callback(void *task_data,void *user_data,const char *error);
#endif
