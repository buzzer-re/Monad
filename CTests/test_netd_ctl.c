/* Tests for monad-netd's control channel: commands, strict parsing, NIC
 * descriptors handed over with the port command, and protocol violations. */
#include "../Monad/Backend/net/mnd_loop.h"
#include "../Monad/Backend/net/mnd_net_internal.h"
#include "../Monad/Backend/net/mnd_netd_ctl.h"
#include "net_test_dns.h"
#include "test_util.h"

#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>

static char last_reply[MND_CTL_MAX_LINE];
static int replies;

static void on_reply(void *ctx, const char *line) {
    (void)ctx;
    snprintf(last_reply, sizeof last_reply, "%s", line);
    replies++;
}

typedef struct {
    mnd_netd *d;
    mnd_ctl *c;
} rig;

static void setup(rig *r) {
    r->d = mnd_netd_create();
    r->c = mnd_ctl_create(r->d, on_reply, NULL);
    replies = 0;
    last_reply[0] = 0;
}

static void teardown(rig *r) {
    mnd_ctl_destroy(r->c);
    mnd_netd_destroy(r->d);
}

static const char *cmd(rig *r, const char *line) {
    static char out[MND_CTL_MAX_LINE];
    mnd_ctl_command(r->c, line, out, sizeof out);
    return out;
}

static bool is_err(const char *reply) { return strncmp(reply, "err ", 4) == 0; }

static int nic(int *other) {
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sv) != 0) return -1;
    *other = sv[1];
    return sv[0];
}

static bool closed(int fd) { return fcntl(fd, F_GETFD) == -1 && errno == EBADF; }

static void test_networks(void) {
    rig r;
    setup(&r);
    CHECK_STR(cmd(&r, "network nat 10.77.0.0/24"), "ok 0");
    CHECK_STR(cmd(&r, "network internal 10.78.0.0/16 lease=600"), "ok 1");
    CHECK_STR(cmd(&r, "network host-only 10.79.0.0/24"), "ok 2");
    CHECK_STR(cmd(&r, "network none 10.80.0.0/24"), "ok 3");
    /* VMs reach each other where nothing leaves, unless told otherwise (F-02). */
    CHECK_STR(cmd(&r, "network nat 10.81.0.0/24 peers=1"), "ok 4");
    CHECK_STR(cmd(&r, "network internal 10.82.0.0/24 lease=600 peers=0"), "ok 5");
    const mnd_net *net = mnd_netd_net(r.d);
    CHECK(net->networks[0].cfg.isolated && net->networks[2].cfg.isolated);
    CHECK(!net->networks[1].cfg.isolated && !net->networks[3].cfg.isolated);
    CHECK(!net->networks[4].cfg.isolated && net->networks[5].cfg.isolated);
    /* Host-only networks look names up through the Mac only when told to (F-10). */
    CHECK_STR(cmd(&r, "network host-only 10.84.0.0/24 dns=1 peers=1"), "ok 6");
    CHECK(!net->networks[2].cfg.host_only_dns && net->networks[6].cfg.host_only_dns);
    const char *bad[] = {
        "network nat 10.83.0.0/24 peers=2",
        "network nat 10.83.0.0/24 peers=",
        "network nat 10.83.0.0/24 peers=1 peers=0",
        "network nat 10.83.0.0/24 lease=600 lease=600",
        "network nat 10.83.0.0/24 peers=1 lease=600 x",
        "network host-only 10.83.0.0/24 dns=2",
        "network host-only 10.83.0.0/24 dns=1 dns=1",
        "network nat 10.77.0.5/24",         /* host bits */
        "network nat 10.77.0.0/31",         /* too small */
        "network nat 10.77.0.0",            /* no prefix */
        "network nat 10.77.0.0/024",        /* leading zero */
        "network nat 10.077.0.0/24",
        "network nat 10.77.0.256/24",
        "network nat 10.77.0/24",
        "network bridged 10.77.0.0/24",     /* unknown kind */
        "network nat 10.77.0.0/24 lease=x",
        "network nat 10.77.0.0/24 lease=0",
        "network nat 10.77.0.0/24 lease=99999999999",
        "network nat 10.77.0.0/24 extra",
        "network nat  10.77.0.0/24",        /* empty field */
        "network",
    };
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) CHECK(is_err(cmd(&r, bad[i])));
    teardown(&r);
}

