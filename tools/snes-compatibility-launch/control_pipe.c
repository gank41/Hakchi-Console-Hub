#include "control_pipe.h"
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

int hc_control_pipe(int descriptors[2]) {
    int p[2];
    if (!descriptors) { errno = EINVAL; return -1; }
    if (pipe(p) != 0) return -1;
    /* A later dup2 to stdin must not accidentally close an endpoint. */
    if (p[0] <= STDERR_FILENO || p[1] <= STDERR_FILENO) {
        close(p[0]);
        close(p[1]);
        errno = EBADF;
        return -1;
    }
    for (int i = 0; i < 2; ++i) {
        int status = fcntl(p[i], F_GETFL);
        int descriptor_flags = fcntl(p[i], F_GETFD);
        if (status == -1 || descriptor_flags == -1 ||
            fcntl(p[i], F_SETFL, status | O_NONBLOCK) == -1 ||
            fcntl(p[i], F_SETFD, descriptor_flags | FD_CLOEXEC) == -1) {
            int saved_errno = errno;
            close(p[0]);
            close(p[1]);
            errno = saved_errno;
            return -1;
        }
    }
    descriptors[0] = p[0];
    descriptors[1] = p[1];
    return 0;
}
