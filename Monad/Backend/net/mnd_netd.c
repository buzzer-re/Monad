/*
 * mnd_netd.c — the network core on real sockets. See mnd_netd.h.
 *
 * Every socket has an entry in a fixed table indexed like the core's own
 * ids, and the entry is the loop callback's context. Callbacks into the
 * core can close sockets (the core calls back into us), so every loop that
 * feeds the core checks its entry is still the same one before going on.
 * Connect results are always reported from the loop, never from inside
 * tcp_connect, so the core is never re-entered mid-call.
 */
#include "mnd_netd.h"

#include "mnd_net_internal.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#ifdef __APPLE__
#define SEND_FLAGS 0
#else
#include <sys/random.h>
#define SEND_FLAGS MSG_NOSIGNAL
#endif

#define MAX_DNS 256
#define DNS_BUF 4096

typedef enum { S_FREE = 0, S_PORT, S_UDP, S_ICMP, S_TCP, S_DNS } sock_kind;

typedef struct {
    mnd_netd *d;
    sock_kind kind;
    int fd;
    uint32_t id;       /* port id, flow or connection id, or the core's DNS id */
    bool connecting;   /* TCP: waiting for connect */
    mnd_ip4 dst;       /* ICMP: replies must come from here */
    uint16_t echo_id;  /* ICMP: the identifier on the wire */
    uint16_t txid;     /* DNS: ours on the wire (the core restores the VM's) */
    uint64_t deadline; /* DNS */
} sock;

struct mnd_netd {
    mnd_loop *loop;
    mnd_net *net;
    sock ports[MND_NET_PORT_SLOTS];
    sock flows[MND_NET_MAX_UDP_FLOWS]; /* UDP and ICMP, by flow index */
    sock conns[MND_NET_MAX_TCP_CONNS];
    sock dns[MAX_DNS];
    struct sockaddr_in nameservers[MND_NETD_MAX_NAMESERVERS];
    int nnameservers, next_nameserver;
    mnd_netd_event_fn event;
    void *event_ctx;
    uint8_t buf[65536];
};

static uint32_t random32(void) {
#ifdef __APPLE__
    return arc4random();
#else
    uint32_t v = 0;
    if (getrandom(&v, sizeof v, 0) != (ssize_t)sizeof v) v = (uint32_t)mnd_loop_now() * 2654435761u;
    return v;
#endif
}

static struct sockaddr_in address(mnd_ip4 ip, uint16_t port) {
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(ip);
    return a;
}

/* A non-blocking, close-on-exec socket that never raises SIGPIPE. */
static int new_socket(int type, int proto) {
    int fd = socket(AF_INET, type, proto);
    if (fd < 0) return -1;
    if (fd >= MND_LOOP_MAX_FDS) {
        close(fd);
        return -1;
    }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
#ifdef __APPLE__
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
#endif
    return fd;
}

static void release(mnd_netd *d, sock *s) {
    if (s->kind == S_FREE) return;
    mnd_loop_watch(d->loop, s->fd, 0, NULL, NULL);
    close(s->fd);
    memset(s, 0, sizeof *s);
}

static sock *flow_entry(mnd_netd *d, uint32_t id, sock_kind kind) {
    uint32_t idx = id & 0xffff;
    if (idx >= MND_NET_MAX_UDP_FLOWS) return NULL;
    sock *s = &d->flows[idx];
    return s->kind == kind && s->id == id ? s : NULL;
}

static sock *conn_entry(mnd_netd *d, uint32_t id) {
    uint32_t idx = id & 0xffff;
    if (idx >= MND_NET_MAX_TCP_CONNS) return NULL;
    sock *s = &d->conns[idx];
    return s->kind == S_TCP && s->id == id ? s : NULL;
}

/* ---- The core's host side ------------------------------------------------------- */

static uint64_t h_now(void *ctx) {
    (void)ctx;
    return mnd_loop_now();
}

