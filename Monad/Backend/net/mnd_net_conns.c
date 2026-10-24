/*
 * mnd_net_conns.c — the connection log: for each VM, every destination it
 * tried to reach through a NAT gateway, what its firewall said and why, its
 * flows and connections, their bytes. See mnd_net.h for what is kept.
 *
 * Entries are found by a hash of (port, proto, dst, dport) when a flow or
 * connection is decided; flows and connections then carry their entry's
 * index, so counting bytes costs no lookup. An entry with something open is
 * never reused, so those indices stay valid.
 */
#include "mnd_net_internal.h"

#include <stdlib.h>
#include <string.h>

static uint64_t now_ms(const mnd_net *net) { return net->host.now_ms(net->host.ctx); }

static uint32_t bucket_of(int port, uint8_t proto, mnd_ip4 dst, uint16_t dport) {
    uint32_t h = (uint32_t)port * 2654435761u;
    h ^= dst * 2246822519u;
    h ^= ((uint32_t)proto << 16 | dport) * 3266489917u;
    h ^= h >> 15;
    return h % MND_CONN_BUCKETS;
}

static uint32_t bucket_of_entry(const mnd_conn_entry *e) {
    return bucket_of(e->port, e->c.proto, e->c.dst, e->c.dport);
}

static void unlink_entry(mnd_net *net, int idx) {
    mnd_conn_entry *e = &net->conns[idx];
    uint16_t *link = &net->conn_bucket[bucket_of_entry(e)];
    while (*link && *link != idx + 1) link = &net->conns[*link - 1].next;
    if (*link) *link = e->next;
    if (net->ports[e->port].nconns > 0) net->ports[e->port].nconns--;
    net->nconns--;
    memset(e, 0, sizeof *e);
}

/* The least recently seen entry with nothing open: of `port`, or (-1) of
 * the ports holding `most` entries. Returns its index, or -1. */
static int oldest_idle(const mnd_net *net, int port, int most) {
    int best = -1;
    for (int i = 0; i < MND_NET_MAX_CONN_LOG; i++) {
        const mnd_conn_entry *e = &net->conns[i];
        if (!e->used || e->c.active) continue;
        if (port >= 0 ? e->port != port : net->ports[e->port].nconns != most) continue;
        if (best < 0 || e->c.last_ms < net->conns[best].c.last_ms) best = i;
    }
    return best;
}

/* Room for one more entry of `port`: frees one if the VM or the log is
 * full. Returns false when nothing can go. */
static bool make_room(mnd_net *net, int port) {
    if (net->ports[port].nconns >= MND_NET_MAX_CONN_LOG_PER_PORT) {
        int idx = oldest_idle(net, port, 0);
        if (idx < 0) return false;
        unlink_entry(net, idx);
        return true;
    }
    if (net->nconns < MND_NET_MAX_CONN_LOG) return true;
    /* The whole log is full: the busiest VM gives way. */
    int most = 0;
    for (int i = 0; i < MND_NET_PORT_SLOTS; i++)
        if (net->ports[i].used && net->ports[i].nconns > most) most = net->ports[i].nconns;
    int idx = oldest_idle(net, -1, most);
    if (idx < 0) {
        /* Everything of the busiest is open: any idle entry, oldest first. */
        for (int i = 0; i < MND_NET_MAX_CONN_LOG; i++) {
            const mnd_conn_entry *e = &net->conns[i];
            if (e->used && !e->c.active && (idx < 0 || e->c.last_ms < net->conns[idx].c.last_ms)) idx = i;
        }
    }
    if (idx < 0) return false;
    unlink_entry(net, idx);
    return true;
}

