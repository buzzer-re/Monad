/*
 * mnd_guestd.h — monad-guestd: Monad's way into a macOS guest (Phase 14).
 *
 * A Linux guest's systemd serves sshd and Monad's agent on vsock ports 22
 * and 1024; macOS's launchd cannot listen on vsock, so this does, as a
 * LaunchDaemon in the guest (MonadHost --guestd, the same binary): one
 * process per connection, the connection as its stdin and stdout, at most
 * so many at a time per service. sshd itself is started by launchd
 * (dev.monad.sshd, as Apple's own ssh job but on the guest's loopback
 * only): port 22 joins each connection to it. The host dials; nothing
 * listens on the guest's network for Monad. Unix sockets stand in for
 * vsock in tests.
 */
#ifndef MND_GUESTD_H
#define MND_GUESTD_H

#define MND_GUESTD_MAX_SERVICES 4
#define MND_GUESTD_AGENT "/usr/local/libexec/monad/agent"
/* launchd's sshd job (dev.monad.sshd) listens on the guest's loopback,
 * this port: Apple's sshd needs an IP peer for its audit session. */
#define MND_GUESTD_SSHD_PORT "22"

typedef struct {
    unsigned port;
    /* An absolute program and its arguments, NULL-terminated. */
    char *const *argv;
} mnd_guestd_service;

typedef struct {
    /* AF_VSOCK in the guest; AF_UNIX in tests (unix_dir/<port>). */
    int family;
    const char *unix_dir;
    mnd_guestd_service services[MND_GUESTD_MAX_SERVICES];
    int nservices;
    /* Connections served at once, per service; one more is closed at once. */
    int max_children;
} mnd_guestd_config;

/* 0 if the configuration is usable. */
int mnd_guestd_check(const mnd_guestd_config *c);

/* The guest's own: ssh on 22 (joined to launchd's sshd on the loopback),
 * the agent on 1024. */
void mnd_guestd_guest_config(mnd_guestd_config *c);

/* Listen and serve until SIGTERM or SIGINT (then 0); -1 if it cannot listen. */
int mnd_guestd_run(const mnd_guestd_config *c);

/* MonadHost --guestd: the guest's configuration, served over vsock. */
int mnd_guestd_main(void);

#endif