static void h_send_frame(void *ctx, int port, const uint8_t *frame, size_t len) {
    mnd_netd *d = ctx;
    if (port < 0 || port >= MND_NET_PORT_SLOTS || d->ports[port].kind != S_PORT) return;
    /* A full NIC queue drops the frame; TCP resends, the rest is datagrams. */
    (void)send(d->ports[port].fd, frame, len, MSG_DONTWAIT | SEND_FLAGS);
}

static void on_udp(void *ctx, int fd, unsigned events) {
    sock *s = ctx;
    mnd_netd *d = s->d;
    uint32_t id = s->id;
    (void)events;
    for (int i = 0; i < 16; i++) {
        ssize_t n = recv(fd, d->buf, sizeof d->buf, 0);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            continue; /* e.g. ECONNREFUSED from an ICMP error: nothing to deliver */
        }
        mnd_net_udp_input(d->net, id, d->buf, (size_t)n);
        if (!flow_entry(d, id, S_UDP)) return; /* closed by the core meanwhile */
    }
}

static int h_udp_open(void *ctx, uint32_t flow, mnd_ip4 dst, uint16_t port) {
    mnd_netd *d = ctx;
    uint32_t idx = flow & 0xffff;
    if (idx >= MND_NET_MAX_UDP_FLOWS || d->flows[idx].kind != S_FREE) return -1;
    int fd = new_socket(SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in a = address(dst, port);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) != 0) {
        close(fd);
        return -1;
    }
    sock *s = &d->flows[idx];
    *s = (sock){.d = d, .kind = S_UDP, .fd = fd, .id = flow};
    if (mnd_loop_watch(d->loop, fd, MND_LOOP_READ, on_udp, s) != 0) {
        close(fd);
        memset(s, 0, sizeof *s);
        return -1;
    }
    return 0;
}

static void h_udp_send(void *ctx, uint32_t flow, const uint8_t *data, size_t len) {
    mnd_netd *d = ctx;
    sock *s = flow_entry(d, flow, S_UDP);
    if (s) (void)send(s->fd, data, len, SEND_FLAGS);
}

static void h_udp_close(void *ctx, uint32_t flow) {
    mnd_netd *d = ctx;
    sock *s = flow_entry(d, flow, S_UDP);
    if (s) release(d, s);
}

/* ---- Ping --------------------------------------------------------------------------- */

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }

static void on_icmp(void *ctx, int fd, unsigned events) {
    sock *s = ctx;
    mnd_netd *d = s->d;
    uint32_t id = s->id;
    (void)events;
    for (int i = 0; i < 16; i++) {
        struct sockaddr_in from;
        socklen_t fl = sizeof from;
        ssize_t n = recvfrom(fd, d->buf, sizeof d->buf, 0, (struct sockaddr *)&from, &fl);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            continue;
        }
        const uint8_t *p = d->buf;
        size_t len = (size_t)n;
        /* macOS hands over the IP header too; Linux only the ICMP message. */
        if (len >= 20 && (p[0] >> 4) == 4) {
            size_t hl = (size_t)(p[0] & 0x0f) * 4;
            if (hl > len) continue;
            p += hl;
            len -= hl;
        }
        if (len < 8 || p[0] != 0 || p[1] != 0) continue; /* echo replies only */
        if (ntohl(from.sin_addr.s_addr) != s->dst || rd16(p + 4) != s->echo_id) continue;
        mnd_net_icmp_input(d->net, id, rd16(p + 6), p + 8, len - 8);
        if (!flow_entry(d, id, S_ICMP)) return;
    }
}