static void test_ports_take_a_nic_descriptor(void) {
    rig r;
    setup(&r);
    cmd(&r, "network nat 10.77.0.0/24");
    int vm, fd = nic(&vm);
    /* Through the channel: the line and its descriptor. */
    CHECK(mnd_ctl_feed(r.c, "port 0 02:4d:4f:4e:00:01\n", 25, &fd, 1) == 0);
    CHECK(replies == 1);
    CHECK_STR(last_reply, "ok 0");
    CHECK(!closed(fd)); /* netd keeps it */
    CHECK_STR(cmd(&r, "stats 0"), "ok rx=0 tx=0 spoofed=0 malformed=0 unknown=0 policy=0 firewall=0");
    /* Without a descriptor waiting. */
    CHECK_STR(cmd(&r, "port 0 02:4d:4f:4e:00:02"), "err no nic descriptor");
    /* A bad port command still uses up (and closes) the descriptor it was sent with. */
    int vm2, fd2 = nic(&vm2);
    CHECK(mnd_ctl_feed(r.c, "port 0 02:4d:4f:4e:00:0g\n", 25, &fd2, 1) == 0);
    CHECK(is_err(last_reply) && closed(fd2));
    int vm3, fd3 = nic(&vm3);
    CHECK(mnd_ctl_feed(r.c, "port 9 02:4d:4f:4e:00:03\n", 25, &fd3, 1) == 0);
    CHECK(is_err(last_reply) && closed(fd3)); /* unknown network */
    const char *bad_macs[] = {"port 0 02:4d:4f:4e:00", "port 0 02-4d-4f-4e-00-01", "port 0 2:4d:4f:4e:00:01",
                              "port 0 02:4d:4f:4e:00:01:02", "port x 02:4d:4f:4e:00:01"};
    for (size_t i = 0; i < sizeof bad_macs / sizeof bad_macs[0]; i++) CHECK(is_err(cmd(&r, bad_macs[i])));
    /* Removal. */
    CHECK_STR(cmd(&r, "unport 0"), "ok");
    CHECK(closed(fd));
    CHECK(is_err(cmd(&r, "unport 0")));
    CHECK(is_err(cmd(&r, "stats 0")));
    CHECK(is_err(cmd(&r, "unport -1")));
    CHECK(is_err(cmd(&r, "unport 99999999999")));
    close(vm);
    close(vm2);
    close(vm3);
    teardown(&r);
}

static void test_reservations_nameservers_hostnets(void) {
    rig r;
    setup(&r);
    cmd(&r, "network nat 10.77.0.0/24");
    CHECK_STR(cmd(&r, "reserve 0 02:4d:4f:4e:00:01 10.77.0.50"), "ok");
    CHECK(is_err(cmd(&r, "reserve 0 02:4d:4f:4e:00:02 10.77.0.50"))); /* taken */
    CHECK(is_err(cmd(&r, "reserve 0 02:4d:4f:4e:00:03 10.78.0.5")));  /* outside */
    CHECK(is_err(cmd(&r, "reserve 0 02:4d:4f:4e:00:03")));
    CHECK_STR(cmd(&r, "nameservers 192.168.1.1 1.1.1.1:5353"), "ok");
    CHECK_STR(cmd(&r, "nameservers"), "ok"); /* none: DNS answers SERVFAIL */
    CHECK(is_err(cmd(&r, "nameservers 1.1.1.1 1.1.1.2 1.1.1.3 1.1.1.4 1.1.1.5")));
    CHECK(is_err(cmd(&r, "nameservers 1.1.1.1:0")));
    CHECK(is_err(cmd(&r, "nameservers 1.1.1.1:65536")));
    CHECK(is_err(cmd(&r, "nameservers 0.0.0.0")));
    CHECK(is_err(cmd(&r, "nameservers 1.1.1.1.1")));
    CHECK(is_err(cmd(&r, "reserve 0 02:4d:4f:4e:00:03 10.77.0.51.1")));
    CHECK(is_err(cmd(&r, "hostnets 10.0.0.0.0/8")));
    CHECK_STR(cmd(&r, "hostnets 192.168.1.0/24 172.20.10.0/28"), "ok");
    CHECK_STR(cmd(&r, "hostnets"), "ok");
    CHECK(is_err(cmd(&r, "hostnets 192.168.1.5/24")));
    /* A Mac with VPNs, bridges and Docker: every network up to the limit,
     * and single addresses (PPPoE, some VPN links) as /32. */
    char line[MND_CTL_MAX_LINE + 1];
    size_t at = (size_t)snprintf(line, sizeof line, "hostnets 203.0.113.7/32");
    for (int i = 1; i < MND_NET_MAX_HOST_NETWORKS; i++)
        at += (size_t)snprintf(line + at, sizeof line - at, " 10.%d.0.0/16", i);
    CHECK_STR(cmd(&r, line), "ok");
    snprintf(line + at, sizeof line - at, " 10.200.0.0/16");
    CHECK(is_err(cmd(&r, line))); /* one too many */
    teardown(&r);
}

