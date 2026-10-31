#include "admission_barrier.h"
#include <limits.h>
int hc_admission_init(HCAdmission *g){if(!g||g->initialized)return -1;if(pthread_mutex_init(&g->lock,0)!=0)return -1;g->active=0;g->closing=0;g->initialized=1;return 0;}
int hc_admission_enter(HCAdmission *g,HCAdmissionLease *l){if(!g||!l||!g->initialized||l->active)return -1;if(pthread_mutex_lock(&g->lock)!=0)return -1;
 int ok=!g->closing&&g->active<UINT_MAX;if(ok){g->active++;l->owner=g;l->active=1;}pthread_mutex_unlock(&g->lock);return ok?0:-1;}
int hc_admission_leave(HCAdmissionLease *l){if(!l||!l->active||!l->owner)return -1;HCAdmission *g=l->owner;if(pthread_mutex_lock(&g->lock)!=0)return -1;
 if(!g->active){pthread_mutex_unlock(&g->lock);return -1;}g->active--;l->active=0;l->owner=0;pthread_mutex_unlock(&g->lock);return 0;}
int hc_admission_close(HCAdmission *g){if(!g||!g->initialized)return -1;if(pthread_mutex_lock(&g->lock)!=0)return -1;int ok=!g->closing;g->closing=1;pthread_mutex_unlock(&g->lock);return ok?0:-1;}
int hc_admission_ready(HCAdmission *g){if(!g||!g->initialized)return 0;if(pthread_mutex_lock(&g->lock)!=0)return 0;int ready=g->closing&&g->active==0;if(pthread_mutex_unlock(&g->lock)!=0)return 0;return ready;}
int hc_admission_destroy(HCAdmission *g){if(!g||!g->initialized||hc_admission_ready(g)!=1)return -1;if(pthread_mutex_destroy(&g->lock)!=0)return -1;g->initialized=0;return 0;}
