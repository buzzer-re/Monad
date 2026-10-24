/*
 * mnd_net_nat.c — traffic from VMs to the outside on NAT networks.
 *
 * TCP lives in mnd_net_tcp.c.
 *
 * ICMP echo shares the UDP flow table (keyed by the VM's echo identifier).
 *
 * UDP: one host socket per flow (VM address and port, destination address
 * and port), connected, so only the destination can answer. Flows live in
 * a fixed table with a hash index; they expire when idle (mnd_net_poll)
 * and close with their VM. A flow id carries a generation, so an id the
 * host still holds after its flow closed matches nothing.
 */
#include "mnd_net_internal.h"

#include <string.h>

static uint64_t now_ms(const mnd_net *net) { return net->host.now_ms(net->host.ctx); }

/* Addresses no network routes: this network, loopback, link-local,
 * multicast, reserved and broadcast, and the network's own subnet. */
static bool routable(const mnd_net_network *nw, mnd_ip4 ip) {
    uint8_t first = (uint8_t)(ip >> 24);
    if (first == 0 || first == 127 || first >= 224) return false;
    if ((ip & 0xffff0000u) == MND_IP4(169, 254, 0, 0)) return false;
    return (ip & nw->mask) != nw->cfg.subnet;
}

/* ---- UDP flows ------------------------------------------------------------ */

static uint32_t flow_id(const mnd_net *net, int idx) { return (uint32_t)net->udp[idx].gen << 16 | (uint32_t)idx; }

uint32_t mnd_net_flow_hash(int network, mnd_ip4 vm_ip, uint16_t vm_port, mnd_ip4 dst, uint16_t dst_port) {
    uint32_t h = vm_ip * 2654435761u;
    h ^= dst * 2246822519u;
    h ^= ((uint32_t)vm_port << 16 | dst_port) * 3266489917u;
    h ^= (uint32_t)network * 668265263u;
    return h ^ (h >> 15);
}

static uint32_t bucket_of(uint8_t proto, int network, mnd_ip4 vm_ip, uint16_t vm_port, mnd_ip4 dst,
                          uint16_t dst_port) {
    return (mnd_net_flow_hash(network, vm_ip, vm_port, dst, dst_port) ^ proto) % MND_UDP_BUCKETS;
}

static uint32_t bucket_of_flow(const mnd_udp_flow *f) {
    return bucket_of(f->proto, f->network, f->vm_ip, f->vm_port, f->dst, f->dst_port);
}

static int flow_find(const mnd_net *net, uint8_t proto, int port, mnd_ip4 vm_ip, uint16_t vm_port, mnd_ip4 dst,
                     uint16_t dst_port) {
    const mnd_net_port *p = &net->ports[port];
    uint32_t b = bucket_of(proto, p->network, vm_ip, vm_port, dst, dst_port);
    for (uint16_t i = net->udp_bucket[b]; i; i = net->udp[i - 1].next) {
        const mnd_udp_flow *f = &net->udp[i - 1];
        if (f->proto == proto && f->port == port && f->vm_ip == vm_ip && f->vm_port == vm_port && f->dst == dst &&
            f->dst_port == dst_port && f->network == p->network && mnd_mac_eq(f->mac, p->mac))
            return i - 1;
    }
    return -1;
}

static void udp_close(mnd_net *net, int idx) {
    mnd_udp_flow *f = &net->udp[idx];
    if (!f->used) return;
    if (f->proto == MND_IPPROTO_ICMP) {
        if (net->host.icmp_close) net->host.icmp_close(net->host.ctx, flow_id(net, idx));
    } else if (net->host.udp_close) {
        net->host.udp_close(net->host.ctx, flow_id(net, idx));
    }
    mnd_net_conn_closed(net, f->log);
    uint16_t *link = &net->udp_bucket[bucket_of_flow(f)];
    while (*link && *link != idx + 1) link = &net->udp[*link - 1].next;
    if (*link) *link = f->next;
    mnd_net_port *p = &net->ports[f->port];
    if (p->used && mnd_mac_eq(p->mac, f->mac) && p->udp_flows > 0) p->udp_flows--;
    f->used = false;
    f->next = 0;
}

static void udp_touch(mnd_net *net, mnd_udp_flow *f) {
    f->expires_ms = now_ms(net) + (f->replied ? MND_NET_UDP_REPLIED_TIMEOUT_MS : MND_NET_UDP_TIMEOUT_MS);
}

