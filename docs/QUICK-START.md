# Quick Start

Hakchi Console Hub helps you organize game files on your Mac and add supported
games to a prepared classic console. This is a work-in-progress version. The
first-time SNES setup guide is a preview and has not yet been tested end to end
on a new console. A limited original-startup restore is available for some
earlier installation records; the new app flow has not yet been tested on a
console. Game transfers for Genesis are also still being developed.

The SNES setup guide reviews a backup, tests and installs startup updates with
separate confirmations, and checks the included games. It can make a new backup
if console data changes. Keep the app open through these steps; resuming every
interrupted step after closing the app is still being developed. This new app
workflow has not been tested end to end on a new console.

Adding supported games to a prepared US SNES Classic has been tested on a
console, including restarting and playing games. Your results may vary with
the game file and console setup. Keep a backup before changing your console.

## What you need

- A Mac with macOS 14 or later.
- Your game files on the Mac.
- A supported, prepared console, a controller and a TV.
- A USB cable that transfers data. Some cables only provide power.

You can add and organize games on the Mac without a console connected.
The app starts in **Easy** mode, with the main tools visible. To see additional
technical tools, open **Settings > General** and choose **Advanced**. Both modes
keep the same backups and confirmations.

## Add games to the Mac

1. Choose your console at the top of the app.
2. Choose **Add Game Files** and select your files. The app makes its own
   copies; your original files stay where they are.
3. Use **Show** to find added games, included games, Cheat Codes copies or games
   that need attention.
4. Select a game to change its name or choose box art. If the app says a game
   needs attention, read its explanation before trying to sync it.

Adding a game to the Mac does not immediately add it to the console.

## Add games to a prepared US SNES Classic

1. Connect the SNES to the Mac, turn it on normally and leave its game menu on
   the TV. Choose **Connect** in the app. If another app or virtual machine is
   using the USB connection, release it there first.
2. On the SNES, open **Options** and turn off **My Game Play Demo** and
   **Classic Demo** so a demo does not start while the app is checking.
3. Check the games you want, then choose **Sync Library**. Review the games,
   folders, space and backup. Choose **Review Changes**, then follow the app's
   instructions if it asks to make a backup.
4. Choose **Step 1. Copy Games to Console**. Once that finishes, choose
   **Step 2. Show Updated Games**.
5. Restart the SNES when the app asks. Check the menu and artwork, then play an
   added game and an included game. Check the picture, sound and controller.
6. If they work, follow the app's prompts and choose **Step 3. Finish Sync**.
   Read the final review: it explains which temporary console files are removed.

Keep power and USB connected while the app is working. If a step stops or an
error appears, read the message and follow the app's instructions before
restarting the console or trying again. Copying a game does not guarantee it
will play; a game marked **Needs Attention** may need different support.

## Keep your backups

Open **Settings > Storage** to find your backup folder and **Backup History**.
Keep the startup backup made for each console. Restoring a games-and-folders
layout is different from restoring game progress or startup software.

To bring an SNES library backup to another Mac:

1. In **Backup History**, select the backup and choose **Copy Backup to Another Mac**.
   Choose an empty folder or a drive with enough room. The app copies and checks
   the backup; your original remains on this Mac.
2. Bring the copied **SNES-Library** folder to the other Mac. In its **Backup
   History**, choose **Add Backup from Another Mac** and select that folder.
3. Set up the replacement SNES using its own startup backup. Select the added
   library backup and choose **Review for Replacement**. The app explains the
   available game and saved-progress steps before any console changes.

This copies added game files, artwork and saved data in the library backup. It
does not copy the original console's startup recovery files to the replacement.
The replacement workflow remains experimental and needs a two-console test.

For a replacement US SNES, Backup History can review a backup from the old
console and prepare a games-and-folders copy for the replacement's sync review.
The replacement must already be set up, and this path has not yet been tested
between two consoles or between two Macs. An experimental, separate saved-game
transfer can review certain saves and unused suspend-point slots. It cannot
transfer every save layout, and it has not yet been proven on a replacement
console. Keep both consoles' backups.

In the replacement review, you can choose eligible saved games and save a review
on your Mac. **Open Saved Review** checks the replacement again and reports
conflicting or partly present files. This is a check only; it does not copy or
repair saved progress, and a review by itself does not approve a future copy.
If Backup History shows an earlier saved-game transfer that needs checking,
keep both backups. **Check Previous Transfer** looks for its temporary files; a
matching result does not mean the saved game has been restored. An unstarted
review can be closed without changing the console or either backup.

If you need to check an earlier setup attempt, choose your US SNES in the app,
then choose **Set Up SNES**, **Check Saved Review**, and your saved review
folder. Choose **Check Saved Installation** and select that installation's
saved folder. The app checks files on the Mac without connecting to the
console. Then choose **Check Saved Menu or Folder Update** and select its saved
folder to continue at the next available step. If the update was prepared but
not installed, the app guides you through any remaining check and asks for a
new confirmation before installation.
If a saved record confirms that an update was written but its game check was
not completed, the app can recheck normal startup without writing the update
again. For an uncertain update, the app can offer a read-only inspection; that
inspection does not repair the console or authorize another write. Keep the
backup and follow the message before trying another update.

To make a separate game with cheat codes, select a game and open **Cheat Codes**.
Choose and turn on the codes you want, then choose **Create Cheat Codes Copy**.
The new copy is marked **[Cheat Code]**; your original game stays in the library.
Codes depend on the game version, so test the copy after syncing it.

## If you need help

Open **Help** in the app for more details. If the Mac cannot find the console,
check that the cable carries data, try another port and close other apps using
the console. For normal connection, do not hold RESET while turning it on.

To check for a newer app, choose **Hakchi Console Hub > Check for Updates** or
open **Settings > Updates**. Choose **Open Downloads on GitHub**, download the
installer, open it, and drag the app into Applications.

To save information for troubleshooting, choose **Tools > Export
Troubleshooting Logs**, choose where to save the ZIP file, and select **Save**.
The file stays on your Mac until you choose to share it. Logs can include
console identifiers, game names and file paths, so review them before sharing.
The ZIP does not include games, console backups, or app settings.
