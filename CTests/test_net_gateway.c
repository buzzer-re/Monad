/* Tests for each network's gateway: ARP, ICMP echo, DHCP leases, and the
 * rules that keep one VM from taking another's address. */
#include "net_test_dns.h"
#include "net_test_gw.h"

/* ---- Tests ---------------------------------------------------------------- */

static void test_gateway_addresses(void) {
    static fixture f;
    setup(&f);
    mnd_mac expected = {{0x02, 0x4d, 0x4e, 0x47, 0x00, (uint8_t)f.n}};
    CHECK(mnd_mac_eq(f.gw_mac, expected));
    CHECK(mnd_net_add_port(f.net, f.n, f.gw_mac) == -1); /* the gateway range is not for VMs */
    mnd_net_config none = {.kind = MND_NET_NONE, .subnet = MND_IP4(10, 78, 0, 0), .prefix = 24};
    int plain = mnd_net_add_network(f.net, &none);
    mnd_mac m;
    mnd_ip4 ip;
    CHECK(mnd_net_gateway(f.net, plain, &m, &ip) == -1);
    CHECK(mnd_net_gateway(f.net, 31, &m, &ip) == -1);
    teardown(&f);
}

static void test_arp_for_the_gateway(void) {
    static fixture f;
    setup(&f);
    uint8_t buf[64];
    size_t n = mnd_build_arp(buf, sizeof buf, 1, MND_MAC_BROADCAST, th_mac(1), 0, (mnd_mac){{0}}, GW);
    mnd_net_input(f.net, f.a, buf, n);
    CHECK(th_count(&f.h, f.a) == 1);
    CHECK(th_count(&f.h, f.b) == 1); /* an ARP request is an ordinary broadcast */
    mnd_eth eth;
    mnd_arp arp;
    const th_frame *r = th_last(&f.h, f.a);
    CHECK(r && mnd_eth_parse(r->data, r->len, &eth) == 0 && eth.type == MND_ETHERTYPE_ARP);
    CHECK(mnd_mac_eq(eth.dst, th_mac(1)) && mnd_mac_eq(eth.src, f.gw_mac));
    CHECK(mnd_arp_parse(eth.payload, eth.len, &arp) == 0 && arp.op == 2);
    CHECK(mnd_mac_eq(arp.sha, f.gw_mac) && arp.spa == GW && mnd_mac_eq(arp.tha, th_mac(1)) && arp.tpa == 0);

    /* Asking for someone else: the gateway stays quiet. */
    th_clear(&f.h);
    n = mnd_build_arp(buf, sizeof buf, 1, MND_MAC_BROADCAST, th_mac(1), 0, (mnd_mac){{0}}, MND_IP4(10, 77, 0, 9));
    mnd_net_input(f.net, f.a, buf, n);
    CHECK(th_count(&f.h, f.a) == 0 && th_count(&f.h, f.b) == 1);

    /* The sender hardware address must be the port's. */
    th_clear(&f.h);
    n = mnd_build_arp(buf, sizeof buf, 1, MND_MAC_BROADCAST, th_mac(2), 0, (mnd_mac){{0}}, GW);
    buf[6 + 5] = 1; /* Ethernet source a, ARP sender b */
    mnd_net_input(f.net, f.a, buf, n);
    CHECK(f.h.count == 0 && stats(&f, f.a).dropped_spoofed == 1);
    teardown(&f);
}

static void test_no_gateway_on_plain_networks(void) {
    static fixture f;
    setup_kind(&f, MND_NET_NONE, 24);
    uint8_t buf[64];
    size_t n = mnd_build_arp(buf, sizeof buf, 1, MND_MAC_BROADCAST, th_mac(1), 0, (mnd_mac){{0}}, GW);
    mnd_net_input(f.net, f.a, buf, n);
    CHECK(th_count(&f.h, f.a) == 0 && th_count(&f.h, f.b) == 1);
    f.gw_mac = (mnd_mac){{0x02, 0x4d, 0x4e, 0x47, 0x00, (uint8_t)f.n}};
    th_clear(&f.h);
    dhcp_send(&f, f.a, (mnd_dhcp){.type = MND_DHCP_DISCOVER}, 0);
    CHECK(th_count(&f.h, f.a) == 0 && th_count(&f.h, f.b) == 1); /* just a broadcast */
    /* No address rules either: anything goes, IPv6 included. */
    th_clear(&f.h);
    send_ip(&f, f.a, th_mac(2), MND_IP4(192, 168, 9, 9), MND_IP4(10, 77, 0, 3));
    n = th_eth(buf, th_mac(2), th_mac(1), MND_ETHERTYPE_IPV6);
    mnd_net_input(f.net, f.a, buf, n);
    CHECK(th_count(&f.h, f.b) == 2);
    teardown(&f);
}

