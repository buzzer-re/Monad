/*
 * mnd_net_tcp.c — the TCP endpoint for NAT networks: a VM's connection is
 * ended here and spliced to a host socket.
 *
 * Handshake: the VM's SYN starts the host's connect; the VM gets its
 * SYN-ACK when the destination accepted, or a reset.
 *
 * VM → Mac: in-order data goes into `rx` and on to the socket as fast as it
 * takes it. The window the VM sees is the room left in rx, so a slow
 * destination slows the VM down. Out-of-order segments are dropped (the VM
 * retransmits), so nothing a guest sends needs reassembly memory.
 *
 * Mac → VM: the socket is read into `tx` only while there is room; tx keeps
 * every byte until the VM acknowledges it. Segments go out within the VM's
 * window; a timeout sends everything unacknowledged again (go-back-N) with
 * exponential backoff, and a connection whose VM stops answering is reset.
 * A zero window is probed with one byte until the VM opens it.
 *
 * Nothing here grows: connections, buffers and timers are bounded, and the
 * host is asked for readiness only when the connection can use it.
 */
#include "mnd_net_internal.h"

#include <stdlib.h>
#include <string.h>

#define BUF MND_NET_TCP_BUF
#define DEFAULT_MSS 536

static uint64_t now_ms(const mnd_net *net) { return net->host.now_ms(net->host.ctx); }

static bool seq_lt(uint32_t a, uint32_t b) { return (int32_t)(a - b) < 0; }
static bool seq_gt(uint32_t a, uint32_t b) { return (int32_t)(a - b) > 0; }
static uint32_t min32(uint32_t a, uint32_t b) { return a < b ? a : b; }

static uint32_t conn_id(const mnd_net *net, const mnd_tcp_conn *c) {
    return (uint32_t)c->gen << 16 | (uint32_t)(c - net->tcp);
}

static mnd_tcp_conn *by_id(mnd_net *net, uint32_t id) {
    uint32_t idx = id & 0xffff;
    if (!net || idx >= MND_NET_MAX_TCP_CONNS) return NULL;
    mnd_tcp_conn *c = &net->tcp[idx];
    return c->state != MND_TCP_FREE && c->gen == id >> 16 ? c : NULL;
}

static uint32_t bucket(const mnd_tcp_conn *c) {
    return mnd_net_flow_hash(c->network, c->vm_ip, c->vm_port, c->dst, c->dst_port) % MND_TCP_BUCKETS;
}

static mnd_tcp_conn *find(mnd_net *net, int port, mnd_ip4 vm_ip, uint16_t vm_port, mnd_ip4 dst, uint16_t dst_port) {
    const mnd_net_port *p = &net->ports[port];
    uint32_t b = mnd_net_flow_hash(p->network, vm_ip, vm_port, dst, dst_port) % MND_TCP_BUCKETS;
    for (uint16_t i = net->tcp_bucket[b]; i; i = net->tcp[i - 1].next) {
        mnd_tcp_conn *c = &net->tcp[i - 1];
        if (c->port == port && c->vm_ip == vm_ip && c->vm_port == vm_port && c->dst == dst &&
            c->dst_port == dst_port && c->network == p->network && mnd_mac_eq(c->mac, p->mac))
            return c;
    }
    return NULL;
}

static uint32_t rx_room(const mnd_tcp_conn *c) { return BUF - c->rx_len; }

/* ---- Segments to the VM ------------------------------------------------------------ */

static void send_raw(mnd_net *net, int port, mnd_ip4 src, uint16_t sport, mnd_ip4 dst, uint16_t dport, uint32_t seq,
                     uint32_t ack, uint8_t flags, uint16_t window, uint16_t mss, const uint8_t *data, size_t len) {
    const mnd_net_network *nw = &net->networks[net->ports[port].network];
    uint8_t frame[MND_FRAME_MAX];
    mnd_ip_hdr_spec h = {.eth_dst = net->ports[port].mac, .eth_src = nw->gw_mac, .src = src, .dst = dst, .ttl = 64,
                         .id = net->ip_id++};
    mnd_tcp_spec t = {.sport = sport, .dport = dport, .seq = seq, .ack = ack, .flags = flags, .window = window,
                      .mss = mss, .wscale = -1};
    size_t n = mnd_build_tcp(frame, sizeof frame, &h, &t, data, len);
    if (n) mnd_net_deliver(net, port, frame, n);
}

