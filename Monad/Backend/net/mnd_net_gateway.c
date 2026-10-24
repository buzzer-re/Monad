/*
 * mnd_net_gateway.c — each network's gateway: ARP and ICMP echo for its
 * own address, the DHCP server, and the address rules of mnd_net.h.
 *
 * Work per frame is bounded by the fixed tables (leases, reservations);
 * picking an address is one pass over them, never a scan per address.
 */
#include "mnd_net_dhcp.h"
#include "mnd_net_internal.h"

#include <string.h>

#define OFFER_HOLD_MS 60000u
/* Declined addresses held out of the pool at once, per network: a guest
 * looping REQUEST/DECLINE cannot drain the pool. */
#define MAX_DECLINED 8
#define BCAST_ALL 0xffffffffu

static const mnd_mac ZERO_MAC;

bool mnd_net_gateway_mac_range(mnd_mac m) {
    return m.b[0] == 0x02 && m.b[1] == 0x4d && m.b[2] == 0x4e && m.b[3] == 0x47 && m.b[4] == 0x00;
}

void mnd_net_gateway_init(mnd_net_network *nw, int id) {
    nw->gw_mac = (mnd_mac){{0x02, 0x4d, 0x4e, 0x47, 0x00, (uint8_t)id}};
    nw->mask = ~((1u << (32 - nw->cfg.prefix)) - 1);
    nw->gw_ip = nw->cfg.subnet + 1;
    nw->bcast = nw->cfg.subnet | ~nw->mask;
    nw->pool_first = nw->cfg.subnet + 2;
    nw->pool_last = nw->bcast - 1;
    if (nw->pool_last - nw->pool_first >= MND_NET_MAX_LEASES) nw->pool_last = nw->pool_first + MND_NET_MAX_LEASES - 1;
}

static uint64_t now_ms(const mnd_net *net) { return net->host.now_ms(net->host.ctx); }
static uint64_t lease_ms(const mnd_net_network *nw) { return (uint64_t)nw->cfg.lease_secs * 1000; }

/* ---- Leases and reservations ------------------------------------------- */

static bool active(const mnd_lease *l, uint64_t now) { return l->state != MND_LEASE_FREE && now < l->expires_ms; }

static mnd_lease *by_ip(mnd_net_network *nw, mnd_ip4 ip) {
    for (int i = 0; i < MND_NET_MAX_LEASES; i++)
        if (nw->leases[i].state != MND_LEASE_FREE && nw->leases[i].ip == ip) return &nw->leases[i];
    return NULL;
}

/* The MAC's active offer or lease. */
static mnd_lease *by_mac(mnd_net_network *nw, mnd_mac mac, uint64_t now) {
    for (int i = 0; i < MND_NET_MAX_LEASES; i++) {
        mnd_lease *l = &nw->leases[i];
        if ((l->state == MND_LEASE_OFFERED || l->state == MND_LEASE_BOUND) && active(l, now) && mnd_mac_eq(l->mac, mac))
            return l;
    }
    return NULL;
}

static mnd_lease *bound(mnd_net_network *nw, mnd_mac mac, uint64_t now) {
    mnd_lease *l = by_mac(nw, mac, now);
    return l && l->state == MND_LEASE_BOUND ? l : NULL;
}

static const mnd_reservation *reservation_for_mac(const mnd_net_network *nw, mnd_mac mac) {
    for (int i = 0; i < nw->nreservations; i++)
        if (mnd_mac_eq(nw->reservations[i].mac, mac)) return &nw->reservations[i];
    return NULL;
}

static const mnd_reservation *reservation_for_ip(const mnd_net_network *nw, mnd_ip4 ip) {
    for (int i = 0; i < nw->nreservations; i++)
        if (nw->reservations[i].ip == ip) return &nw->reservations[i];
    return NULL;
}

static bool is_host(const mnd_net_network *nw, mnd_ip4 ip) {
    return (ip & nw->mask) == nw->cfg.subnet && ip != nw->cfg.subnet && ip != nw->bcast && ip != nw->gw_ip;
}

/* Whether `mac` may hold `ip`: a host address nobody else holds or has
 * reserved, and the MAC holds or is reserved no other address. */