static void test_dhcp_lease(void) {
    static fixture f;
    setup(&f);
    mnd_dhcp r;
    mnd_ip ip;
    dhcp_send(&f, f.a, (mnd_dhcp){.type = MND_DHCP_DISCOVER, .xid = 0x1234}, 0);
    CHECK(th_count(&f.h, f.b) == 0); /* DHCP never reaches other VMs */
    CHECK(th_count(&f.h, f.a) == 1);
    CHECK(dhcp_reply(&f, f.a, &r, &ip) == 0 && r.op == 2 && r.type == MND_DHCP_OFFER && r.xid == 0x1234);
    CHECK(r.yiaddr == MND_IP4(10, 77, 0, 2) && mnd_mac_eq(r.chaddr, th_mac(1)));
    CHECK(r.server_id == GW && r.router == GW && r.dns == GW);
    CHECK(r.subnet_mask == MND_IP4(255, 255, 255, 0) && r.broadcast == MND_IP4(10, 77, 0, 255));
    CHECK(r.lease_secs == 3600 && r.t1 == 1800 && r.t2 == 3150);
    CHECK(ip.dst == r.yiaddr); /* unicast: the client did not ask for a broadcast */
    mnd_ip4 addr;
    CHECK(mnd_net_port_ip(f.net, f.a, &addr) == -1); /* offered is not leased */

    th_clear(&f.h);
    dhcp_send(&f, f.a, (mnd_dhcp){.type = MND_DHCP_REQUEST, .requested = r.yiaddr, .server_id = GW, .flags = MND_DHCP_FLAG_BROADCAST}, 0);
    CHECK(dhcp_reply(&f, f.a, &r, &ip) == 0 && r.type == MND_DHCP_ACK && r.yiaddr == MND_IP4(10, 77, 0, 2));
    CHECK(ip.dst == BCAST);
    CHECK(mnd_net_port_ip(f.net, f.a, &addr) == 0 && addr == MND_IP4(10, 77, 0, 2));
    CHECK(lease(&f, f.b) == MND_IP4(10, 77, 0, 3));

    /* The same VM asking again gets the same address, also after a restart. */
    CHECK(lease(&f, f.a) == MND_IP4(10, 77, 0, 2));
    mnd_net_remove_port(f.net, f.a);
    f.a = add_vm(&f, th_mac(1));
    CHECK(mnd_net_port_ip(f.net, f.a, &addr) == 0 && addr == MND_IP4(10, 77, 0, 2));
    CHECK(lease(&f, f.a) == MND_IP4(10, 77, 0, 2));
    teardown(&f);
}

static void test_dhcp_options_per_kind(void) {
    static fixture f;
    mnd_dhcp r;
    setup_kind(&f, MND_NET_INTERNAL, 24);
    dhcp_send(&f, f.a, (mnd_dhcp){.type = MND_DHCP_DISCOVER}, 0);
    CHECK(dhcp_reply(&f, f.a, &r, NULL) == 0 && r.type == MND_DHCP_OFFER);
    CHECK(r.router == 0 && r.dns == 0); /* nothing leaves an internal network */
    CHECK(r.subnet_mask == MND_IP4(255, 255, 255, 0));
    teardown(&f);
    setup_kind(&f, MND_NET_HOST_ONLY, 24);
    dhcp_send(&f, f.a, (mnd_dhcp){.type = MND_DHCP_DISCOVER}, 0);
    CHECK(dhcp_reply(&f, f.a, &r, NULL) == 0 && r.router == GW && r.dns == GW);
    teardown(&f);
}