static int h_icmp_open(void *ctx, uint32_t flow, mnd_ip4 dst) {
    mnd_netd *d = ctx;
    uint32_t idx = flow & 0xffff;
    if (idx >= MND_NET_MAX_UDP_FLOWS || d->flows[idx].kind != S_FREE) return -1;
    int fd = new_socket(SOCK_DGRAM, IPPROTO_ICMP);
    if (fd < 0) return -1;
    sock *s = &d->flows[idx];
    *s = (sock){.d = d, .kind = S_ICMP, .fd = fd, .id = flow, .dst = dst, .echo_id = (uint16_t)random32()};
    if (mnd_loop_watch(d->loop, fd, MND_LOOP_READ, on_icmp, s) != 0) {
        close(fd);
        memset(s, 0, sizeof *s);
        return -1;
    }
    return 0;
}

static void h_icmp_send(void *ctx, uint32_t flow, uint16_t seq, const uint8_t *data, size_t len) {
    mnd_netd *d = ctx;
    sock *s = flow_entry(d, flow, S_ICMP);
    if (!s || len > sizeof d->buf - 8) return;
    uint8_t *p = d->buf;
    p[0] = 8;
    p[1] = 0;
    p[2] = p[3] = 0;
    p[4] = (uint8_t)(s->echo_id >> 8);
    p[5] = (uint8_t)s->echo_id;
    p[6] = (uint8_t)(seq >> 8);
    p[7] = (uint8_t)seq;
    memcpy(p + 8, data, len);
    uint16_t sum = mnd_csum_finish(mnd_csum_add(0, p, len + 8));
    p[2] = (uint8_t)(sum >> 8);
    p[3] = (uint8_t)sum;
    struct sockaddr_in a = address(s->dst, 0);
    if (sendto(s->fd, p, len + 8, SEND_FLAGS, (struct sockaddr *)&a, sizeof a) < 0) return;
#ifndef __APPLE__
    /* Linux puts the socket's own identifier on the wire (its "port"). */
    struct sockaddr_in local;
    socklen_t ll = sizeof local;
    if (getsockname(s->fd, (struct sockaddr *)&local, &ll) == 0) s->echo_id = ntohs(local.sin_port);
#endif
}

static void h_icmp_close(void *ctx, uint32_t flow) {
    mnd_netd *d = ctx;
    sock *s = flow_entry(d, flow, S_ICMP);
    if (s) release(d, s);
}

/* ---- TCP ------------------------------------------------------------------------------ */

static void on_tcp(void *ctx, int fd, unsigned events) {
    sock *s = ctx;
    mnd_netd *d = s->d;
    uint32_t id = s->id;
    if (s->connecting) {
        int err = 0;
        socklen_t el = sizeof err;
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el) != 0) err = errno;
        s->connecting = false;
        mnd_loop_watch(d->loop, fd, 0, NULL, NULL); /* the core says what to watch next */
        mnd_net_tcp_connected(d->net, id, err == 0);
        return;
    }
    if (events & MND_LOOP_READ) mnd_net_tcp_readable(d->net, id);
    if ((events & MND_LOOP_WRITE) && conn_entry(d, id)) mnd_net_tcp_writable(d->net, id);
}

static int h_tcp_connect(void *ctx, uint32_t conn, mnd_ip4 dst, uint16_t port) {
    mnd_netd *d = ctx;
    uint32_t idx = conn & 0xffff;
    if (idx >= MND_NET_MAX_TCP_CONNS || d->conns[idx].kind != S_FREE) return -1;
    int fd = new_socket(SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in a = address(dst, port);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) != 0 && errno != EINPROGRESS) {
        close(fd);
        return -1;
    }
    sock *s = &d->conns[idx];
    *s = (sock){.d = d, .kind = S_TCP, .fd = fd, .id = conn, .connecting = true};
    /* Writable when the connect is done, either way (also when it already is). */
    if (mnd_loop_watch(d->loop, fd, MND_LOOP_WRITE, on_tcp, s) != 0) {
        close(fd);
        memset(s, 0, sizeof *s);
        return -1;
    }
    return 0;
}