static bool available(mnd_net_network *nw, mnd_ip4 ip, mnd_mac mac, uint64_t now) {
    if (!is_host(nw, ip)) return false;
    const mnd_reservation *r = reservation_for_ip(nw, ip);
    if (r && !mnd_mac_eq(r->mac, mac)) return false;
    r = reservation_for_mac(nw, mac);
    if (r && r->ip != ip) return false;
    const mnd_lease *l = by_ip(nw, ip);
    if (l && active(l, now) && (l->state == MND_LEASE_DECLINED || !mnd_mac_eq(l->mac, mac))) return false;
    const mnd_lease *own = by_mac(nw, mac, now);
    return !own || own->ip == ip;
}

/* Records `ip` for `mac`, dropping the MAC's other records. NULL if the
 * table is full of active records. */
static mnd_lease *take(mnd_net_network *nw, mnd_ip4 ip, mnd_mac mac, mnd_lease_state state, uint64_t expires,
                       uint64_t now) {
    for (int i = 0; i < MND_NET_MAX_LEASES; i++) {
        mnd_lease *l = &nw->leases[i];
        if (l->state != MND_LEASE_FREE && l->state != MND_LEASE_DECLINED && l->ip != ip && mnd_mac_eq(l->mac, mac))
            l->state = MND_LEASE_FREE;
    }
    mnd_lease *slot = by_ip(nw, ip);
    for (int i = 0; !slot && i < MND_NET_MAX_LEASES; i++)
        if (nw->leases[i].state == MND_LEASE_FREE) slot = &nw->leases[i];
    for (int i = 0; !slot && i < MND_NET_MAX_LEASES; i++)
        if (!active(&nw->leases[i], now)) slot = &nw->leases[i];
    if (!slot) return NULL;
    slot->state = state;
    slot->adopted = false;
    slot->mac = mac;
    slot->ip = ip;
    slot->expires_ms = expires;
    return slot;
}

/* The address to offer `mac`, or 0 if the pool is exhausted. */
static mnd_ip4 pick(mnd_net_network *nw, mnd_mac mac, uint64_t now) {
    const mnd_reservation *r = reservation_for_mac(nw, mac);
    if (r) return available(nw, r->ip, mac, now) ? r->ip : 0;
    const mnd_lease *own = by_mac(nw, mac, now);
    if (own) return own->ip;
    /* The address this VM had before, if it is still free. */
    for (int i = 0; i < MND_NET_MAX_LEASES; i++) {
        const mnd_lease *l = &nw->leases[i];
        if ((l->state == MND_LEASE_OFFERED || l->state == MND_LEASE_BOUND) && mnd_mac_eq(l->mac, mac) &&
            available(nw, l->ip, mac, now))
            return l->ip;
    }
    uint8_t busy[MND_NET_MAX_LEASES / 8] = {0};
    uint32_t size = nw->pool_last - nw->pool_first + 1;
    for (int i = 0; i < MND_NET_MAX_LEASES + MND_NET_MAX_RESERVATIONS; i++) {
        mnd_ip4 ip;
        if (i < MND_NET_MAX_LEASES) {
            if (!active(&nw->leases[i], now)) continue;
            ip = nw->leases[i].ip;
        } else {
            if (i - MND_NET_MAX_LEASES >= nw->nreservations) break;
            ip = nw->reservations[i - MND_NET_MAX_LEASES].ip;
        }
        if (ip < nw->pool_first || ip > nw->pool_last) continue;
        uint32_t off = ip - nw->pool_first;
        busy[off / 8] |= (uint8_t)(1u << (off % 8));
    }
    for (uint32_t off = 0; off < size; off++)
        if (!(busy[off / 8] & (1u << (off % 8)))) return nw->pool_first + off;
    return 0;
}

/* Whether the port may send from `src`. A port without a lease takes a
 * free address; one taken this way is kept alive by traffic. */
static bool source_ok(mnd_net *net, mnd_net_network *nw, mnd_net_port *p, mnd_ip4 src) {
    if (src == 0) return false;
    uint64_t now = now_ms(net);
    mnd_lease *l = bound(nw, p->mac, now);
    if (l) {
        if (l->ip != src) return false;
        if (l->adopted) l->expires_ms = now + lease_ms(nw);
        return true;
    }
    if (!available(nw, src, p->mac, now)) return false;
    l = take(nw, src, p->mac, MND_LEASE_BOUND, now + lease_ms(nw), now);
    if (!l) return false;
    l->adopted = true;
    return true;
}