static void test_dhcp_requests_that_are_refused(void) {
    static fixture f;
    setup(&f);
    mnd_dhcp r;
    mnd_ip ip;
    /* Someone else's address. */
    CHECK(lease(&f, f.b) == MND_IP4(10, 77, 0, 2));
    dhcp_send(&f, f.a, (mnd_dhcp){.type = MND_DHCP_REQUEST, .requested = MND_IP4(10, 77, 0, 2)}, 0);
    CHECK(dhcp_reply(&f, f.a, &r, &ip) == 0 && r.type == MND_DHCP_NAK && ip.dst == BCAST);
    /* Outside the subnet, and the gateway itself. */
    th_clear(&f.h);
    dhcp_send(&f, f.a, (mnd_dhcp){.type = MND_DHCP_REQUEST, .requested = MND_IP4(192, 168, 1, 5)}, 0);
    CHECK(dhcp_reply(&f, f.a, &r, NULL) == 0 && r.type == MND_DHCP_NAK);
    th_clear(&f.h);
    dhcp_send(&f, f.a, (mnd_dhcp){.type = MND_DHCP_REQUEST, .requested = GW}, 0);
    CHECK(dhcp_reply(&f, f.a, &r, NULL) == 0 && r.type == MND_DHCP_NAK);
    /* A free address asked for directly (INIT-REBOOT) is granted. */
    th_clear(&f.h);
    dhcp_send(&f, f.a, (mnd_dhcp){.type = MND_DHCP_REQUEST, .requested = MND_IP4(10, 77, 0, 40)}, 0);
    CHECK(dhcp_reply(&f, f.a, &r, NULL) == 0 && r.type == MND_DHCP_ACK && r.yiaddr == MND_IP4(10, 77, 0, 40));
    teardown(&f);
}

static void test_dhcp_client_chose_another_server(void) {
    static fixture f;
    setup(&f);
    mnd_dhcp r;
    dhcp_send(&f, f.a, (mnd_dhcp){.type = MND_DHCP_DISCOVER}, 0);
    CHECK(dhcp_reply(&f, f.a, &r, NULL) == 0 && r.yiaddr == MND_IP4(10, 77, 0, 2));
    th_clear(&f.h);
    dhcp_send(&f, f.a, (mnd_dhcp){.type = MND_DHCP_REQUEST, .requested = r.yiaddr, .server_id = MND_IP4(10, 77, 0, 99)}, 0);
    CHECK(f.h.count == 0);
    CHECK(lease(&f, f.b) == MND_IP4(10, 77, 0, 2)); /* the offer was withdrawn */
    teardown(&f);
}

static void test_dhcp_renew_and_expiry(void) {
    static fixture f;
    setup(&f);
    mnd_dhcp r;
    mnd_ip ip;
    mnd_ip4 a_ip = lease(&f, f.a);
    CHECK(a_ip == MND_IP4(10, 77, 0, 2));
    /* Renewal at T1, unicast from the leased address. */
    f.h.now += 1800 * 1000;
    dhcp_send(&f, f.a, (mnd_dhcp){.type = MND_DHCP_REQUEST, .ciaddr = a_ip}, a_ip);
    CHECK(dhcp_reply(&f, f.a, &r, &ip) == 0 && r.type == MND_DHCP_ACK && r.yiaddr == a_ip && ip.dst == a_ip);
    f.h.now += 3000 * 1000; /* past the first lease, within the renewed one */
    mnd_ip4 addr;
    CHECK(mnd_net_port_ip(f.net, f.a, &addr) == 0 && addr == a_ip);
    /* Renewing an address the client does not hold is refused. */
    th_clear(&f.h);
    dhcp_send(&f, f.a, (mnd_dhcp){.type = MND_DHCP_REQUEST, .ciaddr = MND_IP4(10, 77, 0, 7)}, 0);
    CHECK(dhcp_reply(&f, f.a, &r, NULL) == 0 && r.type == MND_DHCP_NAK);
    /* Expiry: the address is gone and traffic from it no longer passes. */
    f.h.now += 3600 * 1000;
    CHECK(mnd_net_port_ip(f.net, f.a, &addr) == -1);
    CHECK(lease(&f, f.b) == MND_IP4(10, 77, 0, 2)); /* free again */
    th_clear(&f.h);
    send_ip(&f, f.a, th_mac(2), a_ip, MND_IP4(10, 77, 0, 3));
    CHECK(f.h.count == 0 && stats(&f, f.a).dropped_spoofed == 1);
    teardown(&f);
}

