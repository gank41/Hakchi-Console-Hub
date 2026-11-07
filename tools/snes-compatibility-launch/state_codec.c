#include "state_codec.h"
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>
#define HC_STATE_PACKED_MAX (HC_STATE_BYTES_MAX+65536u)
static int ready(HCStateBytes *out){return out&&!out->data&&!out->length;}
int hc_state_gzip_encode(const void *input,size_t length,HCStateBytes *out){
 if(!input||!length||length>HC_STATE_BYTES_MAX||!ready(out)||length>UINT_MAX){errno=EINVAL;return -1;}
 z_stream stream={0};unsigned char *bytes=NULL;int status=-1;
 if(deflateInit2(&stream,Z_DEFAULT_COMPRESSION,Z_DEFLATED,15+16,8,Z_DEFAULT_STRATEGY)!=Z_OK){errno=EIO;return -1;}
 uLong bound=deflateBound(&stream,(uLong)length);
 if(!bound||bound>HC_STATE_PACKED_MAX||bound>UINT_MAX){errno=EOVERFLOW;goto done;}
 bytes=malloc((size_t)bound);if(!bytes)goto done;
 stream.next_in=(Bytef *)(uintptr_t)input;stream.avail_in=(uInt)length;stream.next_out=bytes;stream.avail_out=(uInt)bound;
 if(deflate(&stream,Z_FINISH)!=Z_STREAM_END||stream.avail_in||!stream.total_out){errno=EIO;goto done;}
 out->data=bytes;out->length=(size_t)stream.total_out;bytes=NULL;status=0;
done:
 free(bytes);if(deflateEnd(&stream)!=Z_OK&&status==0){hc_state_bytes_clear(out);errno=EIO;return -1;}return status;
}
int hc_state_decode(const void *input,size_t length,HCStateBytes *out){
 if(!input||!length||length>HC_STATE_PACKED_MAX||length>UINT_MAX||!ready(out)){errno=EINVAL;return -1;}
 const unsigned char *p=input;
 if(length<2||p[0]!=0x1f||p[1]!=0x8b){
  if(length>HC_STATE_BYTES_MAX){errno=EOVERFLOW;return -1;}
  unsigned char *copy=malloc(length);if(!copy)return -1;memcpy(copy,p,length);out->data=copy;out->length=length;return 0;
 }
 if(length<18){errno=EINVAL;return -1;}
 size_t expected=(size_t)p[length-4]|((size_t)p[length-3]<<8)|((size_t)p[length-2]<<16)|((size_t)p[length-1]<<24);
 if(!expected||expected>HC_STATE_BYTES_MAX){errno=EOVERFLOW;return -1;}
 unsigned char *bytes=malloc(expected+1);if(!bytes)return -1;
 z_stream stream={0};int status=-1;
 if(inflateInit2(&stream,15+16)!=Z_OK){free(bytes);errno=EIO;return -1;}
 stream.next_in=(Bytef *)(uintptr_t)input;stream.avail_in=(uInt)length;stream.next_out=bytes;stream.avail_out=(uInt)(expected+1);
 if(inflate(&stream,Z_FINISH)!=Z_STREAM_END||stream.avail_in||stream.total_out!=expected){errno=EINVAL;goto done;}
 out->data=bytes;out->length=expected;bytes=NULL;status=0;
done:
 free(bytes);if(inflateEnd(&stream)!=Z_OK&&status==0){hc_state_bytes_clear(out);errno=EIO;return -1;}return status;
}
void hc_state_bytes_clear(HCStateBytes *state){if(state){free(state->data);state->data=NULL;state->length=0;}}
