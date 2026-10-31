#ifndef HAKCHI_SNES_CONTROL_COMMAND_H
#define HAKCHI_SNES_CONTROL_COMMAND_H
typedef enum { HC_COMMAND_SAVE, HC_COMMAND_SCREENSHOT, HC_COMMAND_QUIT } HCCommand;
/* The dedicated launcher process must set SIGPIPE to SIG_IGN before creating
 * threads and keep that disposition unchanged; this helper never changes it.
 * The caller owns the nonblocking write pipe and must prevent its replacement. Failed/partial/ambiguous writes must not be retried blindly.
 * A successful write confirms delivery to the pipe only: there is no emulator
 * acknowledgment, durable save, screenshot proof, or safe-exit verification. */
int hc_control_command(int fd, HCCommand command);
#endif
