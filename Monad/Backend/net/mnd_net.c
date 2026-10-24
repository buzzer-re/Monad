/*
 * mnd_net.c — networks, ports and the virtual switch. See mnd_net.h for the
 * isolation rules; the gateway lives in mnd_net_gateway.c.
 *
 * Every table is fixed-size and allocated once in mnd_net_create: nothing a
 * guest sends can grow memory. Port ids index a flat table shared by all
 * networks; a freed slot is reused only after the allocator has gone round
 * the table, so a stale id held by the caller does not reach a new VM soon.
 */
#include "mnd_net_internal.h"

#include <stdlib.h>
#include <string.h>

mnd_net *mnd_net_create(const mnd_net_host *host) {
    if (!host || !host->send_frame || !host->now_ms) return NULL;
    mnd_net *net = calloc(1, sizeof *net);
    if (!net) return NULL;
    net->host = *host;
    net->tcp_iss_seed = (uint32_t)host->now_ms(host->ctx) * 2654435761u;
    return net;
}

void mnd_net_destroy(mnd_net *net) {
    if (!net) return;
    mnd_net_nat_close_all(net);
    for (int i = 0; i < MND_NET_PORT_SLOTS; i++) {
        free(net->ports[i].fw);
        free(net->ports[i].session);
    }
    free(net);
}

static bool config_valid(const mnd_net_config *cfg) {
    if (!cfg) return false;
    if ((int)cfg->kind < (int)MND_NET_NONE || (int)cfg->kind > (int)MND_NET_NAT) return false;
    /* /30 is the smallest subnet with room for the gateway and one VM. */
    if (cfg->prefix < 8 || cfg->prefix > 30) return false;
    uint32_t host_mask = (1u << (32 - cfg->prefix)) - 1;
    return (cfg->subnet & host_mask) == 0;
}

int mnd_net_add_network(mnd_net *net, const mnd_net_config *cfg) {
    if (!net || !config_valid(cfg)) return -1;
    for (int i = 0; i < MND_NET_MAX_NETWORKS; i++) {
        mnd_net_network *n = &net->networks[i];
        if (n->used) continue;
        memset(n, 0, sizeof *n);
        n->used = true;
        n->cfg = *cfg;
        if (!n->cfg.lease_secs) n->cfg.lease_secs = MND_NET_DEFAULT_LEASE_SECS;
        if (cfg->kind != MND_NET_NONE) mnd_net_gateway_init(n, i);
        return i;
    }
    return -1;
}

static const mnd_net_network *network_get(const mnd_net *net, int id) {
    if (!net || id < 0 || id >= MND_NET_MAX_NETWORKS || !net->networks[id].used) return NULL;
    return &net->networks[id];
}

int mnd_net_gateway(const mnd_net *net, int network_id, mnd_mac *mac, mnd_ip4 *ip) {
    const mnd_net_network *n = network_get(net, network_id);
    if (!n || n->cfg.kind == MND_NET_NONE) return -1;
    if (mac) *mac = n->gw_mac;
    if (ip) *ip = n->gw_ip;
    return 0;
}

static bool mac_in_use(const mnd_net *net, mnd_mac mac) {
    for (int i = 0; i < MND_NET_PORT_SLOTS; i++)
        if (net->ports[i].used && mnd_mac_eq(net->ports[i].mac, mac)) return true;
    return false;
}

static bool mac_assignable(mnd_mac mac) {
    static const mnd_mac zero;
    return !mnd_mac_is_multicast(mac) && !mnd_mac_eq(mac, zero) && !mnd_net_gateway_mac_range(mac);
}

int mnd_net_add_port(mnd_net *net, int network_id, mnd_mac mac) {
    if (!network_get(net, network_id)) return -1;
    mnd_net_network *n = &net->networks[network_id];
    if (n->count >= MND_NET_MAX_PORTS) return -1;
    if (!mac_assignable(mac) || mac_in_use(net, mac)) return -1;
    for (int k = 0; k < MND_NET_PORT_SLOTS; k++) {
        int id = (net->next_port + k) % MND_NET_PORT_SLOTS;
        mnd_net_port *p = &net->ports[id];
        if (p->used) continue;
        memset(p, 0, sizeof *p);
        p->used = true;
        p->network = network_id;
        p->mac = mac;
        n->members[n->count++] = id;
        net->next_port = (id + 1) % MND_NET_PORT_SLOTS;
        return id;
    }
    return -1;
}

static mnd_net_port *port_get(mnd_net *net, int id) {
    if (!net || id < 0 || id >= MND_NET_PORT_SLOTS || !net->ports[id].used) return NULL;
    return &net->ports[id];
}

