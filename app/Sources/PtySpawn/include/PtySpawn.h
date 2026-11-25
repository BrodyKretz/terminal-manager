#ifndef PTY_SPAWN_H
#define PTY_SPAWN_H

#include <sys/types.h>

/// Starts `path` with `argv` and `envp` on a new pseudo-terminal of `rows` x `cols`, as the leader of a new
/// session whose controlling terminal it is. Returns the child's pid and the master side in `master_fd`
/// (close-on-exec, non-blocking), or -1 with errno set.
pid_t tm_spawn_pty(const char *path, char *const argv[], char *const envp[], unsigned short rows, unsigned short cols, int *master_fd);

/// TIOCSWINSZ on the master: the kernel sends SIGWINCH to the terminal's foreground process group.
int tm_set_window_size(int master_fd, unsigned short rows, unsigned short cols);

#endif
