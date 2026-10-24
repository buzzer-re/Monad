/* Tests for the virtual switch: frames between the VMs of one network,
 * isolation between networks, and no spoofing. */
#include "net_test_host.h"
#include "test_util.h"

static const mnd_net_config PLAIN = {.kind = MND_NET_NONE, .subnet = MND_IP4(10, 77, 0, 0), .prefix = 24};
static const mnd_net_config OTHER = {.kind = MND_NET_NONE, .subnet = MND_IP4(10, 78, 0, 0), .prefix = 24};

typedef struct {
    test_host h;
    mnd_net *net;
    int n1, n2;
    int a, b, c; /* a, b on n1; c on n2 */
} fixture;

static void setup(fixture *f) {
    mnd_net_host host = th_host(&f->h);
    f->net = mnd_net_create(&host);
    f->n1 = mnd_net_add_network(f->net, &PLAIN);
    f->n2 = mnd_net_add_network(f->net, &OTHER);
    f->a = mnd_net_add_port(f->net, f->n1, th_mac(1));
    f->b = mnd_net_add_port(f->net, f->n1, th_mac(2));
    f->c = mnd_net_add_port(f->net, f->n2, th_mac(3));
    CHECK(f->net && f->n1 >= 0 && f->n2 >= 0 && f->a >= 0 && f->b >= 0 && f->c >= 0);
    CHECK(f->a != f->b && f->b != f->c && f->a != f->c);
}

static void teardown(fixture *f) { mnd_net_destroy(f->net); }

static void test_unicast_reaches_only_its_destination(void) {
    static fixture f;
    setup(&f);
    uint8_t buf[64];
    size_t n = th_eth(buf, th_mac(2), th_mac(1), MND_ETHERTYPE_IPV4);
    mnd_net_input(f.net, f.a, buf, n);
    CHECK(th_count(&f.h, f.b) == 1);
    CHECK(th_count(&f.h, f.a) == 0 && th_count(&f.h, f.c) == 0);
    const th_frame *got = th_last(&f.h, f.b);
    CHECK(got && got->len == n && memcmp(got->data, buf, n) == 0);
    mnd_net_port_stats s;
    CHECK(mnd_net_port_stats_get(f.net, f.a, &s) == 0 && s.rx == 1);
    CHECK(mnd_net_port_stats_get(f.net, f.b, &s) == 0 && s.tx == 1);
    teardown(&f);
}

static void test_broadcast_reaches_the_others_on_the_network(void) {
    static fixture f;
    setup(&f);
    int d = mnd_net_add_port(f.net, f.n1, th_mac(4));
    uint8_t buf[64];
    size_t n = th_eth(buf, MND_MAC_BROADCAST, th_mac(1), MND_ETHERTYPE_ARP);
    mnd_net_input(f.net, f.a, buf, n);
    CHECK(th_count(&f.h, f.b) == 1 && th_count(&f.h, d) == 1);
    CHECK(th_count(&f.h, f.a) == 0); /* never back to the sender */
    CHECK(th_count(&f.h, f.c) == 0);
    /* Multicast behaves like broadcast. */
    th_clear(&f.h);
    mnd_mac mcast = {{0x01, 0x00, 0x5e, 0x00, 0x00, 0xfb}};
    n = th_eth(buf, mcast, th_mac(1), MND_ETHERTYPE_IPV4);
    mnd_net_input(f.net, f.a, buf, n);
    CHECK(th_count(&f.h, f.b) == 1 && th_count(&f.h, d) == 1 && th_count(&f.h, f.c) == 0);
    teardown(&f);
}

static void test_networks_are_isolated(void) {
    static fixture f;
    setup(&f);
    uint8_t buf[64];
    /* a knows c's MAC but c is on another network. */
    size_t n = th_eth(buf, th_mac(3), th_mac(1), MND_ETHERTYPE_IPV4);
    mnd_net_input(f.net, f.a, buf, n);
    CHECK(f.h.count == 0);
    mnd_net_port_stats s;
    CHECK(mnd_net_port_stats_get(f.net, f.a, &s) == 0 && s.dropped_unknown == 1);
    n = th_eth(buf, MND_MAC_BROADCAST, th_mac(3), MND_ETHERTYPE_ARP);
    mnd_net_input(f.net, f.c, buf, n);
    CHECK(f.h.count == 0); /* c is alone on its network */
    teardown(&f);
}

static void test_spoofed_sources_are_dropped(void) {
    static fixture f;
    setup(&f);
    uint8_t buf[64];
    /* a pretends to be b. */
    size_t n = th_eth(buf, MND_MAC_BROADCAST, th_mac(2), MND_ETHERTYPE_ARP);
    mnd_net_input(f.net, f.a, buf, n);
    /* a sends from a random MAC (table flooding attempt). */
    n = th_eth(buf, th_mac(2), th_mac(99), MND_ETHERTYPE_IPV4);
    mnd_net_input(f.net, f.a, buf, n);
    CHECK(f.h.count == 0);
    mnd_net_port_stats s;
    CHECK(mnd_net_port_stats_get(f.net, f.a, &s) == 0 && s.dropped_spoofed == 2 && s.rx == 2);
    teardown(&f);
}