static void send_seg(mnd_net *net, mnd_tcp_conn *c, uint32_t seq, uint8_t flags, const uint8_t *data, size_t len,
                     uint16_t mss) {
    uint32_t wnd = rx_room(c);
    if (flags & MND_TCP_ACK) c->adv_wnd = wnd;
    send_raw(net, c->port, c->dst, c->dst_port, c->vm_ip, c->vm_port, seq, c->rcv_nxt, flags, (uint16_t)wnd, mss,
             data, len);
}

static void send_ack(mnd_net *net, mnd_tcp_conn *c) { send_seg(net, c, c->snd_nxt, MND_TCP_ACK, NULL, 0, 0); }

static void send_syn_ack(mnd_net *net, mnd_tcp_conn *c) {
    send_seg(net, c, c->iss, MND_TCP_SYN | MND_TCP_ACK, NULL, 0, MND_NET_TCP_MSS);
}

/* `len` bytes of tx starting `off` bytes after snd_una. */
static void send_data(mnd_net *net, mnd_tcp_conn *c, uint32_t off, uint32_t len, bool push) {
    uint8_t payload[MND_NET_TCP_MSS];
    uint32_t at = (c->tx_head + off) % BUF;
    uint32_t first = min32(len, BUF - at);
    memcpy(payload, c->tx + at, first);
    memcpy(payload + first, c->tx, len - first);
    send_seg(net, c, c->snd_una + off, (uint8_t)(MND_TCP_ACK | (push ? MND_TCP_PSH : 0)), payload, len, 0);
}

/* ---- Lifetime ---------------------------------------------------------------------- */

static void release(mnd_net *net, mnd_tcp_conn *c) {
    uint16_t idx = (uint16_t)(c - net->tcp);
    uint16_t *link = &net->tcp_bucket[bucket(c)];
    while (*link && *link != idx + 1) link = &net->tcp[*link - 1].next;
    if (*link) *link = c->next;
    free(c->rx); /* tx shares the allocation */
    mnd_net_conn_closed(net, c->log);
    uint16_t gen = c->gen;
    memset(c, 0, sizeof *c);
    c->gen = gen;
}

static void host_close(mnd_net *net, mnd_tcp_conn *c, bool abort) {
    if (net->host.tcp_close) net->host.tcp_close(net->host.ctx, conn_id(net, c), abort);
    release(net, c);
}

/* Resets the VM's side (unless the VM reset it) and drops the socket. */
static void abort_conn(mnd_net *net, mnd_tcp_conn *c, bool tell_vm) {
    if (tell_vm) {
        uint8_t flags = MND_TCP_RST | MND_TCP_ACK;
        send_seg(net, c, c->state == MND_TCP_CONNECTING ? 0 : c->snd_nxt, flags, NULL, 0, 0);
    }
    host_close(net, c, true);
}

static void update_interest(mnd_net *net, mnd_tcp_conn *c) {
    bool open = c->state == MND_TCP_OPEN;
    bool r = open && !c->mac_eof && c->tx_len < BUF;
    bool w = open && c->rx_len > 0;
    if (r == c->want_read && w == c->want_write) return;
    c->want_read = r;
    c->want_write = w;
    if (net->host.tcp_interest) net->host.tcp_interest(net->host.ctx, conn_id(net, c), r, w);
}

/* Both directions done: an orderly close. Returns true if c is gone. */
static bool maybe_finish(mnd_net *net, mnd_tcp_conn *c) {
    if (!(c->vm_fin && c->fin_acked && c->rx_len == 0 && c->shut)) return false;
    host_close(net, c, false);
    return true;
}

static void arm(mnd_net *net, mnd_tcp_conn *c) {
    c->persist = false;
    c->timer_at = now_ms(net) + c->rto_ms;
}

/* ---- Moving data ------------------------------------------------------------------- */

