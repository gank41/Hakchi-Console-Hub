# SNES replacement-console migration

## Goal and current state

A person whose SNES Classic no longer works should be able to use a verified
Mac backup to bring compatible added games, artwork and progress to a prepared
replacement US SNES Classic, without connecting the original console. The app
can review games and open a games-and-folders sync review. Backup History now
also offers an experimental, separately confirmed saved-data transfer workflow.
It has not been tested between two physical consoles and must not be described
as a verified restore feature.

To start a review, connect the prepared SNES, open **SNES Backup History**,
select the backup, and choose **Restore Games and Folders**. The app opens the
appropriate review for this console or a replacement; selecting the button does
not itself copy or erase anything. A replacement review has a separate
**Review Copying Games** step, followed by a separate saved-game review.

For a single connected SNES, Backup History also offers a read-only comparison
between one of its Mac backups and its current saved-game files. It counts
matching, changed, backup-only and console-only files after checking the console
identity and catalog. The comparison does not create a replacement plan, save
transfer, recovery record, or console write permit. It is useful for testing
backup visibility on one device; it is not proof of a cross-console transfer.

Backup History also offers **Back Up This SNES**, which saves a fresh library
backup without a sync. One prepared SNES has been used to verify this path and
compare its saved files with the result. This library backup contains added game
objects, the menu and profile data; it is not a fresh full firmware image.

In **Restore Console**, **Check a Full Console Backup** checks an existing
full-data backup's files on the Mac without connecting to a console or making a
copy. A successful check means the files match their saved checksums; it does
not establish which console created the backup or make a full-data restore
available. Keep the original backup even if a check fails.

The saved-file review binds the source backup, replacement backup, game identity,
ROM and launch command. It excludes missing or mismatched games and conflicting
or incomplete sets. The current publication path handles one complete set for a
new profile, or one unused suspend-point slot in an existing profile. Other
layouts, including a new profile with multiple sets, remain unavailable for
copying. It does not overwrite a pre-existing save slot.

The person reviews and confirms the temporary file copy, temporary helper and
saved-data publication separately. The app records intent before each transfer,
checks the connected console and the reviewed data again, and keeps the two Mac
backups. After interruption, it can inspect the recorded attempt without
silently retrying it. Temporary console files are not automatically deleted.

Before game testing, the app checks the copied files and records a fresh,
verified Mac backup of that exact state. The recovery record protects this
backup as well as the two earlier backups. The record can be reopened after an
interruption. Finishing requires explicit confirmation that the game was tested
and another fresh verified backup. The app compares it with the protected
pre-test state: changes are restricted to the selected save set and the game's
recognized cartridge or system-save files. Deleted files, changes to a different
suspend slot, or changes to another game require separate review. The record is
then completed atomically on the Mac; no console files are deleted. This check
cannot prove that a change was actually produced by the game or that another
emulator version can load the progress. Hardware behavior remains unverified.

A bundled, checked helper performs the folder switch; it is placed only in the
temporary runtime as a separate approved step. Synthetic tests and an isolated
ARM guest exercised staging, helper delivery, and publication. That guest uses
Linux 6.1 and RAM-backed storage, with console identity, mount and game-process
checks substituted. It does not establish SNES Linux 3.4 or ext4 behavior,
power-loss durability, protection against concurrent writers, correct game
loading, or the behavior of the live Mac-to-console transport. The user-facing
flow and recovery require hardware and end-to-end testing before a transfer can
be considered proven. No hardware write is authorized by this document.

The project's existing `SNESLibraryBackup` includes the selected menu, referenced
game objects and the `/var/lib/clover` tree. Its manifest binds the capture to
the original console, and the same-console restore path still requires that
same hardware identity. The setup data snapshot is a separate full-partition
backup. Neither backup is a general-purpose cross-console write authorization.

Save data includes more than a single cartridge-save file. The console also uses
suspend-point files and screenshots. A future transfer must account for their
relationships and verify the result; it must not claim that a verified backup
alone proves that a game can load on the replacement.

## Proposed approach

1. Prepare the replacement using its own setup, original startup backup and
   recovery records. Preserve the existing same-console firmware restore checks.
   Do not write the old console's full storage or startup image to it as a
   shortcut.
2. Fully verify the selected source library backup on the Mac. Independently
   identify the replacement, its original game catalog, installed software,
   current library and available space. The source console is not required.
3. Build an inert review of supported added games and their artwork using the
   replacement's catalog. Match progress to the exact game identity, ROM and
   emulator when that evidence exists. Treat ambiguous, incompatible or missing
   matches as needing attention; never guess a mapping from the title alone.
4. List transferable cartridge saves, suspend points and related files, along
   with conflicts, missing games and anything excluded. Preserve the replacement
   console's unrelated settings and its own recovery information. A full
   `/var/lib/clover` tree is not an allowlist of portable files.
5. Before any write, create and verify a current backup of the replacement. Let
   the user review the exact changes and conflicts, with preservation as the
   default. Stage and verify new content before selecting it. Use a separate,
   explicit confirmation for any overwrite or deletion.
6. Verify the copied files and menu, then have the user check a representative
   imported game, an included game and their restored progress. Handle failed or
   interrupted transfers without silently discarding either backup. Do not promise
   that a suspend point is portable across different emulator versions or games.

The reviewed migration must be a distinct operation from same-console rollback.
It must bind its source backup, replacement identity, current destination
inventory and selected contents throughout preparation and transfer. A saved
offline review is not permission to write and does not establish that the
replacement is still connected or unchanged.

## Verification needed

Exercise backup corruption, wrong target, incompatible catalog or game identity,
existing destination saves, insufficient space, interruption and retry with
fixtures before any hardware write. Test both in-game saves and suspend points;
confirm that unrelated destination settings and recovery records remain intact.
Ultimately test with two separate compatible consoles, including a restore from a
backup with the source console disconnected.

The original Hakchi project's [release notes](https://github.com/ClusterM/hakchi2/releases)
describe transferring save states between a console and a computer. Nintendo's
[in-game save guidance](https://en-americas-support.nintendo.com/app/answers/detail/a_id/17386/~/can-in-game-save-features-be-used)
also distinguishes in-game saves from suspend points. Neither source verifies
this app's future cross-console transfer.
