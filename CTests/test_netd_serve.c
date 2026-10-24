/* Tests for mnd_netd_serve: a netd child driven over its control channel,
 * as MonadHost will drive it (commands, a NIC handed over, lifetime). */
#include "../Monad/Backend/net/mnd_net_dhcp.h"
#include "../Monad/Backend/net/mnd_netd.h"
#include "../Monad/Backend/net/mnd_netd_ctl.h"
#include "test_util.h"

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

typedef struct {
    pid_t pid;
    int ctl; /* our end */
    char buf[4096];
    size_t len;
} child;

static void start(child *c) {
    int sv[2];
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    c->pid = fork();
    if (c->pid == 0) {
        close(sv[0]);
        _exit(mnd_netd_serve(sv[1]) & 0xff);
    }
    close(sv[1]);
    c->ctl = sv[0];
    c->len = 0;
}

/* Sends one line (and optionally a descriptor with it). */
static void send_line(child *c, const char *line, int fd) {
    char data[1100];
    int n = snprintf(data, sizeof data, "%s\n", line);
    struct iovec iov = {.iov_base = data, .iov_len = (size_t)n};
    union {
        struct cmsghdr h;
        char space[CMSG_SPACE(sizeof(int))];
    } u;
    struct msghdr m = {.msg_iov = &iov, .msg_iovlen = 1};
    if (fd >= 0) {
        memset(&u, 0, sizeof u);
        m.msg_control = u.space;
        m.msg_controllen = sizeof u.space;
        struct cmsghdr *cm = CMSG_FIRSTHDR(&m);
        cm->cmsg_level = SOL_SOCKET;
        cm->cmsg_type = SCM_RIGHTS;
        cm->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(cm), &fd, sizeof fd);
    }
    CHECK(sendmsg(c->ctl, &m, 0) == n);
}

/* The next reply line, or NULL after `ms`. */
static const char *reply(child *c, int ms) {
    static char line[2048]; /* a reply line is up to MND_CTL_MAX_LINE bytes */
    for (;;) {
        char *nl = memchr(c->buf, '\n', c->len);
        if (nl) {
            size_t n = (size_t)(nl - c->buf);
            memcpy(line, c->buf, n);
            line[n] = 0;
            memmove(c->buf, nl + 1, c->len - n - 1);
            c->len -= n + 1;
            return line;
        }
        struct pollfd p = {.fd = c->ctl, .events = POLLIN};
        if (poll(&p, 1, ms) <= 0) return NULL;
        ssize_t r = read(c->ctl, c->buf + c->len, sizeof c->buf - c->len);
        if (r <= 0) return NULL;
        c->len += (size_t)r;
    }
}

static const char *ask(child *c, const char *line) {
    send_line(c, line, -1);
    return reply(c, 2000);
}

static double child_cpu; /* seconds of CPU the last child used */

/* Waits for the child to exit (up to ms); returns its status or -1. */
static int wait_exit(child *c, int ms) {
    for (int i = 0; i < ms / 10; i++) {
        int st;
        struct rusage ru;
        pid_t r = wait4(c->pid, &st, WNOHANG, &ru);
        if (r == c->pid) {
            child_cpu = (double)ru.ru_utime.tv_sec + (double)ru.ru_utime.tv_usec / 1e6 + (double)ru.ru_stime.tv_sec +
                        (double)ru.ru_stime.tv_usec / 1e6;
            return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
        }
        usleep(10000);
    }
    kill(c->pid, SIGKILL);
    waitpid(c->pid, NULL, 0);
    return -1;
}

