/* Tests for the connection log: per VM, each destination it tried to
 * reach through a NAT gateway, the firewall's last word and why, flows
 * opened, refused, asked about and open now, bytes each way; bounded, and
 * gone with the VM. */
#include "net_test_gw.h"

static mnd_ip4 vm_ip(fixture *f, int port) {
    mnd_ip4 ip = 0;
    mnd_net_port_ip(f->net, port, &ip);
    return ip;
}

static void udp_from(fixture *f, int port, uint16_t sport, mnd_ip4 dst, uint16_t dport, const char *data) {
    send_udp(f, port, port_mac(f, port), f->gw_mac, vm_ip(f, port), dst, sport, dport, (const uint8_t *)data,
             strlen(data));
}

static void ping_to(fixture *f, int port, mnd_ip4 dst, const char *data) {
    uint8_t buf[MND_FRAME_MAX];
    mnd_ip_hdr_spec h = {.eth_dst = f->gw_mac, .eth_src = port_mac(f, port), .src = vm_ip(f, port), .dst = dst,
                         .ttl = 64};
    size_t n = mnd_build_icmp(buf, sizeof buf, &h, 8, 0, 7, 1, (const uint8_t *)data, strlen(data));
    mnd_net_input(f->net, port, buf, n);
}

static void syn_to(fixture *f, int port, mnd_ip4 dst, uint16_t dport, uint16_t sport) {
    uint8_t buf[MND_FRAME_MAX];
    mnd_ip_hdr_spec h = {.eth_dst = f->gw_mac, .eth_src = port_mac(f, port), .src = vm_ip(f, port), .dst = dst,
                         .ttl = 64};
    mnd_tcp_spec t = {.sport = sport, .dport = dport, .seq = 100, .flags = MND_TCP_SYN, .window = 65535,
                      .mss = 1400, .wscale = -1};
    size_t n = mnd_build_tcp(buf, sizeof buf, &h, &t, NULL, 0);
    mnd_net_input(f->net, port, buf, n);
}

/* The log entry for a destination, or NULL. */
static mnd_net_conn found;
static const mnd_net_conn *entry(fixture *f, int port, uint8_t proto, mnd_ip4 dst, uint16_t dport) {
    static mnd_net_conn all[MND_NET_MAX_CONN_LOG_PER_PORT];
    int n = mnd_net_conns(f->net, port, all, MND_NET_MAX_CONN_LOG_PER_PORT);
    for (int i = 0; i < n; i++)
        if (all[i].proto == proto && all[i].dst == dst && all[i].dport == dport) {
            found = all[i];
            return &found;
        }
    return NULL;
}

static int log_size(fixture *f, int port) {
    static mnd_net_conn all[MND_NET_MAX_CONN_LOG];
    return mnd_net_conns(f->net, port, all, MND_NET_MAX_CONN_LOG);
}

static void setup_log(fixture *f) {
    setup(f);
    lease(f, f->a);
    lease(f, f->b);
}

#define DNS1 MND_IP4(1, 1, 1, 1)
#define WEB MND_IP4(93, 184, 216, 34)

/* ---- What is logged ------------------------------------------------------------- */

static void test_flows_are_logged_by_destination(void) {
    static fixture f;
    setup_log(&f);
    CHECK(log_size(&f, f.a) == 0);
    udp_from(&f, f.a, 5000, DNS1, 53, "hello");
    udp_from(&f, f.a, 5000, DNS1, 53, "again!"); /* the same flow */
    udp_from(&f, f.a, 5001, DNS1, 53, "x");      /* a second flow, same destination */
    CHECK(f.h.nudp == 2);
    mnd_net_udp_input(f.net, f.h.udp[0].flow, (const uint8_t *)"reply", 5);
    f.h.now += 10;
    ping_to(&f, f.a, MND_IP4(8, 8, 8, 8), "ping");
    const mnd_net_conn *c = entry(&f, f.a, MND_IPPROTO_UDP, DNS1, 53);
    CHECK(c != NULL);
    if (c) {
        CHECK(c->verdict == MND_CONN_ALLOWED && c->reason == MND_CONN_BY_DEFAULT);
        CHECK(c->opened == 2 && c->active == 2 && c->refused == 0 && c->asked == 0);
        CHECK(c->bytes_out == 5 + 6 + 1);
        CHECK(c->bytes_in == 5);
        CHECK(c->first_ms == 1000);
    }
    c = entry(&f, f.a, MND_IPPROTO_ICMP, MND_IP4(8, 8, 8, 8), 0);
    CHECK(c && c->opened == 1 && c->bytes_out == 4 && c->last_ms == 1010);
    /* Most recently seen first. */
    mnd_net_conn all[4];
    CHECK(mnd_net_conns(f.net, f.a, all, 4) == 2);
    CHECK(all[0].proto == MND_IPPROTO_ICMP && all[1].proto == MND_IPPROTO_UDP);
    CHECK(mnd_net_conns(f.net, f.a, all, 1) == 1);
    CHECK(log_size(&f, f.b) == 0); /* each VM its own */
    CHECK(mnd_net_conns(f.net, 999, all, 4) == -1);
    teardown(&f);
}