static ssize_t h_tcp_read(void *ctx, uint32_t conn, uint8_t *buf, size_t cap) {
    mnd_netd *d = ctx;
    sock *s = conn_entry(d, conn);
    if (!s) return MND_NET_IO_ERROR;
    ssize_t n = recv(s->fd, buf, cap, 0);
    if (n >= 0) return n;
    return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? MND_NET_IO_AGAIN : MND_NET_IO_ERROR;
}

static ssize_t h_tcp_write(void *ctx, uint32_t conn, const uint8_t *data, size_t len) {
    mnd_netd *d = ctx;
    sock *s = conn_entry(d, conn);
    if (!s) return MND_NET_IO_ERROR;
    ssize_t n = send(s->fd, data, len, SEND_FLAGS);
    if (n >= 0) return n;
    return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? 0 : MND_NET_IO_ERROR;
}

static void h_tcp_interest(void *ctx, uint32_t conn, bool read, bool write) {
    mnd_netd *d = ctx;
    sock *s = conn_entry(d, conn);
    if (!s || s->connecting) return;
    unsigned ev = (read ? MND_LOOP_READ : 0u) | (write ? MND_LOOP_WRITE : 0u);
    mnd_loop_watch(d->loop, s->fd, ev, on_tcp, s);
}

static void h_tcp_shutdown(void *ctx, uint32_t conn) {
    mnd_netd *d = ctx;
    sock *s = conn_entry(d, conn);
    if (s) shutdown(s->fd, SHUT_WR);
}

static void h_tcp_close(void *ctx, uint32_t conn, bool abort_) {
    mnd_netd *d = ctx;
    sock *s = conn_entry(d, conn);
    if (!s) return;
    if (abort_) {
        struct linger l = {.l_onoff = 1, .l_linger = 0}; /* a reset, not a FIN */
        setsockopt(s->fd, SOL_SOCKET, SO_LINGER, &l, sizeof l);
    }
    release(d, s);
}

/* ---- Monitor mode --------------------------------------------------------------------------- */

void mnd_netd_format_ask(char *out, size_t cap, int port, uint8_t proto, mnd_ip4 dst, uint16_t dport,
                         const char *const *names, int count) {
    if (!out || !cap) return;
    if (cap > MND_NETD_EVENT_MAX + 1) cap = MND_NETD_EVENT_MAX + 1;
    const char *p = proto == MND_IPPROTO_TCP ? "tcp" : proto == MND_IPPROTO_UDP ? "udp" : "icmp";
    int n = snprintf(out, cap, "event ask %d %s %u.%u.%u.%u %u", port, p, dst >> 24, (dst >> 16) & 255,
                     (dst >> 8) & 255, dst & 255, dport);
    if (n < 0 || (size_t)n >= cap) {
        out[0] = 0;
        return;
    }
    size_t len = (size_t)n;
    char sep = ' ';
    for (int i = 0; i < count; i++) {
        if (!mnd_dns_name_is_plain(names[i])) continue; /* could split or fake the list */
        size_t nl = strlen(names[i]);
        if (len + 1 + nl >= cap) continue; /* does not fit: left out whole */
        out[len++] = sep;
        memcpy(out + len, names[i], nl);
        len += nl;
        out[len] = 0;
        sep = ',';
    }
}

int mnd_netd_format_peer(char *out, size_t cap, const mnd_net_peer *p, uint64_t now_ms) {
    if (!out || !cap || !p) return -1;
    uint64_t last = now_ms > p->last_ms ? (now_ms - p->last_ms) / 1000 : 0;
    int n = snprintf(out, cap, "%d,%d,%llu,%llu,%llu", p->from, p->to, (unsigned long long)p->frames,
                     (unsigned long long)p->bytes, (unsigned long long)last);
    if (n < 0 || (size_t)n >= cap) {
        out[0] = 0;
        return -1;
    }
    return n;
}

