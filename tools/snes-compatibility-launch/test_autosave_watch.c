#include "autosave_watch.h"
#include <assert.h>
int main(void) {
 HCAutosaveWatch w=HC_AUTOSAVE_WATCH_INITIALIZER;
 assert(hc_autosave_begin(&w)==0 && w.phase==HC_AUTOSAVE_ARMED);
 assert(hc_autosave_complete(&w,1)==-1);
 assert(hc_autosave_admitted(&w)==0 && w.phase==HC_AUTOSAVE_PENDING);
 assert(hc_autosave_begin(&w)==-1);
 assert(hc_autosave_complete(&w,0)==0 && w.phase==HC_AUTOSAVE_FAILED);
 assert(hc_autosave_complete(&w,1)==-1 && w.phase==HC_AUTOSAVE_FAILED);
 HCAutosaveWatch ok=HC_AUTOSAVE_WATCH_INITIALIZER;
 assert(hc_autosave_begin(&ok)==0 && hc_autosave_admitted(&ok)==0);
 assert(hc_autosave_complete(&ok,1)==0 && ok.phase==HC_AUTOSAVE_SUCCEEDED);
 HCAutosaveWatch skipped=HC_AUTOSAVE_WATCH_INITIALIZER;
 assert(hc_autosave_begin(&skipped)==0 && hc_autosave_skip(&skipped)==0);
 assert(skipped.phase==HC_AUTOSAVE_SKIPPED);
 HCAutosaveWatch failed=HC_AUTOSAVE_WATCH_INITIALIZER;
 assert(hc_autosave_begin(&failed)==0 && hc_autosave_fail(&failed)==0);
 assert(failed.phase==HC_AUTOSAVE_FAILED);
 HCAutosaveWatch uncertain=HC_AUTOSAVE_WATCH_INITIALIZER;
 assert(hc_autosave_begin(&uncertain)==0 && hc_autosave_admitted(&uncertain)==0);
 assert(hc_autosave_uncertain(&uncertain)==0 && uncertain.phase==HC_AUTOSAVE_UNCERTAIN);
 assert(hc_autosave_complete(&uncertain,1)==-1 && uncertain.phase==HC_AUTOSAVE_UNCERTAIN);
 return 0;
}
