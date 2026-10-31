#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "owned_directory.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int safe_component(const char *name) {
    if (!name) return 0;
    size_t n = 0;
    while (n < 128 && name[n]) {
        unsigned char c = (unsigned char)name[n++];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
              (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.')) return 0;
    }
    return n > 0 && n < 128 && strcmp(name, ".") && strcmp(name, "..");
}
static int safe_directory(int fd, uid_t owner) {
    struct stat st;
    return fstat(fd, &st) == 0 && S_ISDIR(st.st_mode) &&
           st.st_uid == owner && (st.st_mode & 0022) == 0;
}
int hc_open_owned_directory(int parent, const char *name, uid_t owner) {
    if (!safe_component(name) || !safe_directory(parent, owner)) { errno = EINVAL; return -1; }
    int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    if (!safe_directory(fd, owner)) {
        close(fd);
        errno = EACCES;
        return -1;
    }
    return fd;
}

static int safe_file(const struct stat *st, uid_t owner, off_t limit) {
    return S_ISREG(st->st_mode) && st->st_uid == owner &&
        (st->st_mode & 0022) == 0 && st->st_nlink == 1 &&
        st->st_size >= 0 && st->st_size <= limit;
}
int hc_open_owned_file(int parent, const char *name, uid_t owner, off_t max_size) {
    struct stat before, after;
    if (max_size < 0 || !safe_component(name) || !safe_directory(parent, owner)) {
        errno = EINVAL; return -1;
    }
    if (fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) != 0) return -1;
    if (!safe_file(&before, owner, max_size)) { errno = EACCES; return -1; }
    int fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    if (fstat(fd, &after) != 0 || !safe_file(&after, owner, max_size) ||
        before.st_dev != after.st_dev || before.st_ino != after.st_ino) {
        close(fd); errno = EACCES; return -1;
    }
    return fd;
}

int hc_create_checkpoint_workspace(int parent, uid_t owner,
                                   const uint8_t nonce[16], char name[44]) {
    static const char hex[] = "0123456789abcdef";
    struct stat parent_stat, before, after;
    unsigned nonzero = 0;
    if (!nonce || !name || fstat(parent, &parent_stat) != 0 ||
        !S_ISDIR(parent_stat.st_mode) || parent_stat.st_uid != owner ||
        (parent_stat.st_mode & 0777) != 0700) {
        errno = EINVAL; return -1;
    }
    memcpy(name, "checkpoint-", 11);
    for (size_t i = 0; i < 16; i++) {
        nonzero |= nonce[i];
        name[11 + i * 2] = hex[nonce[i] >> 4];
        name[12 + i * 2] = hex[nonce[i] & 15];
    }
    name[43] = '\0';
    if (!nonzero) { errno = EINVAL; return -1; }
    if (mkdirat(parent, name, 0700) != 0) return -1;
    if (fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) != 0) return -1;
    int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    if (fstat(fd, &after) != 0 || !S_ISDIR(after.st_mode) ||
        after.st_uid != owner || (after.st_mode & 0777) != 0700 ||
        before.st_dev != after.st_dev || before.st_ino != after.st_ino) {
        close(fd); errno = EACCES; return -1;
    }
    return fd;
}

int hc_create_checkpoint_file(int workspace, uid_t owner, const char *name) {
    struct stat dir, file, entry;
    if (!safe_component(name) || fstat(workspace, &dir) != 0 ||
        !S_ISDIR(dir.st_mode) || dir.st_uid != owner ||
        (dir.st_mode & 0777) != 0700) {
        errno = EINVAL; return -1;
    }
    int fd = openat(workspace, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    if (fstat(fd, &file) != 0 || fstatat(workspace, name, &entry, AT_SYMLINK_NOFOLLOW) != 0 ||
        !S_ISREG(file.st_mode) || file.st_uid != owner || file.st_nlink != 1 ||
        (file.st_mode & 0777) != 0600 || file.st_dev != entry.st_dev || file.st_ino != entry.st_ino) {
        close(fd); errno = EACCES; return -1;
    }
    return fd;
}

int hc_verify_checkpoint_file(int fd, uid_t owner, const void *expected, size_t size) {
    struct stat before, after;
    unsigned char buffer[4096];
    const unsigned char *bytes = expected;
    if (!expected || size == 0 || size > 128u * 1024u * 1024u ||
        fstat(fd, &before) != 0 || !S_ISREG(before.st_mode) ||
        before.st_uid != owner || before.st_nlink != 1 ||
        (before.st_mode & 0777) != 0600 || before.st_size != (off_t)size) {
        errno = EINVAL; return -1;
    }
    if (fsync(fd) != 0) return -1;
    for (size_t offset = 0; offset < size;) {
        size_t count = size - offset;
        if (count > sizeof buffer) count = sizeof buffer;
        ssize_t n = pread(fd, buffer, count, (off_t)offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { if (n == 0) errno = EIO; return -1; }
        if (memcmp(buffer, bytes + offset, (size_t)n) != 0) { errno = EIO; return -1; }
        offset += (size_t)n;
    }
    if (fstat(fd, &after) != 0 || before.st_dev != after.st_dev ||
        before.st_ino != after.st_ino || before.st_size != after.st_size ||
        after.st_uid != owner || after.st_nlink != 1 || (after.st_mode & 0777) != 0600) {
        errno = EIO; return -1;
    }
    return 0;
}

int hc_write_checkpoint_file(int fd, uid_t owner, const void *bytes, size_t size) {
    struct stat st;
    int flags = fcntl(fd, F_GETFL);
    if (!bytes || size == 0 || size > 128u * 1024u * 1024u ||
        flags < 0 || (flags & O_ACCMODE) != O_RDWR || (flags & O_APPEND) ||
        fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != owner ||
        st.st_nlink != 1 || (st.st_mode & 0777) != 0600 || st.st_size != 0) {
        errno = EINVAL; return -1;
    }
    const unsigned char *input = bytes;
    for (size_t offset = 0; offset < size;) {
        size_t count = size - offset;
        if (count > 65536) count = 65536;
        ssize_t n = pwrite(fd, input + offset, count, (off_t)offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { if (n == 0) errno = EIO; return -1; }
        offset += (size_t)n;
    }
    return hc_verify_checkpoint_file(fd, owner, bytes, size);
}
