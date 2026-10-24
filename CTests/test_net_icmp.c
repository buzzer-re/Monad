/* Tests for ICMP echo NAT: pings from a VM through the host's ICMP
 * sockets, replies back with the VM's identifier, expiry and limits. */
#include "net_test_gw.h"

#define REMOTE MND_IP4(1, 1, 1, 1)

static void ping(fixture *f, int port, mnd_ip4 dst, uint8_t type, uint16_t id, uint16_t seq, const char *data) {
    mnd_ip4 ip = 0;
    mnd_net_port_ip(f->net, port, &ip);
    uint8_t buf[MND_FRAME_MAX];
    mnd_ip_hdr_spec h = {.eth_dst = f->gw_mac, .eth_src = port_mac(f, port), .src = ip, .dst = dst, .ttl = 64};
    size_t n = mnd_build_icmp(buf, sizeof buf, &h, type, 0, id, seq, (const uint8_t *)data, strlen(data));
    CHECK(n > 0);
    mnd_net_input(f->net, port, buf, n);
}

static int got_reply(fixture *f, int port, mnd_ip *ip, mnd_icmp *icmp) {
    const th_frame *fr = th_last(&f->h, port);
    mnd_eth eth;
    if (!fr || mnd_eth_parse(fr->data, fr->len, &eth) || mnd_ip_parse(eth.payload, eth.len, ip)) return -1;
    if (!mnd_mac_eq(eth.src, f->gw_mac) || ip->proto != MND_IPPROTO_ICMP) return -1;
    return mnd_icmp_parse(ip, icmp);
}

static void test_ping_out_and_back(void) {
    static fixture f;
    setup(&f);
    mnd_ip4 a_ip = lease(&f, f.a);
    ping(&f, f.a, REMOTE, 8, 0x77, 1, "abcdefgh");
    CHECK(f.h.nicmp == 1 && f.h.icmp[0].dst == REMOTE && f.h.icmp[0].sent == 1);
    CHECK(f.h.icmp[0].last_seq == 1 && f.h.icmp[0].last_len == 8 && memcmp(f.h.icmp[0].last, "abcdefgh", 8) == 0);
    CHECK(f.h.count == 0 && f.h.nudp == 0);
    mnd_net_icmp_input(f.net, f.h.icmp[0].flow, 1, (const uint8_t *)"abcdefgh", 8);
    mnd_ip ip;
    mnd_icmp icmp;
    CHECK(got_reply(&f, f.a, &ip, &icmp) == 0);
    CHECK(ip.src == REMOTE && ip.dst == a_ip && icmp.type == 0 && icmp.code == 0);
    CHECK(icmp.id == 0x77 && icmp.seq == 1 && icmp.len == 8 && memcmp(icmp.data, "abcdefgh", 8) == 0);
    /* The same identifier again: the same flow. Another: a new one. */
    ping(&f, f.a, REMOTE, 8, 0x77, 2, "x");
    CHECK(f.h.nicmp == 1 && f.h.icmp[0].sent == 2);
    ping(&f, f.a, REMOTE, 8, 0x78, 1, "x");
    ping(&f, f.a, MND_IP4(8, 8, 8, 8), 8, 0x77, 1, "x");
    CHECK(f.h.nicmp == 3);
    /* Unknown flows. */
    th_clear(&f.h);
    mnd_net_icmp_input(f.net, f.h.icmp[0].flow + 0x10000, 1, (const uint8_t *)"x", 1); /* another generation */
    mnd_net_udp_input(f.net, f.h.icmp[0].flow, (const uint8_t *)"x", 1);                 /* not a UDP flow */
    CHECK(f.h.count == 0);
    teardown(&f);
}

static void test_ping_flows_expire_and_close(void) {
    static fixture f;
    setup(&f);
    lease(&f, f.a);
    ping(&f, f.a, REMOTE, 8, 1, 1, "x");
    CHECK(mnd_net_deadline(f.net) == f.h.now + MND_NET_UDP_TIMEOUT_MS);
    f.h.now += MND_NET_UDP_TIMEOUT_MS;
    mnd_net_poll(f.net);
    CHECK(f.h.icmp_closed == 1 && !f.h.icmp[0].open);
    ping(&f, f.a, REMOTE, 8, 1, 2, "x");
    ping(&f, f.a, REMOTE, 8, 2, 1, "x");
    mnd_net_remove_port(f.net, f.a);
    CHECK(f.h.icmp_closed == 3);
    teardown(&f);
}

static void test_what_does_not_leave(void) {
    static fixture f;
    setup(&f);
    lease(&f, f.a);
    ping(&f, f.a, REMOTE, 13, 1, 1, "x");            /* not an echo request */
    ping(&f, f.a, MND_IP4(127, 0, 0, 1), 8, 1, 1, "x"); /* never routed */
    CHECK(f.h.nicmp == 0 && stats(&f, f.a).dropped_policy == 2);
    teardown(&f);
    setup_kind(&f, MND_NET_HOST_ONLY, 24);
    lease(&f, f.a);
    ping(&f, f.a, REMOTE, 8, 1, 1, "x");
    CHECK(f.h.nicmp == 0 && stats(&f, f.a).dropped_policy == 1);
    teardown(&f);
    /* A host without ICMP sockets. */
    setup(&f);
    lease(&f, f.a);
    mnd_net_destroy(f.net);
    mnd_net_host host = {.ctx = &f.h, .now_ms = th_now, .send_frame = th_send, .udp_open = th_udp_open,
                         .udp_send = th_udp_send, .udp_close = th_udp_close};
    f.net = mnd_net_create(&host);
    mnd_net_config cfg = {.kind = MND_NET_NAT, .subnet = MND_IP4(10, 77, 0, 0), .prefix = 24};
    f.n = mnd_net_add_network(f.net, &cfg);
    f.nvms = 0;
    f.a = add_vm(&f, th_mac(1));
    lease(&f, f.a);
    ping(&f, f.a, REMOTE, 8, 1, 1, "x");
    CHECK(f.h.nicmp == 0 && stats(&f, f.a).dropped_policy == 1);
    teardown(&f);
}

int main(void) {
    fprintf(stderr, "mnd_net ICMP echo NAT tests\n");
    RUN(test_ping_out_and_back);
    RUN(test_ping_flows_expire_and_close);
    RUN(test_what_does_not_leave);
    TEST_MAIN_END();
}