static void test_closed_flows_keep_their_counts(void) {
    static fixture f;
    setup_log(&f);
    udp_from(&f, f.a, 5000, DNS1, 53, "hello");
    f.h.now += MND_NET_UDP_TIMEOUT_MS + 1;
    mnd_net_poll(f.net);
    CHECK(f.h.udp_closed == 1);
    const mnd_net_conn *c = entry(&f, f.a, MND_IPPROTO_UDP, DNS1, 53);
    CHECK(c && c->active == 0 && c->opened == 1 && c->bytes_out == 5);
    /* A firewall change closing what it now denies closes it in the log too. */
    udp_from(&f, f.a, 5002, DNS1, 53, "hi");
    c = entry(&f, f.a, MND_IPPROTO_UDP, DNS1, 53);
    CHECK(c && c->active == 1 && c->opened == 2);
    mnd_fw_config deny = {.allowlist = true};
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &deny) == 0);
    c = entry(&f, f.a, MND_IPPROTO_UDP, DNS1, 53);
    CHECK(c && c->active == 0);
    teardown(&f);
}

/* Refused attempts say what refused them: a rule (which), the LAN, or the
 * default of allowlist mode; allowed ones what allowed them. */
static void test_each_verdict_says_why(void) {
    static fixture f;
    setup_log(&f);
    mnd_fw_config cfg = {.allowlist = true, .nrules = 2};
    cfg.rules[0] = (mnd_fw_rule){.action = MND_FW_DENY, .proto = MND_IPPROTO_UDP, .addr = MND_IP4(9, 9, 9, 9),
                                 .prefix = 32};
    cfg.rules[1] = (mnd_fw_rule){.action = MND_FW_ALLOW, .addr = DNS1, .prefix = 32};
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    udp_from(&f, f.a, 5000, MND_IP4(9, 9, 9, 9), 53, "a");
    udp_from(&f, f.a, 5001, MND_IP4(9, 9, 9, 9), 53, "b");
    udp_from(&f, f.a, 5000, DNS1, 53, "c");
    udp_from(&f, f.a, 5000, MND_IP4(192, 168, 1, 5), 53, "d");
    syn_to(&f, f.a, WEB, 443, 40000);
    const mnd_net_conn *c = entry(&f, f.a, MND_IPPROTO_UDP, MND_IP4(9, 9, 9, 9), 53);
    CHECK(c && c->verdict == MND_CONN_DENIED && c->reason == MND_CONN_BY_RULE && c->rule == 0);
    CHECK(c && c->refused == 2 && c->opened == 0 && c->active == 0 && c->bytes_out == 0);
    c = entry(&f, f.a, MND_IPPROTO_UDP, DNS1, 53);
    CHECK(c && c->verdict == MND_CONN_ALLOWED && c->reason == MND_CONN_BY_RULE && c->rule == 1 && c->opened == 1);
    c = entry(&f, f.a, MND_IPPROTO_UDP, MND_IP4(192, 168, 1, 5), 53);
    CHECK(c && c->verdict == MND_CONN_DENIED && c->reason == MND_CONN_BY_LAN && c->refused == 1);
    c = entry(&f, f.a, MND_IPPROTO_TCP, WEB, 443);
    CHECK(c && c->verdict == MND_CONN_DENIED && c->reason == MND_CONN_BY_DEFAULT && c->refused == 1);
    teardown(&f);
}

/* Monitor mode: attempts held for a question are asked; once answered,
 * the next one is decided by the session's answer. */
static void test_questions_and_answers(void) {
    static fixture f;
    setup_log(&f);
    mnd_fw_config cfg = {.monitor = true};
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    syn_to(&f, f.a, WEB, 443, 40000);
    syn_to(&f, f.a, WEB, 443, 40000); /* the VM tries again */
    const mnd_net_conn *c = entry(&f, f.a, MND_IPPROTO_TCP, WEB, 443);
    CHECK(c && c->verdict == MND_CONN_ASKED && c->reason == MND_CONN_BY_MONITOR && c->asked == 2 && c->opened == 0);
    mnd_fw_rule allow = {.action = MND_FW_ALLOW, .addr = WEB, .prefix = 32};
    CHECK(mnd_net_add_session_rule(f.net, f.a, &allow) == 0);
    syn_to(&f, f.a, WEB, 443, 40000);
    c = entry(&f, f.a, MND_IPPROTO_TCP, WEB, 443);
    CHECK(c && c->verdict == MND_CONN_ALLOWED && c->reason == MND_CONN_BY_SESSION && c->opened == 1 &&
          c->active == 1 && c->asked == 2);
    teardown(&f);
}

/* ---- Bounds ---------------------------------------------------------------------- */

