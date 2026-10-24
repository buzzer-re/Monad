/*
 * mnd_net_dnsfwd.c — the gateway's DNS forwarder: VMs' queries go to the
 * Mac through mnd_net_host.dns_query; answers are checked against the
 * query, given the VM's transaction id, truncated to one datagram, and
 * their A records remembered for hostname firewall rules.
 *
 * Both tables are fixed-size. A query holds its place until answered or
 * until MND_NET_DNS_TIMEOUT_MS passes; expired places are reclaimed when
 * needed, so no timer is involved.
 */
#include "mnd_net_internal.h"

#include <string.h>

#define UDP_MAX (MND_ETH_MTU - 28)

static uint64_t now_ms(const mnd_net *net) { return net->host.now_ms(net->host.ctx); }

static bool live(const mnd_dns_pending *e, uint64_t now) { return e->used && now < e->deadline_ms; }

static void reply(mnd_net *net, const mnd_dns_pending *e, const uint8_t *msg, size_t len) {
    const mnd_net_network *nw = &net->networks[e->network];
    mnd_net_send_udp(net, nw, e->port, nw->gw_ip, MND_DNS_PORT, e->client_ip, e->client_port, msg, len);
}

static void answer_error(mnd_net *net, const mnd_dns_pending *e, uint8_t rcode) {
    uint8_t out[sizeof e->question];
    size_t n = mnd_dns_error(out, sizeof out, e->question, &e->q, rcode);
    if (n) reply(net, e, out, n);
}

static void servfail(mnd_net *net, const mnd_dns_pending *e) { answer_error(net, e, MND_DNS_RCODE_SERVFAIL); }

void mnd_net_dns_input(mnd_net *net, mnd_net_network *nw, int id, const mnd_ip *ip) {
    mnd_net_port *p = &net->ports[id];
    if (nw->cfg.kind != MND_NET_HOST_ONLY && nw->cfg.kind != MND_NET_NAT) {
        p->stats.dropped_policy++;
        return;
    }
    mnd_udp udp;
    mnd_dns_pending e = {0};
    if (mnd_udp_parse(ip, &udp) != 0 || mnd_dns_parse_query(udp.payload, udp.len, &e.q) != 0) {
        p->stats.dropped_malformed++;
        return;
    }
    e.used = true;
    e.port = id;
    e.network = p->network;
    e.mac = p->mac;
    e.client_ip = ip->src;
    e.client_port = udp.sport;
    memcpy(e.question, udp.payload, e.q.question_end);
    /* Nothing leaves a host-only network unless it says lookups may. */
    if (nw->cfg.kind == MND_NET_HOST_ONLY && !nw->cfg.host_only_dns) {
        p->stats.dropped_policy++;
        answer_error(net, &e, MND_DNS_RCODE_REFUSED);
        return;
    }
    switch (mnd_net_fw_admit_lookup(net, id, e.q.qname)) {
    case MND_FW_HOLD: return; /* asked about: the resolver tries again */
    case MND_FW_REFUSE:
        p->stats.dropped_firewall++;
        answer_error(net, &e, MND_DNS_RCODE_REFUSED);
        return;
    case MND_FW_ADMIT: break;
    }
    if (!net->host.dns_query) {
        servfail(net, &e);
        return;
    }
    uint64_t now = now_ms(net);
    int mine = 0;
    mnd_dns_pending *slot = NULL;
    for (int i = 0; i < MND_NET_MAX_DNS_PENDING; i++) {
        mnd_dns_pending *x = &net->dns_pending[i];
        if (!live(x, now)) {
            x->used = false;
            if (!slot) slot = x;
        } else if (x->port == id && mnd_mac_eq(x->mac, p->mac)) {
            mine++;
        }
    }
    if (!slot || mine >= MND_NET_MAX_DNS_PENDING_PER_PORT) {
        p->stats.dropped_policy++;
        return;
    }
    if (++net->dns_next_id == 0) net->dns_next_id = 1;
    e.id = net->dns_next_id;
    e.deadline_ms = now + MND_NET_DNS_TIMEOUT_MS;
    *slot = e;
    /* The host may answer from inside this call. */
    net->host.dns_query(net->host.ctx, e.id, udp.payload, udp.len);
}

/* ---- Names ------------------------------------------------------------------ */

typedef struct {
    mnd_net *net;
    int port;
    uint64_t now;
} remember_ctx;

/* The table is full: the VM holding the most names gives up its oldest, so
 * one VM's lookups never push out another's (ties: the VM asking). */