static void test_firewall_transactions(void) {
    rig r;
    setup(&r);
    cmd(&r, "network nat 10.77.0.0/24");
    cmd(&r, "network internal 10.78.0.0/24");
    int vm0, vm1;
    int fd0 = nic(&vm0), fd1 = nic(&vm1);
    CHECK(mnd_ctl_feed(r.c, "port 0 02:4d:4f:4e:00:01\n", 25, &fd0, 1) == 0 && !strcmp(last_reply, "ok 0"));
    CHECK(mnd_ctl_feed(r.c, "port 1 02:4d:4f:4e:00:02\n", 25, &fd1, 1) == 0 && !strcmp(last_reply, "ok 1"));
    /* The firewall is the VM's: "firewall <port> …". */
    CHECK_STR(cmd(&r, "firewall 0 allowlist=1 lan=0"), "ok");
    CHECK_STR(cmd(&r, "rule allow tcp 192.168.1.50/32 ports=5432-5432"), "ok");
    CHECK_STR(cmd(&r, "rule allow any *.github.com"), "ok");
    CHECK_STR(cmd(&r, "rule deny udp 0.0.0.0/0"), "ok");
    CHECK_STR(cmd(&r, "rule allow icmp pypi.org"), "ok");
    CHECK_STR(cmd(&r, "commit"), "ok");
    /* Rules only inside a transaction; a bad rule spoils it. */
    CHECK(is_err(cmd(&r, "rule allow any example.com")));
    CHECK(is_err(cmd(&r, "commit")));
    CHECK_STR(cmd(&r, "firewall 0 allowlist=0 lan=1"), "ok");
    CHECK(is_err(cmd(&r, "rule allow any exa mple.com")));
    CHECK(is_err(cmd(&r, "rule maybe any example.com")));
    CHECK(is_err(cmd(&r, "rule allow sctp example.com")));
    CHECK(is_err(cmd(&r, "rule allow tcp 10.0.0.1/8")));
    CHECK(is_err(cmd(&r, "rule allow tcp 10.0.0.0/8 ports=9-8")));
    CHECK(is_err(cmd(&r, "rule allow tcp 10.0.0.0/8 ports=70000-70001")));
    CHECK(is_err(cmd(&r, "commit"))); /* spoiled: nothing applied */
    /* Too many rules. */
    CHECK_STR(cmd(&r, "firewall 0 allowlist=0 lan=0"), "ok");
    for (int i = 0; i < MND_NET_MAX_FW_RULES; i++) CHECK_STR(cmd(&r, "rule deny any 1.2.3.4/32"), "ok");
    CHECK(is_err(cmd(&r, "rule deny any 1.2.3.4/32")));
    CHECK(is_err(cmd(&r, "commit")));
    /* A port on an internal network takes one too; unknown ports, bad headers. */
    CHECK_STR(cmd(&r, "firewall 1 allowlist=0 lan=0"), "ok");
    CHECK_STR(cmd(&r, "commit"), "ok");
    CHECK(is_err(cmd(&r, "firewall 0 allowlist=2 lan=0")));
    CHECK(is_err(cmd(&r, "firewall 0 lan=0 allowlist=0")));
    CHECK(is_err(cmd(&r, "firewall 7 allowlist=0 lan=0")));
    CHECK(is_err(cmd(&r, "firewall 99999999 allowlist=0 lan=0")));
    /* A port that went away between "firewall" and "commit". */
    CHECK_STR(cmd(&r, "firewall 1 allowlist=0 lan=0"), "ok");
    CHECK_STR(cmd(&r, "commit"), "ok");
    CHECK_STR(cmd(&r, "firewall 1 allowlist=0 lan=1"), "ok");
    CHECK(mnd_ctl_feed(r.c, "unport 1\n", 9, NULL, 0) == 0);
    CHECK_STR(cmd(&r, "commit"), "err no valid firewall to commit");
    CHECK_STR(cmd(&r, "ping"), "ok pong");
    close(vm0);
    close(vm1);
    teardown(&r);
}