/* The flow for a datagram (`ip`), opened if new and the firewall allows it.
 * Returns its index, or -1. */
static int flow_for(mnd_net *net, int id, uint8_t proto, mnd_ip4 vm_ip, uint16_t vm_port, mnd_ip4 dst,
                    uint16_t dst_port, const mnd_ip *ip) {
    mnd_net_port *p = &net->ports[id];
    int idx = flow_find(net, proto, id, vm_ip, vm_port, dst, dst_port);
    if (idx < 0) {
        uint16_t log = 0;
        mnd_fw_admission a = mnd_net_fw_admit(net, id, proto, dst, dst_port, &log);
        if (a == MND_FW_HOLD) return -1; /* asked about: the VM retries */
        if (a == MND_FW_REFUSE) {
            p->stats.dropped_firewall++;
            mnd_net_send_icmp_error(net, &net->networks[p->network], id, 3, 13, ip); /* administratively prohibited */
            return -1;
        }
        if (p->udp_flows >= MND_NET_MAX_UDP_FLOWS_PER_PORT) {
            p->stats.dropped_policy++;
            return -1;
        }
        for (int i = 0; i < MND_NET_MAX_UDP_FLOWS && idx < 0; i++)
            if (!net->udp[i].used) idx = i;
        if (idx < 0) {
            p->stats.dropped_policy++;
            return -1;
        }
        mnd_udp_flow *f = &net->udp[idx];
        uint16_t gen = (uint16_t)(f->gen + 1);
        *f = (mnd_udp_flow){.used = true, .proto = proto, .gen = gen ? gen : 1, .network = p->network, .port = id,
                            .mac = p->mac, .vm_ip = vm_ip, .dst = dst, .vm_port = vm_port, .dst_port = dst_port};
        int opened = proto == MND_IPPROTO_ICMP ? net->host.icmp_open(net->host.ctx, flow_id(net, idx), dst)
                                               : net->host.udp_open(net->host.ctx, flow_id(net, idx), dst, dst_port);
        if (opened != 0) {
            f->used = false;
            p->stats.dropped_policy++;
            return -1;
        }
        uint32_t b = bucket_of_flow(f);
        f->next = net->udp_bucket[b];
        net->udp_bucket[b] = (uint16_t)(idx + 1);
        p->udp_flows++;
        f->log = log;
        mnd_net_conn_opened(net, log);
    }
    udp_touch(net, &net->udp[idx]);
    return idx;
}

static void udp_out(mnd_net *net, int id, const mnd_ip *ip) {
    mnd_net_port *p = &net->ports[id];
    mnd_udp udp;
    if (mnd_udp_parse(ip, &udp) != 0) {
        p->stats.dropped_malformed++;
        return;
    }
    if (!net->host.udp_open || !net->host.udp_send) {
        p->stats.dropped_policy++;
        return;
    }
    int idx = flow_for(net, id, MND_IPPROTO_UDP, ip->src, udp.sport, ip->dst, udp.dport, ip);
    if (idx < 0) return;
    net->host.udp_send(net->host.ctx, flow_id(net, idx), udp.payload, udp.len);
    mnd_net_conn_bytes(net, net->udp[idx].log, udp.len, 0);
}

static void icmp_out(mnd_net *net, int id, const mnd_ip *ip) {
    mnd_net_port *p = &net->ports[id];
    mnd_icmp icmp;
    if (mnd_icmp_parse(ip, &icmp) != 0) {
        p->stats.dropped_malformed++;
        return;
    }
    if (icmp.type != 8 || icmp.code != 0 || !net->host.icmp_open || !net->host.icmp_send) {
        p->stats.dropped_policy++; /* echo requests only */
        return;
    }
    int idx = flow_for(net, id, MND_IPPROTO_ICMP, ip->src, icmp.id, ip->dst, 0, ip);
    if (idx < 0) return;
    net->host.icmp_send(net->host.ctx, flow_id(net, idx), icmp.seq, icmp.data, icmp.len);
    mnd_net_conn_bytes(net, net->udp[idx].log, icmp.len, 0);
}