/* Writes rx to the socket. Returns false if the connection was aborted. */
static bool flush_rx(mnd_net *net, mnd_tcp_conn *c) {
    while (c->rx_len) {
        uint32_t chunk = min32(c->rx_len, BUF - c->rx_head);
        ssize_t w = net->host.tcp_write(net->host.ctx, conn_id(net, c), c->rx + c->rx_head, chunk);
        if (w < 0) {
            abort_conn(net, c, true);
            return false;
        }
        if (w == 0) break;
        mnd_net_conn_bytes(net, c->log, (uint64_t)w, 0);
        c->rx_head = (c->rx_head + (uint32_t)w) % BUF;
        c->rx_len -= (uint32_t)w;
        if ((uint32_t)w < chunk) break;
    }
    if (!c->rx_len && c->vm_fin && !c->shut) {
        if (net->host.tcp_shutdown) net->host.tcp_shutdown(net->host.ctx, conn_id(net, c));
        c->shut = true;
    }
    return true;
}

/* Sends what the VM's window allows, then the FIN once everything is out. */
static void output(mnd_net *net, mnd_tcp_conn *c) {
    if (c->state != MND_TCP_OPEN) return;
    while (!c->fin_sent) {
        uint32_t off = c->snd_nxt - c->snd_una;
        uint32_t unsent = c->tx_len - off;
        if (!unsent || off >= c->snd_wnd) break;
        uint32_t n = min32(min32(unsent, c->snd_wnd - off), c->mss);
        send_data(net, c, off, n, n == unsent);
        c->snd_nxt += n;
        if (!c->timer_at || c->persist) arm(net, c);
    }
    if (c->mac_eof && !c->fin_sent && c->snd_nxt - c->snd_una == c->tx_len) {
        send_seg(net, c, c->snd_nxt, MND_TCP_FIN | MND_TCP_ACK, NULL, 0, 0);
        c->snd_nxt++;
        c->fin_sent = true;
        if (!c->timer_at || c->persist) arm(net, c);
    }
    /* Data waiting and no room at the VM: probe the window later. */
    if (!c->fin_sent && c->snd_nxt == c->snd_una && c->tx_len && c->snd_wnd == 0 && !c->timer_at) {
        c->persist = true;
        c->timer_at = now_ms(net) + c->persist_ms;
    }
}

/* Reads the socket into tx while there is room. Returns false if aborted. */
static bool pull(mnd_net *net, mnd_tcp_conn *c) {
    while (!c->mac_eof && c->tx_len < BUF) {
        uint32_t tail = (c->tx_head + c->tx_len) % BUF;
        uint32_t space = min32(BUF - c->tx_len, BUF - tail);
        ssize_t r = net->host.tcp_read(net->host.ctx, conn_id(net, c), c->tx + tail, space);
        if (r > 0) {
            c->tx_len += (uint32_t)r;
            mnd_net_conn_bytes(net, c->log, 0, (uint64_t)r);
        } else if (r == 0) {
            c->mac_eof = true;
        } else if (r == MND_NET_IO_AGAIN) {
            break;
        } else {
            abort_conn(net, c, true);
            return false;
        }
    }
    return true;
}

/* After any event: send, maybe close, tell the host what to watch. */
static void settle(mnd_net *net, mnd_tcp_conn *c) {
    output(net, c);
    if (maybe_finish(net, c)) return;
    update_interest(net, c);
}

/* ---- Segments from the VM ------------------------------------------------------------ */

static void reset_unknown(mnd_net *net, int port, const mnd_ip *ip, const mnd_tcp *t) {
    if (t->flags & MND_TCP_RST) return;
    if (t->flags & MND_TCP_ACK) {
        send_raw(net, port, ip->dst, t->dport, ip->src, t->sport, t->ack, 0, MND_TCP_RST, 0, 0, NULL, 0);
    } else {
        uint32_t ack = t->seq + (uint32_t)t->len + ((t->flags & MND_TCP_SYN) ? 1 : 0) + ((t->flags & MND_TCP_FIN) ? 1 : 0);
        send_raw(net, port, ip->dst, t->dport, ip->src, t->sport, 0, ack, MND_TCP_RST | MND_TCP_ACK, 0, 0, NULL, 0);
    }
}

static int count_for_port(const mnd_net *net, int port) {
    int n = 0;
    for (int i = 0; i < MND_NET_MAX_TCP_CONNS; i++) {
        const mnd_tcp_conn *c = &net->tcp[i];
        if (c->state != MND_TCP_FREE && c->port == port) n++;
    }
    return n;
}

