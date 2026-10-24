/* A network with a gateway and two VMs (a, b), plus helpers to lease
 * addresses and send frames, for the gateway and DNS tests. */
#ifndef NET_TEST_GW_H
#define NET_TEST_GW_H

#include "../Monad/Backend/net/mnd_net_dhcp.h"
#include "net_test_host.h"
#include "test_util.h"

#define GW MND_IP4(10, 77, 0, 1)
#define BCAST MND_IP4(255, 255, 255, 255)

typedef struct {
    test_host h;
    mnd_net *net;
    int n;
    mnd_mac gw_mac;
    int a, b; /* th_mac(1), th_mac(2) */
    struct {
        int port;
        mnd_mac mac;
    } vms[32];
    int nvms;
} fixture;

/* A VM joins the network; the fixture remembers its MAC. */
static inline int add_vm(fixture *f, mnd_mac mac) {
    int port = mnd_net_add_port(f->net, f->n, mac);
    if (port >= 0 && f->nvms < 32) {
        f->vms[f->nvms].port = port;
        f->vms[f->nvms].mac = mac;
        f->nvms++;
    }
    return port;
}

static inline void setup_cfg(fixture *f, mnd_net_config cfg) {
    mnd_net_host host = th_host(&f->h);
    f->h.now = 1000;
    f->net = mnd_net_create(&host);
    mnd_net_kind kind = cfg.kind;
    f->n = mnd_net_add_network(f->net, &cfg);
    f->nvms = 0;
    f->a = add_vm(f, th_mac(1));
    f->b = add_vm(f, th_mac(2));
    mnd_ip4 ip = 0;
    if (kind != MND_NET_NONE) CHECK(mnd_net_gateway(f->net, f->n, &f->gw_mac, &ip) == 0 && ip == GW);
    CHECK(f->net && f->n >= 0 && f->a >= 0 && f->b >= 0);
}

static inline void setup_kind(fixture *f, mnd_net_kind kind, uint8_t prefix) {
    setup_cfg(f, (mnd_net_config){.kind = kind, .subnet = MND_IP4(10, 77, 0, 0), .prefix = prefix});
}

static inline void setup(fixture *f) { setup_kind(f, MND_NET_NAT, 24); }
static inline void teardown(fixture *f) { mnd_net_destroy(f->net); }

static inline mnd_mac port_mac(fixture *f, int port) {
    for (int i = f->nvms - 1; i >= 0; i--)
        if (f->vms[i].port == port) return f->vms[i].mac;
    return (mnd_mac){{0}};
}

/* ---- Frame helpers ------------------------------------------------------ */

static inline void send_udp(fixture *f, int port, mnd_mac eth_src, mnd_mac eth_dst, mnd_ip4 src, mnd_ip4 dst,
                     uint16_t sport, uint16_t dport, const uint8_t *payload, size_t len) {
    uint8_t buf[MND_FRAME_MAX];
    mnd_ip_hdr_spec h = {.eth_dst = eth_dst, .eth_src = eth_src, .src = src, .dst = dst, .ttl = 64};
    size_t n = mnd_build_udp(buf, sizeof buf, &h, sport, dport, payload, len);
    CHECK(n > 0);
    mnd_net_input(f->net, port, buf, n);
}

/* A DHCP client message from `port` (chaddr = the port's MAC unless set). */
static inline void dhcp_send(fixture *f, int port, mnd_dhcp m, mnd_ip4 src) {
    uint8_t p[600];
    mnd_mac mac = port_mac(f, port);
    m.op = 1;
    if (!m.xid) m.xid = 0xabc;
    if (mnd_mac_eq(m.chaddr, (mnd_mac){{0}})) m.chaddr = mac;
    size_t n = mnd_dhcp_build(p, sizeof p, &m);
    CHECK(n > 0);
    bool unicast = src != 0;
    send_udp(f, port, mac, unicast ? f->gw_mac : MND_MAC_BROADCAST, src, unicast ? GW : BCAST,
             MND_DHCP_CLIENT_PORT, MND_DHCP_SERVER_PORT, p, n);
}

/* The last DHCP reply delivered to `port`. Returns 0 if there is one. */
static inline int dhcp_reply(fixture *f, int port, mnd_dhcp *out, mnd_ip *ip_out) {
    const th_frame *fr = th_last(&f->h, port);
    mnd_eth eth;
    mnd_ip ip;
    mnd_udp udp;
    if (!fr || mnd_eth_parse(fr->data, fr->len, &eth) || eth.type != MND_ETHERTYPE_IPV4) return -1;
    if (mnd_ip_parse(eth.payload, eth.len, &ip) || ip.proto != MND_IPPROTO_UDP) return -1;
    if (mnd_udp_parse(&ip, &udp) || udp.sport != MND_DHCP_SERVER_PORT || udp.dport != MND_DHCP_CLIENT_PORT)
        return -1;
    if (!mnd_mac_eq(eth.src, f->gw_mac) || !mnd_mac_eq(eth.dst, port_mac(f, port)) || ip.src != GW) return -1;
    if (ip_out) *ip_out = ip;
    return mnd_dhcp_parse(udp.payload, udp.len, out);
}

/* DISCOVER → OFFER → REQUEST → ACK. Returns the address, or 0. */
static inline mnd_ip4 lease(fixture *f, int port) {
    mnd_dhcp r;
    th_clear(&f->h);
    dhcp_send(f, port, (mnd_dhcp){.type = MND_DHCP_DISCOVER}, 0);
    if (dhcp_reply(f, port, &r, NULL) || r.type != MND_DHCP_OFFER) return 0;
    mnd_ip4 offered = r.yiaddr;
    th_clear(&f->h);
    dhcp_send(f, port, (mnd_dhcp){.type = MND_DHCP_REQUEST, .requested = offered, .server_id = GW}, 0);
    if (dhcp_reply(f, port, &r, NULL) || r.type != MND_DHCP_ACK || r.yiaddr != offered) return 0;
    th_clear(&f->h);
    return offered;
}

static inline void send_ip(fixture *f, int port, mnd_mac eth_dst, mnd_ip4 src, mnd_ip4 dst) {
    const uint8_t data[4] = {1, 2, 3, 4};
    send_udp(f, port, port_mac(f, port), eth_dst, src, dst, 5000, 5000, data, sizeof data);
}

static inline mnd_net_port_stats stats(fixture *f, int port) {
    mnd_net_port_stats s = {0};
    CHECK(mnd_net_port_stats_get(f->net, port, &s) == 0);
    return s;
}

#endif
