#define _POSIX_C_SOURCE 200809L
#include "control_command.h"
#include "atomic_pipe.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int hc_atomic_pipe_write(int fd,const uint8_t *bytes,size_t length) {
    if (!bytes || !length || length > 32) { errno = EINVAL; return -1; }
    struct stat st;
    int flags = fcntl(fd, F_GETFL);
    if (flags == -1 || (flags & O_ACCMODE) != O_WRONLY || !(flags & O_NONBLOCK) ||
        fstat(fd, &st) != 0 || !S_ISFIFO(st.st_mode)) { errno = EINVAL; return -1; }
    struct sigaction disposition;
    if (sigaction(SIGPIPE, NULL, &disposition) != 0) return -1;
    if (disposition.sa_handler != SIG_IGN) { errno = EPERM; return -1; }
    ssize_t result = write(fd, bytes, length);
    if (result == (ssize_t)length) return 0;
    if (result >= 0) errno = EIO;
    return -1;
}

int hc_control_command(int fd, HCCommand command) {
    const char *text;
    switch (command) {
        case HC_COMMAND_SAVE: text = "SAVE_STATE\n"; break;
        case HC_COMMAND_SCREENSHOT: text = "SCREENSHOT\n"; break;
        case HC_COMMAND_QUIT: text = "QUIT\n"; break;
        default: errno = EINVAL; return -1;
    }
    return hc_atomic_pipe_write(fd,(const uint8_t *)text,strlen(text));
}