int mnd_net_reserve(mnd_net *net, int network, mnd_mac mac, mnd_ip4 ip) {
    if (!net || network < 0 || network >= MND_NET_MAX_NETWORKS) return -1;
    mnd_net_network *nw = &net->networks[network];
    if (!nw->used || nw->cfg.kind == MND_NET_NONE) return -1;
    if (mnd_mac_is_multicast(mac) || mnd_mac_eq(mac, ZERO_MAC) || mnd_net_gateway_mac_range(mac)) return -1;
    if (!is_host(nw, ip) || nw->nreservations >= MND_NET_MAX_RESERVATIONS) return -1;
    if (reservation_for_mac(nw, mac) || reservation_for_ip(nw, ip)) return -1;
    const mnd_lease *l = by_ip(nw, ip);
    if (l && active(l, now_ms(net)) && !mnd_mac_eq(l->mac, mac)) return -1;
    nw->reservations[nw->nreservations++] = (mnd_reservation){.mac = mac, .ip = ip};
    return 0;
}

int mnd_net_port_ip(const mnd_net *net, int port, mnd_ip4 *out) {
    if (!net || !out || port < 0 || port >= MND_NET_PORT_SLOTS || !net->ports[port].used) return -1;
    /* Lookups do not modify; the cast keeps one set of helpers. */
    mnd_net_network *nw = (mnd_net_network *)&net->networks[net->ports[port].network];
    if (nw->cfg.kind == MND_NET_NONE) return -1;
    const mnd_lease *l = bound(nw, net->ports[port].mac, now_ms(net));
    if (!l) return -1;
    *out = l->ip;
    return 0;
}

void mnd_net_send_icmp_error(mnd_net *net, const mnd_net_network *nw, int port, uint8_t type, uint8_t code,
                             const mnd_ip *ip) {
    /* RFC 792: the original header and the first 8 bytes of its payload. */
    uint8_t quote[60 + 8];
    size_t extra = ip->len < 8 ? ip->len : 8;
    memcpy(quote, ip->header, ip->header_len);
    memcpy(quote + ip->header_len, ip->payload, extra);
    uint8_t frame[MND_FRAME_MAX];
    mnd_ip_hdr_spec h = {.eth_dst = net->ports[port].mac, .eth_src = nw->gw_mac, .src = nw->gw_ip, .dst = ip->src,
                         .ttl = 64, .id = net->ip_id++};
    size_t n = mnd_build_icmp(frame, sizeof frame, &h, type, code, 0, 0, quote, ip->header_len + extra);
    if (n) mnd_net_deliver(net, port, frame, n);
}

/* ---- DHCP ------------------------------------------------------------------ */

void mnd_net_send_udp(mnd_net *net, const mnd_net_network *nw, int port, mnd_ip4 src, uint16_t sport, mnd_ip4 dst,
                      uint16_t dport, const uint8_t *payload, size_t len) {
    uint8_t frame[MND_FRAME_MAX];
    mnd_ip_hdr_spec h = {.eth_dst = net->ports[port].mac, .eth_src = nw->gw_mac, .src = src, .dst = dst, .ttl = 64,
                         .id = net->ip_id++};
    size_t n = mnd_build_udp(frame, sizeof frame, &h, sport, dport, payload, len);
    if (n) mnd_net_deliver(net, port, frame, n);
}

static void dhcp_reply(mnd_net *net, const mnd_net_network *nw, int id, const mnd_dhcp *req, uint8_t type,
                       mnd_ip4 yiaddr, bool with_lease) {
    mnd_dhcp r = {0};
    r.op = 2;
    r.xid = req->xid;
    r.flags = req->flags;
    r.chaddr = req->chaddr;
    r.type = type;
    r.server_id = nw->gw_ip;
    mnd_ip4 dst = BCAST_ALL;
    if (type != MND_DHCP_NAK) {
        r.ciaddr = req->ciaddr;
        r.yiaddr = yiaddr;
        r.subnet_mask = nw->mask;
        r.broadcast = nw->bcast;
        if (nw->cfg.kind == MND_NET_HOST_ONLY || nw->cfg.kind == MND_NET_NAT) {
            r.router = nw->gw_ip;
            r.dns = nw->gw_ip;
        }
        if (with_lease) {
            r.lease_secs = nw->cfg.lease_secs;
            r.t1 = nw->cfg.lease_secs / 2;
            r.t2 = (uint32_t)((uint64_t)nw->cfg.lease_secs * 7 / 8);
        }
        if (req->ciaddr) dst = req->ciaddr;
        else if (!(req->flags & MND_DHCP_FLAG_BROADCAST)) dst = yiaddr;
    }
    uint8_t payload[576];
    size_t n = mnd_dhcp_build(payload, sizeof payload, &r);
    if (n) mnd_net_send_udp(net, nw, id, nw->gw_ip, MND_DHCP_SERVER_PORT, dst, MND_DHCP_CLIENT_PORT, payload, n);
}