/* A VM's port starts closed: until MonadHost sends the VM's firewall (right
 * after "port", and again after netd restarts) nothing leaves through it. */
static void test_a_new_port_is_closed_until_its_firewall_arrives(void) {
    rig r;
    setup(&r);
    cmd(&r, "network nat 10.77.0.0/24");
    int vm, fd = nic(&vm);
    CHECK(mnd_ctl_feed(r.c, "port 0 02:4d:4f:4e:00:01\n", 25, &fd, 1) == 0 && !strcmp(last_reply, "ok 0"));
    uint8_t f[MND_FRAME_MAX];
    mnd_ip_hdr_spec h = {.eth_dst = {{0x02, 0x4d, 0x4e, 0x47, 0, 0}}, .eth_src = {{0x02, 0x4d, 0x4f, 0x4e, 0, 1}},
                         .src = MND_IP4(10, 77, 0, 50), .dst = MND_IP4(203, 0, 113, 9), .ttl = 64};
    size_t n = mnd_build_udp(f, sizeof f, &h, 5000, 9, (const uint8_t *)"x", 1);
    CHECK(send(vm, f, n, 0) == (ssize_t)n);
    for (int i = 0; i < 10; i++) mnd_netd_run_once(r.d, mnd_loop_now() + 5);
    CHECK(strstr(cmd(&r, "stats 0"), " firewall=1") != NULL);
    CHECK(mnd_netd_open_sockets(r.d) == 0);
    /* Its firewall arrives: the same datagram goes out. */
    CHECK_STR(cmd(&r, "firewall 0 allowlist=0 lan=0"), "ok");
    CHECK_STR(cmd(&r, "commit"), "ok");
    CHECK(send(vm, f, n, 0) == (ssize_t)n);
    for (int i = 0; i < 10; i++) mnd_netd_run_once(r.d, mnd_loop_now() + 5);
    CHECK(strstr(cmd(&r, "stats 0"), " firewall=1") != NULL);
    CHECK(mnd_netd_open_sockets(r.d) == 1);
    close(vm);
    teardown(&r);
}

static char events[8][256];
static int nevents;

static void on_event(void *ctx, const char *line) {
    (void)ctx;
    if (nevents < 8) snprintf(events[nevents], sizeof events[0], "%s", line);
    nevents++;
}

static void test_ask_lines(void) {
    char out[256];
    const char *names[] = {"www.example.com", "example.com"};
    mnd_netd_format_ask(out, sizeof out, 3, MND_IPPROTO_TCP, MND_IP4(93, 184, 216, 34), 443, names, 2);
    CHECK_STR(out, "event ask 3 tcp 93.184.216.34 443 www.example.com,example.com");
    mnd_netd_format_ask(out, sizeof out, 0, MND_IPPROTO_ICMP, MND_IP4(1, 1, 1, 1), 0, NULL, 0);
    CHECK_STR(out, "event ask 0 icmp 1.1.1.1 0");
    /* Names that do not fit are left out whole. */
    char longname[200];
    memset(longname, 'a', sizeof longname - 1);
    longname[sizeof longname - 1] = 0;
    const char *many[] = {"first.example", longname, "last.example"};
    mnd_netd_format_ask(out, 100, 1, MND_IPPROTO_UDP, MND_IP4(9, 9, 9, 9), 53, many, 3);
    CHECK_STR(out, "event ask 1 udp 9.9.9.9 53 first.example,last.example");
    /* Only names a rule could use: nothing that could split or fake the list. */
    const char *odd[] = {"good.example", "github.com,x.attacker.test", "bad name", "b!d.example", "fine_2.test"};
    mnd_netd_format_ask(out, sizeof out, 2, MND_IPPROTO_TCP, MND_IP4(203, 0, 113, 9), 443, odd, 5);
    CHECK_STR(out, "event ask 2 tcp 203.0.113.9 443 good.example,fine_2.test");
    /* A lookup in monitor mode (F-10): only a name a rule could use. */
    mnd_netd_format_lookup(out, sizeof out, 4, "api.example.com");
    CHECK_STR(out, "event lookup 4 api.example.com");
    mnd_netd_format_lookup(out, sizeof out, 4, "github.com,x.attacker.test");
    CHECK_STR(out, "");
}

