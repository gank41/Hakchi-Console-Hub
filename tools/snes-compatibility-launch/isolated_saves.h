#ifndef HAKCHI_SNES_ISOLATED_SAVES_H
#define HAKCHI_SNES_ISOLATED_SAVES_H
#include <sys/types.h>
/* The caller authenticates and exclusively controls the game profile folder.
 * Creates only private compatibility-emulator directories and returns an
 * owned close-on-exec descriptor. Never touches save files. On failure,
 * already-created empty directories may remain. */
int hc_open_isolated_save_directory(int game_profile,uid_t owner,const char *rom_sha256);
#endif
