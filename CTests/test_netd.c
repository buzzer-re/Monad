/* Tests for mnd_netd: the network core on real sockets. The VM is the other
 * end of a datagram socket pair; destinations are real servers on this
 * machine's LAN address (the VM's firewall is told to allow the LAN). */
#include "../Monad/Backend/net/mnd_net_dhcp.h"
#include "../Monad/Backend/net/mnd_net_dns.h"
#include "../Monad/Backend/net/mnd_netd.h"
#include "net_test_dns.h"
#include "test_util.h"

#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

/* The rig's network: not Monad's default (10.77.0.0/24), which these
 * tests' machine may itself be on when they run in a Monad VM; netd never
 * routes to a VM's own subnet. */
#define VM_IP MND_IP4(10, 199, 77, 10)
static const mnd_mac VM_MAC = {{0x02, 0x4d, 0x4f, 0x4e, 0x00, 0x01}};

typedef struct {
    mnd_netd *d;
    int vm; /* the VM's end */
    int nic; /* netd's end */
    int net, port;
    mnd_mac gw;
    mnd_ip4 lan;
} rig;

static mnd_ip4 lan_address(void) {
    struct ifaddrs *all = NULL, *i;
    mnd_ip4 found = 0;
    if (getifaddrs(&all) != 0) return 0;
    for (i = all; i && !found; i = i->ifa_next) {
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET || (i->ifa_flags & IFF_LOOPBACK)) continue;
        if (!(i->ifa_flags & IFF_UP)) continue;
        found = ntohl(((struct sockaddr_in *)(void *)i->ifa_addr)->sin_addr.s_addr);
    }
    freeifaddrs(all);
    return found;
}

static int open_fds(void) {
    int n = 0;
    DIR *dir = opendir("/proc/self/fd");
    if (!dir) return -1;
    while (readdir(dir)) n++;
    closedir(dir);
    return n;
}

static void setup(rig *r) {
    memset(r, 0, sizeof *r);
    r->lan = lan_address();
    r->d = mnd_netd_create();
    CHECK(r->d != NULL && r->lan != 0);
    mnd_net *net = mnd_netd_net(r->d);
    mnd_net_config cfg = {.kind = MND_NET_NAT, .subnet = MND_IP4(10, 199, 77, 0), .prefix = 24};
    r->net = mnd_net_add_network(net, &cfg);
    mnd_net_gateway(net, r->net, &r->gw, NULL);
    int sv[2];
    CHECK(socketpair(AF_UNIX, SOCK_DGRAM, 0, sv) == 0);
    r->vm = sv[1];
    r->nic = sv[0];
    fcntl(r->vm, F_SETFL, fcntl(r->vm, F_GETFL) | O_NONBLOCK);
    r->port = mnd_netd_add_port(r->d, r->net, VM_MAC, sv[0]);
    mnd_fw_config fw = {.allow_lan = true};
    CHECK(mnd_net_set_port_firewall(net, r->port, &fw) == 0);
    CHECK(r->port >= 0);
}

static void teardown(rig *r) {
    mnd_netd_destroy(r->d);
    close(r->vm);
}

static void pump(rig *r, int ms) {
    uint64_t end = mnd_loop_now() + (uint64_t)ms;
    while (mnd_loop_now() < end) mnd_netd_run_once(r->d, mnd_loop_now() + 5);
}

static void vm_send(rig *r, const uint8_t *frame, size_t len) { CHECK(send(r->vm, frame, len, 0) == (ssize_t)len); }

/* The next frame for the VM, running netd while waiting (up to ms). */
static ssize_t vm_recv(rig *r, uint8_t *buf, size_t cap, int ms) {
    uint64_t end = mnd_loop_now() + (uint64_t)ms;
    for (;;) {
        ssize_t n = recv(r->vm, buf, cap, 0);
        if (n > 0) return n;
        if (mnd_loop_now() >= end) return -1;
        mnd_netd_run_once(r->d, mnd_loop_now() + 5);
    }
}

static void vm_udp(rig *r, mnd_ip4 dst, uint16_t sport, uint16_t dport, const void *data, size_t len) {
    uint8_t f[MND_FRAME_MAX];
    mnd_ip_hdr_spec h = {.eth_dst = r->gw, .eth_src = VM_MAC, .src = VM_IP, .dst = dst, .ttl = 64};
    vm_send(r, f, mnd_build_udp(f, sizeof f, &h, sport, dport, data, len));
}

