#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "owned_directory.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int main(void) {
    char temp[] = "/tmp/hakchi-file-XXXXXX";
    assert(mkdtemp(temp));
    int root = open(temp, O_RDONLY);
    assert(root >= 0);
    int fd = openat(root, "state", O_CREAT | O_EXCL | O_WRONLY, 0600);
    assert(fd >= 0 && write(fd, "save", 4) == 4); close(fd);
    fd = hc_open_owned_file(root, "state", getuid(), 4);
    assert(fd >= 0);
    char bytes[4]; assert(read(fd, bytes, sizeof bytes) == 4 && memcmp(bytes, "save", 4) == 0);
    assert((fcntl(fd, F_GETFD) & FD_CLOEXEC) != 0);
    assert(renameat(root, "state", root, "renamed") == 0);
    assert(symlinkat("renamed", root, "state") == 0);
    assert(hc_open_owned_file(root, "state", getuid(), 4) < 0);
    assert(lseek(fd, 0, SEEK_SET) == 0 && read(fd, bytes, 4) == 4 && memcmp(bytes, "save", 4) == 0);
    assert(unlinkat(root, "state", 0) == 0);
    assert(renameat(root, "renamed", root, "state") == 0);
    close(fd);
    assert(hc_open_owned_file(root, "state", getuid(), 3) < 0);
    assert(hc_open_owned_file(root, "state", getuid(), -1) < 0);
    assert(fchmod(root, 0777) == 0);
    assert(hc_open_owned_file(root, "state", getuid(), 4) < 0);
    assert(fchmod(root, 0700) == 0);
    assert(hc_open_owned_file(root, "state", getuid() + 1, 4) < 0);
    assert(symlinkat("state", root, "link") == 0);
    assert(hc_open_owned_file(root, "link", getuid(), 4) < 0);
    assert(linkat(root, "state", root, "hardlink", 0) == 0);
    assert(hc_open_owned_file(root, "state", getuid(), 4) < 0);
    assert(unlinkat(root, "hardlink", 0) == 0);
    assert(mkfifoat(root, "pipe", 0600) == 0);
    assert(hc_open_owned_file(root, "pipe", getuid(), 4) < 0);
    assert(fchmodat(root, "state", 0666, 0) == 0);
    assert(hc_open_owned_file(root, "state", getuid(), 4) < 0);
    assert(hc_open_owned_file(root, "../state", getuid(), 4) < 0);
    assert(unlinkat(root, "pipe", 0) == 0);
    assert(unlinkat(root, "link", 0) == 0);
    assert(unlinkat(root, "state", 0) == 0);
    close(root); assert(rmdir(temp) == 0);
    return 0;
}
