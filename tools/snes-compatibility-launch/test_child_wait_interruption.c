#include "child_process.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static int injected_error;
static int calls;
static int always_interrupted;
pid_t hc_test_waitpid(pid_t pid, int *status, int options) {
    (void)pid; (void)status;
    assert(options == WNOHANG);
    calls++;
    if (injected_error == EINTR && calls == 2 && !always_interrupted) return 0;
    errno = injected_error;
    return -1;
}

int main(void) {
    int fd = open("/dev/null", O_RDONLY);
    assert(fd >= 0);
    HCChild child = { .pid = 123, .input = fd };
    int status = 91;
    injected_error = EINTR;
    assert(hc_child_poll(&child, &status) == 0);
    assert(calls == 2);
    assert(child.pid == 123 && child.input == fd && status == 91);
    assert(fcntl(fd, F_GETFD) >= 0);
    calls = 0; always_interrupted = 1;
    /* Exhausting the bounded retries is still pending: no exit status was
     * observed, so the owner must retain and continue polling the child. */
    assert(hc_child_poll(&child, &status) == 0);
    assert(calls == 4 && child.pid == 123 && child.input == fd && status == 91);
    calls = 0; always_interrupted = 0;
    assert(hc_child_poll(&child, &status) == 0);
    assert(calls == 2 && child.pid == 123 && child.input == fd && status == 91);
    injected_error = EIO;
    calls = 0;
    assert(hc_child_poll(&child, &status) == -1 && errno == EIO);
    assert(child.pid == 123 && child.input == fd && status == 91);
    injected_error = ECHILD;
    calls = 0;
    assert(hc_child_poll(&child, &status) == -1 && errno == ECHILD);
    assert(child.pid == -1 && child.input == -1 && status == 91);
    return 0;
}
