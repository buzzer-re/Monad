/* Tests for UDP NAT: flows to host sockets, replies back to the VM, expiry
 * driven by mnd_net_poll, limits, and what is never routed. */
#include "net_test_gw.h"

#define REMOTE MND_IP4(1, 1, 1, 1)

static void out(fixture *f, int port, mnd_ip4 dst, uint16_t sport, uint16_t dport, const char *text) {
    mnd_ip4 ip = 0;
    CHECK(mnd_net_port_ip(f->net, port, &ip) == 0);
    send_udp(f, port, port_mac(f, port), f->gw_mac, ip, dst, sport, dport, (const uint8_t *)text, strlen(text));
}

/* The last UDP datagram delivered to `port`. */
static int got_udp(fixture *f, int port, mnd_ip *ip, mnd_udp *udp) {
    const th_frame *fr = th_last(&f->h, port);
    mnd_eth eth;
    if (!fr || mnd_eth_parse(fr->data, fr->len, &eth) || mnd_ip_parse(eth.payload, eth.len, ip)) return -1;
    if (!mnd_mac_eq(eth.src, f->gw_mac) || !mnd_mac_eq(eth.dst, port_mac(f, port))) return -1;
    return ip->proto == MND_IPPROTO_UDP ? mnd_udp_parse(ip, udp) : -1;
}

static void test_a_flow_per_destination(void) {
    static fixture f;
    setup(&f);
    lease(&f, f.a);
    out(&f, f.a, REMOTE, 5000, 53, "hello");
    CHECK(f.h.udp_opened == 1 && f.h.udp[0].dst == REMOTE && f.h.udp[0].port == 53);
    CHECK(f.h.udp[0].sent == 1 && f.h.udp[0].last_len == 5 && memcmp(f.h.udp[0].last, "hello", 5) == 0);
    out(&f, f.a, REMOTE, 5000, 53, "again");
    CHECK(f.h.udp_opened == 1 && f.h.udp[0].sent == 2);
    out(&f, f.a, REMOTE, 5000, 54, "x");  /* another destination port */
    out(&f, f.a, REMOTE, 5001, 53, "x");  /* another source port */
    out(&f, f.a, MND_IP4(9, 9, 9, 9), 5000, 53, "x");
    CHECK(f.h.udp_opened == 4);
    CHECK(f.h.count == 0); /* nothing goes to other VMs */
    /* Many flows differing only in the destination port (hash collisions
     * included): each its own socket, each reply from its own port. */
    for (int i = 0; i < 200; i++) out(&f, f.a, REMOTE, 6000, (uint16_t)(1000 + i), "x");
    CHECK(f.h.udp_opened == 204);
    int right = 0;
    for (int i = 0; i < 200; i++) {
        th_clear(&f.h);
        mnd_net_udp_input(f.net, f.h.udp[4 + i].flow, (const uint8_t *)"r", 1);
        mnd_ip ip;
        mnd_udp udp;
        if (got_udp(&f, f.a, &ip, &udp) == 0 && udp.sport == 1000 + i && udp.dport == 6000) right++;
    }
    CHECK(right == 200);
    teardown(&f);
}

static void test_replies_reach_the_vm(void) {
    static fixture f;
    setup(&f);
    mnd_ip4 a_ip = lease(&f, f.a);
    out(&f, f.a, REMOTE, 5000, 53, "q");
    mnd_net_udp_input(f.net, f.h.udp[0].flow, (const uint8_t *)"answer", 6);
    mnd_ip ip;
    mnd_udp udp;
    CHECK(th_count(&f.h, f.a) == 1 && th_count(&f.h, f.b) == 0);
    CHECK(got_udp(&f, f.a, &ip, &udp) == 0); /* checksums verified by the parsers */
    CHECK(ip.src == REMOTE && ip.dst == a_ip && udp.sport == 53 && udp.dport == 5000);
    CHECK(udp.len == 6 && memcmp(udp.payload, "answer", 6) == 0);
    /* Larger than one frame holds: dropped. */
    th_clear(&f.h);
    static uint8_t big[2000];
    mnd_net_udp_input(f.net, f.h.udp[0].flow, big, MND_ETH_MTU - 28 + 1);
    CHECK(f.h.count == 0);
    mnd_net_udp_input(f.net, f.h.udp[0].flow, big, MND_ETH_MTU - 28);
    CHECK(f.h.count == 1);
    /* Unknown flows. */
    th_clear(&f.h);
    mnd_net_udp_input(f.net, f.h.udp[0].flow + 1, big, 10);
    mnd_net_udp_input(f.net, 0xffffffffu, big, 10);
    CHECK(f.h.count == 0);
    teardown(&f);
}