static void syn(mnd_net *net, int id, const mnd_ip *ip, const mnd_tcp *t) {
    mnd_net_port *p = &net->ports[id];
    uint16_t log = 0;
    mnd_fw_admission a = mnd_net_fw_admit(net, id, MND_IPPROTO_TCP, ip->dst, t->dport, &log);
    if (a == MND_FW_HOLD) return; /* asked about: the VM sends its SYN again */
    if (a == MND_FW_REFUSE) {
        p->stats.dropped_firewall++;
        reset_unknown(net, id, ip, t); /* refused, at once */
        return;
    }
    mnd_tcp_conn *c = NULL;
    if (count_for_port(net, id) < MND_NET_MAX_TCP_CONNS_PER_PORT)
        for (int i = 0; i < MND_NET_MAX_TCP_CONNS && !c; i++)
            if (net->tcp[i].state == MND_TCP_FREE) c = &net->tcp[i];
    uint8_t *mem = c ? malloc(2 * BUF) : NULL;
    if (!mem) {
        reset_unknown(net, id, ip, t);
        return;
    }
    uint16_t gen = (uint16_t)(c->gen + 1);
    memset(c, 0, sizeof *c);
    c->gen = gen ? gen : 1;
    c->state = MND_TCP_CONNECTING;
    c->network = p->network;
    c->port = id;
    c->mac = p->mac;
    c->vm_ip = ip->src;
    c->dst = ip->dst;
    c->vm_port = t->sport;
    c->dst_port = t->dport;
    c->rcv_nxt = t->seq + 1;
    c->rx = mem;
    c->tx = mem + BUF;
    c->snd_wnd = t->window;
    /* Between the default (also the floor: a tiny MSS would make netd build
     * thousands of frames) and what netd sends. */
    c->mss = t->mss > DEFAULT_MSS ? (uint16_t)min32(t->mss, MND_NET_TCP_MSS) : DEFAULT_MSS;
    c->rto_ms = MND_NET_TCP_RTO_MS;
    c->persist_ms = MND_NET_TCP_RTO_MS;
    net->tcp_iss_seed = net->tcp_iss_seed * 1664525u + 1013904223u;
    c->iss = net->tcp_iss_seed ^ mnd_net_flow_hash(c->network, c->vm_ip, c->vm_port, c->dst, c->dst_port);
    c->snd_una = c->snd_nxt = c->iss;
    c->timer_at = now_ms(net) + MND_NET_TCP_CONNECT_TIMEOUT_MS;
    uint32_t b = bucket(c);
    c->next = net->tcp_bucket[b];
    net->tcp_bucket[b] = (uint16_t)(c - net->tcp + 1);
    if (net->host.tcp_connect(net->host.ctx, conn_id(net, c), c->dst, c->dst_port) != 0) {
        send_seg(net, c, 0, MND_TCP_RST | MND_TCP_ACK, NULL, 0, 0);
        release(net, c);
        return;
    }
    c->log = log;
    mnd_net_conn_opened(net, log);
}

/* In-order data and FIN from the VM. */
static void receive(mnd_net *net, mnd_tcp_conn *c, const mnd_tcp *t) {
    const uint8_t *data = t->payload;
    uint32_t len = (uint32_t)t->len, seq = t->seq;
    bool fin = t->flags & MND_TCP_FIN;
    if (!len && !fin) return;
    if (seq_lt(seq, c->rcv_nxt)) {
        uint32_t skip = c->rcv_nxt - seq;
        if (skip > len || (skip == len && !fin)) {
            send_ack(net, c); /* an old duplicate */
            return;
        }
        data += skip;
        len -= skip;
        seq = c->rcv_nxt;
    }
    if (seq != c->rcv_nxt || c->vm_fin) {
        send_ack(net, c); /* out of order, or after the FIN: dropped */
        return;
    }
    uint32_t n = min32(len, rx_room(c));
    uint32_t tail = (c->rx_head + c->rx_len) % BUF;
    uint32_t first = min32(n, BUF - tail);
    memcpy(c->rx + tail, data, first);
    memcpy(c->rx, data + first, n - first);
    c->rx_len += n;
    c->rcv_nxt += n;
    if (fin && n == len) {
        c->rcv_nxt++;
        c->vm_fin = true;
    }
    if (!flush_rx(net, c)) return;
    send_ack(net, c);
}

