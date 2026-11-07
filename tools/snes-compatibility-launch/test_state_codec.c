#include "state_codec.h"
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

int main(void){
 unsigned char source[4096];for(size_t i=0;i<sizeof source;i++)source[i]=(unsigned char)((i*13u)^(i>>3));
 HCStateBytes compressed=HC_STATE_BYTES_INITIALIZER,decoded=HC_STATE_BYTES_INITIALIZER;
 assert(hc_state_gzip_encode(NULL,sizeof source,&compressed)<0&&!compressed.data&&!compressed.length);
 assert(hc_state_gzip_encode(source,0,&compressed)<0&&!compressed.data&&!compressed.length);
 assert(!hc_state_gzip_encode(source,sizeof source,&compressed));
 assert(compressed.length>18&&compressed.data[0]==0x1f&&compressed.data[1]==0x8b);
 assert(!hc_state_decode(compressed.data,compressed.length,&decoded));
 assert(decoded.length==sizeof source&&!memcmp(decoded.data,source,sizeof source));
 assert(hc_state_decode(source,sizeof source,&decoded)<0); /* never overwrite owned data */
 hc_state_bytes_clear(&decoded);
 assert(!hc_state_decode(source,sizeof source,&decoded)); /* legacy raw states */
 assert(decoded.length==sizeof source&&!memcmp(decoded.data,source,sizeof source));hc_state_bytes_clear(&decoded);
 assert(hc_state_decode(compressed.data,compressed.length-1,&decoded)<0&&!decoded.data&&!decoded.length);
 unsigned char *bad=malloc(compressed.length+1);assert(bad);memcpy(bad,compressed.data,compressed.length);
 bad[compressed.length-8]^=1;assert(hc_state_decode(bad,compressed.length,&decoded)<0&&!decoded.data&&!decoded.length);
 memcpy(bad,compressed.data,compressed.length);bad[compressed.length]=0;
 assert(hc_state_decode(bad,compressed.length+1,&decoded)<0&&!decoded.data&&!decoded.length);
 unsigned char *members=malloc(2*compressed.length);assert(members);
 memcpy(members,compressed.data,compressed.length);memcpy(members+compressed.length,compressed.data,compressed.length);
 assert(hc_state_decode(members,2*compressed.length,&decoded)<0&&!decoded.data&&!decoded.length);free(members);
 /* Advertised uncompressed size is checked before allocating. */
 memcpy(bad,compressed.data,compressed.length);memset(bad+compressed.length-4,0xff,4);
 assert(hc_state_decode(bad,compressed.length,&decoded)<0&&!decoded.data&&!decoded.length);
 assert(hc_state_decode(source,HC_STATE_BYTES_MAX+1u,&decoded)<0&&!decoded.data&&!decoded.length);
 free(bad);hc_state_bytes_clear(&compressed);assert(!compressed.data&&!compressed.length);
 /* Exercise the full limit with data that cannot be trivially compressed. */
 unsigned char *large=malloc(HC_STATE_BYTES_MAX);assert(large);uint32_t prng=1;
 for(size_t i=0;i<HC_STATE_BYTES_MAX;i++){prng^=prng<<13;prng^=prng>>17;prng^=prng<<5;large[i]=(unsigned char)prng;}
 assert(!hc_state_gzip_encode(large,HC_STATE_BYTES_MAX,&compressed));
 assert(!hc_state_decode(compressed.data,compressed.length,&decoded));
 assert(decoded.length==HC_STATE_BYTES_MAX&&!memcmp(decoded.data,large,decoded.length));
 hc_state_bytes_clear(&decoded);hc_state_bytes_clear(&compressed);free(large);
 return 0;
}
