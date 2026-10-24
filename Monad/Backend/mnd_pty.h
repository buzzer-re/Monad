/*
 * mnd_pty.h — pseudo-terminal process spawning.
 */
#ifndef MND_PTY_H
#define MND_PTY_H

#include <stdbool.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int master_fd; /* non-blocking, close-on-exec */
    pid_t pid;     /* session leader of the child */
} mnd_pty;

/* Spawn `path` with argv/envp (NULL-terminated) on a new PTY of cols x rows.
 * The child gets a new session with the PTY as controlling terminal, default
 * signal dispositions, an empty signal mask and only fds 0-2 open.
 * cwd may be NULL. Returns 0 on success or an errno value (including the
 * child's execve() error). */
int mnd_pty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd, int cols, int rows,
                  mnd_pty *out);

/* Update the window size (TIOCSWINSZ); the kernel delivers SIGWINCH. */
int mnd_pty_resize(int master_fd, int cols, int rows, int px_width, int px_height);

/* Send a signal to the child's process group (falls back to the pid). */
int mnd_pty_signal(pid_t pid, int sig);

/* Reap the child. Returns 1 if it exited (status stored), 0 if still running
 * (nohang), -1 on error. */
int mnd_pty_wait(pid_t pid, int *status, bool nohang);

/* Name of the foreground process on the PTY (for tab titles), or empty. */
bool mnd_pty_foreground_pid(int master_fd, pid_t *pid);

#ifdef __cplusplus
}
#endif

#endif