static void vm_tcp(rig *r, uint16_t sport, uint16_t dport, uint32_t seq, uint32_t ack, uint8_t flags, const void *data,
                   size_t len) {
    uint8_t f[MND_FRAME_MAX];
    mnd_ip_hdr_spec h = {.eth_dst = r->gw, .eth_src = VM_MAC, .src = VM_IP, .dst = r->lan, .ttl = 64};
    mnd_tcp_spec t = {.sport = sport, .dport = dport, .seq = seq, .ack = ack, .flags = flags, .window = 65535,
                      .mss = (flags & MND_TCP_SYN) ? 1400 : 0, .wscale = -1};
    vm_send(r, f, mnd_build_tcp(f, sizeof f, &h, &t, data, len));
}

/* The next IPv4 frame for the VM with this protocol, parsed. */
static int vm_next_ip(rig *r, uint8_t proto, uint8_t *buf, mnd_ip *ip, int ms) {
    uint64_t end = mnd_loop_now() + (uint64_t)ms;
    while (mnd_loop_now() < end) {
        ssize_t n = vm_recv(r, buf, MND_FRAME_MAX, (int)(end - mnd_loop_now()) + 1);
        if (n <= 0) return -1;
        mnd_eth eth;
        if (mnd_eth_parse(buf, (size_t)n, &eth) || eth.type != MND_ETHERTYPE_IPV4) continue;
        if (mnd_ip_parse(eth.payload, eth.len, ip) == 0 && ip->proto == proto) return 0;
    }
    return -1;
}

static int bound_socket(int type, uint16_t *port) {
    int s = socket(AF_INET, type, 0);
    int on = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    struct sockaddr_in a = {.sin_family = AF_INET};
    bind(s, (struct sockaddr *)&a, sizeof a);
    socklen_t al = sizeof a;
    getsockname(s, (struct sockaddr *)&a, &al);
    *port = ntohs(a.sin_port);
    fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK);
    return s;
}

/* ---- Tests -------------------------------------------------------------------- */

static void test_frames_through_the_nic_socket(void) {
    rig r;
    setup(&r);
    uint8_t p[600], f[MND_FRAME_MAX];
    mnd_dhcp m = {.op = 1, .xid = 9, .chaddr = VM_MAC, .type = MND_DHCP_DISCOVER};
    size_t n = mnd_dhcp_build(p, sizeof p, &m);
    mnd_ip_hdr_spec h = {.eth_dst = MND_MAC_BROADCAST, .eth_src = VM_MAC, .src = 0, .dst = 0xffffffffu, .ttl = 64};
    vm_send(&r, f, mnd_build_udp(f, sizeof f, &h, 68, 67, p, n));
    mnd_ip ip;
    mnd_udp u;
    mnd_dhcp got;
    CHECK(vm_next_ip(&r, MND_IPPROTO_UDP, f, &ip, 1000) == 0 && mnd_udp_parse(&ip, &u) == 0);
    CHECK(mnd_dhcp_parse(u.payload, u.len, &got) == 0 && got.type == MND_DHCP_OFFER && got.xid == 9);
    teardown(&r);
}

static void test_udp_round_trip(void) {
    rig r;
    setup(&r);
    uint16_t sport;
    int srv = bound_socket(SOCK_DGRAM, &sport);
    vm_udp(&r, r.lan, 5000, sport, "ping", 4);
    char got[16] = {0};
    struct sockaddr_in from;
    socklen_t fl = sizeof from;
    ssize_t n = -1;
    for (int i = 0; i < 200 && n < 0; i++) {
        pump(&r, 5);
        n = recvfrom(srv, got, sizeof got, 0, (struct sockaddr *)&from, &fl);
    }
    CHECK(n == 4 && memcmp(got, "ping", 4) == 0);
    CHECK(mnd_netd_open_sockets(r.d) == 1);
    CHECK(sendto(srv, "pong", 4, 0, (struct sockaddr *)&from, fl) == 4);
    uint8_t f[MND_FRAME_MAX];
    mnd_ip ip;
    mnd_udp u;
    CHECK(vm_next_ip(&r, MND_IPPROTO_UDP, f, &ip, 1000) == 0 && mnd_udp_parse(&ip, &u) == 0);
    CHECK(ip.src == r.lan && ip.dst == VM_IP && u.sport == sport && u.dport == 5000);
    CHECK(u.len == 4 && memcmp(u.payload, "pong", 4) == 0);
    close(srv);
    teardown(&r);
}