static int declined_count(const mnd_net_network *nw, uint64_t now) {
    int n = 0;
    for (int i = 0; i < MND_NET_MAX_LEASES; i++)
        if (nw->leases[i].state == MND_LEASE_DECLINED && active(&nw->leases[i], now)) n++;
    return n;
}

static void dhcp_input(mnd_net *net, mnd_net_network *nw, int id, const mnd_ip *ip) {
    mnd_net_port *p = &net->ports[id];
    mnd_udp udp;
    mnd_dhcp m;
    if (mnd_udp_parse(ip, &udp) != 0 || mnd_dhcp_parse(udp.payload, udp.len, &m) != 0 || m.op != 1 || !m.type) {
        p->stats.dropped_malformed++;
        return;
    }
    if (!mnd_mac_eq(m.chaddr, p->mac) || (ip->src != 0 && !source_ok(net, nw, p, ip->src))) {
        p->stats.dropped_spoofed++;
        return;
    }
    uint64_t now = now_ms(net);
    switch (m.type) {
    case MND_DHCP_DISCOVER: {
        mnd_ip4 a = pick(nw, p->mac, now);
        if (!a) return;
        const mnd_lease *held = bound(nw, p->mac, now);
        if (!(held && held->ip == a) && !take(nw, a, p->mac, MND_LEASE_OFFERED, now + OFFER_HOLD_MS, now)) return;
        dhcp_reply(net, nw, id, &m, MND_DHCP_OFFER, a, true);
        return;
    }
    case MND_DHCP_REQUEST: {
        if (m.server_id && m.server_id != nw->gw_ip) {
            /* The client took another server's offer: withdraw ours. */
            mnd_lease *l = by_mac(nw, p->mac, now);
            if (l && l->state == MND_LEASE_OFFERED) l->state = MND_LEASE_FREE;
            return;
        }
        mnd_ip4 a = m.requested ? m.requested : m.ciaddr;
        if (!a || !available(nw, a, p->mac, now) || !take(nw, a, p->mac, MND_LEASE_BOUND, now + lease_ms(nw), now)) {
            dhcp_reply(net, nw, id, &m, MND_DHCP_NAK, 0, false);
            return;
        }
        dhcp_reply(net, nw, id, &m, MND_DHCP_ACK, a, true);
        return;
    }
    case MND_DHCP_DECLINE: {
        mnd_lease *l = by_ip(nw, m.requested);
        if (!l || !active(l, now) || l->state == MND_LEASE_DECLINED || !mnd_mac_eq(l->mac, p->mac)) return;
        if (declined_count(nw, now) >= MAX_DECLINED) {
            l->state = MND_LEASE_FREE;
            return;
        }
        l->state = MND_LEASE_DECLINED;
        l->adopted = false;
        l->mac = ZERO_MAC;
        l->expires_ms = now + lease_ms(nw);
        return;
    }
    case MND_DHCP_RELEASE: {
        mnd_lease *l = by_ip(nw, m.ciaddr);
        if (l && l->state != MND_LEASE_DECLINED && mnd_mac_eq(l->mac, p->mac)) l->state = MND_LEASE_FREE;
        return;
    }
    case MND_DHCP_INFORM:
        if (m.ciaddr && m.ciaddr == ip->src) dhcp_reply(net, nw, id, &m, MND_DHCP_ACK, 0, false);
        return;
    default: /* server messages sent by a client */
        p->stats.dropped_policy++;
        return;
    }
}

/* ---- ARP, ICMP, dispatch ---------------------------------------------------- */