static void test_dhcp_release_decline_inform(void) {
    static fixture f;
    setup(&f);
    mnd_dhcp r;
    mnd_ip4 a_ip = lease(&f, f.a);
    dhcp_send(&f, f.a, (mnd_dhcp){.type = MND_DHCP_RELEASE, .ciaddr = a_ip, .server_id = GW}, a_ip);
    CHECK(f.h.count == 0); /* RELEASE has no answer */
    mnd_ip4 addr;
    CHECK(mnd_net_port_ip(f.net, f.a, &addr) == -1);
    /* Declined (someone answered ARP for it): not offered to anyone for a while. */
    CHECK(lease(&f, f.b) == MND_IP4(10, 77, 0, 2));
    dhcp_send(&f, f.b, (mnd_dhcp){.type = MND_DHCP_DECLINE, .requested = MND_IP4(10, 77, 0, 2), .server_id = GW}, 0);
    CHECK(f.h.count == 0);
    CHECK(mnd_net_port_ip(f.net, f.b, &addr) == -1);
    CHECK(lease(&f, f.b) == MND_IP4(10, 77, 0, 3));
    CHECK(lease(&f, f.a) == MND_IP4(10, 77, 0, 4));
    /* INFORM: configuration only, no lease time. */
    dhcp_send(&f, f.a, (mnd_dhcp){.type = MND_DHCP_INFORM, .ciaddr = MND_IP4(10, 77, 0, 4)}, MND_IP4(10, 77, 0, 4));
    CHECK(dhcp_reply(&f, f.a, &r, NULL) == 0 && r.type == MND_DHCP_ACK);
    CHECK(r.yiaddr == 0 && r.lease_secs == 0 && r.router == GW && r.dns == GW);
    teardown(&f);
}

static void test_declines_are_capped(void) {
    static fixture f;
    setup(&f);
    /* A VM looping REQUEST/DECLINE takes at most 8 addresses out of the pool. */
    for (int i = 0; i < 12; i++) {
        mnd_ip4 ip = lease(&f, f.a);
        CHECK(ip != 0);
        dhcp_send(&f, f.a, (mnd_dhcp){.type = MND_DHCP_DECLINE, .requested = ip, .server_id = GW}, 0);
    }
    CHECK(lease(&f, f.b) == MND_IP4(10, 77, 0, 10)); /* .2 to .9 declined */
    teardown(&f);
}

static void test_dhcp_pool_exhaustion(void) {
    static fixture f;
    setup_kind(&f, MND_NET_NAT, 28); /* .2 to .14: 13 addresses */
    int got = 0;
    for (uint8_t i = 1; i <= 13; i++) {
        int port = i == 1 ? f.a : i == 2 ? f.b : add_vm(&f, th_mac(i));
        if (lease(&f, port) == MND_IP4(10, 77, 0, i + 1)) got++;
    }
    CHECK(got == 13);
    int late = add_vm(&f, th_mac(14));
    dhcp_send(&f, late, (mnd_dhcp){.type = MND_DHCP_DISCOVER}, 0);
    CHECK(f.h.count == 0); /* nothing to offer */
    mnd_ip4 addr;
    CHECK(mnd_net_port_ip(f.net, late, &addr) == -1);
    /* Offers are held briefly: an offer nobody takes does not keep an address. */
    th_clear(&f.h);
    dhcp_send(&f, f.a, (mnd_dhcp){.type = MND_DHCP_RELEASE, .ciaddr = MND_IP4(10, 77, 0, 2), .server_id = GW},
              MND_IP4(10, 77, 0, 2));
    int ghost = add_vm(&f, th_mac(15));
    dhcp_send(&f, ghost, (mnd_dhcp){.type = MND_DHCP_DISCOVER}, 0);
    mnd_dhcp r;
    CHECK(dhcp_reply(&f, ghost, &r, NULL) == 0 && r.yiaddr == MND_IP4(10, 77, 0, 2));
    th_clear(&f.h);
    dhcp_send(&f, late, (mnd_dhcp){.type = MND_DHCP_DISCOVER}, 0);
    CHECK(f.h.count == 0); /* held for ghost */
    f.h.now += 61 * 1000;
    CHECK(lease(&f, late) == MND_IP4(10, 77, 0, 2));
    teardown(&f);
}

