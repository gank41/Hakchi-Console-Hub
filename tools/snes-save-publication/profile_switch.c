/* Fixed-path SNES save-profile switch. Not currently installed or used. */
#define _POSIX_C_SOURCE 200809L
#include <sys/types.h>
#include <sys/stat.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int valid_id(const char *id) {
    if (strlen(id) != 36) return 0;
    for (size_t i = 0; i < 36; ++i) {
        if (i == 8 || i == 13 || i == 18 || i == 23) { if (id[i] != '-') return 0; }
        else if (!((id[i] >= '0' && id[i] <= '9') || (id[i] >= 'A' && id[i] <= 'F'))) return 0;
    }
    return 1;
}

static int valid_game(const char *game) {
    if (strlen(game) != 11 || memcmp(game, "CLV-", 4) || game[5] != '-' || !strchr("PUS", game[4])) return 0;
    for (size_t i = 6; i < 11; ++i)
        if (!((game[i] >= '0' && game[i] <= '9') || (game[i] >= 'A' && game[i] <= 'Z'))) return 0;
    return 1;
}

static int valid_slot(const char *slot) {
    return strlen(slot) == 13 && !memcmp(slot, "suspendpoint", 12) && slot[12] >= '1' && slot[12] <= '4';
}

static int number(const char *text, uintmax_t *value) {
    if (!*text) return 0;
    for (const char *p = text; *p; ++p) if (*p < '0' || *p > '9') return 0;
    errno = 0;
    char *end = NULL;
    uintmax_t parsed = strtoumax(text, &end, 10);
    if (errno || !end || *end) return 0;
    *value = parsed;
    return 1;
}

/* Open each child separately so no accepted path follows a symbolic link. */
static int child(int parent, const char *name, dev_t device, int check_device) {
    int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat st;
    if (fd < 0) return -1;
    if (fstat(fd, &st) || !S_ISDIR(st.st_mode) || st.st_uid != 0 || (check_device && st.st_dev != device)) {
        close(fd); return -1;
    }
    return fd;
}

static int matches(int parent, const char *name, int fd, uintmax_t device, uintmax_t inode, int require_private) {
    struct stat opened, named;
    if (fstat(fd, &opened) || fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW)) return 0;
    return S_ISDIR(named.st_mode) && named.st_uid == 0 && opened.st_dev == named.st_dev && opened.st_ino == named.st_ino &&
           (uintmax_t)opened.st_dev == device && (uintmax_t)opened.st_ino == inode &&
           (!require_private || (opened.st_mode & 07777) == 0700);
}

static int empty_directory(int fd) {
    /* dup shares a directory offset, so a later check could miss new files. */
    int copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (copy < 0) return 0;
    DIR *dir = fdopendir(copy);
    if (!dir) { close(copy); return 0; }
    int empty = 1;
    errno = 0;
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, "..")) { empty = 0; break; }
    }
    if (errno) empty = 0;
    if (closedir(dir)) empty = 0;
    return empty;
}

int main(int argc, char **argv) {
    uintmax_t src_dev, src_ino, dst_dev, dst_ino, profile_dev = 0, profile_ino = 0;
    int is_slot = argc == 10, offset = is_slot ? 1 : 0;
    if ((argc != 7 && !is_slot) || !valid_id(argv[1]) || !valid_game(argv[2]) ||
        (is_slot && !valid_slot(argv[3])) || !number(argv[3 + offset], &src_dev) ||
        !number(argv[4 + offset], &src_ino) || !number(argv[5 + offset], &dst_dev) || !number(argv[6 + offset], &dst_ino) ||
        (is_slot && (!number(argv[8], &profile_dev) || !number(argv[9], &profile_ino)))) return 2;
    int fd[10]; for (size_t i = 0; i < 10; ++i) fd[i] = -1;
    int result = 1;
    fd[0] = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd[0] < 0) goto done;
    fd[1] = child(fd[0], "var", 0, 0); if (fd[1] < 0) goto done;
    fd[2] = child(fd[1], "lib", 0, 0); if (fd[2] < 0) goto done;
    struct stat data;
    if (fstat(fd[2], &data) || (uintmax_t)data.st_dev != src_dev || src_dev != dst_dev) goto done;
    fd[3] = child(fd[2], "swifthakchi", data.st_dev, 1); if (fd[3] < 0) goto done;
    fd[4] = child(fd[3], "snes-v2", data.st_dev, 1); if (fd[4] < 0) goto done;
    fd[5] = child(fd[4], "save-staging", data.st_dev, 1); if (fd[5] < 0) goto done;
    fd[6] = child(fd[5], argv[1], data.st_dev, 1); if (fd[6] < 0) goto done;
    fd[7] = child(fd[2], "clover", data.st_dev, 1); if (fd[7] < 0) goto done;
    fd[8] = child(fd[7], "profiles", data.st_dev, 1); if (fd[8] < 0) goto done;
    fd[9] = child(fd[8], "0", data.st_dev, 1); if (fd[9] < 0) goto done;
    int profile = -1, parent = fd[9];
    const char *target_name = argv[2];
    if (is_slot) {
        profile = child(fd[9], argv[2], data.st_dev, 1);
        if (profile < 0) goto done;
        if (!matches(fd[9], argv[2], profile, profile_dev, profile_ino, 1)) { close(profile); goto done; }
        parent = profile; target_name = argv[3];
    }
    int source = child(fd[6], "publication", data.st_dev, 1);
    int target = child(parent, target_name, data.st_dev, 1);
    if (source < 0 || target < 0) { if (source >= 0) close(source); if (target >= 0) close(target); if (profile >= 0) close(profile); goto done; }
    if (!matches(fd[6], "publication", source, src_dev, src_ino, 1) ||
        !matches(parent, target_name, target, dst_dev, dst_ino, 1) || !empty_directory(target) || fsync(source) ||
        (is_slot && !matches(fd[9], argv[2], profile, profile_dev, profile_ino, 1)) ||
        !matches(fd[6], "publication", source, src_dev, src_ino, 1) ||
        !matches(parent, target_name, target, dst_dev, dst_ino, 1) || !empty_directory(target)) goto close_pair;
    /* Linux rename replaces an empty directory atomically on one filesystem.
       The caller still needs exclusive coordination against other root writers. */
    if (renameat(fd[6], "publication", parent, target_name)) goto close_pair;
    struct stat after;
    if ((is_slot && !matches(fd[9], argv[2], profile, profile_dev, profile_ino, 1)) ||
        fstatat(parent, target_name, &after, AT_SYMLINK_NOFOLLOW) || !S_ISDIR(after.st_mode) ||
        (uintmax_t)after.st_dev != src_dev || (uintmax_t)after.st_ino != src_ino) goto close_pair;
    if (!fstatat(fd[6], "publication", &after, AT_SYMLINK_NOFOLLOW) || errno != ENOENT || fsync(fd[6]) || fsync(parent)) goto close_pair;
    if (fputs("PROFILE_SWITCHED\n", stdout) == EOF || fflush(stdout)) goto close_pair;
    result = 0;
close_pair:
    close(source); close(target);
    if (profile >= 0) close(profile);
done:
    for (size_t i = 0; i < 10; ++i) if (fd[i] >= 0) close(fd[i]);
    return result;
}
