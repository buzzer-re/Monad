/*
 * mnd_netd_main.c — the netd process: MonadHost starts its own binary with
 * --netd, the control channel as descriptor 3. See mnd_netd.h.
 *
 * Order matters: nothing inherited survives except stderr and the channel,
 * and the sandbox is on before the first command is read.
 */
#include "mnd_netd.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <spawn.h>
#include <unistd.h>

#ifdef __APPLE__
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include <sandbox.h>

/* The network, nothing else: no files (read or write), no processes, no
 * services, no listening. Inbound is allowed only for what is neither TCP
 * nor UDP, because ping replies arrive as inbound ICMP; connected UDP and TCP
 * work with outbound alone. Checked by MonadHost --netd-sandbox-check.
 * Everything netd uses is loaded before this applies. */
static const char SANDBOX_PROFILE[] = "(version 1)\n"
                                      "(deny default)\n"
                                      "(allow network-outbound)\n"
                                      "(allow network-inbound)\n"
                                      "(deny network-inbound (local tcp))\n"
                                      "(deny network-bind (local udp \"*:*\"))\n"
                                      "(allow system-socket)\n"
                                      "(allow sysctl-read)\n";

static int enter_sandbox(void) {
    char *err = NULL;
    if (sandbox_init(SANDBOX_PROFILE, 0, &err) != 0) {
        if (err) {
            fprintf(stderr, "monad-netd: sandbox: %s\n", err);
            sandbox_free_error(err);
        }
        return -1;
    }
    return 0;
}
#pragma clang diagnostic pop
#else
/* Linux builds exist for the tests; netd ships on macOS only. */
static int enter_sandbox(void) { return 0; }
#endif

/* Everything open except stderr and the control channel is closed; stdin
 * and stdout read and write nothing. */
static void close_inherited(void) {
    int top = (int)sysconf(_SC_OPEN_MAX);
    if (top < 0 || top > 65536) top = 65536;
    for (int fd = MND_NETD_CONTROL_FD + 1; fd < top; fd++) close(fd);
    int null = open("/dev/null", O_RDWR);
    if (null >= 0) {
        dup2(null, STDIN_FILENO);
        dup2(null, STDOUT_FILENO);
        if (null > STDERR_FILENO && null != MND_NETD_CONTROL_FD) close(null);
    }
}

static void limits(void) {
    struct rlimit core = {0, 0};
    setrlimit(RLIMIT_CORE, &core);
    struct rlimit files;
    if (getrlimit(RLIMIT_NOFILE, &files) == 0) {
        rlim_t want = MND_LOOP_MAX_FDS;
        if (files.rlim_max != RLIM_INFINITY && files.rlim_max < want) want = files.rlim_max;
        if (files.rlim_cur < want) {
            files.rlim_cur = want;
            setrlimit(RLIMIT_NOFILE, &files);
        }
    }
}

int mnd_netd_main(void) {
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, SIG_DFL); /* MonadHost stops netd with it */
    signal(SIGINT, SIG_DFL);
    struct stat st;
    if (fstat(MND_NETD_CONTROL_FD, &st) != 0 || !S_ISSOCK(st.st_mode)) {
        fprintf(stderr, "monad-netd: descriptor %d is not a socket\n", MND_NETD_CONTROL_FD);
        return 64;
    }
    close_inherited();
    limits();
    if (enter_sandbox() != 0) {
        fprintf(stderr, "monad-netd: refusing to run without the sandbox\n");
        return 70;
    }
    int status = mnd_netd_serve(MND_NETD_CONTROL_FD);
    return status == 0 ? 0 : status == 1 ? 1 : 70;
}

/* ---- Checking the sandbox (MonadHost --netd-sandbox-check, Debug builds) ---- */

static const char *verdict(bool ok) { return ok ? "ok" : "FAILED"; }

static bool wait_readable(int fd) {
    struct pollfd p = {.fd = fd, .events = POLLIN};
    return poll(&p, 1, 1000) == 1;
}

static struct sockaddr_in loopback(uint16_t port) {
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    return a;
}

static bool udp_works(uint16_t port) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in a = loopback(port);
    bool ok = fd >= 0 && connect(fd, (struct sockaddr *)&a, sizeof a) == 0 && send(fd, "x", 1, 0) == 1 &&
              wait_readable(fd);
    char b;
    ok = ok && recv(fd, &b, 1, 0) == 1;
    if (fd >= 0) close(fd);
    return ok;
}

static bool tcp_works(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = loopback(port);
    bool ok = fd >= 0 && connect(fd, (struct sockaddr *)&a, sizeof a) == 0 && wait_readable(fd);
    char b[2];
    ok = ok && recv(fd, b, 2, 0) > 0;
    if (fd >= 0) close(fd);
    return ok;
}

