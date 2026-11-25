#include "PtySpawn.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

pid_t tm_spawn_pty(const char *path, char *const argv[], char *const envp[], unsigned short rows, unsigned short cols, int *master_fd) {
    struct winsize size;
    memset(&size, 0, sizeof(size));
    size.ws_row = rows;
    size.ws_col = cols;
    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &size);
    if (pid < 0) return -1;
    if (pid == 0) {
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        signal(SIGPIPE, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        execve(path, argv, envp);
        _exit(127);
    }
    fcntl(master, F_SETFD, FD_CLOEXEC);
    int flags = fcntl(master, F_GETFL);
    if (flags >= 0) fcntl(master, F_SETFL, flags | O_NONBLOCK);
    *master_fd = master;
    return pid;
}

int tm_set_window_size(int master_fd, unsigned short rows, unsigned short cols) {
    struct winsize size;
    memset(&size, 0, sizeof(size));
    size.ws_row = rows;
    size.ws_col = cols;
    return ioctl(master_fd, TIOCSWINSZ, &size);
}