/* The VM acknowledged `ack` with window `wnd`. */
static void acknowledge(mnd_net *net, mnd_tcp_conn *c, uint32_t ack, uint16_t wnd) {
    if (seq_gt(ack, c->snd_una)) {
        uint32_t acked = ack - c->snd_una;
        if (c->fin_sent && ack == c->snd_nxt) {
            c->fin_acked = true;
            acked--;
        }
        c->tx_head = (c->tx_head + acked) % BUF;
        c->tx_len -= acked;
        c->snd_una = ack;
        c->retries = 0;
        c->rto_ms = MND_NET_TCP_RTO_MS;
        c->timer_at = 0;
        c->persist = false;
        if (c->snd_nxt != c->snd_una) arm(net, c);
    }
    c->snd_wnd = wnd;
    if (wnd) {
        c->persist_ms = MND_NET_TCP_RTO_MS;
    } else if (seq_gt(c->snd_nxt, c->snd_una) && !c->fin_sent) {
        /* Nothing fits: take back what is out (a probe, or data past a
         * shrunk window) and probe again later. An answered probe is not a
         * failed retransmission. */
        c->snd_nxt = c->snd_una;
        c->retries = 0;
        c->persist = true;
        c->persist_ms = min32(c->persist_ms * 2, MND_NET_TCP_RTO_MAX_MS);
        c->timer_at = now_ms(net) + c->persist_ms;
    }
}

void mnd_net_tcp_input(mnd_net *net, mnd_net_network *nw, int id, const mnd_ip *ip) {
    (void)nw;
    mnd_net_port *p = &net->ports[id];
    mnd_tcp t;
    if (mnd_tcp_parse(ip, &t) != 0) {
        p->stats.dropped_malformed++;
        return;
    }
    if (!net->host.tcp_connect) {
        p->stats.dropped_policy++;
        return;
    }
    mnd_tcp_conn *c = find(net, id, ip->src, t.sport, ip->dst, t.dport);
    if (!c) {
        if ((t.flags & (MND_TCP_SYN | MND_TCP_ACK | MND_TCP_RST | MND_TCP_FIN)) == MND_TCP_SYN) syn(net, id, ip, &t);
        else reset_unknown(net, id, ip, &t);
        return;
    }
    bool in_window = !seq_lt(t.seq, c->rcv_nxt) && seq_lt(t.seq, c->rcv_nxt + BUF);
    if (t.flags & MND_TCP_RST) {
        if (in_window) host_close(net, c, true);
        return;
    }
    switch (c->state) {
    case MND_TCP_CONNECTING:
        return; /* a retried SYN, or early segments: the VM will retry */
    case MND_TCP_SYN_RCVD:
        if (t.flags & MND_TCP_SYN) {
            send_syn_ack(net, c);
            return;
        }
        if (!(t.flags & MND_TCP_ACK)) return;
        if (t.ack != c->iss + 1) {
            send_raw(net, id, ip->dst, t.dport, ip->src, t.sport, t.ack, 0, MND_TCP_RST, 0, 0, NULL, 0);
            return;
        }
        c->state = MND_TCP_OPEN;
        c->snd_una = c->snd_nxt = c->iss + 1;
        c->timer_at = 0;
        c->retries = 0;
        c->rto_ms = MND_NET_TCP_RTO_MS;
        break;
    default:
        break;
    }
    if (t.flags & MND_TCP_SYN) {
        send_ack(net, c); /* a stray SYN on an open connection */
        return;
    }
    if (!(t.flags & MND_TCP_ACK)) return;
    if (seq_gt(t.ack, c->snd_nxt)) {
        send_ack(net, c); /* acknowledges data never sent */
        return;
    }
    acknowledge(net, c, t.ack, t.window);
    receive(net, c, &t);
    if (c->state == MND_TCP_FREE) return; /* aborted while writing */
    settle(net, c); /* room freed in tx re-arms reading through the interest */
}

/* ---- Host events ---------------------------------------------------------------------- */