/* Ping 127.0.0.1; on failure `why` names the step and the error. */
static bool icmp_works(char *why, size_t cap) {
    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
    if (fd < 0) {
        snprintf(why, cap, " (socket: errno %d)", errno);
        return false;
    }
    uint8_t echo[8] = {8, 0, 0, 0, 0x12, 0x34, 0, 1};
    uint16_t sum = mnd_csum_finish(mnd_csum_add(0, echo, sizeof echo));
    echo[2] = (uint8_t)(sum >> 8);
    echo[3] = (uint8_t)sum;
    struct sockaddr_in a = loopback(0);
    bool ok = false;
    if (sendto(fd, echo, sizeof echo, 0, (struct sockaddr *)&a, sizeof a) != (ssize_t)sizeof echo)
        snprintf(why, cap, " (send: errno %d)", errno);
    else if (!wait_readable(fd))
        snprintf(why, cap, " (no reply)");
    else {
        uint8_t b[128];
        ok = recv(fd, b, sizeof b, 0) > 0;
        if (!ok) snprintf(why, cap, " (recv: errno %d)", errno);
    }
    close(fd);
    return ok;
}

static bool unix_connect_works(const char *path) {
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    if (!path || strlen(path) >= sizeof a.sun_path) return false;
    strcpy(a.sun_path, path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    bool ok = fd >= 0 && connect(fd, (struct sockaddr *)&a, sizeof a) == 0;
    if (fd >= 0) close(fd);
    return ok;
}

int mnd_netd_sandbox_check(uint16_t udp_port, uint16_t tcp_port, const char *unix_path) {
    /* The same connect outside the sandbox works, or the check proves nothing. */
    bool unix_control = unix_connect_works(unix_path);
    if (enter_sandbox() != 0) {
        printf("sandbox FAILED\n");
        return 70;
    }
    char why[64] = "";
    bool udp = udp_works(udp_port), tcp = tcp_works(tcp_port), icmp = icmp_works(why, sizeof why);
    int f = open("/etc/hosts", O_RDONLY);
    bool no_read = f < 0;
    if (f >= 0) close(f);
    int w = open("/tmp/monad-netd-sandbox-check", O_WRONLY | O_CREAT, 0600);
    bool no_write = w < 0;
    if (w >= 0) {
        close(w);
        unlink("/tmp/monad-netd-sandbox-check");
    }
    /* Inbound is allowed for ping replies, but netd may not listen. */
    int l = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in any = loopback(0);
    bool no_listen = l < 0 || bind(l, (struct sockaddr *)&any, sizeof any) != 0 || listen(l, 1) != 0;
    if (l >= 0) close(l);
    /* A UDP "listener": a bound port a datagram from outside can reach. The
     * sender is this process, from before the sandbox would matter. */
    int u = socket(AF_INET, SOCK_DGRAM, 0), sender = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in ua = loopback(0);
    socklen_t ul = sizeof ua;
    bool udp_listener = u >= 0 && bind(u, (struct sockaddr *)&ua, sizeof ua) == 0 &&
                        getsockname(u, (struct sockaddr *)&ua, &ul) == 0 &&
                        sendto(sender, "y", 1, 0, (struct sockaddr *)&ua, sizeof ua) == 1 && wait_readable(u);
    char yb;
    udp_listener = udp_listener && recv(u, &yb, 1, 0) == 1;
    if (u >= 0) close(u);
    if (sender >= 0) close(sender);
    pid_t pid = fork();
    if (pid == 0) _exit(0);
    if (pid > 0) waitpid(pid, NULL, 0);
    bool no_fork = pid < 0;
    bool no_unix = !unix_connect_works(unix_path);
    printf("udp %s\ntcp %s\nicmp %s%s\nfile-read-denied %s\nfile-write-denied %s\nfork-denied %s\nlisten-denied %s\n"
           "unix-connect-denied %s%s\nudp-listener %s\n",
           verdict(udp), verdict(tcp), verdict(icmp), why, verdict(no_read), verdict(no_write), verdict(no_fork),
           verdict(no_listen), verdict(unix_control && no_unix), unix_control ? "" : " (no listener to try)",
           udp_listener ? "possible" : "denied");
    fflush(stdout);
    return udp && tcp && icmp && no_read && no_write && no_fork && no_listen && unix_control && no_unix ? 0 : 1;
}

/* ---- Starting netd (MonadHost) ---------------------------------------------------- */

pid_t mnd_netd_spawn(const char *path, int control) {
    if (!path || control < 0) return -1;
    posix_spawn_file_actions_t fa;
    posix_spawnattr_t attr;
    if (posix_spawn_file_actions_init(&fa) != 0) return -1;
    if (posix_spawnattr_init(&attr) != 0) {
        posix_spawn_file_actions_destroy(&fa);
        return -1;
    }
    /* Only the channel goes across, as descriptor 3 (netd closes anything else
     * too). stdin/stdout are /dev/null; stderr is MonadHost's. */
    int ok = posix_spawn_file_actions_adddup2(&fa, control, MND_NETD_CONTROL_FD) == 0 &&
             posix_spawn_file_actions_addopen(&fa, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0 &&
             posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0;
#ifdef __APPLE__
    ok = ok && posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT) == 0 &&
         posix_spawn_file_actions_addinherit_np(&fa, STDERR_FILENO) == 0;
#endif
    char *const argv[] = {(char *)path, (char *)"--netd", NULL};
    char *const envp[] = {NULL};
    pid_t pid = -1;
    if (!ok || posix_spawn(&pid, path, &fa, &attr, argv, envp) != 0) pid = -1;
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    return pid;
}