uint16_t mnd_net_conn_entry(mnd_net *net, int port, uint8_t proto, mnd_ip4 dst, uint16_t dport) {
    uint32_t b = bucket_of(port, proto, dst, dport);
    for (uint16_t i = net->conn_bucket[b]; i; i = net->conns[i - 1].next) {
        const mnd_conn_entry *e = &net->conns[i - 1];
        if (e->port == port && e->c.proto == proto && e->c.dst == dst && e->c.dport == dport) return i;
    }
    if (!make_room(net, port)) return 0;
    int idx = -1;
    for (int i = 0; i < MND_NET_MAX_CONN_LOG && idx < 0; i++)
        if (!net->conns[i].used) idx = i;
    if (idx < 0) return 0;
    uint64_t now = now_ms(net);
    mnd_conn_entry *e = &net->conns[idx];
    *e = (mnd_conn_entry){.used = true, .port = port,
                          .c = {.proto = proto, .dst = dst, .dport = dport, .first_ms = now, .last_ms = now}};
    e->next = net->conn_bucket[b];
    net->conn_bucket[b] = (uint16_t)(idx + 1);
    net->ports[port].nconns++;
    net->nconns++;
    return (uint16_t)(idx + 1);
}

static mnd_net_conn *conn_at(mnd_net *net, uint16_t log) {
    if (!log || log > MND_NET_MAX_CONN_LOG || !net->conns[log - 1].used) return NULL;
    return &net->conns[log - 1].c;
}

void mnd_net_conn_decided(mnd_net *net, uint16_t log, mnd_conn_verdict v, mnd_conn_reason why, int rule) {
    mnd_net_conn *c = conn_at(net, log);
    if (!c) return;
    c->verdict = v;
    c->reason = why;
    c->rule = why == MND_CONN_BY_RULE ? rule : 0;
    if (v == MND_CONN_DENIED) c->refused++;
    else if (v == MND_CONN_ASKED) c->asked++;
    c->last_ms = now_ms(net);
}

void mnd_net_conn_opened(mnd_net *net, uint16_t log) {
    mnd_net_conn *c = conn_at(net, log);
    if (!c) return;
    c->opened++;
    c->active++;
}

void mnd_net_conn_closed(mnd_net *net, uint16_t log) {
    mnd_net_conn *c = conn_at(net, log);
    if (c && c->active) c->active--;
}

void mnd_net_conn_bytes(mnd_net *net, uint16_t log, uint64_t out, uint64_t in) {
    mnd_net_conn *c = conn_at(net, log);
    if (!c) return;
    c->bytes_out += out;
    c->bytes_in += in;
    c->last_ms = now_ms(net);
}

void mnd_net_conns_port_removed(mnd_net *net, int port) {
    for (int i = 0; i < MND_NET_MAX_CONN_LOG; i++)
        if (net->conns[i].used && net->conns[i].port == port) unlink_entry(net, i);
}

int mnd_net_conns(const mnd_net *net, int port, mnd_net_conn *out, int max) {
    if (!net || port < 0 || port >= MND_NET_PORT_SLOTS || !net->ports[port].used || max < 0 || (max && !out))
        return -1;
    mnd_net_conn *all = malloc(MND_NET_MAX_CONN_LOG_PER_PORT * sizeof *all);
    if (!all) return -1;
    /* Most recently seen first; seen in the same millisecond, the newer
     * entry first (insertion: stable, and a VM has few entries). */
    int n = 0;
    for (int i = 0; i < MND_NET_MAX_CONN_LOG && n < MND_NET_MAX_CONN_LOG_PER_PORT; i++) {
        if (!net->conns[i].used || net->conns[i].port != port) continue;
        mnd_net_conn c = net->conns[i].c;
        int at = n++;
        while (at > 0 && (all[at - 1].last_ms < c.last_ms ||
                          (all[at - 1].last_ms == c.last_ms && all[at - 1].first_ms <= c.first_ms))) {
            all[at] = all[at - 1];
            at--;
        }
        all[at] = c;
    }
    if (n > max) n = max;
    if (n) memcpy(out, all, (size_t)n * sizeof *all);
    free(all);
    return n;
}
