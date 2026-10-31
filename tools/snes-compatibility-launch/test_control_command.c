#define _POSIX_C_SOURCE 200809L
#include "control_pipe.h"
#include "control_command.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

static volatile sig_atomic_t caught;
static void on_pipe(int s) { (void)s; caught++; }
int main(void) {
    struct sigaction sa = {0}, old;
    sa.sa_handler = on_pipe; sigemptyset(&sa.sa_mask);
    assert(sigaction(SIGPIPE, &sa, &old) == 0);
    int p[2]; assert(hc_control_pipe(p) == 0);
    assert(hc_control_command(p[1], HC_COMMAND_SAVE) == -1 && errno == EPERM);
    char probe;assert(read(p[0], &probe, 1)==-1 && (errno==EAGAIN || errno==EWOULDBLOCK));
    sa.sa_handler = SIG_IGN; assert(sigaction(SIGPIPE, &sa, NULL) == 0);
    assert(hc_control_command(p[1], HC_COMMAND_SAVE) == 0);
    assert(hc_control_command(p[1], HC_COMMAND_SCREENSHOT) == 0);
    assert(hc_control_command(p[1], HC_COMMAND_QUIT) == 0);
    char buf[64] = {0}; ssize_t n = read(p[0], buf, sizeof buf);
    const char expected[] = "SAVE_STATE\nSCREENSHOT\nQUIT\n";
    assert(n == (ssize_t)(sizeof expected - 1) && memcmp(buf, expected, sizeof expected - 1) == 0);
    assert(hc_control_command(p[1], (HCCommand)99) == -1);
    assert(hc_control_command(p[0], HC_COMMAND_QUIT) == -1);
    char full[4096] = {0};
    while (write(p[1], full, sizeof full) > 0) {}
    assert(errno == EAGAIN || errno == EWOULDBLOCK);
    assert(hc_control_command(p[1], HC_COMMAND_QUIT) == -1 && (errno == EAGAIN || errno == EWOULDBLOCK));
    close(p[0]);
    assert(hc_control_command(p[1], HC_COMMAND_QUIT) == -1 && errno == EPIPE);
    assert(caught == 0);
    close(p[1]); assert(sigaction(SIGPIPE, &old, NULL) == 0);
    return 0;
}
