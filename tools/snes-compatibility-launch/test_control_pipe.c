#include "control_pipe.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--child") == 0) {
        char b;
        return (fcntl(STDIN_FILENO, F_GETFL) & O_NONBLOCK) &&
            read(STDIN_FILENO, &b, 1) == -1 &&
            (errno == EAGAIN || errno == EWOULDBLOCK) ? 0 : 1;
    }
    pid_t closed_stdin_child = fork();
    assert(closed_stdin_child >= 0);
    if (closed_stdin_child == 0) {
        close(STDIN_FILENO);
        int low[2] = {-1, -1};
        _exit(hc_control_pipe(low) == -1 && low[0] == -1 && low[1] == -1 ? 0 : 1);
    }
    int low_status;
    assert(waitpid(closed_stdin_child, &low_status, 0) == closed_stdin_child);
    assert(WIFEXITED(low_status) && WEXITSTATUS(low_status) == 0);
    int p[2] = {-1, -1};
    assert(hc_control_pipe(NULL) == -1);
    assert(hc_control_pipe(p) == 0);
    assert((fcntl(p[0], F_GETFL) & O_NONBLOCK) != 0);
    assert((fcntl(p[1], F_GETFL) & O_NONBLOCK) != 0);
    assert((fcntl(p[0], F_GETFD) & FD_CLOEXEC) != 0);
    assert((fcntl(p[1], F_GETFD) & FD_CLOEXEC) != 0);
    pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        close(p[1]);
        assert(dup2(p[0], STDIN_FILENO) == STDIN_FILENO);
        close(p[0]);
        execl(argv[0], argv[0], "--child", (char *)NULL);
        _exit(127);
    }
    int child_status;
    assert(waitpid(child, &child_status, 0) == child);
    assert(WIFEXITED(child_status) && WEXITSTATUS(child_status) == 0);
    char byte;
    assert(read(p[0], &byte, 1) == -1 && (errno == EAGAIN || errno == EWOULDBLOCK));
    const char command[] = "QUIT\n";
    assert(write(p[1], command, sizeof command - 1) == (ssize_t)(sizeof command - 1));
    char buf[8] = {0};
    assert(read(p[0], buf, sizeof buf) == (ssize_t)(sizeof command - 1));
    assert(memcmp(buf, command, sizeof command - 1) == 0);
    /* A stopped frontend must not block the future supervisor. */
    char block[4096] = {0};
    int full = 0;
    for (int i = 0; i < 16384; ++i) {
        ssize_t n = write(p[1], block, sizeof block);
        if (n == -1) { assert(errno == EAGAIN || errno == EWOULDBLOCK); full = 1; break; }
        assert(n > 0);
    }
    assert(full);
    while (read(p[0], block, sizeof block) > 0) {}
    assert(errno == EAGAIN || errno == EWOULDBLOCK);
    close(p[1]);
    assert(read(p[0], &byte, 1) == 0);
    close(p[0]);
    return 0;
}