static void test_configure_and_carry_frames(void) {
    child c;
    start(&c);
    const char *r = ask(&c, "ping");
    CHECK(r && !strcmp(r, "ok pong"));
    r = ask(&c, "network nat 10.77.0.0/24");
    CHECK(r && !strcmp(r, "ok 0"));
    int sv[2];
    CHECK(socketpair(AF_UNIX, SOCK_DGRAM, 0, sv) == 0);
    send_line(&c, "port 0 02:4d:4f:4e:00:01", sv[0]);
    close(sv[0]); /* netd has its own copy now */
    r = reply(&c, 2000);
    CHECK(r && !strcmp(r, "ok 0"));
    /* The VM asks for an address through the NIC netd now holds. */
    uint8_t p[600], f[MND_FRAME_MAX];
    mnd_mac mac = {{0x02, 0x4d, 0x4f, 0x4e, 0x00, 0x01}};
    mnd_dhcp m = {.op = 1, .xid = 5, .chaddr = mac, .type = MND_DHCP_DISCOVER};
    size_t n = mnd_dhcp_build(p, sizeof p, &m);
    mnd_ip_hdr_spec h = {.eth_dst = MND_MAC_BROADCAST, .eth_src = mac, .dst = 0xffffffffu, .ttl = 64};
    n = mnd_build_udp(f, sizeof f, &h, 68, 67, p, n);
    CHECK(send(sv[1], f, n, 0) == (ssize_t)n);
    struct pollfd pf = {.fd = sv[1], .events = POLLIN};
    CHECK(poll(&pf, 1, 2000) == 1);
    ssize_t got = recv(sv[1], f, sizeof f, 0);
    mnd_eth eth;
    mnd_ip ip;
    mnd_udp u;
    mnd_dhcp offer;
    CHECK(got > 0 && mnd_eth_parse(f, (size_t)got, &eth) == 0 && mnd_ip_parse(eth.payload, eth.len, &ip) == 0);
    CHECK(mnd_udp_parse(&ip, &u) == 0 && mnd_dhcp_parse(u.payload, u.len, &offer) == 0 && offer.type == MND_DHCP_OFFER);
    r = ask(&c, "stats 0");
    CHECK(r && !strncmp(r, "ok rx=1 tx=1 ", 13));
    /* MonadHost goes away: netd exits cleanly, and the VM's NIC goes with it. */
    close(c.ctl);
    CHECK(wait_exit(&c, 2000) == 0);
    CHECK(recv(sv[1], f, sizeof f, MSG_DONTWAIT) == 0 || errno == ECONNREFUSED || errno == EAGAIN);
    close(sv[1]);
}

static void test_violations_end_the_session(void) {
    child c;
    start(&c);
    char big[MND_FRAME_MAX * 2];
    memset(big, 'a', sizeof big);
    CHECK(write(c.ctl, big, sizeof big) == (ssize_t)sizeof big);
    CHECK(wait_exit(&c, 2000) == 1);
    close(c.ctl);
    start(&c);
    CHECK(write(c.ctl, "ping\x01\n", 6) == 6);
    CHECK(wait_exit(&c, 2000) == 1);
    close(c.ctl);
}

/* A DHCP discover from the VM's end; true if an offer comes back in time. */
static bool vm_gets_offer(int vm, int ms) {
    uint8_t p[600], f[MND_FRAME_MAX];
    mnd_mac mac = {{0x02, 0x4d, 0x4f, 0x4e, 0x00, 0x01}};
    mnd_dhcp m = {.op = 1, .xid = 7, .chaddr = mac, .type = MND_DHCP_DISCOVER};
    size_t n = mnd_dhcp_build(p, sizeof p, &m);
    mnd_ip_hdr_spec h = {.eth_dst = MND_MAC_BROADCAST, .eth_src = mac, .dst = 0xffffffffu, .ttl = 64};
    n = mnd_build_udp(f, sizeof f, &h, 68, 67, p, n);
    if (send(vm, f, n, 0) != (ssize_t)n) return false;
    struct pollfd pf = {.fd = vm, .events = POLLIN};
    if (poll(&pf, 1, ms) != 1) return false;
    return recv(vm, f, sizeof f, 0) > 0;
}