int mnd_netd_format_conn(char *out, size_t cap, const mnd_net_conn *c, const char *name, uint64_t now_ms) {
    if (!out || !cap || !c) return -1;
    const char *p = c->proto == MND_IPPROTO_TCP ? "tcp" : c->proto == MND_IPPROTO_UDP ? "udp" : "icmp";
    const char *v = c->verdict == MND_CONN_ALLOWED ? "allow" : c->verdict == MND_CONN_ASKED ? "ask" : "deny";
    char why[16];
    switch (c->reason) {
    case MND_CONN_BY_RULE: snprintf(why, sizeof why, "rule:%d", c->rule); break;
    case MND_CONN_BY_SESSION: snprintf(why, sizeof why, "session"); break;
    case MND_CONN_BY_LAN: snprintf(why, sizeof why, "lan"); break;
    case MND_CONN_BY_MONITOR: snprintf(why, sizeof why, "monitor"); break;
    default: snprintf(why, sizeof why, "default"); break;
    }
    uint64_t first = now_ms > c->first_ms ? (now_ms - c->first_ms) / 1000 : 0;
    uint64_t last = now_ms > c->last_ms ? (now_ms - c->last_ms) / 1000 : 0;
    const char *shown = name && mnd_dns_name_is_plain(name) ? name : "-"; /* could split or fake the list */
    int n = snprintf(out, cap, "%s,%u.%u.%u.%u,%u,%s,%s,%u,%u,%u,%u,%llu,%llu,%llu,%llu,%s", p, c->dst >> 24,
                     (c->dst >> 16) & 255, (c->dst >> 8) & 255, c->dst & 255, c->dport, v, why, c->opened, c->refused,
                     c->asked, c->active, (unsigned long long)c->bytes_out, (unsigned long long)c->bytes_in,
                     (unsigned long long)first, (unsigned long long)last, shown);
    if (n < 0 || (size_t)n >= cap) {
        out[0] = 0;
        return -1;
    }
    return n;
}

void mnd_netd_format_lookup(char *out, size_t cap, int port, const char *name) {
    if (!out || !cap) return;
    out[0] = 0;
    if (!name || !mnd_dns_name_is_plain(name)) return;
    if (cap > MND_NETD_EVENT_MAX + 1) cap = MND_NETD_EVENT_MAX + 1;
    int n = snprintf(out, cap, "event lookup %d %s", port, name);
    if (n < 0 || (size_t)n >= cap) out[0] = 0;
}

static void h_ask(void *ctx, int port, uint8_t proto, mnd_ip4 dst, uint16_t dport) {
    mnd_netd *d = ctx;
    if (!d->event) return;
    const char *names[8];
    int n = mnd_net_dns_names(d->net, port, dst, names, 8);
    char line[MND_NETD_EVENT_MAX + 1];
    mnd_netd_format_ask(line, sizeof line, port, proto, dst, dport, names, n);
    d->event(d->event_ctx, line);
}

static void h_ask_lookup(void *ctx, int port, const char *name) {
    mnd_netd *d = ctx;
    if (!d->event) return;
    char line[MND_NETD_EVENT_MAX + 1];
    mnd_netd_format_lookup(line, sizeof line, port, name);
    if (line[0]) d->event(d->event_ctx, line);
}

void mnd_netd_set_event_sink(mnd_netd *d, mnd_netd_event_fn fn, void *ctx) {
    if (!d) return;
    d->event = fn;
    d->event_ctx = ctx;
}

/* ---- DNS ---------------------------------------------------------------------------------- */

static void dns_done(mnd_netd *d, sock *s, const uint8_t *answer, size_t len) {
    uint32_t id = s->id;
    release(d, s); /* before answering: the core may send a new query at once */
    mnd_net_dns_answer(d->net, id, answer, len);
}

