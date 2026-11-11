#include "stock-entry-finalize.h"
#include <errno.h>
#include <string.h>
static int previous_matches(HCStockGameSession *s,const void *previous,size_t length){
 if(!s||s->save.child_wait_unknown||s->save.child.reaped_pending||!s->save.initial_valid||
    !s->save.stage_size||s->save.stage_size>4u*1024u*1024u||((previous==NULL)!=(length==0))||
    (!!previous!=!!s->save.initial_present)||
    (previous&&(length!=s->save.stage_size||!s->save.initial_bytes||s->save.initial_length!=length||memcmp(previous,s->save.initial_bytes,length))))return 0;
 return 1;
}
int hc_stock_entry_publish_and_finish(HCStockGameSession *s,HCStockControlSession *control,const void *previous,size_t length){
 if(!control||!previous_matches(s,previous,length)||s->detected_no_sram||s->save.phase!=HC_STOCK_REAPED_CLEAN){errno=EINVAL;return -1;}
 int result=hc_stock_game_publish_after_exit(s,control);
 if(result)return result;
 if(hc_stock_game_finish_published_after_exit(s,control,previous,length))return -2;
 return 0;
}
int hc_stock_entry_finish_no_sram(HCStockGameSession *s,HCStockControlSession *control,const void *previous,size_t length){
 if(!control||!previous_matches(s,previous,length)||!s->detected_no_sram||s->save.phase!=HC_STOCK_REAPED_NO_SRAM){errno=EINVAL;return -1;}
 return hc_stock_game_finish_no_sram_after_exit(s,control);
}