static void test_flows_expire(void) {
    static fixture f;
    setup(&f);
    lease(&f, f.a);
    CHECK(mnd_net_deadline(f.net) == UINT64_MAX);
    uint64_t t0 = f.h.now;
    out(&f, f.a, REMOTE, 5000, 53, "q");
    CHECK(mnd_net_deadline(f.net) == t0 + MND_NET_UDP_TIMEOUT_MS);
    /* Not due yet: nothing happens. */
    f.h.now = t0 + MND_NET_UDP_TIMEOUT_MS - 1;
    CHECK(mnd_net_poll(f.net) == t0 + MND_NET_UDP_TIMEOUT_MS);
    CHECK(f.h.udp_closed == 0);
    /* Never answered: closed after 30 s. */
    f.h.now = t0 + MND_NET_UDP_TIMEOUT_MS;
    CHECK(mnd_net_poll(f.net) == UINT64_MAX);
    CHECK(f.h.udp_closed == 1 && !f.h.udp[0].open);
    uint32_t old = f.h.udp[0].flow;
    th_clear(&f.h);
    mnd_net_udp_input(f.net, old, (const uint8_t *)"late", 4);
    CHECK(f.h.count == 0);

    /* Answered: kept 180 s after the last datagram either way. */
    uint64_t t1 = f.h.now;
    out(&f, f.a, REMOTE, 5000, 53, "q");
    CHECK(f.h.udp[1].flow != old); /* the slot is reused, the id is not */
    CHECK((f.h.udp[1].flow & 0xffff) == (old & 0xffff));
    th_clear(&f.h);
    mnd_net_udp_input(f.net, old, (const uint8_t *)"late", 4);
    CHECK(f.h.count == 0);
    mnd_net_udp_input(f.net, f.h.udp[1].flow, (const uint8_t *)"a", 1);
    CHECK(mnd_net_deadline(f.net) <= t1 + MND_NET_UDP_REPLIED_TIMEOUT_MS);
    f.h.now = t1 + 100 * 1000;
    mnd_net_poll(f.net);
    out(&f, f.a, REMOTE, 5000, 53, "q"); /* refreshes */
    f.h.now = t1 + 100 * 1000 + MND_NET_UDP_REPLIED_TIMEOUT_MS - 1;
    CHECK(mnd_net_poll(f.net) == t1 + 100 * 1000 + MND_NET_UDP_REPLIED_TIMEOUT_MS);
    CHECK(f.h.udp[1].open);
    f.h.now++;
    mnd_net_poll(f.net);
    CHECK(!f.h.udp[1].open);
    teardown(&f);
}

static void test_limits(void) {
    static fixture f;
    setup(&f);
    lease(&f, f.a);
    for (int i = 0; i < MND_NET_MAX_UDP_FLOWS_PER_PORT + 10; i++) out(&f, f.a, REMOTE, (uint16_t)(10000 + i), 53, "q");
    CHECK(f.h.udp_opened == MND_NET_MAX_UDP_FLOWS_PER_PORT);
    CHECK(stats(&f, f.a).dropped_policy == 10);
    int vms = MND_NET_MAX_UDP_FLOWS / MND_NET_MAX_UDP_FLOWS_PER_PORT;
    for (int v = 0; v < vms; v++) {
        int port = add_vm(&f, th_mac((uint8_t)(20 + v)));
        CHECK(lease(&f, port) != 0);
        for (int i = 0; i < MND_NET_MAX_UDP_FLOWS_PER_PORT; i++) out(&f, port, REMOTE, (uint16_t)(10000 + i), 53, "q");
    }
    CHECK(f.h.udp_opened == MND_NET_MAX_UDP_FLOWS);
    /* Existing flows still carry traffic. */
    int sent = f.h.udp[0].sent;
    out(&f, f.a, REMOTE, 10000, 53, "q");
    CHECK(f.h.udp[0].sent == sent + 1);
    teardown(&f);

    /* The host refusing a socket: dropped, nothing kept. */
    setup(&f);
    lease(&f, f.a);
    f.h.udp_refuse = true;
    out(&f, f.a, REMOTE, 5000, 53, "q");
    CHECK(f.h.udp_opened == 0 && stats(&f, f.a).dropped_policy == 1 && mnd_net_deadline(f.net) == UINT64_MAX);
    f.h.udp_refuse = false;
    out(&f, f.a, REMOTE, 5000, 53, "q");
    CHECK(f.h.udp_opened == 1);
    teardown(&f);
}