static void test_a_slow_reader_does_not_stall_netd(void) {
    child c;
    start(&c);
    CHECK(!strcmp(ask(&c, "network nat 10.77.0.0/24"), "ok 0"));
    int sv[2];
    CHECK(socketpair(AF_UNIX, SOCK_DGRAM, 0, sv) == 0);
    send_line(&c, "port 0 02:4d:4f:4e:00:01", sv[0]);
    close(sv[0]);
    CHECK(!strcmp(reply(&c, 2000), "ok 0"));
    /* Pings, never reading the answers, until the channel is full both ways. */
    long sent = 0;
    for (int stalls = 0; stalls < 20;) {
        ssize_t w = send(c.ctl, "ping\n", 5, MSG_DONTWAIT);
        if (w == 5) {
            sent++;
            stalls = 0;
        } else {
            stalls++;
            usleep(10000);
        }
    }
    CHECK(sent > 1000);
    /* netd stopped reading commands, not serving: the VM still gets answers. */
    CHECK(vm_gets_offer(sv[1], 1000));
    /* …and while paused it sleeps: no wakeups for commands it will not read. */
    usleep(1000000);
    /* Draining the replies lets it go on: every ping is answered, none lost. */
    long pongs = 0;
    const char *r;
    while ((r = reply(&c, 500)) != NULL) pongs += !strcmp(r, "ok pong");
    CHECK(pongs == sent);
    close(c.ctl);
    CHECK(wait_exit(&c, 2000) == 0);
    fprintf(stderr, "    netd used %.2f s of CPU\n", child_cpu);
    CHECK(child_cpu < 0.8); /* a paused netd that spins burns well over a second here */
    close(sv[1]);
}

/* The VM takes an address (DISCOVER, OFFER, REQUEST, ACK); returns it, or 0,
 * and the gateway's MAC in *gw. */
static mnd_ip4 vm_lease(int vm, mnd_mac mac, mnd_mac *gw) {
    mnd_ip4 offered = 0;
    for (uint8_t type = MND_DHCP_DISCOVER;; type = MND_DHCP_REQUEST) {
        uint8_t p[600], f[MND_FRAME_MAX];
        mnd_dhcp m = {.op = 1, .xid = 9, .chaddr = mac, .type = type};
        if (type == MND_DHCP_REQUEST) {
            m.requested = offered;
            m.server_id = MND_IP4(10, 77, 0, 1);
        }
        size_t n = mnd_dhcp_build(p, sizeof p, &m);
        mnd_ip_hdr_spec h = {.eth_dst = MND_MAC_BROADCAST, .eth_src = mac, .dst = 0xffffffffu, .ttl = 64};
        n = mnd_build_udp(f, sizeof f, &h, 68, 67, p, n);
        if (send(vm, f, n, 0) != (ssize_t)n) return 0;
        struct pollfd pf = {.fd = vm, .events = POLLIN};
        if (poll(&pf, 1, 2000) != 1) return 0;
        ssize_t got = recv(vm, f, sizeof f, 0);
        mnd_eth eth;
        mnd_ip ip;
        mnd_udp u;
        mnd_dhcp r;
        if (got <= 0 || mnd_eth_parse(f, (size_t)got, &eth) || mnd_ip_parse(eth.payload, eth.len, &ip) ||
            mnd_udp_parse(&ip, &u) || mnd_dhcp_parse(u.payload, u.len, &r))
            return 0;
        if (type == MND_DHCP_DISCOVER) {
            if (r.type != MND_DHCP_OFFER) return 0;
            offered = r.yiaddr;
            *gw = eth.src;
            continue;
        }
        return r.type == MND_DHCP_ACK && r.yiaddr == offered ? offered : 0;
    }
}

/* A NAT network, one VM on it behind a firewall that lets nothing out, and
 * `count` UDP datagrams from it to as many destinations (each refused and
 * logged). Returns the VM's end of its NIC. */
static int vm_with_refused(child *c, int count) {
    CHECK_STR(ask(c, "network nat 10.77.0.0/24"), "ok 0");
    int sv[2];
    CHECK(socketpair(AF_UNIX, SOCK_DGRAM, 0, sv) == 0);
    send_line(c, "port 0 02:4d:4f:4e:00:01", sv[0]);
    close(sv[0]);
    CHECK_STR(reply(c, 2000), "ok 0");
    CHECK_STR(ask(c, "firewall 0 allowlist=1 lan=0"), "ok");
    CHECK_STR(ask(c, "commit"), "ok");
    mnd_mac mac = {{0x02, 0x4d, 0x4f, 0x4e, 0x00, 0x01}}, gw;
    mnd_ip4 me = vm_lease(sv[1], mac, &gw);
    CHECK(me != 0);
    for (int i = 0; i < count; i++) {
        uint8_t f[MND_FRAME_MAX];
        const uint8_t data[4] = {1, 2, 3, 4};
        mnd_ip_hdr_spec h = {.eth_dst = gw, .eth_src = mac, .src = me, .dst = MND_IP4(198, 51, 100, 1 + i), .ttl = 64};
        size_t n = mnd_build_udp(f, sizeof f, &h, 5000, 53, data, sizeof data);
        CHECK(send(sv[1], f, n, 0) == (ssize_t)n);
    }
    /* The NIC is not the control channel: wait until netd has seen them all. */
    char want[32];
    snprintf(want, sizeof want, " firewall=%d", count);
    bool seen = false;
    for (int i = 0; i < 200 && !seen; i++) {
        const char *r = ask(c, "stats 0");
        seen = r && strstr(r, want) && !strcmp(strstr(r, want), want);
        if (!seen) usleep(10000);
    }
    CHECK(seen);
    return sv[1];
}