/* Monitor mode over the channel: netd asks, MonadHost answers with a
 * session rule, and forgets the answers when the VM stops. */
static void test_monitor_over_the_channel(void) {
    rig r;
    setup(&r);
    nevents = 0;
    mnd_netd_set_event_sink(r.d, on_event, NULL);
    cmd(&r, "network nat 10.77.0.0/24");
    int vm, fd = nic(&vm);
    CHECK(mnd_ctl_feed(r.c, "port 0 02:4d:4f:4e:00:01\n", 25, &fd, 1) == 0 && !strcmp(last_reply, "ok 0"));
    CHECK_STR(cmd(&r, "firewall 0 allowlist=0 lan=0 monitor=1"), "ok");
    CHECK_STR(cmd(&r, "commit"), "ok");
    uint8_t f[MND_FRAME_MAX];
    mnd_ip_hdr_spec h = {.eth_dst = {{0x02, 0x4d, 0x4e, 0x47, 0, 0}}, .eth_src = {{0x02, 0x4d, 0x4f, 0x4e, 0, 1}},
                         .src = MND_IP4(10, 77, 0, 50), .dst = MND_IP4(203, 0, 113, 9), .ttl = 64};
    size_t n = mnd_build_udp(f, sizeof f, &h, 5000, 9, (const uint8_t *)"x", 1);
    CHECK(send(vm, f, n, 0) == (ssize_t)n);
    for (int i = 0; i < 10; i++) mnd_netd_run_once(r.d, mnd_loop_now() + 5);
    CHECK(nevents == 1);
    CHECK_STR(events[0], "event ask 0 udp 203.0.113.9 9");
    CHECK(mnd_netd_open_sockets(r.d) == 0);
    CHECK_STR(cmd(&r, "session 0 allow udp 203.0.113.9/32 ports=9-9"), "ok");
    CHECK(send(vm, f, n, 0) == (ssize_t)n);
    for (int i = 0; i < 10; i++) mnd_netd_run_once(r.d, mnd_loop_now() + 5);
    CHECK(mnd_netd_open_sockets(r.d) == 1);
    CHECK_STR(cmd(&r, "session 0 deny tcp *.example.com"), "ok");
    CHECK(is_err(cmd(&r, "session 0 allow udp no way")));
    CHECK(is_err(cmd(&r, "session 7 allow udp 1.2.3.4/32")));
    CHECK(is_err(cmd(&r, "session 0 maybe udp 1.2.3.4/32")));
    CHECK(is_err(cmd(&r, "firewall 0 allowlist=0 lan=0 monitor=2")));
    CHECK(is_err(cmd(&r, "firewall 0 allowlist=0 lan=0 watch=1")));
    /* A lookup no rule decides is asked about by name and waits. */
    uint8_t q[512];
    size_t qn = td_query(q, 0x77, "new.example", MND_DNS_TYPE_A, 0);
    h.dst = MND_IP4(10, 77, 0, 1);
    n = mnd_build_udp(f, sizeof f, &h, 40000, 53, q, qn);
    CHECK(send(vm, f, n, 0) == (ssize_t)n);
    for (int i = 0; i < 10; i++) mnd_netd_run_once(r.d, mnd_loop_now() + 5);
    CHECK(nevents == 2);
    CHECK_STR(events[1], "event lookup 0 new.example");
    CHECK_STR(cmd(&r, "forget 0"), "ok");
    CHECK(is_err(cmd(&r, "forget 7")));
    CHECK(is_err(cmd(&r, "forget")));
    close(vm);
    teardown(&r);
}

/* One entry of the connection log as a token: no space, no comma but the
 * separators, a name only if a rule could use it. */