static void test_what_is_never_routed(void) {
    static fixture f;
    setup(&f);
    lease(&f, f.a);
    /* Routing, not the firewall: even with the LAN allowed. */
    mnd_fw_config open_lan = {.allow_lan = true};
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &open_lan) == 0);
    const mnd_ip4 never[] = {
        MND_IP4(0, 1, 2, 3),       MND_IP4(127, 0, 0, 1),   MND_IP4(169, 254, 169, 254), MND_IP4(224, 0, 0, 251),
        MND_IP4(239, 1, 1, 1),     MND_IP4(240, 0, 0, 1),   MND_IP4(255, 255, 255, 255), MND_IP4(10, 77, 0, 9),
        MND_IP4(10, 77, 0, 255),
    };
    int count = (int)(sizeof never / sizeof never[0]);
    for (int i = 0; i < count; i++) out(&f, f.a, never[i], 5000, 53, "q");
    CHECK(f.h.udp_opened == 0 && stats(&f, f.a).dropped_policy == (uint64_t)count);
    /* The neighbours of those ranges are routed. */
    out(&f, f.a, MND_IP4(1, 0, 0, 0), 5000, 53, "q");
    out(&f, f.a, MND_IP4(126, 255, 255, 255), 5000, 53, "q");
    out(&f, f.a, MND_IP4(169, 253, 0, 1), 5000, 53, "q");
    out(&f, f.a, MND_IP4(223, 255, 255, 254), 5000, 53, "q");
    out(&f, f.a, MND_IP4(10, 78, 0, 1), 5000, 53, "q");
    CHECK(f.h.udp_opened == 5);
    /* Bad checksum. */
    mnd_ip4 ip;
    mnd_net_port_ip(f.net, f.a, &ip);
    uint8_t buf[MND_FRAME_MAX];
    mnd_ip_hdr_spec h = {.eth_dst = f.gw_mac, .eth_src = th_mac(1), .src = ip, .dst = REMOTE, .ttl = 64};
    size_t n = mnd_build_udp(buf, sizeof buf, &h, 5000, 53, (const uint8_t *)"q", 1);
    buf[n - 1] ^= 0xff;
    mnd_net_input(f.net, f.a, buf, n);
    CHECK(stats(&f, f.a).dropped_malformed == 1);
    teardown(&f);
}

static void test_only_nat_networks_leave(void) {
    static fixture f;
    setup_kind(&f, MND_NET_HOST_ONLY, 24);
    lease(&f, f.a);
    out(&f, f.a, REMOTE, 5000, 53, "q");
    CHECK(f.h.udp_opened == 0 && stats(&f, f.a).dropped_policy == 1);
    teardown(&f);
    setup_kind(&f, MND_NET_INTERNAL, 24);
    lease(&f, f.a);
    out(&f, f.a, REMOTE, 5000, 53, "q");
    CHECK(f.h.udp_opened == 0 && stats(&f, f.a).dropped_policy == 1);
    teardown(&f);
    /* A NAT host without sockets. */
    setup(&f);
    lease(&f, f.a);
    mnd_net_destroy(f.net);
    mnd_net_host host = {.ctx = &f.h, .now_ms = th_now, .send_frame = th_send};
    f.net = mnd_net_create(&host);
    mnd_net_config cfg = {.kind = MND_NET_NAT, .subnet = MND_IP4(10, 77, 0, 0), .prefix = 24};
    f.n = mnd_net_add_network(f.net, &cfg);
    f.nvms = 0;
    f.a = add_vm(&f, th_mac(1));
    lease(&f, f.a);
    out(&f, f.a, REMOTE, 5000, 53, "q");
    CHECK(f.h.udp_opened == 0 && stats(&f, f.a).dropped_policy == 1);
    teardown(&f);
}

static void test_sockets_close_with_their_vm(void) {
    static fixture f;
    setup(&f);
    lease(&f, f.a);
    lease(&f, f.b);
    out(&f, f.a, REMOTE, 5000, 53, "q");
    out(&f, f.a, REMOTE, 5001, 53, "q");
    out(&f, f.b, REMOTE, 5000, 53, "q");
    mnd_net_remove_port(f.net, f.a);
    CHECK(f.h.udp_closed == 2 && !f.h.udp[0].open && !f.h.udp[1].open && f.h.udp[2].open);
    /* A reply that was in flight goes nowhere. */
    mnd_net_udp_input(f.net, f.h.udp[0].flow, (const uint8_t *)"a", 1);
    CHECK(f.h.count == 0);
    mnd_net_destroy(f.net);
    CHECK(f.h.udp_closed == 3);
}

int main(void) {
    fprintf(stderr, "mnd_net UDP NAT tests\n");
    RUN(test_a_flow_per_destination);
    RUN(test_replies_reach_the_vm);
    RUN(test_flows_expire);
    RUN(test_limits);
    RUN(test_what_is_never_routed);
    RUN(test_only_nat_networks_leave);
    RUN(test_sockets_close_with_their_vm);
    TEST_MAIN_END();
}