/* One conns reply: its next=, and how many entries it carries, each whole
 * (the fourteen fields of mnd_netd_format_conn, ending in the name "-"),
 * each destination marked in `seen`. -1 if the reply is not a page. */
static int page_entries(const char *r, int *next, bool *seen, int count) {
    if (!r || strncmp(r, "ok next=", 8)) return -1;
    *next = atoi(r + 8);
    int entries = 0;
    for (const char *t = strchr(r + 8, ' '); t; t = strchr(t + 1, ' ')) {
        const char *end = strchr(t + 1, ' ');
        size_t len = end ? (size_t)(end - t - 1) : strlen(t + 1);
        char entry[256];
        if (len >= sizeof entry) return -1;
        memcpy(entry, t + 1, len);
        entry[len] = 0;
        int commas = 0;
        for (char *p = entry; *p; p++) commas += *p == ',';
        unsigned a, b, cc, d, port;
        if (commas != 13 || len < 2 || strcmp(entry + len - 2, ",-") ||
            sscanf(entry, "udp,%u.%u.%u.%u,%u,deny,default,", &a, &b, &cc, &d, &port) != 5 || a != 198 || b != 51 ||
            cc != 100 || d < 1 || (int)d > count || port != 53)
            return -1;
        seen[d - 1] = true;
        entries++;
    }
    return entries;
}

/* A page of the connection log crosses the channel whole: every entry netd
 * put in it, and next= as netd set it (a cut page hid all but the newest). */
static void test_a_conns_page_crosses_whole(void) {
    child c;
    start(&c);
    int vm = vm_with_refused(&c, 12);
    bool seen[12] = {false};
    int next = -1;
    CHECK(page_entries(ask(&c, "conns 0 from=0"), &next, seen, 12) == 12);
    CHECK(next == 0);
    for (int i = 0; i < 12; i++) CHECK(seen[i]);
    close(c.ctl);
    CHECK(wait_exit(&c, 2000) == 0);
    close(vm);
}

/* A full page, about a thousand bytes, crosses whole too; the next pages
 * have the rest. */
static void test_a_full_page_crosses_whole(void) {
    enum { COUNT = 40 };
    child c;
    start(&c);
    int vm = vm_with_refused(&c, COUNT);
    bool seen[COUNT] = {false};
    int next = -1;
    const char *r = ask(&c, "conns 0 from=0");
    CHECK(r && strlen(r) > 950 && strlen(r) < MND_CTL_MAX_LINE);
    int first = page_entries(r, &next, seen, COUNT);
    CHECK(first > 12 && first < COUNT && next == first);
    int total = first > 0 ? first : 0, pages = 1;
    while (next > 0 && pages < 10) {
        char line[64];
        snprintf(line, sizeof line, "conns 0 from=%d", next);
        int from = next, got = page_entries(ask(&c, line), &next, seen, COUNT);
        CHECK(got > 0 && (next == 0 || next == from + got));
        total += got > 0 ? got : 0;
        pages++;
    }
    CHECK(next == 0 && total == COUNT);
    for (int i = 0; i < COUNT; i++) CHECK(seen[i]);
    close(c.ctl);
    CHECK(wait_exit(&c, 2000) == 0);
    close(vm);
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    fprintf(stderr, "monad-netd server tests\n");
    RUN(test_configure_and_carry_frames);
    RUN(test_violations_end_the_session);
    RUN(test_a_slow_reader_does_not_stall_netd);
    RUN(test_a_conns_page_crosses_whole);
    RUN(test_a_full_page_crosses_whole);
    TEST_MAIN_END();
}
