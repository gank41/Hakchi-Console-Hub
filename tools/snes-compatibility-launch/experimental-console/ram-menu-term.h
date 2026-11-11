#ifndef HC_RAM_MENU_TERM_H
#define HC_RAM_MENU_TERM_H
/* Single-threaded disposable RAM trial: SIGTERM requests one RESET handoff. */
int hc_ram_menu_term_install(void);
int hc_ram_menu_term_requested(void);
#endif