static void test_a_vm_keeps_its_most_recent_destinations(void) {
    static fixture f;
    setup_log(&f);
    mnd_fw_config deny = {.allowlist = true};
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &deny) == 0);
    udp_from(&f, f.b, 5000, DNS1, 53, "b's");
    for (int i = 0; i < MND_NET_MAX_CONN_LOG_PER_PORT + 40; i++) {
        f.h.now++;
        udp_from(&f, f.a, 5000, MND_IP4(20, 0, (i >> 8) & 0xff, i & 0xff), 53, "x");
    }
    CHECK(log_size(&f, f.a) == MND_NET_MAX_CONN_LOG_PER_PORT);
    CHECK(entry(&f, f.a, MND_IPPROTO_UDP, MND_IP4(20, 0, 0, 0), 53) == NULL); /* the oldest went */
    int last = MND_NET_MAX_CONN_LOG_PER_PORT + 39;
    CHECK(entry(&f, f.a, MND_IPPROTO_UDP, MND_IP4(20, 0, (last >> 8) & 0xff, last & 0xff), 53) != NULL);
    CHECK(entry(&f, f.b, MND_IPPROTO_UDP, DNS1, 53) != NULL); /* another VM's stays */
    teardown(&f);
}

/* An entry with something open stays, however old. */
static void test_open_flows_keep_their_entry(void) {
    static fixture f;
    setup_log(&f);
    udp_from(&f, f.a, 5000, DNS1, 53, "open");
    mnd_fw_config cfg = {.allowlist = true, .nrules = 1};
    cfg.rules[0] = (mnd_fw_rule){.action = MND_FW_ALLOW, .addr = DNS1, .prefix = 32};
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    for (int i = 0; i < MND_NET_MAX_CONN_LOG_PER_PORT + 10; i++) {
        f.h.now++;
        udp_from(&f, f.a, 5001, MND_IP4(20, 0, (i >> 8) & 0xff, i & 0xff), 53, "x");
    }
    const mnd_net_conn *c = entry(&f, f.a, MND_IPPROTO_UDP, DNS1, 53);
    CHECK(c && c->active == 1);
    CHECK(log_size(&f, f.a) == MND_NET_MAX_CONN_LOG_PER_PORT);
    teardown(&f);
}

/* When the whole log is full, the VM with the most entries gives way. */
static void test_a_full_log_takes_from_the_busiest_vm(void) {
    static fixture f;
    setup_log(&f);
    int vms = MND_NET_MAX_CONN_LOG / MND_NET_MAX_CONN_LOG_PER_PORT; /* enough to fill it */
    int ports[32];
    mnd_fw_config deny = {.allowlist = true};
    for (int v = 0; v < vms + 1 && v < 32; v++) {
        ports[v] = v == 0 ? f.a : v == 1 ? f.b : add_vm(&f, th_mac((uint8_t)(10 + v)));
        lease(&f, ports[v]);
        CHECK(mnd_net_set_port_firewall(f.net, ports[v], &deny) == 0);
    }
    for (int v = 0; v < vms; v++)
        for (int i = 0; i < MND_NET_MAX_CONN_LOG_PER_PORT; i++) {
            f.h.now++;
            udp_from(&f, ports[v], 5000, MND_IP4(20, (uint8_t)v, (i >> 8) & 0xff, i & 0xff), 53, "x");
        }
    int newcomer = ports[vms];
    udp_from(&f, newcomer, 5000, DNS1, 53, "late");
    CHECK(log_size(&f, newcomer) == 1);
    CHECK(log_size(&f, ports[0]) == MND_NET_MAX_CONN_LOG_PER_PORT - 1); /* the oldest overall, of a full VM */
    CHECK(entry(&f, ports[0], MND_IPPROTO_UDP, MND_IP4(20, 0, 0, 0), 53) == NULL);
    teardown(&f);
}

static void test_the_log_goes_with_the_vm(void) {
    static fixture f;
    setup_log(&f);
    udp_from(&f, f.a, 5000, DNS1, 53, "hello");
    CHECK(log_size(&f, f.a) == 1);
    mnd_net_remove_port(f.net, f.a);
    mnd_net_conn all[4];
    CHECK(mnd_net_conns(f.net, f.a, all, 4) == -1);
    int again = add_vm(&f, th_mac(9)); /* may reuse the slot */
    CHECK(again >= 0 && log_size(&f, again) == 0);
    teardown(&f);
}

int main(void) {
    fprintf(stderr, "mnd_net connection log tests\n");
    RUN(test_flows_are_logged_by_destination);
    RUN(test_closed_flows_keep_their_counts);
    RUN(test_each_verdict_says_why);
    RUN(test_questions_and_answers);
    RUN(test_a_vm_keeps_its_most_recent_destinations);
    RUN(test_open_flows_keep_their_entry);
    RUN(test_a_full_log_takes_from_the_busiest_vm);
    RUN(test_the_log_goes_with_the_vm);
    TEST_MAIN_END();
}