static void test_malformed_and_unknown_frames_are_dropped(void) {
    static fixture f;
    setup(&f);
    uint8_t buf[64];
    size_t n = th_eth(buf, th_mac(2), th_mac(1), MND_ETHERTYPE_IPV4);
    mnd_net_input(f.net, f.a, buf, 13); /* shorter than a header */
    mnd_net_input(f.net, f.a, NULL, 0);
    n = th_eth(buf, th_mac(50), th_mac(1), MND_ETHERTYPE_IPV4); /* no such VM */
    mnd_net_input(f.net, f.a, buf, n);
    mnd_net_input(f.net, 999, buf, n); /* no such port */
    CHECK(f.h.count == 0);
    mnd_net_port_stats s;
    CHECK(mnd_net_port_stats_get(f.net, f.a, &s) == 0 && s.dropped_malformed == 2 && s.dropped_unknown == 1);
    CHECK(mnd_net_port_stats_get(f.net, 999, &s) == -1);
    teardown(&f);
}

static void test_removed_ports_receive_nothing(void) {
    static fixture f;
    setup(&f);
    mnd_net_remove_port(f.net, f.b);
    uint8_t buf[64];
    size_t n = th_eth(buf, th_mac(2), th_mac(1), MND_ETHERTYPE_IPV4);
    mnd_net_input(f.net, f.a, buf, n);
    n = th_eth(buf, MND_MAC_BROADCAST, th_mac(1), MND_ETHERTYPE_ARP);
    mnd_net_input(f.net, f.a, buf, n);
    mnd_net_input(f.net, f.b, buf, n); /* a removed port sends nothing either */
    CHECK(f.h.count == 0);
    /* Its MAC can join again (the VM restarted). */
    int again = mnd_net_add_port(f.net, f.n1, th_mac(2));
    CHECK(again >= 0);
    n = th_eth(buf, th_mac(2), th_mac(1), MND_ETHERTYPE_IPV4);
    mnd_net_input(f.net, f.a, buf, n);
    CHECK(th_count(&f.h, again) == 1);
    teardown(&f);
}

static void test_limits_and_invalid_ports(void) {
    static fixture f;
    setup(&f);
    CHECK(mnd_net_add_port(f.net, f.n1, th_mac(1)) == -1); /* a MAC is on one port only */
    CHECK(mnd_net_add_port(f.net, f.n2, th_mac(1)) == -1); /* …across networks too */
    CHECK(mnd_net_add_port(f.net, 99, th_mac(10)) == -1);
    CHECK(mnd_net_add_port(f.net, f.n1, MND_MAC_BROADCAST) == -1);
    mnd_mac mcast = {{0x01, 0, 0, 0, 0, 1}};
    CHECK(mnd_net_add_port(f.net, f.n1, mcast) == -1);
    CHECK(mnd_net_add_port(f.net, f.n1, (mnd_mac){{0}}) == -1);
    int added = 0;
    for (int i = 0; i < MND_NET_MAX_PORTS + 5; i++) {
        mnd_mac m = {{0x02, 0x10, 0, 0, (uint8_t)(i >> 8), (uint8_t)i}};
        if (mnd_net_add_port(f.net, f.n2, m) >= 0) added++;
    }
    CHECK(added == MND_NET_MAX_PORTS - 1); /* c is already on n2 */
    int nets = 2;
    for (int i = 0; i < MND_NET_MAX_NETWORKS + 5; i++)
        if (mnd_net_add_network(f.net, &PLAIN) >= 0) nets++;
    CHECK(nets == MND_NET_MAX_NETWORKS);
    mnd_net_config bad = PLAIN;
    bad.prefix = 31;
    teardown(&f);
    mnd_net_host host = th_host(&f.h);
    mnd_net *n = mnd_net_create(&host);
    CHECK(mnd_net_add_network(n, &bad) == -1); /* too small for a gateway and a VM */
    bad.prefix = 7;
    CHECK(mnd_net_add_network(n, &bad) == -1);
    bad = PLAIN;
    bad.subnet = MND_IP4(10, 77, 0, 5); /* host bits set */
    CHECK(mnd_net_add_network(n, &bad) == -1);
    mnd_net_destroy(n);
}

int main(void) {
    fprintf(stderr, "mnd_net switch tests\n");
    RUN(test_unicast_reaches_only_its_destination);
    RUN(test_broadcast_reaches_the_others_on_the_network);
    RUN(test_networks_are_isolated);
    RUN(test_spoofed_sources_are_dropped);
    RUN(test_malformed_and_unknown_frames_are_dropped);
    RUN(test_removed_ports_receive_nothing);
    RUN(test_limits_and_invalid_ports);
    TEST_MAIN_END();
}