static void test_ip_source_guard(void) {
    static fixture f;
    setup(&f);
    mnd_ip4 a_ip = lease(&f, f.a);
    mnd_ip4 b_ip = lease(&f, f.b);
    /* From its own address: delivered. */
    send_ip(&f, f.a, th_mac(2), a_ip, b_ip);
    CHECK(th_count(&f.h, f.b) == 1);
    /* From b's address, or any other: dropped. */
    th_clear(&f.h);
    send_ip(&f, f.a, th_mac(2), b_ip, b_ip);
    send_ip(&f, f.a, th_mac(2), MND_IP4(10, 77, 0, 50), b_ip);
    send_ip(&f, f.a, MND_MAC_BROADCAST, MND_IP4(8, 8, 8, 8), BCAST);
    CHECK(f.h.count == 0 && stats(&f, f.a).dropped_spoofed == 3);
    /* A gratuitous ARP claiming b's address. */
    uint8_t buf[64];
    size_t n = mnd_build_arp(buf, sizeof buf, 2, MND_MAC_BROADCAST, th_mac(1), b_ip, MND_MAC_BROADCAST, b_ip);
    mnd_net_input(f.net, f.a, buf, n);
    CHECK(f.h.count == 0 && stats(&f, f.a).dropped_spoofed == 4);
    /* 0.0.0.0 is for DHCP only. */
    send_ip(&f, f.a, th_mac(2), 0, b_ip);
    CHECK(f.h.count == 0 && stats(&f, f.a).dropped_spoofed == 5);
    teardown(&f);
}

/* A network that keeps its VMs apart: each reaches the gateway (ARP, DHCP,
 * the way out) and never another VM, by unicast, ARP or broadcast (F-02). */
static void test_vms_kept_apart(void) {
    static fixture f;
    setup_cfg(&f, (mnd_net_config){.kind = MND_NET_NAT, .subnet = MND_IP4(10, 77, 0, 0), .prefix = 24, .isolated = true});
    mnd_ip4 a_ip = lease(&f, f.a);
    mnd_ip4 b_ip = lease(&f, f.b);
    CHECK(a_ip && b_ip);
    th_clear(&f.h);
    send_ip(&f, f.a, th_mac(2), a_ip, b_ip);
    send_ip(&f, f.a, MND_MAC_BROADCAST, a_ip, BCAST);
    send_ip(&f, f.a, MND_MAC_BROADCAST, a_ip, MND_IP4(10, 77, 0, 255));
    uint8_t buf[64];
    size_t n = mnd_build_arp(buf, sizeof buf, 1, MND_MAC_BROADCAST, th_mac(1), a_ip, (mnd_mac){{0}}, b_ip);
    mnd_net_input(f.net, f.a, buf, n);
    CHECK(th_count(&f.h, f.b) == 0);
    CHECK(stats(&f, f.a).dropped_policy == 4);
    n = mnd_build_arp(buf, sizeof buf, 1, MND_MAC_BROADCAST, th_mac(1), a_ip, (mnd_mac){{0}}, GW);
    mnd_net_input(f.net, f.a, buf, n);
    CHECK(th_count(&f.h, f.a) == 1 && th_count(&f.h, f.b) == 0); /* the gateway answers, b hears nothing */
    teardown(&f);
}