static void on_dns(void *ctx, int fd, unsigned events) {
    sock *s = ctx;
    mnd_netd *d = s->d;
    (void)events;
    for (int i = 0; i < 8; i++) {
        ssize_t n = recv(fd, d->buf, DNS_BUF, 0);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;
            dns_done(d, s, NULL, 0); /* the nameserver refused: SERVFAIL */
            return;
        }
        /* Only an answer carrying our transaction id counts. */
        if (n < 12 || rd16(d->buf) != s->txid) continue;
        dns_done(d, s, d->buf, (size_t)n);
        return;
    }
}

static void h_dns_query(void *ctx, uint32_t id, const uint8_t *query, size_t len) {
    mnd_netd *d = ctx;
    sock *s = NULL;
    for (int i = 0; i < MAX_DNS && !s; i++)
        if (d->dns[i].kind == S_FREE) s = &d->dns[i];
    int fd = s && d->nnameservers && len >= 12 && len <= DNS_BUF ? new_socket(SOCK_DGRAM, 0) : -1;
    if (fd < 0) {
        mnd_net_dns_answer(d->net, id, NULL, 0);
        return;
    }
    const struct sockaddr_in *ns = &d->nameservers[d->next_nameserver++ % d->nnameservers];
    uint16_t txid = (uint16_t)random32();
    memcpy(d->buf, query, len);
    d->buf[0] = (uint8_t)(txid >> 8);
    d->buf[1] = (uint8_t)txid;
    if (connect(fd, (const struct sockaddr *)ns, sizeof *ns) != 0 || send(fd, d->buf, len, SEND_FLAGS) < 0) {
        close(fd);
        mnd_net_dns_answer(d->net, id, NULL, 0);
        return;
    }
    *s = (sock){.d = d, .kind = S_DNS, .fd = fd, .id = id, .txid = txid,
                .deadline = mnd_loop_now() + MND_NETD_DNS_TIMEOUT_MS};
    if (mnd_loop_watch(d->loop, fd, MND_LOOP_READ, on_dns, s) != 0) dns_done(d, s, NULL, 0);
}

int mnd_netd_set_nameservers(mnd_netd *d, const mnd_ip4 *addrs, const uint16_t *ports, int count) {
    if (!d || count < 0 || count > MND_NETD_MAX_NAMESERVERS || (count && (!addrs || !ports))) return -1;
    for (int i = 0; i < count; i++) {
        if (!addrs[i] || !ports[i]) return -1;
    }
    for (int i = 0; i < count; i++) d->nameservers[i] = address(addrs[i], ports[i]);
    d->nnameservers = count;
    d->next_nameserver = 0;
    return 0;
}

/* ---- VM NICs ------------------------------------------------------------------------------ */

static void on_port(void *ctx, int fd, unsigned events) {
    sock *s = ctx;
    mnd_netd *d = s->d;
    int port = (int)s->id;
    (void)events;
    for (int i = 0; i < MND_NETD_FRAMES_PER_WAKEUP; i++) {
        ssize_t n = recv(fd, d->buf, sizeof d->buf, MSG_DONTWAIT);
        if (n > 0) {
            mnd_net_input(d->net, port, d->buf, (size_t)n);
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) return;
        /* The VM's end is gone (or broken): stop listening instead of spinning;
         * MonadHost removes the port. */
        mnd_loop_watch(d->loop, fd, 0, NULL, NULL);
        return;
    }
}

int mnd_netd_add_port(mnd_netd *d, int network, mnd_mac mac, int fd) {
    if (!d || fd < 0) return -1;
    if (fd >= MND_LOOP_MAX_FDS) {
        close(fd);
        return -1;
    }
    int port = mnd_net_add_port(d->net, network, mac);
    if (port < 0 || port >= MND_NET_PORT_SLOTS || d->ports[port].kind != S_FREE) {
        if (port >= 0) mnd_net_remove_port(d->net, port);
        close(fd);
        return -1;
    }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    /* Room for bursts both ways (the values Apple suggests for this attachment). */
    int snd = 1 << 20, rcv = 4 << 20;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &snd, sizeof snd);
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, sizeof rcv);
    sock *s = &d->ports[port];
    *s = (sock){.d = d, .kind = S_PORT, .fd = fd, .id = (uint32_t)port};
    if (mnd_loop_watch(d->loop, fd, MND_LOOP_READ, on_port, s) != 0) {
        mnd_net_remove_port(d->net, port);
        close(fd);
        memset(s, 0, sizeof *s);
        return -1;
    }
    return port;
}

