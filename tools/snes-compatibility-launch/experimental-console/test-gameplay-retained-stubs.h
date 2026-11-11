/* Isolated gameplay tests exercise the battery-only branch. The real-image
 * integration is covered by check-real-entry-frontend.py. */
int hc_console_game_check_manager_record_full(int fd,const HCLaunchRequest *r,const HCManagerCheckpointPaths *c,const HCManagerTimePaths *t){(void)fd;(void)r;(void)c;(void)t;return 0;}
static int hc_test_archive_result=-1;
int hc_stock_state_archive_capture(HCStockStateArchive *a,HCStockStateReceipt *s,HCStockGameSession *g,HCConsoleRuntime *r,HCStockControlSession *c){(void)s;(void)g;(void)r;(void)c;if(!hc_test_archive_result)a->attempted=1;return hc_test_archive_result;}
int hc_stock_state_archive_recheck(HCStockStateArchive *a,HCStockStateReceipt *s,HCStockGameSession *g,HCConsoleRuntime *r,HCStockControlSession *c){(void)a;(void)s;(void)g;(void)r;(void)c;return 0;}
int hc_stock_state_archive_encode(HCStockStateArchive *a,HCStockStateReceipt *s,HCStockGameSession *g,HCConsoleRuntime *r,HCStockControlSession *c,HCStateBytes *b){(void)a;(void)s;(void)g;(void)r;(void)c;(void)b;return -1;}
int hc_stock_manager_state_preflight(HCStockManagerState *o,HCStockGameSession *g,HCConsoleRuntime *r,HCConsoleGame *m,int p){(void)o;(void)g;(void)r;(void)m;(void)p;return -1;}
int hc_stock_manager_state_publish(HCStockManagerState *o,HCStockGameSession *g,HCConsoleRuntime *r,HCConsoleGame *m,HCStockControlSession *c,HCStockStateReceipt *s,HCStockStateArchive *a,const HCStateBytes *b,int p){(void)o;(void)g;(void)r;(void)m;(void)c;(void)s;(void)a;(void)b;(void)p;return -1;}
int hc_stock_manager_state_recheck(HCStockManagerState *o,HCStockGameSession *g,HCConsoleRuntime *r,HCConsoleGame *m,HCStockControlSession *c,HCStockStateReceipt *s,HCStockStateArchive *a,const HCStateBytes *b,int p){(void)o;(void)g;(void)r;(void)m;(void)c;(void)s;(void)a;(void)b;(void)p;return -1;}
int hc_stock_selected_state_recheck(HCStockSelectedState *s){(void)s;return -1;}
int hc_stock_retained_image_retire(HCStockRetainedImage *i,HCStockGameSession *s,HCStockControlSession *c,HCStockScreenshotReceipt *p){(void)i;(void)s;(void)c;(void)p;return 0;}
static int hc_test_previous_validate_result=-1;
int hc_stock_previous_validate(HCStockPrevious *p,HCStockGameSession *s){(void)p;(void)s;return hc_test_previous_validate_result;}
int hc_stock_retained_image_prepare(HCStockRetainedImage *i,HCStockGameSession *s,HCStockControlSession *c,HCStockScreenshotReceipt *r){(void)i;(void)s;(void)c;(void)r;return -1;}
int hc_stock_game_publish_after_exit(HCStockGameSession *s,HCStockControlSession *c){(void)s;(void)c;return -1;}
int hc_stock_retained_image_finish_save(HCStockRetainedImage *i,HCStockGameSession *s,HCStockControlSession *c,HCStockScreenshotReceipt *r,const void *b,size_t n){(void)i;(void)s;(void)c;(void)r;(void)b;(void)n;return -1;}
int hc_stock_retained_image_finish_no_sram(HCStockRetainedImage *i,HCStockGameSession *s,HCStockControlSession *c,HCStockScreenshotReceipt *r,const void *b,size_t n){(void)i;(void)s;(void)c;(void)r;(void)b;(void)n;return -1;}
int hc_stock_manager_image_publish(HCStockManagerImage *i,HCStockRetainedImage *r,HCStockGameSession *s,HCStockControlSession *c,HCStockScreenshotReceipt *p,HCConsoleRuntime *runtime,HCConsoleGame *g,int d){(void)i;(void)r;(void)s;(void)c;(void)p;(void)runtime;(void)g;(void)d;return -1;}
int hc_stock_manager_time_publish(HCStockManagerTime *t,HCStockManagerImage *i,HCStockRetainedImage *r,HCStockGameSession *s,HCStockControlSession *c,HCStockScreenshotReceipt *p,HCConsoleRuntime *runtime,HCConsoleGame *g,int d,HCPlaytimeInstant start,HCPlaytimeInstant end){(void)t;(void)i;(void)r;(void)s;(void)c;(void)p;(void)runtime;(void)g;(void)d;(void)start;(void)end;return -1;}
int hc_stock_time_seed_recheck(HCStockTimeSeed *seed,HCStockGameSession *s,HCConsoleRuntime *r,HCConsoleGame *g,int d){(void)seed;(void)s;(void)r;(void)g;(void)d;return -1;}
int hc_stock_time_seed_retain(HCStockTimeSeed *seed,HCStockGameSession *s,HCConsoleRuntime *r){(void)seed;(void)s;(void)r;return -1;}
int hc_stock_time_seed_backup_recheck(HCStockTimeSeed *seed,HCStockGameSession *s,HCConsoleRuntime *r){(void)seed;(void)s;(void)r;return -1;}
int hc_stock_manager_time_publish_resumed(HCStockManagerTime *t,HCStockManagerImage *i,HCStockRetainedImage *r,HCStockGameSession *s,HCStockControlSession *c,HCStockScreenshotReceipt *p,HCConsoleRuntime *runtime,HCConsoleGame *g,HCStockTimeSeed *seed,int d,HCPlaytimeInstant start,HCPlaytimeInstant end){(void)t;(void)i;(void)r;(void)s;(void)c;(void)p;(void)runtime;(void)g;(void)seed;(void)d;(void)start;(void)end;return -1;}