static void test_a_port_without_lease_may_take_one_free_address(void) {
    static fixture f;
    setup(&f);
    mnd_ip4 b_ip = lease(&f, f.b);
    CHECK(mnd_net_reserve(f.net, f.n, th_mac(9), MND_IP4(10, 77, 0, 60)) == 0);
    /* Taken by b, reserved for someone else, the gateway, outside the subnet. */
    send_ip(&f, f.a, th_mac(2), b_ip, b_ip);
    send_ip(&f, f.a, th_mac(2), MND_IP4(10, 77, 0, 60), b_ip);
    send_ip(&f, f.a, th_mac(2), GW, b_ip);
    send_ip(&f, f.a, th_mac(2), MND_IP4(10, 77, 0, 255), b_ip);
    send_ip(&f, f.a, th_mac(2), MND_IP4(10, 78, 0, 5), b_ip);
    CHECK(f.h.count == 0 && stats(&f, f.a).dropped_spoofed == 5);
    mnd_ip4 addr;
    CHECK(mnd_net_port_ip(f.net, f.a, &addr) == -1);
    /* A free address: taken, and from then on the port's only one. */
    send_ip(&f, f.a, th_mac(2), MND_IP4(10, 77, 0, 9), b_ip);
    CHECK(th_count(&f.h, f.b) == 1);
    CHECK(mnd_net_port_ip(f.net, f.a, &addr) == 0 && addr == MND_IP4(10, 77, 0, 9));
    send_ip(&f, f.a, th_mac(2), MND_IP4(10, 77, 0, 10), b_ip);
    CHECK(th_count(&f.h, f.b) == 1);
    /* DHCP agrees: the same VM is offered the address it took. */
    CHECK(lease(&f, f.a) == MND_IP4(10, 77, 0, 9));
    teardown(&f);
}

static void test_reservations(void) {
    static fixture f;
    setup(&f);
    CHECK(mnd_net_reserve(f.net, f.n, th_mac(2), MND_IP4(10, 77, 0, 2)) == 0);
    CHECK(lease(&f, f.a) == MND_IP4(10, 77, 0, 3)); /* .2 is b's */
    CHECK(lease(&f, f.b) == MND_IP4(10, 77, 0, 2));
    /* Invalid: gateway, network, broadcast, outside, taken address, MAC twice. */
    CHECK(mnd_net_reserve(f.net, f.n, th_mac(7), GW) == -1);
    CHECK(mnd_net_reserve(f.net, f.n, th_mac(7), MND_IP4(10, 77, 0, 0)) == -1);
    CHECK(mnd_net_reserve(f.net, f.n, th_mac(7), MND_IP4(10, 77, 0, 255)) == -1);
    CHECK(mnd_net_reserve(f.net, f.n, th_mac(7), MND_IP4(10, 78, 0, 7)) == -1);
    CHECK(mnd_net_reserve(f.net, f.n, th_mac(7), MND_IP4(10, 77, 0, 2)) == -1);
    CHECK(mnd_net_reserve(f.net, f.n, th_mac(7), MND_IP4(10, 77, 0, 3)) == -1); /* leased to a */
    CHECK(mnd_net_reserve(f.net, f.n, th_mac(2), MND_IP4(10, 77, 0, 70)) == -1);
    CHECK(mnd_net_reserve(f.net, f.n, MND_MAC_BROADCAST, MND_IP4(10, 77, 0, 70)) == -1);
    int ok = 1;
    for (int i = 0; i < MND_NET_MAX_RESERVATIONS + 3; i++)
        if (mnd_net_reserve(f.net, f.n, th_mac((uint8_t)(10 + i)), MND_IP4(10, 77, 0, (uint8_t)(100 + i))) == 0) ok++;
    CHECK(ok == MND_NET_MAX_RESERVATIONS);
    teardown(&f);
}

