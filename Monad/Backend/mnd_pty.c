/*
 * mnd_pty.c — PTY spawning with fork/exec.
 *
 * posix_spawn cannot acquire a controlling terminal (TIOCSCTTY), so we fork
 * and restrict the child to async-signal-safe calls until execve().
 */
#include "mnd_pty.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#endif

static int set_flags(int fd) {
    int fl = fcntl(fd, F_GETFL);
    if (fl < 0 || fcntl(fd, F_SETFL, fl | O_NONBLOCK) < 0) return errno;
    int fdfl = fcntl(fd, F_GETFD);
    if (fdfl < 0 || fcntl(fd, F_SETFD, fdfl | FD_CLOEXEC) < 0) return errno;
    return 0;
}

static void default_termios(struct termios *t) {
    memset(t, 0, sizeof *t);
    t->c_iflag = ICRNL | IXON | IXANY | IMAXBEL | BRKINT;
#ifdef IUTF8
    t->c_iflag |= IUTF8;
#endif
    t->c_oflag = OPOST | ONLCR;
    t->c_cflag = CREAD | CS8 | HUPCL;
    t->c_lflag = ICANON | ISIG | IEXTEN | ECHO | ECHOE | ECHOK | ECHOKE | ECHOCTL;
    t->c_cc[VEOF] = 4;
    t->c_cc[VEOL] = 0xff;
    t->c_cc[VEOL2] = 0xff;
    t->c_cc[VERASE] = 0x7f;
    t->c_cc[VWERASE] = 23;
    t->c_cc[VKILL] = 21;
    t->c_cc[VREPRINT] = 18;
    t->c_cc[VINTR] = 3;
    t->c_cc[VQUIT] = 0x1c;
    t->c_cc[VSUSP] = 26;
    t->c_cc[VSTART] = 17;
    t->c_cc[VSTOP] = 19;
    t->c_cc[VLNEXT] = 22;
    t->c_cc[VDISCARD] = 15;
    t->c_cc[VMIN] = 1;
    t->c_cc[VTIME] = 0;
#ifdef VDSUSP
    t->c_cc[VDSUSP] = 25;
#endif
#ifdef VSTATUS
    t->c_cc[VSTATUS] = 20;
#endif
    cfsetispeed(t, B38400);
    cfsetospeed(t, B38400);
}

int mnd_pty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd, int cols, int rows,
                  mnd_pty *out) {
    if (!path || !argv || !out || cols < 1 || rows < 1) return EINVAL;
    int master = -1, slave = -1;
    struct winsize ws = {(unsigned short)rows, (unsigned short)cols, 0, 0};
    struct termios tio;
    default_termios(&tio);
    if (openpty(&master, &slave, NULL, &tio, &ws) != 0) return errno;

    int err = set_flags(master);
    if (err) {
        close(master);
        close(slave);
        return err;
    }

    /* Pipe to report execve() failure from the child. */
    int ep[2];
    if (pipe(ep) != 0) {
        err = errno;
        close(master);
        close(slave);
        return err;
    }
    fcntl(ep[0], F_SETFD, FD_CLOEXEC);
    fcntl(ep[1], F_SETFD, FD_CLOEXEC);

    struct rlimit rl;
    int maxfd = (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur != RLIM_INFINITY && rl.rlim_cur < 65536)
                    ? (int)rl.rlim_cur
                    : 65536;

    sigset_t all, old;
    sigfillset(&all);
    pthread_sigmask(SIG_SETMASK, &all, &old);

    pid_t pid = fork();
    if (pid < 0) {
        err = errno;
        pthread_sigmask(SIG_SETMASK, &old, NULL);
        close(master);
        close(slave);
        close(ep[0]);
        close(ep[1]);
        return err;
    }

    if (pid == 0) {
        /* Child: async-signal-safe calls only. */
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_handler = SIG_DFL;
        for (int s = 1; s < NSIG; s++) {
            if (s == SIGKILL || s == SIGSTOP) continue;
            sigaction(s, &sa, NULL);
        }
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);

        if (setsid() < 0) goto child_fail;
        if (ioctl(slave, TIOCSCTTY, 0) < 0) goto child_fail;
        if (dup2(slave, 0) < 0 || dup2(slave, 1) < 0 || dup2(slave, 2) < 0) goto child_fail;
        for (int fd = 3; fd < maxfd; fd++)
            if (fd != ep[1]) close(fd);
        if (cwd && chdir(cwd) != 0) {
            /* Not fatal: fall back to the inherited directory. */
        }
        execve(path, argv, envp);
    child_fail: {
        int e = errno;
        ssize_t w;
        do {
            w = write(ep[1], &e, sizeof e);
        } while (w < 0 && errno == EINTR);
        _exit(127);
    }
    }

    pthread_sigmask(SIG_SETMASK, &old, NULL);
    close(slave);
    close(ep[1]);
    int child_err = 0;
    ssize_t r;
    do {
        r = read(ep[0], &child_err, sizeof child_err);
    } while (r < 0 && errno == EINTR);
    close(ep[0]);
    if (r == (ssize_t)sizeof child_err) {
        int st;
        waitpid(pid, &st, 0);
        close(master);
        return child_err ? child_err : ECHILD;
    }
    out->master_fd = master;
    out->pid = pid;
    return 0;
}

int mnd_pty_resize(int master_fd, int cols, int rows, int px_width, int px_height) {
    if (cols < 1 || rows < 1) return EINVAL;
    struct winsize ws = {(unsigned short)rows, (unsigned short)cols, (unsigned short)(px_width > 0 ? px_width : 0),
                         (unsigned short)(px_height > 0 ? px_height : 0)};
    return ioctl(master_fd, TIOCSWINSZ, &ws) == 0 ? 0 : errno;
}

int mnd_pty_signal(pid_t pid, int sig) {
    if (pid <= 0) return EINVAL;
    if (kill(-pid, sig) == 0) return 0;
    return kill(pid, sig) == 0 ? 0 : errno;
}

int mnd_pty_wait(pid_t pid, int *status, bool nohang) {
    int st = 0;
    pid_t r;
    do {
        r = waitpid(pid, &st, nohang ? WNOHANG : 0);
    } while (r < 0 && errno == EINTR);
    if (r < 0) return -1;
    if (r == 0) return 0;
    if (status) *status = st;
    return 1;
}

bool mnd_pty_foreground_pid(int master_fd, pid_t *pid) {
    pid_t p = tcgetpgrp(master_fd);
    if (p <= 0) return false;
    *pid = p;
    return true;
}
