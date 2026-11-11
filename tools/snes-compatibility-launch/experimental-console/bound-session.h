#ifndef HC_BOUND_SESSION_H
#define HC_BOUND_SESSION_H
#include "recovery-binding.h"
/* Experimental, single-threaded pre-launch integration. The caller must
 * authenticate the game, actual ROM digest, session, region paths and private
 * directories independently and preserve exclusive access. A durable binding
 * is created before owner registration. On ANY error a binding or other partial
 * state may remain: do not retry over it or delete it; retain for review.
 * This is not an app connection, recovery authorization or launch approval. */
int hc_bound_session_install(HCSessionOwner *,uid_t,const HCSessionExpected *,size_t,HCSessionRetention,const uint8_t session[16],uint64_t epoch,int binding_dir,const char *binding_name,const char *game,const char *rom_sha256);
#endif