static void test_conn_tokens(void) {
    char out[512];
    mnd_net_conn c = {.proto = MND_IPPROTO_TCP, .dst = MND_IP4(140, 82, 112, 3), .dport = 443,
                      .verdict = MND_CONN_ALLOWED, .reason = MND_CONN_BY_RULE, .rule = 2, .opened = 7, .refused = 1,
                      .asked = 0, .active = 2, .bytes_out = 1234, .bytes_in = 56789, .first_ms = 1000, .last_ms = 61000};
    CHECK(mnd_netd_format_conn(out, sizeof out, &c, "github.com", 121000) > 0);
    CHECK_STR(out, "tcp,140.82.112.3,443,allow,rule:2,7,1,0,2,1234,56789,120,60,github.com");
    mnd_net_conn d = {.proto = MND_IPPROTO_ICMP, .dst = MND_IP4(1, 1, 1, 1), .verdict = MND_CONN_ASKED,
                      .reason = MND_CONN_BY_MONITOR, .asked = 3, .first_ms = 5000, .last_ms = 5000};
    CHECK(mnd_netd_format_conn(out, sizeof out, &d, NULL, 5999) > 0);
    CHECK_STR(out, "icmp,1.1.1.1,0,ask,monitor,0,0,3,0,0,0,0,0,-");
    const char *reasons[] = {"session", "lan", "default"};
    mnd_conn_reason codes[] = {MND_CONN_BY_SESSION, MND_CONN_BY_LAN, MND_CONN_BY_DEFAULT};
    for (int i = 0; i < 3; i++) {
        mnd_net_conn e = {.proto = MND_IPPROTO_UDP, .dst = MND_IP4(9, 9, 9, 9), .dport = 53,
                          .verdict = MND_CONN_DENIED, .reason = codes[i]};
        CHECK(mnd_netd_format_conn(out, sizeof out, &e, NULL, 0) > 0);
        CHECK(strstr(out, reasons[i]) != NULL && strstr(out, ",deny,") != NULL);
    }
    /* Names that could split or fake the list are left out. */
    const char *odd[] = {"github.com,x.attacker.test", "bad name", "b!d.example", "a.b c"};
    for (int i = 0; i < 4; i++) {
        CHECK(mnd_netd_format_conn(out, sizeof out, &c, odd[i], 121000) > 0);
        CHECK(out[strlen(out) - 1] == '-' && out[strlen(out) - 2] == ',');
    }
    CHECK(mnd_netd_format_conn(out, 20, &c, "github.com", 121000) == -1); /* does not fit */
}

static int count_entries(const char *reply) {
    int n = 0;
    for (const char *p = strchr(reply, ' '); p; p = strchr(p + 1, ' ')) n++;
    return n - 1; /* after "ok next=…" */
}

/* conns <port> [from=<n>]: the VM's log, most recent first, in pages that
 * fit a line; "next" says where the next page starts, 0 at the end. */
static void test_conns_over_the_channel(void) {
    rig r;
    setup(&r);
    cmd(&r, "network nat 10.77.0.0/24");
    int vm, fd = nic(&vm);
    CHECK(mnd_ctl_feed(r.c, "port 0 02:4d:4f:4e:00:01\n", 25, &fd, 1) == 0 && !strcmp(last_reply, "ok 0"));
    CHECK_STR(cmd(&r, "conns 0"), "ok next=0");
    CHECK_STR(cmd(&r, "firewall 0 allowlist=1 lan=0"), "ok");
    CHECK_STR(cmd(&r, "commit"), "ok");
    uint8_t f[MND_FRAME_MAX];
    mnd_ip_hdr_spec h = {.eth_dst = {{0x02, 0x4d, 0x4e, 0x47, 0, 0}}, .eth_src = {{0x02, 0x4d, 0x4f, 0x4e, 0, 1}},
                         .src = MND_IP4(10, 77, 0, 50), .ttl = 64};
    for (int i = 0; i < 40; i++) {
        h.dst = MND_IP4(203, 0, 113, i + 1);
        size_t n = mnd_build_udp(f, sizeof f, &h, 5000, 9, (const uint8_t *)"x", 1);
        CHECK(send(vm, f, n, 0) == (ssize_t)n);
        for (int k = 0; k < 3; k++) mnd_netd_run_once(r.d, mnd_loop_now() + 2);
    }
    const char *page = cmd(&r, "conns 0");
    CHECK(strncmp(page, "ok next=", 8) == 0);
    int next = atoi(page + 8), first = count_entries(page);
    CHECK(next > 0 && next == first && strlen(page) < MND_CTL_MAX_LINE);
    CHECK(strstr(page, " udp,203.0.113.40,9,deny,default,0,1,0,0,0,0,") != NULL); /* the newest first */
    int total = first;
    char from[64];
    while (next) {
        snprintf(from, sizeof from, "conns 0 from=%d", next);
        page = cmd(&r, from);
        CHECK(strncmp(page, "ok next=", 8) == 0);
        int got = count_entries(page);
        next = atoi(page + 8);
        CHECK(got > 0 || next == 0);
        total += got;
        if (total > 40) break;
    }
    CHECK(total == 40);
    CHECK(strstr(page, " udp,203.0.113.1,9,") != NULL); /* the oldest last */
    CHECK(is_err(cmd(&r, "conns 7")));
    CHECK(is_err(cmd(&r, "conns")));
    CHECK(is_err(cmd(&r, "conns 0 from=x")));
    CHECK(is_err(cmd(&r, "conns 0 next=2")));
    CHECK_STR(cmd(&r, "conns 0 from=999"), "ok next=0");
    close(vm);
    teardown(&r);
}