static void test_dhcp_rules(void) {
    static fixture f;
    setup(&f);
    /* A client asking for another MAC (pool exhaustion attack). */
    dhcp_send(&f, f.a, (mnd_dhcp){.type = MND_DHCP_DISCOVER, .chaddr = th_mac(77)}, 0);
    CHECK(f.h.count == 0 && stats(&f, f.a).dropped_spoofed == 1);
    /* A VM playing DHCP server. */
    uint8_t p[600];
    mnd_dhcp offer = {.op = 2, .type = MND_DHCP_OFFER, .chaddr = th_mac(2), .yiaddr = MND_IP4(10, 77, 0, 66)};
    size_t n = mnd_dhcp_build(p, sizeof p, &offer);
    send_udp(&f, f.a, th_mac(1), MND_MAC_BROADCAST, 0, BCAST, MND_DHCP_SERVER_PORT, MND_DHCP_CLIENT_PORT, p, n);
    CHECK(f.h.count == 0 && stats(&f, f.a).dropped_policy == 1);
    /* A reply-shaped message sent to the server port. */
    send_udp(&f, f.a, th_mac(1), MND_MAC_BROADCAST, 0, BCAST, MND_DHCP_CLIENT_PORT, MND_DHCP_SERVER_PORT, p, n);
    CHECK(f.h.count == 0);
    /* Garbage to the server port. */
    send_udp(&f, f.a, th_mac(1), MND_MAC_BROADCAST, 0, BCAST, MND_DHCP_CLIENT_PORT, MND_DHCP_SERVER_PORT, p, 100);
    CHECK(f.h.count == 0 && stats(&f, f.a).dropped_malformed == 2);
    teardown(&f);
}

static void test_icmp_echo(void) {
    static fixture f;
    setup(&f);
    mnd_ip4 a_ip = lease(&f, f.a);
    uint8_t buf[MND_FRAME_MAX], data[56];
    for (size_t i = 0; i < sizeof data; i++) data[i] = (uint8_t)i;
    mnd_ip_hdr_spec h = {.eth_dst = f.gw_mac, .eth_src = th_mac(1), .src = a_ip, .dst = GW, .ttl = 64};
    size_t n = mnd_build_icmp(buf, sizeof buf, &h, 8, 0, 0x77, 5, data, sizeof data);
    mnd_net_input(f.net, f.a, buf, n);
    CHECK(th_count(&f.h, f.a) == 1 && th_count(&f.h, f.b) == 0);
    const th_frame *fr = th_last(&f.h, f.a);
    mnd_eth eth;
    mnd_ip ip;
    mnd_icmp icmp;
    CHECK(fr && mnd_eth_parse(fr->data, fr->len, &eth) == 0 && mnd_mac_eq(eth.dst, th_mac(1)));
    CHECK(mnd_ip_parse(eth.payload, eth.len, &ip) == 0 && ip.src == GW && ip.dst == a_ip);
    CHECK(mnd_icmp_parse(&ip, &icmp) == 0 && icmp.type == 0 && icmp.id == 0x77 && icmp.seq == 5);
    CHECK(icmp.len == sizeof data && memcmp(icmp.data, data, sizeof data) == 0);
    /* Not an echo request: no answer. */
    th_clear(&f.h);
    n = mnd_build_icmp(buf, sizeof buf, &h, 13, 0, 1, 1, NULL, 0);
    mnd_net_input(f.net, f.a, buf, n);
    CHECK(f.h.count == 0);
    teardown(&f);
}

static void test_what_the_gateway_does_not_carry(void) {
    static fixture f;
    setup_kind(&f, MND_NET_HOST_ONLY, 24);
    mnd_ip4 a_ip = lease(&f, f.a);
    lease(&f, f.b);
    uint8_t buf[64];
    size_t n = th_eth(buf, th_mac(2), th_mac(1), MND_ETHERTYPE_IPV6);
    mnd_net_input(f.net, f.a, buf, n);
    n = th_eth(buf, MND_MAC_BROADCAST, th_mac(1), 0x88cc); /* LLDP */
    mnd_net_input(f.net, f.a, buf, n);
    /* Routed through the gateway: host-only networks do not leave. */
    send_ip(&f, f.a, f.gw_mac, a_ip, MND_IP4(1, 1, 1, 1));
    CHECK(f.h.count == 0 && stats(&f, f.a).dropped_policy == 3);
    teardown(&f);
}

/* Guests hand TCP and UDP to their NIC with the checksum left for it to
 * finish (offload). Such frames reach the host sockets and the DNS
 * forwarder, and another VM gets them finished, as a NIC would send them. */
