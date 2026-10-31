#include "autosave_watch.h"
int hc_autosave_begin(HCAutosaveWatch *w){if(!w||w->phase!=HC_AUTOSAVE_IDLE)return -1;w->phase=HC_AUTOSAVE_ARMED;return 0;}
int hc_autosave_admitted(HCAutosaveWatch *w){if(!w||w->phase!=HC_AUTOSAVE_ARMED)return -1;w->phase=HC_AUTOSAVE_PENDING;return 0;}
int hc_autosave_complete(HCAutosaveWatch *w,int ok){if(!w||w->phase!=HC_AUTOSAVE_PENDING||(ok!=0&&ok!=1))return -1;w->phase=ok?HC_AUTOSAVE_SUCCEEDED:HC_AUTOSAVE_FAILED;return 0;}
int hc_autosave_skip(HCAutosaveWatch *w){if(!w||w->phase!=HC_AUTOSAVE_ARMED)return -1;w->phase=HC_AUTOSAVE_SKIPPED;return 0;}
int hc_autosave_fail(HCAutosaveWatch *w){if(!w||(w->phase!=HC_AUTOSAVE_ARMED&&w->phase!=HC_AUTOSAVE_PENDING))return -1;w->phase=HC_AUTOSAVE_FAILED;return 0;}
int hc_autosave_uncertain(HCAutosaveWatch *w){if(!w||w->phase!=HC_AUTOSAVE_PENDING)return -1;w->phase=HC_AUTOSAVE_UNCERTAIN;return 0;}