/* One VM-to-VM entry as a token: sender and receiver ports, frames, bytes,
 * seconds since last seen. */
static void test_peer_tokens(void) {
    char out[128];
    mnd_net_peer p = {.from = 3, .to = 7, .frames = 12, .bytes = 720, .last_ms = 1000};
    CHECK(mnd_netd_format_peer(out, sizeof out, &p, 6500) > 0);
    CHECK_STR(out, "3,7,12,720,5");
    CHECK(mnd_netd_format_peer(out, sizeof out, &p, 500) > 0);
    CHECK_STR(out, "3,7,12,720,0"); /* a clock behind the entry: 0, never a wrap */
    CHECK(mnd_netd_format_peer(out, 6, &p, 6500) == -1); /* does not fit */
}

/* peers <network> [from=<n>]: the network's VM-to-VM traffic, in pages
 * that fit a line. */
static void test_peers_over_the_channel(void) {
    rig r;
    setup(&r);
    CHECK_STR(cmd(&r, "network none 10.78.0.0/24"), "ok 0");
    CHECK_STR(cmd(&r, "peers 0"), "ok next=0");
    enum { VMS = 12 }; /* 132 entries: more than one line holds */
    int vms[VMS];
    for (int i = 0; i < VMS; i++) {
        int fd = nic(&vms[i]);
        char line[64], want[16];
        int n = snprintf(line, sizeof line, "port 0 02:4d:4f:4e:00:%02x\n", i + 1);
        snprintf(want, sizeof want, "ok %d", i);
        CHECK(mnd_ctl_feed(r.c, line, (size_t)n, &fd, 1) == 0 && !strcmp(last_reply, want));
    }
    /* Each VM sends one frame to every other. */
    uint8_t f[60] = {0};
    for (int i = 0; i < VMS; i++) {
        for (int k = 0; k < VMS; k++) {
            if (k == i) continue;
            const uint8_t dst[6] = {0x02, 0x4d, 0x4f, 0x4e, 0, (uint8_t)(k + 1)}, src[6] = {0x02, 0x4d, 0x4f, 0x4e, 0, (uint8_t)(i + 1)};
            memcpy(f, dst, 6);
            memcpy(f + 6, src, 6);
            f[12] = 0x08;
            CHECK(send(vms[i], f, sizeof f, 0) == (ssize_t)sizeof f);
        }
        for (int k = 0; k < 4; k++) mnd_netd_run_once(r.d, mnd_loop_now() + 2);
    }
    const char *page = cmd(&r, "peers 0");
    CHECK(strncmp(page, "ok next=", 8) == 0);
    int next = atoi(page + 8), total = count_entries(page);
    CHECK(next > 0 && next == total && strlen(page) < MND_CTL_MAX_LINE);
    CHECK(strstr(page, " 0,1,1,60,") != NULL); /* the first sender first */
    char from[64];
    while (next) {
        snprintf(from, sizeof from, "peers 0 from=%d", next);
        page = cmd(&r, from);
        CHECK(strncmp(page, "ok next=", 8) == 0);
        int got = count_entries(page);
        next = atoi(page + 8);
        CHECK(got > 0 || next == 0);
        total += got;
        if (total > VMS * (VMS - 1)) break;
    }
    CHECK(total == VMS * (VMS - 1));
    CHECK(strstr(page, " 11,10,1,60,") != NULL); /* the last pair last */
    CHECK(is_err(cmd(&r, "peers 5")));
    CHECK(is_err(cmd(&r, "peers")));
    CHECK(is_err(cmd(&r, "peers 0 from=x")));
    CHECK(is_err(cmd(&r, "peers 0 next=2")));
    CHECK_STR(cmd(&r, "peers 0 from=999"), "ok next=0");
    for (int i = 0; i < VMS; i++) close(vms[i]);
    teardown(&r);
}

