#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "owned_directory.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int main(void) {
    char path[] = "/tmp/hc-workspace-test-XXXXXX";
    uint8_t nonce[16] = {1};
    char name[44];
    assert(mkdtemp(path));
    int parent = open(path, O_RDONLY | O_DIRECTORY);
    assert(parent >= 0);
    int fd = hc_create_checkpoint_workspace(parent, getuid(), nonce, name);
    assert(fd >= 0);
    assert(strcmp(name, "checkpoint-01000000000000000000000000000000") == 0);
    struct stat st;
    assert(fstat(fd, &st) == 0 && (st.st_mode & 0777) == 0700);
    int file = hc_create_checkpoint_file(fd, getuid(), "state.tmp");
    assert(file >= 0 && fstat(file, &st) == 0 && S_ISREG(st.st_mode));
    assert((st.st_mode & 0777) == 0600 && st.st_nlink == 1);
    assert(hc_write_checkpoint_file(file, getuid(), "state", 5) == 0);
    assert(hc_write_checkpoint_file(file, getuid(), "other", 5) < 0);
    assert(hc_verify_checkpoint_file(file, getuid(), "state", 5) == 0);
    assert(hc_verify_checkpoint_file(file, getuid(), "stale", 5) < 0);
    assert(hc_verify_checkpoint_file(file, getuid(), "state", 4) < 0);
    assert(hc_verify_checkpoint_file(file, getuid(), NULL, 5) < 0);
    assert(fchmod(file, 0644) == 0);
    assert(hc_verify_checkpoint_file(file, getuid(), "state", 5) < 0);
    assert(fchmod(file, 0600) == 0);
    assert(linkat(fd, "state.tmp", fd, "other-link", 0) == 0);
    assert(hc_verify_checkpoint_file(file, getuid(), "state", 5) < 0);
    assert(unlinkat(fd, "other-link", 0) == 0);
    char large[9000]; memset(large, 'x', sizeof large);
    assert(ftruncate(file, 0) == 0 && lseek(file, 0, SEEK_SET) == 0);
    assert(write(file, large, sizeof large) == (ssize_t)sizeof large);
    assert(hc_verify_checkpoint_file(file, getuid(), large, sizeof large) == 0);
    large[8999] = 'y';
    assert(hc_verify_checkpoint_file(file, getuid(), large, sizeof large) < 0);
    assert(hc_create_checkpoint_file(fd, getuid(), "state.tmp") < 0 && errno == EEXIST);
    assert(hc_create_checkpoint_file(fd, getuid(), "../state.tmp") < 0);
    assert(hc_create_checkpoint_file(fd, getuid() + 1, "other.tmp") < 0);
    assert(symlinkat("/tmp", fd, "link") == 0);
    assert(hc_create_checkpoint_file(fd, getuid(), "link") < 0);
    close(file);
    assert(unlinkat(fd, "state.tmp", 0) == 0);
    assert(unlinkat(fd, "link", 0) == 0);
    assert(hc_create_checkpoint_workspace(parent, getuid(), nonce, name) < 0 && errno == EEXIST);
    memset(nonce, 0, sizeof nonce);
    assert(hc_create_checkpoint_workspace(parent, getuid(), nonce, name) < 0);
    nonce[0] = 2;
    assert(chmod(path, 0755) == 0);
    assert(hc_create_checkpoint_workspace(parent, getuid(), nonce, name) < 0);
    assert(chmod(path, 0700) == 0);
    assert(hc_create_checkpoint_workspace(parent, getuid() + 1, nonce, name) < 0);
    close(fd);
    assert(unlinkat(parent, "checkpoint-01000000000000000000000000000000", AT_REMOVEDIR) == 0);
    close(parent);
    assert(rmdir(path) == 0);
    puts("checkpoint workspace tests passed");
}
