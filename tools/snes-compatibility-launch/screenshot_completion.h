#ifndef HAKCHI_SNES_SCREENSHOT_COMPLETION_H
#define HAKCHI_SNES_SCREENSHOT_COMPLETION_H
#include <stdint.h>
/* Private, caller-owned context: keep alive until the callback runs, keep fd
 * stable and exclusive, and enforce a deadline. Delivery is not file proof. */
typedef struct {int fd;uint8_t session[16];uint64_t sequence;int attempted;int delivery;int reported_success;} HCScreenshotCompletion;
int hc_screenshot_completion_init(HCScreenshotCompletion *,int fd,const uint8_t session[16],uint64_t sequence);
void hc_screenshot_completion_callback(void *task_data,void *user_data,const char *error);
#endif