static void test_tcp_round_trip(void) {
    rig r;
    setup(&r);
    uint16_t port;
    int lst = bound_socket(SOCK_STREAM, &port);
    CHECK(listen(lst, 4) == 0);
    vm_tcp(&r, 40000, port, 1000, 0, MND_TCP_SYN, NULL, 0);
    uint8_t f[MND_FRAME_MAX];
    mnd_ip ip;
    mnd_tcp t;
    CHECK(vm_next_ip(&r, MND_IPPROTO_TCP, f, &ip, 2000) == 0 && mnd_tcp_parse(&ip, &t) == 0);
    CHECK(t.flags == (MND_TCP_SYN | MND_TCP_ACK) && t.ack == 1001);
    uint32_t rcv = t.seq + 1, snd = 1001;
    vm_tcp(&r, 40000, port, snd, rcv, MND_TCP_ACK, NULL, 0);
    int c = -1;
    for (int i = 0; i < 200 && c < 0; i++) {
        pump(&r, 5);
        c = accept(lst, NULL, NULL);
    }
    CHECK(c >= 0);
    /* The Mac side speaks first. */
    CHECK(send(c, "hello", 5, 0) == 5);
    CHECK(vm_next_ip(&r, MND_IPPROTO_TCP, f, &ip, 1000) == 0 && mnd_tcp_parse(&ip, &t) == 0);
    CHECK(t.len == 5 && memcmp(t.payload, "hello", 5) == 0 && t.seq == rcv);
    rcv += 5;
    vm_tcp(&r, 40000, port, snd, rcv, MND_TCP_ACK | MND_TCP_PSH, "world", 5);
    snd += 5;
    char got[16] = {0};
    ssize_t n = -1;
    fcntl(c, F_SETFL, fcntl(c, F_GETFL) | O_NONBLOCK);
    for (int i = 0; i < 200 && n < 0; i++) {
        pump(&r, 5);
        n = recv(c, got, sizeof got, 0);
    }
    CHECK(n == 5 && memcmp(got, "world", 5) == 0);
    /* The Mac closes; the VM sees the FIN, acknowledges and closes too. */
    close(c);
    bool fin = false;
    for (int i = 0; i < 4 && !fin; i++) {
        if (vm_next_ip(&r, MND_IPPROTO_TCP, f, &ip, 1000) != 0 || mnd_tcp_parse(&ip, &t) != 0) break;
        if (t.flags & MND_TCP_FIN) fin = true;
    }
    CHECK(fin);
    rcv++;
    vm_tcp(&r, 40000, port, snd, rcv, MND_TCP_ACK | MND_TCP_FIN, NULL, 0);
    pump(&r, 50);
    CHECK(mnd_netd_open_sockets(r.d) == 0);
    close(lst);
    teardown(&r);
}

static void test_tcp_refused(void) {
    rig r;
    setup(&r);
    uint16_t port;
    int s = bound_socket(SOCK_STREAM, &port);
    close(s); /* nothing listens there now */
    vm_tcp(&r, 40001, port, 5000, 0, MND_TCP_SYN, NULL, 0);
    uint8_t f[MND_FRAME_MAX];
    mnd_ip ip;
    mnd_tcp t;
    CHECK(vm_next_ip(&r, MND_IPPROTO_TCP, f, &ip, 2000) == 0 && mnd_tcp_parse(&ip, &t) == 0);
    CHECK((t.flags & MND_TCP_RST) && t.ack == 5001);
    CHECK(mnd_netd_open_sockets(r.d) == 0);
    teardown(&r);
}

