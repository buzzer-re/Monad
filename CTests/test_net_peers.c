/* Tests for VM-to-VM traffic (Phase 13, the canvas's live edges): per
 * sending VM, the VMs it sent unicast frames to, with frames, bytes and
 * when last seen; at most MND_NET_MAX_PEERS per VM, the least recently
 * seen giving way; gone with either VM. Broadcast, frames to no one, and
 * frames a network keeps from other VMs are not counted. */
#include "net_test_gw.h"

static const mnd_net_config SWITCH = {.kind = MND_NET_NONE, .subnet = MND_IP4(10, 77, 0, 0), .prefix = 24};

/* A frame from `from` to `to`'s MAC (60 bytes). */
static void unicast(fixture *f, int from, mnd_mac to) {
    uint8_t buf[64];
    size_t n = th_eth(buf, to, port_mac(f, from), MND_ETHERTYPE_IPV4);
    mnd_net_input(f->net, from, buf, n);
}

static int peers(fixture *f, mnd_net_peer *out, int max) { return mnd_net_peers(f->net, f->n, out, max); }

static const mnd_net_peer *find(const mnd_net_peer *list, int count, int from, int to) {
    for (int i = 0; i < count; i++)
        if (list[i].from == from && list[i].to == to) return &list[i];
    return NULL;
}

static void test_unicast_is_counted_per_sender(void) {
    static fixture f;
    setup_cfg(&f, SWITCH);
    unicast(&f, f.a, th_mac(2));
    f.h.now = 1500;
    unicast(&f, f.a, th_mac(2));
    f.h.now = 2000;
    unicast(&f, f.b, th_mac(1));
    CHECK(th_count(&f.h, f.b) == 2 && th_count(&f.h, f.a) == 1); /* delivered as before */
    mnd_net_peer list[8];
    CHECK(peers(&f, list, 8) == 2);
    const mnd_net_peer *ab = find(list, 2, f.a, f.b), *ba = find(list, 2, f.b, f.a);
    CHECK(ab && ab->frames == 2 && ab->bytes == 120 && ab->last_ms == 1500);
    CHECK(ba && ba->frames == 1 && ba->bytes == 60 && ba->last_ms == 2000);
    /* By sender, then receiver, in port order: the same order page after page. */
    CHECK(list[0].from < list[1].from || (list[0].from == list[1].from && list[0].to < list[1].to));
    teardown(&f);
}

static void test_what_is_not_vm_to_vm_is_not_counted(void) {
    static fixture f;
    setup_cfg(&f, SWITCH);
    uint8_t buf[64];
    size_t n = th_eth(buf, MND_MAC_BROADCAST, th_mac(1), MND_ETHERTYPE_ARP);
    mnd_net_input(f.net, f.a, buf, n);      /* broadcast */
    unicast(&f, f.a, th_mac(50));           /* to no one */
    n = th_eth(buf, th_mac(2), th_mac(7), MND_ETHERTYPE_IPV4);
    mnd_net_input(f.net, f.a, buf, n);      /* spoofed */
    mnd_net_peer list[4];
    CHECK(peers(&f, list, 4) == 0);
    teardown(&f);
    /* A network that keeps its VMs apart counts nothing between them. */
    setup_cfg(&f, (mnd_net_config){.kind = MND_NET_NAT, .subnet = MND_IP4(10, 77, 0, 0), .prefix = 24, .isolated = true});
    mnd_ip4 a_ip = lease(&f, f.a), b_ip = lease(&f, f.b);
    CHECK(a_ip && b_ip);
    send_ip(&f, f.a, th_mac(2), a_ip, b_ip);
    CHECK(th_count(&f.h, f.b) == 0);
    CHECK(peers(&f, list, 4) == 0);
    teardown(&f);
}

/* On a NAT network whose VMs may reach each other, their traffic counts;
 * what goes to the gateway does not. */