void mnd_net_tcp_connected(mnd_net *net, uint32_t id, bool ok) {
    mnd_tcp_conn *c = by_id(net, id);
    if (!c || c->state != MND_TCP_CONNECTING) return;
    if (!ok) {
        abort_conn(net, c, true);
        return;
    }
    c->state = MND_TCP_SYN_RCVD;
    send_syn_ack(net, c);
    c->snd_nxt = c->iss + 1;
    c->rto_ms = MND_NET_TCP_RTO_MS;
    arm(net, c);
}

void mnd_net_tcp_readable(mnd_net *net, uint32_t id) {
    mnd_tcp_conn *c = by_id(net, id);
    if (!c || c->state != MND_TCP_OPEN) return;
    if (!pull(net, c)) return;
    settle(net, c);
}

void mnd_net_tcp_writable(mnd_net *net, uint32_t id) {
    mnd_tcp_conn *c = by_id(net, id);
    if (!c || c->state != MND_TCP_OPEN) return;
    uint32_t before = c->adv_wnd;
    if (!flush_rx(net, c)) return;
    uint32_t wnd = rx_room(c);
    /* Tell the VM when the window opened enough to matter. */
    if ((before == 0 && wnd > 0) || wnd >= before + MND_NET_TCP_MSS) send_ack(net, c);
    settle(net, c);
}

/* ---- Timers and teardown ----------------------------------------------------------------- */

static void fire(mnd_net *net, mnd_tcp_conn *c) {
    c->timer_at = 0;
    switch (c->state) {
    case MND_TCP_CONNECTING:
        abort_conn(net, c, true);
        return;
    case MND_TCP_SYN_RCVD:
        if (++c->retries > MND_NET_TCP_MAX_RETRIES) {
            abort_conn(net, c, true);
            return;
        }
        send_syn_ack(net, c);
        c->rto_ms = min32(c->rto_ms * 2, MND_NET_TCP_RTO_MAX_MS);
        arm(net, c);
        return;
    case MND_TCP_OPEN:
        if (c->persist) {
            /* One byte past the window: the VM answers with its window. */
            send_data(net, c, 0, 1, true);
            c->snd_nxt = c->snd_una + 1;
            arm(net, c);
            return;
        }
        if (++c->retries > MND_NET_TCP_MAX_RETRIES) {
            abort_conn(net, c, true);
            return;
        }
        c->snd_nxt = c->snd_una;
        if (!c->fin_acked) c->fin_sent = false;
        c->rto_ms = min32(c->rto_ms * 2, MND_NET_TCP_RTO_MAX_MS);
        output(net, c); /* arms the backed-off timeout, or a probe */
        return;
    default:
        return;
    }
}

uint64_t mnd_net_tcp_poll(mnd_net *net, uint64_t now) {
    for (int i = 0; i < MND_NET_MAX_TCP_CONNS; i++) {
        mnd_tcp_conn *c = &net->tcp[i];
        if (c->state != MND_TCP_FREE && c->timer_at && now >= c->timer_at) fire(net, c);
    }
    return mnd_net_tcp_deadline(net);
}

uint64_t mnd_net_tcp_deadline(const mnd_net *net) {
    uint64_t next = UINT64_MAX;
    for (int i = 0; i < MND_NET_MAX_TCP_CONNS; i++) {
        const mnd_tcp_conn *c = &net->tcp[i];
        if (c->state != MND_TCP_FREE && c->timer_at && c->timer_at < next) next = c->timer_at;
    }
    return next;
}

void mnd_net_tcp_recheck(mnd_net *net, int port) {
    for (int i = 0; i < MND_NET_MAX_TCP_CONNS; i++) {
        mnd_tcp_conn *c = &net->tcp[i];
        if (c->state != MND_TCP_FREE && (port < 0 || c->port == port) &&
            !mnd_net_fw_allows(net, c->port, MND_IPPROTO_TCP, c->dst, c->dst_port))
            abort_conn(net, c, true);
    }
}

void mnd_net_tcp_port_removed(mnd_net *net, int port) {
    for (int i = 0; i < MND_NET_MAX_TCP_CONNS; i++)
        if (net->tcp[i].state != MND_TCP_FREE && net->tcp[i].port == port) host_close(net, &net->tcp[i], true);
}

void mnd_net_tcp_close_all(mnd_net *net) {
    for (int i = 0; i < MND_NET_MAX_TCP_CONNS; i++)
        if (net->tcp[i].state != MND_TCP_FREE) host_close(net, &net->tcp[i], true);
}