static void test_dns_through_the_nameserver(void) {
    rig r;
    setup(&r);
    uint16_t nsport;
    int ns = bound_socket(SOCK_DGRAM, &nsport);
    CHECK(mnd_netd_set_nameservers(r.d, &r.lan, &nsport, 1) == 0);
    uint8_t q[512], a[512], f[MND_FRAME_MAX];
    size_t qn = td_query(q, 0x1234, "example.com", MND_DNS_TYPE_A, 0);
    vm_udp(&r, MND_IP4(10, 199, 77, 1), 40000, 53, q, qn);
    struct sockaddr_in from;
    socklen_t fl = sizeof from;
    ssize_t n = -1;
    for (int i = 0; i < 200 && n < 0; i++) {
        pump(&r, 5);
        n = recvfrom(ns, a, sizeof a, 0, (struct sockaddr *)&from, &fl);
    }
    CHECK(n == (ssize_t)qn && memcmp(a + 2, q + 2, qn - 2) == 0); /* the same query... */
    uint16_t txid = (uint16_t)(a[0] << 8 | a[1]);                /* ...under another id */
    /* A spoofed answer with a guessed id is ignored; the real one arrives. */
    size_t an = td_response(a, (uint16_t)(txid + 1), "example.com", MND_DNS_TYPE_A);
    an = td_a(a, an, 12, MND_IP4(6, 6, 6, 6), 60);
    td_set_ancount(a, 1);
    sendto(ns, a, an, 0, (struct sockaddr *)&from, fl);
    an = td_response(a, txid, "example.com", MND_DNS_TYPE_A);
    an = td_a(a, an, 12, MND_IP4(93, 184, 216, 34), 60);
    td_set_ancount(a, 1);
    sendto(ns, a, an, 0, (struct sockaddr *)&from, fl);
    mnd_ip ip;
    mnd_udp u;
    CHECK(vm_next_ip(&r, MND_IPPROTO_UDP, f, &ip, 1000) == 0 && mnd_udp_parse(&ip, &u) == 0);
    CHECK(u.sport == 53 && u.dport == 40000 && u.len == an);
    CHECK(u.payload[0] == 0x12 && u.payload[1] == 0x34); /* the VM's own id */
    CHECK(memcmp(u.payload + an - 4, "\x5d\xb8\xd8\x22", 4) == 0);
    const char *names[2];
    CHECK(mnd_net_dns_names(mnd_netd_net(r.d), r.port, MND_IP4(93, 184, 216, 34), names, 2) == 1);
    CHECK(mnd_net_dns_names(mnd_netd_net(r.d), r.port, MND_IP4(6, 6, 6, 6), names, 2) == 0);
    pump(&r, 20);
    CHECK(mnd_netd_open_sockets(r.d) == 0); /* the query's socket is closed */
    /* No answer at all: SERVFAIL after the timeout. */
    qn = td_query(q, 0x4321, "slow.example", MND_DNS_TYPE_A, 0);
    vm_udp(&r, MND_IP4(10, 199, 77, 1), 40001, 53, q, qn);
    CHECK(vm_next_ip(&r, MND_IPPROTO_UDP, f, &ip, MND_NETD_DNS_TIMEOUT_MS + 1000) == 0 && mnd_udp_parse(&ip, &u) == 0);
    CHECK(u.len >= 12 && u.payload[0] == 0x43 && u.payload[1] == 0x21 && (u.payload[3] & 0x0f) == MND_DNS_RCODE_SERVFAIL);
    CHECK(mnd_netd_open_sockets(r.d) == 0);
    /* The id on the wire is not the VM's (random; three tries make a false
     * alarm a 1 in 2^48 event). */
    bool differs = false;
    while (recvfrom(ns, a, sizeof a, 0, (struct sockaddr *)&from, &fl) > 0) {
    } /* the unanswered query from before */
    for (int k = 0; k < 3; k++) {
        qn = td_query(q, 0x1234, "example.com", MND_DNS_TYPE_A, 0);
        vm_udp(&r, MND_IP4(10, 199, 77, 1), (uint16_t)(40100 + k), 53, q, qn);
        n = -1;
        for (int i = 0; i < 200 && n < 0; i++) {
            pump(&r, 5);
            n = recvfrom(ns, a, sizeof a, 0, (struct sockaddr *)&from, &fl);
        }
        if (n >= 2 && (a[0] != 0x12 || a[1] != 0x34)) differs = true;
    }
    CHECK(differs);
    close(ns);
    teardown(&r);
}