static void test_the_stream(void) {
    rig r;
    setup(&r);
    /* Several lines at once, and lines split across reads. */
    CHECK(mnd_ctl_feed(r.c, "ping\nnetwork nat 10.77.0.0/24\npi", 32, NULL, 0) == 0);
    CHECK(replies == 2);
    CHECK_STR(last_reply, "ok 0");
    CHECK(mnd_ctl_feed(r.c, "ng\n", 3, NULL, 0) == 0);
    CHECK(replies == 3);
    CHECK_STR(last_reply, "ok pong");
    CHECK(mnd_ctl_feed(r.c, "launch-missiles\n", 16, NULL, 0) == 0);
    CHECK_STR(last_reply, "err unknown command");
    CHECK(mnd_ctl_feed(r.c, "\n", 1, NULL, 0) == 0);
    CHECK_STR(last_reply, "err unknown command");
    teardown(&r);
}

static void test_protocol_violations(void) {
    rig r;
    /* A line that never ends. */
    setup(&r);
    static char big[MND_CTL_MAX_LINE + 2];
    memset(big, 'a', sizeof big);
    CHECK(mnd_ctl_feed(r.c, big, MND_CTL_MAX_LINE, NULL, 0) == 0);
    CHECK(mnd_ctl_feed(r.c, big, 2, NULL, 0) == -1);
    teardown(&r);
    /* Control bytes and NUL. */
    setup(&r);
    CHECK(mnd_ctl_feed(r.c, "pi\x01ng\n", 6, NULL, 0) == -1);
    teardown(&r);
    setup(&r);
    CHECK(mnd_ctl_feed(r.c, "pi\0ng\n", 6, NULL, 0) == -1);
    teardown(&r);
    setup(&r);
    CHECK(mnd_ctl_feed(r.c, "ping\xc3\xa9\n", 7, NULL, 0) == -1);
    teardown(&r);
    /* Descriptors nobody claims pile up to the limit, then the session ends;
     * destroying it closes them. */
    setup(&r);
    int fds[MND_CTL_MAX_FDS + 1], others[MND_CTL_MAX_FDS + 1];
    for (int i = 0; i <= MND_CTL_MAX_FDS; i++) fds[i] = nic(&others[i]);
    CHECK(mnd_ctl_feed(r.c, "ping\n", 5, fds, MND_CTL_MAX_FDS) == 0);
    CHECK(mnd_ctl_feed(r.c, "ping\n", 5, fds + MND_CTL_MAX_FDS, 1) == -1);
    CHECK(closed(fds[MND_CTL_MAX_FDS])); /* the one over the limit is closed at once */
    teardown(&r);
    for (int i = 0; i < MND_CTL_MAX_FDS; i++) CHECK(closed(fds[i]));
    for (int i = 0; i <= MND_CTL_MAX_FDS; i++) close(others[i]);
}

int main(void) {
    fprintf(stderr, "monad-netd control channel tests\n");
    RUN(test_networks);
    RUN(test_ports_take_a_nic_descriptor);
    RUN(test_reservations_nameservers_hostnets);
    RUN(test_firewall_transactions);
    RUN(test_a_new_port_is_closed_until_its_firewall_arrives);
    RUN(test_ask_lines);
    RUN(test_monitor_over_the_channel);
    RUN(test_conn_tokens);
    RUN(test_conns_over_the_channel);
    RUN(test_peer_tokens);
    RUN(test_peers_over_the_channel);
    RUN(test_the_stream);
    RUN(test_protocol_violations);
    TEST_MAIN_END();
}
