#define _DARWIN_C_SOURCE 1

#define _POSIX_C_SOURCE 200809L
#include "owned_directory.h"
#include <assert.h>
#include <fcntl.h>
#include <stdlib.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

int main(void) {
    char temp[] = "/tmp/hakchi-owned-XXXXXX";
    assert(mkdtemp(temp));
    int root = open(temp, O_RDONLY);
    assert(root >= 0);
    assert(mkdirat(root, "engine", 0700) == 0);
    assert(mkdirat(root, "unsafe", 0777) == 0);
    assert(fchmodat(root, "unsafe", 0777, 0) == 0);
    assert(symlinkat("engine", root, "link") == 0);
    int regular = openat(root, "file", O_CREAT | O_EXCL | O_WRONLY, 0600);
    assert(regular >= 0); close(regular);
    int engine = hc_open_owned_directory(root, "engine", getuid());
    assert(engine >= 0);
    struct stat st; assert(fstat(engine, &st) == 0 && S_ISDIR(st.st_mode));
    assert((fcntl(engine, F_GETFD) & FD_CLOEXEC) != 0);
    assert(renameat(root, "engine", root, "moved") == 0);
    assert(symlinkat("unsafe", root, "engine") == 0);
    struct stat still_open; assert(fstat(engine, &still_open) == 0 && st.st_ino == still_open.st_ino);
    assert(hc_open_owned_directory(root, "engine", getuid()) < 0);
    assert(unlinkat(root, "engine", 0) == 0);
    assert(renameat(root, "moved", root, "engine") == 0);
    close(engine);
    assert(fchmod(root, 0777) == 0);
    assert(hc_open_owned_directory(root, "engine", getuid()) < 0);
    assert(fchmod(root, 0700) == 0);
    assert(hc_open_owned_directory(root, "link", getuid()) < 0);
    assert(hc_open_owned_directory(root, "unsafe", getuid()) < 0);
    assert(hc_open_owned_directory(root, "file", getuid()) < 0);
    assert(hc_open_owned_directory(root, "engine", getuid() + 1) < 0);
    assert(hc_open_owned_directory(root, "..", getuid()) < 0);
    assert(hc_open_owned_directory(root, "engine/..", getuid()) < 0);
    assert(hc_open_owned_directory(root, "", getuid()) < 0);
    assert(hc_open_owned_directory(root, NULL, getuid()) < 0);
    assert(unlinkat(root, "link", 0) == 0);
    assert(unlinkat(root, "file", 0) == 0);
    assert(unlinkat(root, "engine", AT_REMOVEDIR) == 0);
    assert(unlinkat(root, "unsafe", AT_REMOVEDIR) == 0);
    close(root); assert(rmdir(temp) == 0);
    return 0;
}