static void test_ping(void) {
    rig r;
    setup(&r);
    uint8_t f[MND_FRAME_MAX];
    mnd_ip_hdr_spec h = {.eth_dst = r.gw, .eth_src = VM_MAC, .src = VM_IP, .dst = r.lan, .ttl = 64};
    vm_send(&r, f, mnd_build_icmp(f, sizeof f, &h, 8, 0, 0x77, 3, (const uint8_t *)"abcdefgh", 8));
    mnd_ip ip;
    mnd_icmp icmp;
    int got = vm_next_ip(&r, MND_IPPROTO_ICMP, f, &ip, 2000);
    if (got != 0 && mnd_netd_open_sockets(r.d) == 0) {
        fprintf(stderr, "    (unprivileged ICMP sockets unavailable here: skipped)\n");
    } else {
        CHECK(got == 0 && mnd_icmp_parse(&ip, &icmp) == 0);
        CHECK(icmp.type == 0 && icmp.id == 0x77 && icmp.seq == 3 && ip.src == r.lan && ip.dst == VM_IP);
        CHECK(icmp.len == 8 && memcmp(icmp.data, "abcdefgh", 8) == 0);
    }
    teardown(&r);
}

static void test_nothing_leaks(void) {
    int before = open_fds();
    rig r;
    setup(&r);
    uint16_t port;
    int lst = bound_socket(SOCK_STREAM, &port);
    listen(lst, 4);
    int srv = bound_socket(SOCK_DGRAM, &port);
    uint16_t uport;
    int udp = bound_socket(SOCK_DGRAM, &uport);
    for (int i = 0; i < 5; i++) vm_udp(&r, r.lan, (uint16_t)(6000 + i), uport, "x", 1);
    struct sockaddr_in a;
    socklen_t al = sizeof a;
    getsockname(lst, (struct sockaddr *)&a, &al);
    for (int i = 0; i < 5; i++) vm_tcp(&r, (uint16_t)(41000 + i), ntohs(a.sin_port), 100, 0, MND_TCP_SYN, NULL, 0);
    pump(&r, 100);
    CHECK(mnd_netd_open_sockets(r.d) == 10);
    /* The VM goes away: its sockets close. */
    mnd_netd_remove_port(r.d, r.port);
    CHECK(mnd_netd_open_sockets(r.d) == 0);
    CHECK(fcntl(r.nic, F_GETFD) == -1 && errno == EBADF); /* the NIC descriptor too */
    /* Another VM, then destroy with sockets open. */
    int sv[2];
    socketpair(AF_UNIX, SOCK_DGRAM, 0, sv);
    int p2 = mnd_netd_add_port(r.d, r.net, VM_MAC, sv[0]);
    CHECK(p2 >= 0);
    mnd_fw_config fw = {.allow_lan = true}; /* a new VM starts with the LAN denied */
    CHECK(mnd_net_set_port_firewall(mnd_netd_net(r.d), p2, &fw) == 0);
    close(r.vm);
    r.vm = sv[1];
    fcntl(r.vm, F_SETFL, fcntl(r.vm, F_GETFL) | O_NONBLOCK);
    for (int i = 0; i < 3; i++) vm_udp(&r, r.lan, (uint16_t)(7000 + i), uport, "x", 1);
    pump(&r, 50);
    CHECK(mnd_netd_open_sockets(r.d) == 3);
    teardown(&r);
    close(lst);
    close(srv);
    close(udp);
    CHECK(open_fds() == before);
    /* A port with a bad descriptor or network: refused, the descriptor closed. */
    mnd_netd *d = mnd_netd_create();
    int bad[2];
    socketpair(AF_UNIX, SOCK_DGRAM, 0, bad);
    CHECK(mnd_netd_add_port(d, 5, VM_MAC, bad[0]) == -1);
    CHECK(fcntl(bad[0], F_GETFD) == -1 && errno == EBADF);
    CHECK(mnd_netd_add_port(d, 0, VM_MAC, -1) == -1);
    close(bad[1]);
    mnd_netd_destroy(d);
    CHECK(open_fds() == before);
}

int main(void) {
    fprintf(stderr, "mnd_netd tests (real sockets)\n");
    RUN(test_frames_through_the_nic_socket);
    RUN(test_udp_round_trip);
    RUN(test_tcp_round_trip);
    RUN(test_tcp_refused);
    RUN(test_dns_through_the_nameserver);
    RUN(test_ping);
    RUN(test_nothing_leaks);
    TEST_MAIN_END();
}