static void arp_input(mnd_net *net, mnd_net_network *nw, int id, const mnd_eth *eth, const uint8_t *frame,
                      size_t len) {
    mnd_net_port *p = &net->ports[id];
    mnd_arp a;
    if (mnd_arp_parse(eth->payload, eth->len, &a) != 0) {
        p->stats.dropped_malformed++;
        return;
    }
    /* spa 0.0.0.0 is an address probe (RFC 5227). */
    if (!mnd_mac_eq(a.sha, p->mac) || (a.spa != 0 && !source_ok(net, nw, p, a.spa))) {
        p->stats.dropped_spoofed++;
        return;
    }
    if (a.op == 1 && a.tpa == nw->gw_ip) {
        uint8_t reply[64];
        size_t n = mnd_build_arp(reply, sizeof reply, 2, p->mac, nw->gw_mac, nw->gw_ip, a.sha, a.spa);
        if (n) mnd_net_deliver(net, id, reply, n);
    }
    if (!mnd_mac_eq(eth->dst, nw->gw_mac)) mnd_net_switch(net, id, eth, frame, len);
}

static uint16_t rd16(const uint8_t *b) { return (uint16_t)(b[0] << 8 | b[1]); }

/* A packet for the gateway's MAC. */
static void gateway_local(mnd_net *net, mnd_net_network *nw, int id, const mnd_ip *ip) {
    mnd_net_port *p = &net->ports[id];
    if (ip->dst == nw->gw_ip && ip->proto == MND_IPPROTO_UDP && ip->len >= 8 && rd16(ip->payload + 2) == MND_DNS_PORT) {
        mnd_net_dns_input(net, nw, id, ip);
        return;
    }
    if (ip->dst != nw->gw_ip) {
        mnd_net_route(net, nw, id, ip);
        return;
    }
    if (ip->proto != MND_IPPROTO_ICMP) {
        p->stats.dropped_policy++;
        return;
    }
    mnd_icmp icmp;
    if (mnd_icmp_parse(ip, &icmp) != 0) {
        p->stats.dropped_malformed++;
        return;
    }
    if (icmp.type != 8 || icmp.code != 0) {
        p->stats.dropped_policy++;
        return;
    }
    uint8_t frame[MND_FRAME_MAX];
    mnd_ip_hdr_spec h = {.eth_dst = p->mac, .eth_src = nw->gw_mac, .src = nw->gw_ip, .dst = ip->src, .ttl = 64,
                         .id = net->ip_id++};
    size_t n = mnd_build_icmp(frame, sizeof frame, &h, 0, 0, icmp.id, icmp.seq, icmp.data, icmp.len);
    if (n) mnd_net_deliver(net, id, frame, n);
}

static void ip_input(mnd_net *net, mnd_net_network *nw, int id, const mnd_eth *eth, const uint8_t *frame,
                     size_t len) {
    mnd_net_port *p = &net->ports[id];
    mnd_ip ip;
    if (mnd_ip_parse(eth->payload, eth->len, &ip) != 0) {
        p->stats.dropped_malformed++;
        return;
    }
    /* DHCP goes to the gateway alone. Only the ports are read here: traffic
     * between VMs is checked by the VMs (the switch only finishes offloaded
     * checksums). */
    if (ip.proto == MND_IPPROTO_UDP && ip.len >= 8) {
        uint16_t sport = rd16(ip.payload), dport = rd16(ip.payload + 2);
        if (sport == MND_DHCP_SERVER_PORT) {
            p->stats.dropped_policy++;
            return;
        }
        if (dport == MND_DHCP_SERVER_PORT) {
            if (sport == MND_DHCP_CLIENT_PORT) dhcp_input(net, nw, id, &ip);
            else p->stats.dropped_policy++;
            return;
        }
    }
    if (!source_ok(net, nw, p, ip.src)) {
        p->stats.dropped_spoofed++;
        return;
    }
    if (mnd_mac_eq(eth->dst, nw->gw_mac)) gateway_local(net, nw, id, &ip);
    else mnd_net_switch(net, id, eth, frame, len);
}

void mnd_net_gateway_input(mnd_net *net, int id, const mnd_eth *eth, const uint8_t *frame, size_t len) {
    mnd_net_network *nw = &net->networks[net->ports[id].network];
    if (eth->type == MND_ETHERTYPE_ARP) arp_input(net, nw, id, eth, frame, len);
    else if (eth->type == MND_ETHERTYPE_IPV4) ip_input(net, nw, id, eth, frame, len);
    else net->ports[id].stats.dropped_policy++;
}
