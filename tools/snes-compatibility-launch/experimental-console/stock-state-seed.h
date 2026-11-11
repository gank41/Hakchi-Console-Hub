#ifndef HC_STOCK_STATE_SEED_H
#define HC_STOCK_STATE_SEED_H
#include "stock-game-session.h"
#include <stddef.h>
/* Decode one independently authenticated state for this exact game and ROM
 * into a new 210.state.auto file in the already-pinned private stage. Caller
 * authenticates the input and its provenance, excludes other writers and
 * keeps the game and descriptors alive. This does not select a menu slot,
 * authorize launch or prove that the core accepts the state. A -2 result means
 * a partial stage file may remain; retain the session for inspection. */
int hc_stock_state_seed(HCStockGameSession *,const char *,const char *,const void *,size_t);
#endif
