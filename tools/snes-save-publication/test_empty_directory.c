/* Exercise repeated directory checks with a change between them. */
#define main profile_switch_program_main
#include "profile_switch.c"
#undef main

int main(int argc, char **argv) {
    if (argc != 2 || mkdir(argv[1], 0700)) return 2;
    int fd = open(argv[1], O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (fd < 0 || !empty_directory(fd)) return 3;
    int file = openat(fd, "new-save", O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (file < 0 || close(file)) return 4;
    int correctly_not_empty = !empty_directory(fd);
    int cleanup = unlinkat(fd, "new-save", 0) || close(fd) || rmdir(argv[1]);
    return correctly_not_empty && !cleanup ? 0 : 5;
}
