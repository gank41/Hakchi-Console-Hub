#ifndef HC_SCREENSHOT_SESSION_NAMES_H
#define HC_SCREENSHOT_SESSION_NAMES_H
#include <stdint.h>
#include <string.h>
typedef struct {char manager[46],retained_binding[47],retained_file[42];} HCScreenshotSessionNames;
/* Derivation is correlation only: caller authenticates the session and keeps
 * private paths stable. A zero session is never a valid launch identity. */
static inline int hc_screenshot_session_names(const uint8_t token[16],HCScreenshotSessionNames *out){
 if(!token||!out)return -1;
 int nonzero=0;char hex[33];static const char digits[]="0123456789abcdef";
 for(int i=0;i<16;i++){nonzero|=token[i];hex[2*i]=digits[token[i]>>4];hex[2*i+1]=digits[token[i]&15];}
 if(!nonzero)return -1;hex[32]=0;
 HCScreenshotSessionNames n;
 memcpy(n.manager,"shot-manager-",13);memcpy(n.manager+13,hex,33);
 memcpy(n.retained_binding,"shot-retained-",14);memcpy(n.retained_binding+14,hex,33);
 memcpy(n.retained_file,"shot-",5);memcpy(n.retained_file+5,hex,32);memcpy(n.retained_file+37,".png",5);
 *out=n;return 0;
}
#endif