/* The live flow for an id from the host, or NULL. */
static mnd_udp_flow *flow_by_id(mnd_net *net, uint32_t flow, uint8_t proto) {
    uint32_t idx = flow & 0xffff;
    if (!net || idx >= MND_NET_MAX_UDP_FLOWS) return NULL;
    mnd_udp_flow *f = &net->udp[idx];
    if (!f->used || f->gen != flow >> 16 || f->proto != proto) return NULL;
    const mnd_net_port *p = &net->ports[f->port];
    if (!p->used || p->network != f->network || !mnd_mac_eq(p->mac, f->mac)) {
        udp_close(net, (int)idx);
        return NULL;
    }
    f->replied = true;
    udp_touch(net, f);
    return f;
}

void mnd_net_udp_input(mnd_net *net, uint32_t flow, const uint8_t *data, size_t len) {
    if (!data && len) return;
    mnd_udp_flow *f = flow_by_id(net, flow, MND_IPPROTO_UDP);
    /* More than one frame holds is dropped by the builder: no fragments. */
    if (!f) return;
    mnd_net_send_udp(net, &net->networks[f->network], f->port, f->dst, f->dst_port, f->vm_ip, f->vm_port, data, len);
    mnd_net_conn_bytes(net, f->log, 0, len);
}

void mnd_net_icmp_input(mnd_net *net, uint32_t flow, uint16_t seq, const uint8_t *data, size_t len) {
    if (!data && len) return;
    mnd_udp_flow *f = flow_by_id(net, flow, MND_IPPROTO_ICMP);
    if (!f) return;
    const mnd_net_network *nw = &net->networks[f->network];
    uint8_t frame[MND_FRAME_MAX];
    mnd_ip_hdr_spec h = {.eth_dst = net->ports[f->port].mac, .eth_src = nw->gw_mac, .src = f->dst, .dst = f->vm_ip,
                         .ttl = 64, .id = net->ip_id++};
    size_t n = mnd_build_icmp(frame, sizeof frame, &h, 0, 0, f->vm_port, seq, data, len);
    if (!n) return;
    mnd_net_deliver(net, f->port, frame, n);
    mnd_net_conn_bytes(net, f->log, 0, len);
}

void mnd_net_nat_recheck(mnd_net *net, int port) {
    for (int i = 0; i < MND_NET_MAX_UDP_FLOWS; i++) {
        const mnd_udp_flow *f = &net->udp[i];
        if (f->used && (port < 0 || f->port == port) && !mnd_net_fw_allows(net, f->port, f->proto, f->dst, f->dst_port))
            udp_close(net, i);
    }
}

void mnd_net_nat_port_removed(mnd_net *net, int port) {
    for (int i = 0; i < MND_NET_MAX_UDP_FLOWS; i++)
        if (net->udp[i].used && net->udp[i].port == port) udp_close(net, i);
    mnd_net_tcp_port_removed(net, port);
}

void mnd_net_nat_close_all(mnd_net *net) {
    for (int i = 0; i < MND_NET_MAX_UDP_FLOWS; i++) udp_close(net, i);
    mnd_net_tcp_close_all(net);
}

/* ---- Routing and time -------------------------------------------------------- */

void mnd_net_route(mnd_net *net, mnd_net_network *nw, int id, const mnd_ip *ip) {
    mnd_net_port *p = &net->ports[id];
    if (nw->cfg.kind != MND_NET_NAT || !routable(nw, ip->dst)) {
        p->stats.dropped_policy++;
        return;
    }
    if (ip->proto == MND_IPPROTO_UDP) udp_out(net, id, ip);
    else if (ip->proto == MND_IPPROTO_TCP) mnd_net_tcp_input(net, nw, id, ip);
    else if (ip->proto == MND_IPPROTO_ICMP) icmp_out(net, id, ip);
    else p->stats.dropped_policy++;
}

uint64_t mnd_net_poll(mnd_net *net) {
    if (!net) return UINT64_MAX;
    uint64_t now = now_ms(net);
    for (int i = 0; i < MND_NET_MAX_UDP_FLOWS; i++)
        if (net->udp[i].used && now >= net->udp[i].expires_ms) udp_close(net, i);
    mnd_net_tcp_poll(net, now);
    return mnd_net_deadline(net);
}

/* Exact, from the tables: one pass, no bookkeeping to drift. */
uint64_t mnd_net_deadline(const mnd_net *net) {
    if (!net) return UINT64_MAX;
    uint64_t next = mnd_net_tcp_deadline(net);
    for (int i = 0; i < MND_NET_MAX_UDP_FLOWS; i++)
        if (net->udp[i].used && net->udp[i].expires_ms < next) next = net->udp[i].expires_ms;
    return next;
}
