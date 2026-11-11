#ifndef HC_STOCK_SESSION_SIGNALS_H
#define HC_STOCK_SESSION_SIGNALS_H
/* Call once, before a manager wait, child, or command pipe is started. The
 * single-threaded owner must retain the resulting process-wide dispositions
 * until all children and pipe writers stop. This cannot recover a signal
 * delivered before the function is called or authenticate the manager. */
int hc_stock_session_signals_install(void);
#endif