static void test_offloaded_checksums(void) {
    static fixture f;
    setup(&f);
    mnd_ip4 a_ip = lease(&f, f.a), b_ip = lease(&f, f.b);
    uint8_t buf[MND_FRAME_MAX];
    mnd_ip_hdr_spec h = {.eth_dst = f.gw_mac, .eth_src = th_mac(1), .src = a_ip, .ttl = 64};

    h.dst = MND_IP4(1, 1, 1, 1); /* UDP NAT */
    size_t n = mnd_build_udp(buf, sizeof buf, &h, 5000, 123, (const uint8_t *)"ntp", 3);
    th_offload(buf);
    mnd_net_input(f.net, f.a, buf, n);
    CHECK(f.h.udp_opened == 1 && f.h.udp[0].sent == 1);

    uint8_t q[512]; /* DNS to the gateway */
    size_t qn = td_query(q, 7, "example.com", MND_DNS_TYPE_A, 0);
    h.dst = GW;
    n = mnd_build_udp(buf, sizeof buf, &h, 40000, MND_DNS_PORT, q, qn);
    th_offload(buf);
    mnd_net_input(f.net, f.a, buf, n);
    CHECK(f.h.dns_count == 1);

    h.dst = MND_IP4(93, 184, 216, 34); /* TCP */
    mnd_tcp_spec syn = {.sport = 40001, .dport = 443, .seq = 1, .flags = MND_TCP_SYN, .window = 65535,
                        .mss = 1460, .wscale = -1};
    n = mnd_build_tcp(buf, sizeof buf, &h, &syn, NULL, 0);
    th_offload(buf);
    mnd_net_input(f.net, f.a, buf, n);
    CHECK(f.h.ntcp == 1 && f.h.tcp[0].port == 443);

    h.eth_dst = th_mac(2), h.dst = b_ip; /* to another VM: finished on the way */
    th_clear(&f.h);
    n = mnd_build_udp(buf, sizeof buf, &h, 6000, 6000, (const uint8_t *)"hi", 2);
    uint8_t sent[MND_FRAME_MAX];
    memcpy(sent, buf, n);
    th_offload(buf);
    mnd_net_input(f.net, f.a, buf, n);
    CHECK(th_count(&f.h, f.b) == 1 && th_last(&f.h, f.b)->len == n);
    CHECK(memcmp(th_last(&f.h, f.b)->data, sent, n) == 0);
    n = mnd_build_tcp(buf, sizeof buf, &h, &syn, NULL, 0);
    memcpy(sent, buf, n);
    th_offload(buf);
    mnd_net_input(f.net, f.a, buf, n);
    CHECK(th_count(&f.h, f.b) == 2 && memcmp(th_last(&f.h, f.b)->data, sent, n) == 0);
    /* Broadcast too. */
    h.eth_dst = MND_MAC_BROADCAST, h.dst = MND_IP4(10, 77, 0, 255);
    n = mnd_build_udp(buf, sizeof buf, &h, 6000, 6000, (const uint8_t *)"all", 3);
    memcpy(sent, buf, n);
    th_offload(buf);
    mnd_net_input(f.net, f.a, buf, n);
    CHECK(th_count(&f.h, f.b) == 3 && memcmp(th_last(&f.h, f.b)->data, sent, n) == 0);
    CHECK(stats(&f, f.a).dropped_malformed == 0);
    teardown(&f);
}

int main(void) {
    fprintf(stderr, "mnd_net gateway tests\n");
    RUN(test_gateway_addresses);
    RUN(test_arp_for_the_gateway);
    RUN(test_no_gateway_on_plain_networks);
    RUN(test_dhcp_lease);
    RUN(test_dhcp_options_per_kind);
    RUN(test_dhcp_requests_that_are_refused);
    RUN(test_dhcp_client_chose_another_server);
    RUN(test_dhcp_renew_and_expiry);
    RUN(test_dhcp_release_decline_inform);
    RUN(test_declines_are_capped);
    RUN(test_dhcp_pool_exhaustion);
    RUN(test_ip_source_guard);
    RUN(test_a_port_without_lease_may_take_one_free_address);
    RUN(test_reservations);
    RUN(test_dhcp_rules);
    RUN(test_icmp_echo);
    RUN(test_what_the_gateway_does_not_carry);
    RUN(test_offloaded_checksums);
    RUN(test_vms_kept_apart);
    TEST_MAIN_END();
}