static void test_a_nat_network_counts_its_vms_traffic(void) {
    static fixture f;
    setup(&f);
    mnd_ip4 a_ip = lease(&f, f.a), b_ip = lease(&f, f.b);
    CHECK(a_ip && b_ip);
    mnd_net_peer list[4];
    CHECK(peers(&f, list, 4) == 0); /* DHCP with the gateway is not VM to VM */
    send_ip(&f, f.a, th_mac(2), a_ip, b_ip);
    CHECK(th_count(&f.h, f.b) == 1);
    CHECK(peers(&f, list, 4) == 1 && list[0].from == f.a && list[0].to == f.b && list[0].frames == 1);
    teardown(&f);
}

static void test_each_vm_keeps_its_most_recent_peers(void) {
    static fixture f;
    setup_cfg(&f, SWITCH);
    int others[MND_NET_MAX_PEERS + 1];
    for (int i = 0; i <= MND_NET_MAX_PEERS; i++) {
        others[i] = add_vm(&f, th_mac((uint8_t)(10 + i)));
        CHECK(others[i] >= 0);
    }
    for (int i = 0; i < MND_NET_MAX_PEERS; i++) {
        f.h.now = 2000 + (uint64_t)i;
        unicast(&f, f.a, th_mac((uint8_t)(10 + i)));
    }
    f.h.now = 3000;
    unicast(&f, f.a, th_mac(10)); /* the first is recent again */
    f.h.now = 3001;
    unicast(&f, f.a, th_mac((uint8_t)(10 + MND_NET_MAX_PEERS))); /* one more than fits */
    static mnd_net_peer list[64];
    int count = peers(&f, list, 64);
    CHECK(count == MND_NET_MAX_PEERS);
    CHECK(find(list, count, f.a, others[0]) && find(list, count, f.a, others[MND_NET_MAX_PEERS]));
    CHECK(!find(list, count, f.a, others[1])); /* the least recently seen gave way */
    /* Delivery never depended on the table. */
    CHECK(th_count(&f.h, others[1]) == 1);
    teardown(&f);
}

static void test_peers_go_with_either_vm(void) {
    static fixture f;
    setup_cfg(&f, SWITCH);
    int c = add_vm(&f, th_mac(3));
    unicast(&f, f.a, th_mac(2));
    unicast(&f, f.b, th_mac(1));
    unicast(&f, f.a, th_mac(3));
    unicast(&f, c, th_mac(2));
    mnd_net_peer list[8];
    CHECK(peers(&f, list, 8) == 4);
    mnd_net_remove_port(f.net, f.b);
    int count = peers(&f, list, 8);
    CHECK(count == 1 && find(list, count, f.a, c));
    /* A VM taking the slot starts with nothing, and nothing points at it. */
    int d = add_vm(&f, th_mac(9));
    CHECK(d >= 0);
    count = peers(&f, list, 8);
    CHECK(count == 1 && !find(list, count, f.a, d) && !find(list, count, d, f.a));
    teardown(&f);
}

static void test_bounds_and_unknown_networks(void) {
    static fixture f;
    setup_cfg(&f, SWITCH);
    mnd_net_peer list[2];
    CHECK(mnd_net_peers(f.net, 99, list, 2) == -1);
    CHECK(mnd_net_peers(f.net, -1, list, 2) == -1);
    CHECK(mnd_net_peers(NULL, f.n, list, 2) == -1);
    CHECK(peers(&f, list, 2) == 0);
    unicast(&f, f.a, th_mac(2));
    unicast(&f, f.b, th_mac(1));
    CHECK(peers(&f, list, 1) == 1); /* no more than asked for */
    CHECK(peers(&f, NULL, 0) == 0);
    teardown(&f);
}

int main(void) {
    fprintf(stderr, "mnd_net VM-to-VM traffic tests\n");
    RUN(test_unicast_is_counted_per_sender);
    RUN(test_what_is_not_vm_to_vm_is_not_counted);
    RUN(test_a_nat_network_counts_its_vms_traffic);
    RUN(test_each_vm_keeps_its_most_recent_peers);
    RUN(test_peers_go_with_either_vm);
    RUN(test_bounds_and_unknown_networks);
    TEST_MAIN_END();
}
