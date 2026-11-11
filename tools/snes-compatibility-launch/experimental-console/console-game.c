#include "console-game.h"
#include <errno.h>
#include <string.h>
int hc_console_game_open(HCConsoleGame *game,int argc,const char *const argv[],int directory,uid_t uid){
 HCCompatibilityMenuCommand parsed;
 if(!game||game->rom.ready||hc_parse_compatibility_menu_command(argc,argv,&parsed)){errno=EINVAL;return -2;}
 if(hc_verified_rom_open(&game->rom,directory,parsed.rom_name,uid,parsed.digest))return -1;
 if(hc_verified_launch_recheck(&game->rom)){int saved=errno;(void)hc_verified_launch_close(&game->rom);errno=saved;return -1;}
 game->command=parsed;return 0;
}
int hc_console_game_close(HCConsoleGame *game){
 if(!game||!game->rom.ready){errno=EINVAL;return -1;}
 if(hc_verified_launch_close(&game->rom))return -1;
 memset(&game->command,0,sizeof game->command);return 0;
}
