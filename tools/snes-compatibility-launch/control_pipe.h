#ifndef HAKCHI_SNES_CONTROL_PIPE_H
#define HAKCHI_SNES_CONTROL_PIPE_H
/* Creates a private nonblocking control pipe with close-on-exec endpoints.
 * Standard descriptors must be open; failure leaves output untouched.
 * Create before starting threads or forking: pipe + fcntl is not atomic.
 * The caller owns both descriptors and must dup2 the read end onto child stdin.
 * This does not send commands or supervise an emulator. */
int hc_control_pipe(int descriptors[2]);
#endif