/* Leases stay with the MAC: a VM that restarts gets its address back. */
void mnd_net_remove_port(mnd_net *net, int id) {
    mnd_net_port *p = port_get(net, id);
    if (!p) return;
    mnd_net_nat_port_removed(net, id);
    mnd_net_network *n = &net->networks[p->network];
    for (int i = 0; i < n->count; i++) {
        if (n->members[i] != id) continue;
        n->members[i] = n->members[--n->count];
        break;
    }
    /* Its neighbours forget it (its own table goes with the port). */
    for (int i = 0; i < n->count; i++) {
        mnd_net_port *o = &net->ports[n->members[i]];
        for (int k = o->npeers - 1; k >= 0; k--)
            if (o->peers[k].to == id) o->peers[k] = o->peers[--o->npeers];
    }
    mnd_net_fw_port_removed(net, id);
    mnd_net_dns_port_removed(net, id);
    mnd_net_conns_port_removed(net, id);
    free(p->fw);
    memset(p, 0, sizeof *p);
}

void mnd_net_deliver(mnd_net *net, int id, const uint8_t *frame, size_t len) {
    net->ports[id].stats.tx++;
    net->host.send_frame(net->host.ctx, id, frame, len);
}

/* A unicast frame from VM `from` to VM `to`: counted on the sender, a VM it
 * has not sent to for longest giving way when its table is full. */
static void peer_count(mnd_net *net, int from, int to, size_t len) {
    mnd_net_port *p = &net->ports[from];
    int slot = -1, oldest = 0;
    for (int i = 0; i < p->npeers && slot < 0; i++)
        if (p->peers[i].to == to) slot = i;
    if (slot < 0) {
        if (p->npeers < MND_NET_MAX_PEERS) {
            slot = p->npeers++;
        } else {
            for (int i = 1; i < p->npeers; i++)
                if (p->peers[i].last_ms < p->peers[oldest].last_ms) oldest = i;
            slot = oldest;
        }
        p->peers[slot].to = to;
        p->peers[slot].frames = p->peers[slot].bytes = 0;
    }
    p->peers[slot].frames++;
    p->peers[slot].bytes += len;
    p->peers[slot].last_ms = net->host.now_ms(net->host.ctx);
}

int mnd_net_peers(const mnd_net *net, int network, mnd_net_peer *out, int max) {
    if (!net || network < 0 || network >= MND_NET_MAX_NETWORKS || !net->networks[network].used) return -1;
    if (!out || max <= 0) return 0;
    int count = 0;
    for (int from = 0; from < MND_NET_PORT_SLOTS && count < max; from++) {
        const mnd_net_port *p = &net->ports[from];
        if (!p->used || p->network != network) continue;
        int order[MND_NET_MAX_PEERS]; /* its peers by receiver */
        for (int k = 0; k < p->npeers; k++) {
            int j = k;
            for (; j > 0 && p->peers[order[j - 1]].to > p->peers[k].to; j--) order[j] = order[j - 1];
            order[j] = k;
        }
        for (int k = 0; k < p->npeers && count < max; k++) {
            int e = order[k];
            out[count++] = (mnd_net_peer){.from = from, .to = p->peers[e].to, .frames = p->peers[e].frames,
                                          .bytes = p->peers[e].bytes, .last_ms = p->peers[e].last_ms};
        }
    }
    return count;
}

void mnd_net_switch(mnd_net *net, int id, const mnd_eth *eth, const uint8_t *frame, size_t len) {
    mnd_net_port *src = &net->ports[id];
    const mnd_net_network *n = &net->networks[src->network];
    if (n->cfg.isolated) { /* the gateway is all a VM reaches here */
        src->stats.dropped_policy++;
        return;
    }
    /* The receiving VM checks checksums its sender left to the NIC: finish them. */
    uint8_t finished[MND_FRAME_MAX];
    if (mnd_csum_offload_finish(frame, len, finished)) frame = finished;
    if (mnd_mac_is_multicast(eth->dst)) {
        for (int i = 0; i < n->count; i++)
            if (n->members[i] != id) mnd_net_deliver(net, n->members[i], frame, len);
        return;
    }
    for (int i = 0; i < n->count; i++) {
        int to = n->members[i];
        if (to != id && mnd_mac_eq(net->ports[to].mac, eth->dst)) {
            peer_count(net, id, to, len);
            mnd_net_deliver(net, to, frame, len);
            return;
        }
    }
    src->stats.dropped_unknown++;
}

void mnd_net_input(mnd_net *net, int id, const uint8_t *frame, size_t len) {
    mnd_net_port *src = port_get(net, id);
    if (!src) return;
    src->stats.rx++;
    mnd_eth eth;
    if (mnd_eth_parse(frame, len, &eth) != 0) {
        src->stats.dropped_malformed++;
        return;
    }
    if (!mnd_mac_eq(eth.src, src->mac)) {
        src->stats.dropped_spoofed++;
        return;
    }
    if (net->networks[src->network].cfg.kind == MND_NET_NONE)
        mnd_net_switch(net, id, &eth, frame, len);
    else
        mnd_net_gateway_input(net, id, &eth, frame, len);
}

int mnd_net_port_stats_get(const mnd_net *net, int id, mnd_net_port_stats *out) {
    if (!net || !out || id < 0 || id >= MND_NET_PORT_SLOTS || !net->ports[id].used) return -1;
    *out = net->ports[id].stats;
    return 0;
}
