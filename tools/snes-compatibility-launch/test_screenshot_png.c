#include "screenshot_png.h"
#include <assert.h>
#include <string.h>
#include <zlib.h>
static const unsigned char valid[] = {137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,2,0,0,0,144,119,83,222,0,0,0,12,73,68,65,84,120,156,99,248,207,192,0,0,3,1,1,0,201,254,146,239,0,0,0,0,73,69,78,68,174,66,96,130};
static const unsigned char badfilter[] = {137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,2,0,0,0,144,119,83,222,0,0,0,12,73,68,65,84,120,156,99,253,207,192,0,0,3,21,1,5,232,44,40,131,0,0,0,0,73,69,78,68,174,66,96,130};
static const unsigned char baddeflate[] = {137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,2,0,0,0,144,119,83,222,0,0,0,7,73,68,65,84,110,111,116,122,108,105,98,53,227,181,58,0,0,0,0,73,69,78,68,174,66,96,130};
static const unsigned char rgba[] = {137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,6,0,0,0,31,21,196,137,0,0,0,13,73,68,65,84,120,156,99,97,104,248,255,31,0,4,150,2,131,167,62,132,201,0,0,0,0,73,69,78,68,174,66,96,130};
int main(void) {
 assert(hc_screenshot_png(valid,sizeof valid)==0);
 assert(hc_screenshot_png(rgba,sizeof rgba)==0);
 for (size_t n=0;n<sizeof valid;n++) assert(hc_screenshot_png(valid,n)!=0);
 unsigned char extra[sizeof valid+1]; memcpy(extra,valid,sizeof valid); extra[sizeof valid]=0;
 assert(hc_screenshot_png(extra,sizeof extra)!=0);
 assert(hc_screenshot_png(badfilter,sizeof badfilter)!=0);
 assert(hc_screenshot_png(baddeflate,sizeof baddeflate)!=0);
 unsigned char changed[sizeof valid]; memcpy(changed,valid,sizeof valid); changed[20]^=1;
 assert(hc_screenshot_png(changed,sizeof changed)!=0);
 memcpy(changed,valid,sizeof valid); memset(changed+16,0xff,4);
 uLong crc=crc32(0L,Z_NULL,0); crc=crc32(crc,changed+12,17);
 changed[29]=(unsigned char)(crc>>24); changed[30]=(unsigned char)(crc>>16);
 changed[31]=(unsigned char)(crc>>8); changed[32]=(unsigned char)crc;
 assert(hc_screenshot_png(changed,sizeof changed)!=0);
 assert(hc_screenshot_png(NULL,0)!=0);
 return 0;
}