static mnd_dns_name *evict(mnd_net *net, int asking) {
    uint16_t held[MND_NET_PORT_SLOTS] = {0};
    for (int i = 0; i < MND_NET_MAX_DNS_NAMES; i++) held[net->dns_names[i].port]++;
    int top = asking;
    for (int p = 0; p < MND_NET_PORT_SLOTS; p++)
        if (held[p] > held[top]) top = p;
    mnd_dns_name *oldest = NULL;
    for (int i = 0; i < MND_NET_MAX_DNS_NAMES; i++) {
        mnd_dns_name *x = &net->dns_names[i];
        if (x->port == top && (!oldest || x->seq < oldest->seq)) oldest = x;
    }
    return oldest;
}

static void remember(void *ctx, const char *name, mnd_ip4 ip, uint32_t ttl) {
    remember_ctx *c = ctx;
    mnd_net *net = c->net;
    /* Only names a rule can name: anything else could be made to look like
     * another name in the firewall's question (a comma, for one). */
    if (!mnd_dns_name_is_plain(name)) return;
    if (ttl < MND_NET_DNS_MIN_TTL) ttl = MND_NET_DNS_MIN_TTL;
    if (ttl > MND_NET_DNS_MAX_TTL) ttl = MND_NET_DNS_MAX_TTL;
    mnd_dns_name *slot = NULL, *free_slot = NULL;
    for (int i = 0; i < MND_NET_MAX_DNS_NAMES && !slot; i++) {
        mnd_dns_name *x = &net->dns_names[i];
        if (x->used && c->now < x->expires_ms) {
            if (x->ip == ip && x->port == c->port && strcmp(x->name, name) == 0) slot = x;
        } else if (!free_slot) {
            free_slot = x;
        }
    }
    if (!slot) slot = free_slot ? free_slot : evict(net, c->port);
    slot->used = true;
    slot->port = c->port;
    slot->ip = ip;
    slot->expires_ms = c->now + (uint64_t)ttl * 1000;
    slot->seq = ++net->dns_name_seq;
    strcpy(slot->name, name);
}

void mnd_net_dns_port_removed(mnd_net *net, int port) {
    for (int i = 0; i < MND_NET_MAX_DNS_NAMES; i++)
        if (net->dns_names[i].used && net->dns_names[i].port == port) memset(&net->dns_names[i], 0, sizeof net->dns_names[i]);
}

void mnd_net_dns_answer(mnd_net *net, uint32_t id, const uint8_t *answer, size_t len) {
    if (!net || !id) return;
    uint64_t now = now_ms(net);
    mnd_dns_pending *e = NULL;
    for (int i = 0; i < MND_NET_MAX_DNS_PENDING && !e; i++)
        if (net->dns_pending[i].used && net->dns_pending[i].id == id) e = &net->dns_pending[i];
    if (!e) return;
    if (!live(e, now)) {
        e->used = false;
        return;
    }
    const mnd_net_port *p = &net->ports[e->port];
    if (!p->used || p->network != e->network || !mnd_mac_eq(p->mac, e->mac)) {
        e->used = false; /* the VM is gone */
        return;
    }
    if (!answer || !len) {
        servfail(net, e);
        e->used = false;
        return;
    }
    /* Not an answer to this question: ignored, the query stays pending. */
    if (mnd_dns_parse_answer(answer, len, &e->q, NULL, NULL) != 0) return;
    remember_ctx rc = {.net = net, .port = e->port, .now = now};
    mnd_dns_parse_answer(answer, len, &e->q, remember, &rc);

    uint8_t out[UDP_MAX];
    size_t limit = e->q.udp_size < UDP_MAX ? e->q.udp_size : UDP_MAX;
    size_t n;
    if (len <= limit) {
        memcpy(out, answer, len);
        n = len;
    } else {
        memcpy(out, answer, e->q.question_end);
        n = mnd_dns_truncate(out, e->q.question_end, &e->q);
    }
    out[0] = (uint8_t)(e->q.id >> 8);
    out[1] = (uint8_t)e->q.id;
    reply(net, e, out, n);
    e->used = false;
}

int mnd_net_dns_names(const mnd_net *net, int port, mnd_ip4 ip, const char **names, int max) {
    if (!net || !names || max <= 0 || port < 0 || port >= MND_NET_PORT_SLOTS) return 0;
    uint64_t now = now_ms(net);
    int count = 0;
    uint64_t below = UINT64_MAX;
    /* Newest first: each pass takes the newest pair older than the last. */
    while (count < max) {
        const mnd_dns_name *best = NULL;
        for (int i = 0; i < MND_NET_MAX_DNS_NAMES; i++) {
            const mnd_dns_name *x = &net->dns_names[i];
            if (!x->used || x->ip != ip || x->port != port || now >= x->expires_ms || x->seq >= below) continue;
            if (!best || x->seq > best->seq) best = x;
        }
        if (!best) break;
        names[count++] = best->name;
        below = best->seq;
    }
    return count;
}