void mnd_netd_remove_port(mnd_netd *d, int port) {
    if (!d || port < 0 || port >= MND_NET_PORT_SLOTS || d->ports[port].kind != S_PORT) return;
    mnd_net_remove_port(d->net, port); /* closes its flows and connections through us */
    release(d, &d->ports[port]);
}

/* ---- Lifetime and the loop ------------------------------------------------------------------ */

mnd_netd *mnd_netd_create(void) {
    mnd_netd *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    d->loop = mnd_loop_create();
    mnd_net_host host = {.ctx = d, .now_ms = h_now, .send_frame = h_send_frame, .dns_query = h_dns_query,
                         .udp_open = h_udp_open, .udp_send = h_udp_send, .udp_close = h_udp_close,
                         .icmp_open = h_icmp_open, .icmp_send = h_icmp_send, .icmp_close = h_icmp_close,
                         .tcp_connect = h_tcp_connect, .tcp_read = h_tcp_read, .tcp_write = h_tcp_write,
                         .tcp_interest = h_tcp_interest, .tcp_shutdown = h_tcp_shutdown, .tcp_close = h_tcp_close,
                         .ask = h_ask, .ask_lookup = h_ask_lookup};
    d->net = d->loop ? mnd_net_create(&host) : NULL;
    if (!d->net) {
        mnd_loop_destroy(d->loop);
        free(d);
        return NULL;
    }
    return d;
}

void mnd_netd_destroy(mnd_netd *d) {
    if (!d) return;
    mnd_net_destroy(d->net); /* closes flows and connections through us */
    for (int i = 0; i < MAX_DNS; i++) release(d, &d->dns[i]);
    for (int i = 0; i < MND_NET_PORT_SLOTS; i++) release(d, &d->ports[i]);
    mnd_loop_destroy(d->loop);
    free(d);
}

mnd_net *mnd_netd_net(mnd_netd *d) { return d ? d->net : NULL; }

mnd_loop *mnd_netd_loop(mnd_netd *d) { return d ? d->loop : NULL; }

int mnd_netd_open_sockets(const mnd_netd *d) {
    int n = 0;
    for (int i = 0; i < MND_NET_MAX_UDP_FLOWS; i++) n += d->flows[i].kind != S_FREE;
    for (int i = 0; i < MND_NET_MAX_TCP_CONNS; i++) n += d->conns[i].kind != S_FREE;
    for (int i = 0; i < MAX_DNS; i++) n += d->dns[i].kind != S_FREE;
    return n;
}

int mnd_netd_run_once(mnd_netd *d, uint64_t deadline) {
    if (!d) return -1;
    uint64_t wait = deadline, core = mnd_net_deadline(d->net);
    if (core < wait) wait = core;
    for (int i = 0; i < MAX_DNS; i++)
        if (d->dns[i].kind == S_DNS && d->dns[i].deadline < wait) wait = d->dns[i].deadline;
    if (mnd_loop_run_once(d->loop, wait) < 0) return -1;
    uint64_t now = mnd_loop_now();
    if (mnd_net_deadline(d->net) <= now) mnd_net_poll(d->net);
    for (int i = 0; i < MAX_DNS; i++)
        if (d->dns[i].kind == S_DNS && d->dns[i].deadline <= now) dns_done(d, &d->dns[i], NULL, 0);
    return 0;
}
