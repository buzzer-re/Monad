/* Tests for the TCP endpoint: a VM's connection ended in the core and
 * spliced to a host socket — handshake, data both ways, windows and
 * backpressure, retransmission, persist, close, reset, limits. */
#include "net_test_gw.h"

#define REMOTE MND_IP4(93, 184, 216, 34)
#define VM_ISN 1000u

/* The VM's side of one connection. */
typedef struct {
    int port;
    uint16_t sport;
    uint32_t snd; /* VM's next sequence number */
    uint32_t rcv; /* what the VM acknowledges next */
    uint16_t win; /* the window the VM advertises */
    int sock;     /* index in f->h.tcp */
} vm_tcp;

static void seg(fixture *f, int port, uint16_t sport, uint32_t seq, uint32_t ack, uint8_t flags, uint16_t win,
                const void *data, size_t len, uint16_t mss) {
    mnd_ip4 ip = 0;
    mnd_net_port_ip(f->net, port, &ip);
    uint8_t buf[MND_FRAME_MAX];
    mnd_ip_hdr_spec h = {.eth_dst = f->gw_mac, .eth_src = port_mac(f, port), .src = ip, .dst = REMOTE, .ttl = 64};
    mnd_tcp_spec t = {.sport = sport, .dport = 80, .seq = seq, .ack = ack, .flags = flags, .window = win, .mss = mss,
                      .wscale = -1};
    size_t n = mnd_build_tcp(buf, sizeof buf, &h, &t, data, len);
    CHECK(n > 0);
    mnd_net_input(f->net, port, buf, n);
}

/* The i-th frame delivered to `port` since the last clear, as TCP. */
static int nth_seg(fixture *f, int port, int nth, mnd_tcp *t) {
    int k = 0;
    for (int i = 0; i < f->h.count; i++) {
        if (f->h.frames[i].port != port) continue;
        if (k++ != nth) continue;
        mnd_eth eth;
        mnd_ip ip;
        const th_frame *fr = &f->h.frames[i];
        if (mnd_eth_parse(fr->data, fr->len, &eth) || mnd_ip_parse(eth.payload, eth.len, &ip)) return -1;
        if (!mnd_mac_eq(eth.src, f->gw_mac) || ip.src != REMOTE || ip.proto != MND_IPPROTO_TCP) return -1;
        return mnd_tcp_parse(&ip, t);
    }
    return -1;
}

static int last_seg(fixture *f, int port, mnd_tcp *t) { return nth_seg(f, port, th_count(&f->h, port) - 1, t); }

static uint32_t conn_of(fixture *f, int sock) { return f->h.tcp[sock].conn; }

/* SYN, host connects, SYN-ACK, ACK. */
static vm_tcp open_conn(fixture *f, int port, uint16_t sport, uint16_t win, uint16_t mss) {
    vm_tcp c = {.port = port, .sport = sport, .snd = VM_ISN, .win = win, .sock = -1};
    th_clear(&f->h);
    int before = f->h.ntcp;
    seg(f, port, sport, c.snd, 0, MND_TCP_SYN, win, NULL, 0, mss);
    c.snd++;
    if (f->h.ntcp != before + 1) return c;
    c.sock = before;
    mnd_net_tcp_connected(f->net, conn_of(f, c.sock), true);
    mnd_tcp t;
    if (last_seg(f, port, &t) == 0 && t.flags == (MND_TCP_SYN | MND_TCP_ACK) && t.ack == c.snd) {
        c.rcv = t.seq + 1;
        seg(f, port, sport, c.snd, c.rcv, MND_TCP_ACK, win, NULL, 0, 0);
    }
    th_clear(&f->h);
    return c;
}

static void vm_send(fixture *f, vm_tcp *c, const void *data, size_t len, uint8_t extra) {
    seg(f, c->port, c->sport, c->snd, c->rcv, (uint8_t)(MND_TCP_ACK | extra), c->win, data, len, 0);
    c->snd += (uint32_t)len + ((extra & MND_TCP_FIN) ? 1 : 0);
}

static void vm_ack(fixture *f, vm_tcp *c) {
    seg(f, c->port, c->sport, c->snd, c->rcv, MND_TCP_ACK, c->win, NULL, 0, 0);
}

/* Takes the data (and FIN) the VM received since the last clear, in order;
 * returns the byte count, -1 on a gap. */
static long take(fixture *f, vm_tcp *c, uint8_t *out, size_t cap, bool *fin) {
    long total = 0;
    int n = th_count(&f->h, c->port);
    for (int i = 0; i < n; i++) {
        mnd_tcp t;
        if (nth_seg(f, c->port, i, &t) != 0) return -1;
        if (t.len == 0 && !(t.flags & MND_TCP_FIN)) continue;
        if (t.seq != c->rcv) return -1;
        if (out && (size_t)total + t.len <= cap) memcpy(out + total, t.payload, t.len);
        total += (long)t.len;
        c->rcv += (uint32_t)t.len;
        if (t.flags & MND_TCP_FIN) {
            c->rcv++;
            if (fin) *fin = true;
        }
    }
    return total;
}

static uint8_t PATTERN[70000];

static void setup_tcp(fixture *f) {
    setup(f);
    lease(f, f->a);
    for (size_t i = 0; i < sizeof PATTERN; i++) PATTERN[i] = (uint8_t)i;
}

/* ---- Handshake ------------------------------------------------------------- */

static void test_handshake(void) {
    static fixture f;
    setup_tcp(&f);
    seg(&f, f.a, 40000, VM_ISN, 0, MND_TCP_SYN, 65535, NULL, 0, 1400);
    CHECK(f.h.ntcp == 1 && f.h.tcp[0].dst == REMOTE && f.h.tcp[0].port == 80);
    CHECK(f.h.count == 0); /* no SYN-ACK before the destination accepts */
    seg(&f, f.a, 40000, VM_ISN, 0, MND_TCP_SYN, 65535, NULL, 0, 1400); /* the VM retries */
    CHECK(f.h.ntcp == 1 && f.h.count == 0);
    mnd_net_tcp_connected(f.net, conn_of(&f, 0), true);
    mnd_tcp t;
    CHECK(th_count(&f.h, f.a) == 1 && last_seg(&f, f.a, &t) == 0);
    CHECK(t.flags == (MND_TCP_SYN | MND_TCP_ACK) && t.ack == VM_ISN + 1 && t.dport == 40000 && t.sport == 80);
    CHECK(t.mss == MND_NET_TCP_MSS && t.window == MND_NET_TCP_BUF && t.wscale == -1);
    uint32_t iss = t.seq;
    /* A retried SYN now gets the SYN-ACK again. */
    th_clear(&f.h);
    seg(&f, f.a, 40000, VM_ISN, 0, MND_TCP_SYN, 65535, NULL, 0, 1400);
    CHECK(last_seg(&f, f.a, &t) == 0 && t.flags == (MND_TCP_SYN | MND_TCP_ACK) && t.seq == iss);
    CHECK(!f.h.tcp[0].want_read);
    /* An ACK for something else: reset, the handshake stays open. */
    th_clear(&f.h);
    seg(&f, f.a, 40000, VM_ISN + 1, iss + 77, MND_TCP_ACK, 65535, NULL, 0, 0);
    CHECK(last_seg(&f, f.a, &t) == 0 && t.flags == MND_TCP_RST && t.seq == iss + 77 && !f.h.tcp[0].want_read);
    seg(&f, f.a, 40000, VM_ISN + 1, iss + 1, MND_TCP_ACK, 65535, NULL, 0, 0);
    CHECK(f.h.tcp[0].want_read && !f.h.tcp[0].want_write);
    CHECK(mnd_net_deadline(f.net) == UINT64_MAX); /* idle: no timers */
    /* A repeated report from the host changes nothing. */
    th_clear(&f.h);
    mnd_net_tcp_connected(f.net, conn_of(&f, 0), true);
    mnd_net_tcp_connected(f.net, conn_of(&f, 0), false);
    CHECK(f.h.count == 0 && f.h.tcp[0].open);
    teardown(&f);
}

static void test_data_in_the_ack_that_completes_the_handshake(void) {
    static fixture f;
    setup_tcp(&f);
    seg(&f, f.a, 40000, VM_ISN, 0, MND_TCP_SYN, 65535, NULL, 0, 1400);
    mnd_net_tcp_connected(f.net, conn_of(&f, 0), true);
    mnd_tcp t;
    CHECK(last_seg(&f, f.a, &t) == 0 && t.flags == (MND_TCP_SYN | MND_TCP_ACK));
    th_clear(&f.h);
    seg(&f, f.a, 40000, VM_ISN + 1, t.seq + 1, MND_TCP_ACK | MND_TCP_PSH, 65535, "hello", 5, 0);
    CHECK(f.h.tcp[0].nwritten == 5 && memcmp(f.h.tcp[0].written, "hello", 5) == 0);
    CHECK(last_seg(&f, f.a, &t) == 0 && t.ack == VM_ISN + 6);
    teardown(&f);
}

static void test_refused(void) {
    static fixture f;
    setup_tcp(&f);
    mnd_tcp t;
    /* The destination refuses. */
    seg(&f, f.a, 40000, VM_ISN, 0, MND_TCP_SYN, 65535, NULL, 0, 1400);
    mnd_net_tcp_connected(f.net, conn_of(&f, 0), false);
    CHECK(last_seg(&f, f.a, &t) == 0 && t.flags == (MND_TCP_RST | MND_TCP_ACK) && t.ack == VM_ISN + 1);
    CHECK(f.h.tcp[0].closed);
    /* The host refuses to even try. */
    th_clear(&f.h);
    f.h.tcp_refuse = true;
    seg(&f, f.a, 40001, VM_ISN, 0, MND_TCP_SYN, 65535, NULL, 0, 1400);
    CHECK(last_seg(&f, f.a, &t) == 0 && t.flags == (MND_TCP_RST | MND_TCP_ACK) && t.ack == VM_ISN + 1);
    f.h.tcp_refuse = false;
    /* No answer from the destination within the connect timeout. */
    th_clear(&f.h);
    seg(&f, f.a, 40002, VM_ISN, 0, MND_TCP_SYN, 65535, NULL, 0, 1400);
    CHECK(mnd_net_deadline(f.net) == f.h.now + MND_NET_TCP_CONNECT_TIMEOUT_MS);
    f.h.now += MND_NET_TCP_CONNECT_TIMEOUT_MS;
    mnd_net_poll(f.net);
    CHECK(last_seg(&f, f.a, &t) == 0 && (t.flags & MND_TCP_RST));
    CHECK(f.h.tcp[1].closed && f.h.tcp[1].aborted);
    /* A late report for a connection that is gone changes nothing. */
    th_clear(&f.h);
    mnd_net_tcp_connected(f.net, conn_of(&f, 1), true);
    CHECK(f.h.count == 0);
    teardown(&f);
}

static void test_syn_ack_retransmitted_then_given_up(void) {
    static fixture f;
    setup_tcp(&f);
    seg(&f, f.a, 40000, VM_ISN, 0, MND_TCP_SYN, 65535, NULL, 0, 1400);
    mnd_net_tcp_connected(f.net, conn_of(&f, 0), true);
    uint64_t wait = MND_NET_TCP_RTO_MS;
    int synacks = 0;
    for (int i = 0; i < MND_NET_TCP_MAX_RETRIES; i++) {
        th_clear(&f.h);
        f.h.now += wait;
        mnd_net_poll(f.net);
        mnd_tcp t;
        if (last_seg(&f, f.a, &t) == 0 && t.flags == (MND_TCP_SYN | MND_TCP_ACK)) synacks++;
        wait = wait * 2 > MND_NET_TCP_RTO_MAX_MS ? MND_NET_TCP_RTO_MAX_MS : wait * 2;
    }
    CHECK(synacks == MND_NET_TCP_MAX_RETRIES && !f.h.tcp[0].closed);
    th_clear(&f.h);
    f.h.now += wait;
    mnd_net_poll(f.net);
    mnd_tcp t;
    CHECK(last_seg(&f, f.a, &t) == 0 && (t.flags & MND_TCP_RST));
    CHECK(f.h.tcp[0].closed && f.h.tcp[0].aborted);
    teardown(&f);
}

/* ---- VM → Mac ------------------------------------------------------------------ */

static void test_data_to_the_mac(void) {
    static fixture f;
    setup_tcp(&f);
    vm_tcp c = open_conn(&f, f.a, 40000, 65535, 1400);
    CHECK(c.sock == 0);
    vm_send(&f, &c, "hello", 5, 0);
    CHECK(f.h.tcp[0].nwritten == 5 && memcmp(f.h.tcp[0].written, "hello", 5) == 0);
    mnd_tcp t;
    CHECK(th_count(&f.h, f.a) == 1 && last_seg(&f, f.a, &t) == 0);
    CHECK(t.flags == MND_TCP_ACK && t.ack == c.snd && t.window == MND_NET_TCP_BUF && t.len == 0);
    /* The socket takes part: the rest waits, the window shows it. */
    th_clear(&f.h);
    f.h.tcp[0].room = 3;
    vm_send(&f, &c, "world", 5, 0);
    CHECK(f.h.tcp[0].nwritten == 8 && memcmp(f.h.tcp[0].written, "hellowor", 8) == 0);
    CHECK(last_seg(&f, f.a, &t) == 0 && t.ack == c.snd && t.window == MND_NET_TCP_BUF - 2);
    CHECK(f.h.tcp[0].want_write);
    f.h.tcp[0].room = (size_t)-1;
    mnd_net_tcp_writable(f.net, conn_of(&f, 0));
    CHECK(f.h.tcp[0].nwritten == 10 && memcmp(f.h.tcp[0].written, "helloworld", 10) == 0);
    CHECK(!f.h.tcp[0].want_write);
    teardown(&f);
}

static void test_backpressure_towards_the_mac(void) {
    static fixture f;
    setup_tcp(&f);
    vm_tcp c = open_conn(&f, f.a, 40000, 65535, 1400);
    f.h.tcp[0].room = 0;
    f.h.tcp[0].pattern = true;
    for (int i = 0; i < MND_NET_TCP_BUF / 1024; i++) {
        th_clear(&f.h);
        vm_send(&f, &c, PATTERN + (size_t)i * 1024, 1024, 0);
    }
    mnd_tcp t;
    CHECK(last_seg(&f, f.a, &t) == 0 && t.ack == c.snd && t.window == 0);
    CHECK(f.h.tcp[0].nwritten == 0 && f.h.tcp[0].want_write);
    /* Beyond the window: not taken. */
    th_clear(&f.h);
    uint32_t edge = c.snd;
    vm_send(&f, &c, PATTERN + MND_NET_TCP_BUF, 1024, 0);
    CHECK(last_seg(&f, f.a, &t) == 0 && t.ack == edge && t.window == 0);
    c.snd = edge;
    /* The socket drains: all of it arrives, and the VM hears the window open. */
    th_clear(&f.h);
    f.h.tcp[0].room = (size_t)-1;
    mnd_net_tcp_writable(f.net, conn_of(&f, 0));
    CHECK(f.h.tcp[0].nwritten == MND_NET_TCP_BUF && f.h.tcp[0].pattern_ok);
    CHECK(last_seg(&f, f.a, &t) == 0 && t.flags == MND_TCP_ACK && t.window == MND_NET_TCP_BUF && t.ack == edge);
    vm_send(&f, &c, PATTERN + MND_NET_TCP_BUF, 1024, 0);
    CHECK(f.h.tcp[0].nwritten == MND_NET_TCP_BUF + 1024 && f.h.tcp[0].pattern_ok);
    teardown(&f);
}

static void test_out_of_order_and_duplicates(void) {
    static fixture f;
    setup_tcp(&f);
    vm_tcp c = open_conn(&f, f.a, 40000, 65535, 1400);
    uint32_t base = c.snd;
    mnd_tcp t;
    /* "world" before "hello": dropped, duplicate ACK. */
    seg(&f, f.a, 40000, base + 5, c.rcv, MND_TCP_ACK, 65535, "world", 5, 0);
    CHECK(f.h.tcp[0].nwritten == 0 && last_seg(&f, f.a, &t) == 0 && t.ack == base);
    seg(&f, f.a, 40000, base, c.rcv, MND_TCP_ACK, 65535, "hello", 5, 0);
    CHECK(f.h.tcp[0].nwritten == 5);
    seg(&f, f.a, 40000, base + 5, c.rcv, MND_TCP_ACK, 65535, "world", 5, 0);
    CHECK(f.h.tcp[0].nwritten == 10 && memcmp(f.h.tcp[0].written, "helloworld", 10) == 0);
    /* An old duplicate: acknowledged, not written again. */
    th_clear(&f.h);
    seg(&f, f.a, 40000, base, c.rcv, MND_TCP_ACK, 65535, "hello", 5, 0);
    CHECK(f.h.tcp[0].nwritten == 10 && last_seg(&f, f.a, &t) == 0 && t.ack == base + 10);
    /* Overlapping: only the new part. */
    seg(&f, f.a, 40000, base + 8, c.rcv, MND_TCP_ACK, 65535, "ldXYZ", 5, 0);
    CHECK(f.h.tcp[0].nwritten == 13 && memcmp(f.h.tcp[0].written, "helloworldXYZ", 13) == 0);
    teardown(&f);
}

/* ---- Mac → VM ------------------------------------------------------------------ */

static void test_data_to_the_vm(void) {
    static fixture f;
    setup_tcp(&f);
    vm_tcp c = open_conn(&f, f.a, 40000, 65535, 1400);
    f.h.tcp[0].src = PATTERN;
    f.h.tcp[0].src_len = 3000;
    mnd_net_tcp_readable(f.net, conn_of(&f, 0));
    CHECK(th_count(&f.h, f.a) == 3);
    mnd_tcp t;
    CHECK(nth_seg(&f, f.a, 0, &t) == 0 && t.len == 1400 && (t.flags & MND_TCP_ACK) && t.ack == c.snd);
    CHECK(t.window == MND_NET_TCP_BUF);
    CHECK(nth_seg(&f, f.a, 2, &t) == 0 && t.len == 200);
    static uint8_t got[70000];
    CHECK(take(&f, &c, got, sizeof got, NULL) == 3000 && memcmp(got, PATTERN, 3000) == 0);
    CHECK(mnd_net_deadline(f.net) == f.h.now + MND_NET_TCP_RTO_MS);
    th_clear(&f.h);
    vm_ack(&f, &c);
    CHECK(f.h.count == 0 && mnd_net_deadline(f.net) == UINT64_MAX);
    CHECK(f.h.tcp[0].want_read);
    teardown(&f);
}

static void test_the_vm_window_limits_what_is_sent(void) {
    static fixture f;
    setup_tcp(&f);
    vm_tcp c = open_conn(&f, f.a, 40000, 1000, 1400);
    f.h.tcp[0].src = PATTERN;
    f.h.tcp[0].src_len = 3000;
    mnd_net_tcp_readable(f.net, conn_of(&f, 0));
    static uint8_t got[4000];
    CHECK(take(&f, &c, got, sizeof got, NULL) == 1000);
    th_clear(&f.h);
    vm_ack(&f, &c);
    CHECK(take(&f, &c, got + 1000, sizeof got - 1000, NULL) == 1000);
    th_clear(&f.h);
    vm_ack(&f, &c);
    CHECK(take(&f, &c, got + 2000, sizeof got - 2000, NULL) == 1000);
    CHECK(memcmp(got, PATTERN, 3000) == 0);
    teardown(&f);
}

static void test_the_host_is_read_only_with_room(void) {
    static fixture f;
    setup_tcp(&f);
    vm_tcp c = open_conn(&f, f.a, 40000, 65535, 1400);
    f.h.tcp[0].src = PATTERN;
    f.h.tcp[0].src_len = 50000;
    mnd_net_tcp_readable(f.net, conn_of(&f, 0));
    CHECK(f.h.tcp[0].src_off == MND_NET_TCP_BUF); /* read what fits, no more */
    CHECK(!f.h.tcp[0].want_read);
    static uint8_t got[70000];
    long n = take(&f, &c, got, sizeof got, NULL);
    CHECK(n == MND_NET_TCP_BUF);
    th_clear(&f.h);
    vm_ack(&f, &c); /* frees the buffer: reading resumes */
    CHECK(f.h.tcp[0].want_read);
    mnd_net_tcp_readable(f.net, conn_of(&f, 0));
    n += take(&f, &c, got + n, sizeof got - (size_t)n, NULL);
    CHECK(n == 50000 && memcmp(got, PATTERN, 50000) == 0);
    teardown(&f);
}

static void test_default_mss(void) {
    static fixture f;
    setup_tcp(&f);
    vm_tcp c = open_conn(&f, f.a, 40000, 65535, 0); /* no MSS option */
    f.h.tcp[0].src = PATTERN;
    f.h.tcp[0].src_len = 1000;
    mnd_net_tcp_readable(f.net, conn_of(&f, 0));
    mnd_tcp t;
    CHECK(th_count(&f.h, f.a) == 2 && nth_seg(&f, f.a, 0, &t) == 0 && t.len == 536);
    (void)c;
    teardown(&f);
}

/* A guest asking for tiny segments gets the minimum (536): MSS 1 would
 * make netd, shared by every VM, build thousands of frames (F-15). */
static void test_a_tiny_mss_is_raised(void) {
    static fixture f;
    setup_tcp(&f);
    vm_tcp c = open_conn(&f, f.a, 40000, 65535, 1);
    f.h.tcp[0].src = PATTERN;
    f.h.tcp[0].src_len = 1000;
    mnd_net_tcp_readable(f.net, conn_of(&f, 0));
    mnd_tcp t;
    CHECK(th_count(&f.h, f.a) == 2 && nth_seg(&f, f.a, 0, &t) == 0 && t.len == 536);
    (void)c;
    teardown(&f);
}

static void test_retransmission_then_reset(void) {
    static fixture f;
    setup_tcp(&f);
    vm_tcp c = open_conn(&f, f.a, 40000, 65535, 1400);
    f.h.tcp[0].src = PATTERN;
    f.h.tcp[0].src_len = 3000;
    mnd_net_tcp_readable(f.net, conn_of(&f, 0));
    uint32_t first = c.rcv;
    uint64_t wait = MND_NET_TCP_RTO_MS;
    int resent = 0;
    for (int i = 0; i < MND_NET_TCP_MAX_RETRIES; i++) {
        th_clear(&f.h);
        f.h.now += wait - 1;
        mnd_net_poll(f.net);
        CHECK(f.h.count == 0); /* not yet */
        f.h.now += 1;
        mnd_net_poll(f.net);
        vm_tcp copy = c;
        if (take(&f, &copy, NULL, 0, NULL) == 3000) resent++; /* all of it, from the first byte */
        wait = wait * 2 > MND_NET_TCP_RTO_MAX_MS ? MND_NET_TCP_RTO_MAX_MS : wait * 2;
    }
    CHECK(resent == MND_NET_TCP_MAX_RETRIES && c.rcv == first);
    th_clear(&f.h);
    f.h.now += wait;
    mnd_net_poll(f.net);
    mnd_tcp t;
    CHECK(last_seg(&f, f.a, &t) == 0 && (t.flags & MND_TCP_RST));
    CHECK(f.h.tcp[0].closed && f.h.tcp[0].aborted);
    teardown(&f);
}

static void test_an_ack_resets_the_retries(void) {
    static fixture f;
    setup_tcp(&f);
    vm_tcp c = open_conn(&f, f.a, 40000, 65535, 1400);
    f.h.tcp[0].src = PATTERN;
    f.h.tcp[0].src_len = 2800;
    mnd_net_tcp_readable(f.net, conn_of(&f, 0));
    for (int i = 0; i < 5; i++) {
        f.h.now = mnd_net_deadline(f.net);
        mnd_net_poll(f.net);
    }
    /* The VM acknowledges the first segment only: the RTO starts over. */
    th_clear(&f.h);
    c.rcv += 1400;
    vm_ack(&f, &c);
    CHECK(mnd_net_deadline(f.net) == f.h.now + MND_NET_TCP_RTO_MS);
    teardown(&f);
}

static void test_zero_window_persist(void) {
    static fixture f;
    setup_tcp(&f);
    vm_tcp c = open_conn(&f, f.a, 40000, 0, 1400);
    f.h.tcp[0].src = PATTERN;
    f.h.tcp[0].src_len = 100;
    mnd_net_tcp_readable(f.net, conn_of(&f, 0));
    CHECK(f.h.count == 0); /* the VM has no room */
    CHECK(mnd_net_deadline(f.net) == f.h.now + MND_NET_TCP_RTO_MS);
    /* Probes go on as long as the VM answers them, past the retry limit,
     * further and further apart (up to the maximum). */
    uint64_t last_gap = 0, last_at = f.h.now;
    bool growing = true;
    for (int i = 0; i < MND_NET_TCP_MAX_RETRIES + 5; i++) {
        th_clear(&f.h);
        f.h.now = mnd_net_deadline(f.net);
        uint64_t gap = f.h.now - last_at;
        if (gap < last_gap || (i > 0 && i < 5 && gap == last_gap)) growing = false;
        last_gap = gap;
        last_at = f.h.now;
        mnd_net_poll(f.net);
        mnd_tcp t;
        CHECK(last_seg(&f, f.a, &t) == 0 && t.len == 1 && t.seq == c.rcv && !(t.flags & MND_TCP_RST));
        vm_ack(&f, &c); /* still no room */
    }
    CHECK(!f.h.tcp[0].closed && growing && last_gap == MND_NET_TCP_RTO_MAX_MS);
    /* A probe lost now and then is not a dead VM: answered probes clear it. */
    for (int i = 0; i < MND_NET_TCP_MAX_RETRIES + 2; i++) {
        f.h.now = mnd_net_deadline(f.net); /* probe */
        mnd_net_poll(f.net);
        f.h.now = mnd_net_deadline(f.net); /* unanswered: retransmission timeout */
        mnd_net_poll(f.net);
        f.h.now = mnd_net_deadline(f.net); /* probe again */
        mnd_net_poll(f.net);
        vm_ack(&f, &c);                    /* answered, still no room */
    }
    CHECK(!f.h.tcp[0].closed);
    /* Room at last: the data goes. */
    th_clear(&f.h);
    c.win = 65535;
    vm_ack(&f, &c);
    static uint8_t got[200];
    CHECK(take(&f, &c, got, sizeof got, NULL) == 100 && memcmp(got, PATTERN, 100) == 0);
    teardown(&f);
}

/* ---- Close and reset ---------------------------------------------------------------- */

static void test_fin_waits_for_the_data(void) {
    static fixture f;
    setup_tcp(&f);
    vm_tcp c = open_conn(&f, f.a, 40000, 1000, 1400);
    f.h.tcp[0].src = PATTERN;
    f.h.tcp[0].src_len = 3000;
    f.h.tcp[0].eof = true;
    mnd_net_tcp_readable(f.net, conn_of(&f, 0));
    static uint8_t got[4000];
    long n = 0;
    bool fin = false;
    for (int i = 0; i < 4 && !fin; i++) {
        long k = take(&f, &c, got + n, sizeof got - (size_t)n, &fin);
        CHECK(k >= 0);
        if (k < 0) break;
        n += k;
        CHECK(fin == (n == 3000)); /* the FIN comes last, never before the data */
        th_clear(&f.h);
        vm_ack(&f, &c);
    }
    CHECK(n == 3000 && fin && memcmp(got, PATTERN, 3000) == 0);
    teardown(&f);
}

static void test_no_close_before_the_last_data_is_written(void) {
    static fixture f;
    setup_tcp(&f);
    vm_tcp c = open_conn(&f, f.a, 40000, 65535, 1400);
    f.h.tcp[0].eof = true;
    mnd_net_tcp_readable(f.net, conn_of(&f, 0));
    bool fin = false;
    take(&f, &c, NULL, 0, &fin);
    vm_ack(&f, &c); /* our FIN acknowledged */
    f.h.tcp[0].room = 0;
    vm_send(&f, &c, "tail", 4, MND_TCP_FIN);
    CHECK(!f.h.tcp[0].closed && !f.h.tcp[0].shut);
    f.h.tcp[0].room = (size_t)-1;
    mnd_net_tcp_writable(f.net, conn_of(&f, 0));
    CHECK(f.h.tcp[0].nwritten == 4 && f.h.tcp[0].shut && f.h.tcp[0].closed && !f.h.tcp[0].aborted);
    teardown(&f);
}

static void test_the_vm_closes_first(void) {
    static fixture f;
    setup_tcp(&f);
    vm_tcp c = open_conn(&f, f.a, 40000, 65535, 1400);
    f.h.tcp[0].room = 1;
    vm_send(&f, &c, "bye", 3, MND_TCP_FIN);
    mnd_tcp t;
    CHECK(last_seg(&f, f.a, &t) == 0 && t.ack == c.snd); /* FIN acknowledged */
    CHECK(!f.h.tcp[0].shut); /* data still waits for the socket */
    f.h.tcp[0].room = (size_t)-1;
    mnd_net_tcp_writable(f.net, conn_of(&f, 0));
    CHECK(f.h.tcp[0].nwritten == 3 && f.h.tcp[0].shut);
    /* The destination answers and closes. */
    th_clear(&f.h);
    f.h.tcp[0].src = (const uint8_t *)"ok";
    f.h.tcp[0].src_len = 2;
    f.h.tcp[0].eof = true;
    mnd_net_tcp_readable(f.net, conn_of(&f, 0));
    bool fin = false;
    uint8_t got[8];
    CHECK(take(&f, &c, got, sizeof got, &fin) == 2 && fin && memcmp(got, "ok", 2) == 0);
    CHECK(!f.h.tcp[0].closed);
    vm_ack(&f, &c);
    CHECK(f.h.tcp[0].closed && !f.h.tcp[0].aborted);
    CHECK(mnd_net_deadline(f.net) == UINT64_MAX);
    /* The same ports again: a new connection, in the same slot. */
    vm_tcp again = open_conn(&f, f.a, 40000, 65535, 1400);
    CHECK(again.sock == 1 && f.h.tcp[1].open);
    CHECK((conn_of(&f, 1) & 0xffff) == (conn_of(&f, 0) & 0xffff) && conn_of(&f, 1) != conn_of(&f, 0));
    /* The old id reaches nothing. */
    f.h.tcp[1].src = (const uint8_t *)"zz";
    f.h.tcp[1].src_len = 2;
    mnd_net_tcp_readable(f.net, conn_of(&f, 0));
    mnd_net_tcp_writable(f.net, conn_of(&f, 0));
    CHECK(f.h.tcp[1].src_off == 0 && f.h.count == 0);
    teardown(&f);
}

static void test_the_mac_closes_first(void) {
    static fixture f;
    setup_tcp(&f);
    vm_tcp c = open_conn(&f, f.a, 40000, 65535, 1400);
    f.h.tcp[0].src = (const uint8_t *)"banner";
    f.h.tcp[0].src_len = 6;
    f.h.tcp[0].eof = true;
    mnd_net_tcp_readable(f.net, conn_of(&f, 0));
    bool fin = false;
    uint8_t got[8];
    CHECK(take(&f, &c, got, sizeof got, &fin) == 6 && fin);
    CHECK(!f.h.tcp[0].want_read);
    th_clear(&f.h);
    vm_ack(&f, &c);
    /* Half-closed: the VM may still send. */
    vm_send(&f, &c, "late", 4, 0);
    CHECK(f.h.tcp[0].nwritten == 4 && !f.h.tcp[0].closed);
    vm_send(&f, &c, NULL, 0, MND_TCP_FIN);
    mnd_tcp t;
    CHECK(last_seg(&f, f.a, &t) == 0 && t.ack == c.snd);
    CHECK(f.h.tcp[0].shut && f.h.tcp[0].closed && !f.h.tcp[0].aborted);
    teardown(&f);
}

static void test_our_fin_is_retransmitted(void) {
    static fixture f;
    setup_tcp(&f);
    vm_tcp c = open_conn(&f, f.a, 40000, 65535, 1400);
    f.h.tcp[0].eof = true;
    mnd_net_tcp_readable(f.net, conn_of(&f, 0));
    bool fin = false;
    CHECK(take(&f, &c, NULL, 0, &fin) == 0 && fin);
    th_clear(&f.h);
    f.h.now = mnd_net_deadline(f.net);
    mnd_net_poll(f.net);
    mnd_tcp t;
    CHECK(last_seg(&f, f.a, &t) == 0 && (t.flags & MND_TCP_FIN) && t.seq == c.rcv - 1);
    teardown(&f);
}

static void test_reset_by_the_vm(void) {
    static fixture f;
    setup_tcp(&f);
    vm_tcp c = open_conn(&f, f.a, 40000, 65535, 1400);
    /* Outside the window: ignored. */
    seg(&f, f.a, 40000, c.snd + 100000, 0, MND_TCP_RST, 0, NULL, 0, 0);
    CHECK(!f.h.tcp[0].closed);
    seg(&f, f.a, 40000, c.snd, 0, MND_TCP_RST, 0, NULL, 0, 0);
    CHECK(f.h.tcp[0].closed && f.h.tcp[0].aborted && f.h.count == 0);
    teardown(&f);
}

/* The connection log counts what passes, both ways, and the connection
 * open until it closes. */
static void test_the_log_counts_the_bytes(void) {
    static fixture f;
    setup_tcp(&f);
    vm_tcp c = open_conn(&f, f.a, 40000, 65535, 1400);
    CHECK(c.sock == 0);
    vm_send(&f, &c, "hello world", 11, 0);
    f.h.tcp[0].src = PATTERN;
    f.h.tcp[0].src_len = 3000;
    mnd_net_tcp_readable(f.net, conn_of(&f, 0));
    mnd_net_conn all[2];
    CHECK(mnd_net_conns(f.net, f.a, all, 2) == 1);
    CHECK(all[0].proto == MND_IPPROTO_TCP && all[0].dst == REMOTE && all[0].dport == 80);
    CHECK(all[0].verdict == MND_CONN_ALLOWED && all[0].opened == 1 && all[0].active == 1);
    CHECK(all[0].bytes_out == 11 && all[0].bytes_in == 3000);
    seg(&f, f.a, 40000, c.snd, 0, MND_TCP_RST, 0, NULL, 0, 0);
    CHECK(mnd_net_conns(f.net, f.a, all, 2) == 1 && all[0].active == 0 && all[0].bytes_in == 3000);
    teardown(&f);
}

static void test_socket_errors_reset_the_vm(void) {
    static fixture f;
    setup_tcp(&f);
    vm_tcp c = open_conn(&f, f.a, 40000, 65535, 1400);
    f.h.tcp[0].read_error = true;
    mnd_net_tcp_readable(f.net, conn_of(&f, 0));
    mnd_tcp t;
    CHECK(last_seg(&f, f.a, &t) == 0 && (t.flags & MND_TCP_RST) && t.seq == c.rcv);
    CHECK(f.h.tcp[0].closed && f.h.tcp[0].aborted);
    vm_tcp d = open_conn(&f, f.a, 40001, 65535, 1400);
    f.h.tcp[1].write_error = true;
    vm_send(&f, &d, "x", 1, 0);
    CHECK(last_seg(&f, f.a, &t) == 0 && (t.flags & MND_TCP_RST));
    CHECK(f.h.tcp[1].closed && f.h.tcp[1].aborted);
    teardown(&f);
}

static void test_segments_for_no_connection(void) {
    static fixture f;
    setup_tcp(&f);
    mnd_tcp t;
    seg(&f, f.a, 40000, 5000, 7777, MND_TCP_ACK, 65535, "x", 1, 0);
    CHECK(last_seg(&f, f.a, &t) == 0 && t.flags == MND_TCP_RST && t.seq == 7777);
    th_clear(&f.h);
    seg(&f, f.a, 40000, 5000, 0, MND_TCP_PSH, 65535, "xy", 2, 0);
    CHECK(last_seg(&f, f.a, &t) == 0 && t.flags == (MND_TCP_RST | MND_TCP_ACK) && t.seq == 0 && t.ack == 5002);
    th_clear(&f.h);
    seg(&f, f.a, 40000, 5000, 0, MND_TCP_RST, 65535, NULL, 0, 0);
    CHECK(f.h.count == 0 && f.h.ntcp == 0);
    teardown(&f);
}

static void test_ack_for_data_never_sent(void) {
    static fixture f;
    setup_tcp(&f);
    vm_tcp c = open_conn(&f, f.a, 40000, 65535, 1400);
    seg(&f, f.a, 40000, c.snd, c.rcv + 5000, MND_TCP_ACK, 65535, "x", 1, 0);
    mnd_tcp t;
    CHECK(last_seg(&f, f.a, &t) == 0 && t.ack == c.snd && f.h.tcp[0].nwritten == 0); /* ACKed, dropped */
    teardown(&f);
}

/* ---- Limits and lifetime --------------------------------------------------------------- */

static void test_limits(void) {
    static fixture f;
    setup_tcp(&f);
    for (int i = 0; i < MND_NET_MAX_TCP_CONNS_PER_PORT; i++)
        seg(&f, f.a, (uint16_t)(20000 + i), VM_ISN, 0, MND_TCP_SYN, 65535, NULL, 0, 1400);
    CHECK(f.h.ntcp == MND_NET_MAX_TCP_CONNS_PER_PORT);
    th_clear(&f.h);
    seg(&f, f.a, 30000, VM_ISN, 0, MND_TCP_SYN, 65535, NULL, 0, 1400);
    mnd_tcp t;
    CHECK(f.h.ntcp == MND_NET_MAX_TCP_CONNS_PER_PORT && last_seg(&f, f.a, &t) == 0 && (t.flags & MND_TCP_RST));
    int vms = MND_NET_MAX_TCP_CONNS / MND_NET_MAX_TCP_CONNS_PER_PORT;
    for (int v = 0; v < vms; v++) {
        int port = add_vm(&f, th_mac((uint8_t)(30 + v)));
        CHECK(lease(&f, port) != 0);
        for (int i = 0; i < MND_NET_MAX_TCP_CONNS_PER_PORT; i++)
            seg(&f, port, (uint16_t)(20000 + i), VM_ISN, 0, MND_TCP_SYN, 65535, NULL, 0, 1400);
    }
    CHECK(f.h.ntcp == MND_NET_MAX_TCP_CONNS);
    teardown(&f);
}

static void test_connections_close_with_their_vm(void) {
    static fixture f;
    setup_tcp(&f);
    lease(&f, f.b);
    open_conn(&f, f.a, 40000, 65535, 1400);
    open_conn(&f, f.a, 40001, 65535, 1400);
    open_conn(&f, f.b, 40000, 65535, 1400);
    mnd_net_remove_port(f.net, f.a);
    CHECK(f.h.tcp[0].closed && f.h.tcp[0].aborted && f.h.tcp[1].closed && f.h.tcp[2].open);
    mnd_net_tcp_readable(f.net, conn_of(&f, 0)); /* a stale id */
    mnd_net_destroy(f.net);
    CHECK(f.h.tcp[2].closed);
}

static void test_only_nat_networks_leave(void) {
    static fixture f;
    setup_kind(&f, MND_NET_HOST_ONLY, 24);
    lease(&f, f.a);
    seg(&f, f.a, 40000, VM_ISN, 0, MND_TCP_SYN, 65535, NULL, 0, 1400);
    CHECK(f.h.ntcp == 0 && f.h.count == 0 && stats(&f, f.a).dropped_policy == 1);
    teardown(&f);
}

int main(void) {
    fprintf(stderr, "mnd_net TCP tests\n");
    RUN(test_handshake);
    RUN(test_data_in_the_ack_that_completes_the_handshake);
    RUN(test_refused);
    RUN(test_syn_ack_retransmitted_then_given_up);
    RUN(test_data_to_the_mac);
    RUN(test_backpressure_towards_the_mac);
    RUN(test_out_of_order_and_duplicates);
    RUN(test_data_to_the_vm);
    RUN(test_the_vm_window_limits_what_is_sent);
    RUN(test_the_host_is_read_only_with_room);
    RUN(test_default_mss);
    RUN(test_a_tiny_mss_is_raised);
    RUN(test_retransmission_then_reset);
    RUN(test_an_ack_resets_the_retries);
    RUN(test_zero_window_persist);
    RUN(test_fin_waits_for_the_data);
    RUN(test_no_close_before_the_last_data_is_written);
    RUN(test_the_vm_closes_first);
    RUN(test_the_mac_closes_first);
    RUN(test_our_fin_is_retransmitted);
    RUN(test_reset_by_the_vm);
    RUN(test_the_log_counts_the_bytes);
    RUN(test_socket_errors_reset_the_vm);
    RUN(test_segments_for_no_connection);
    RUN(test_ack_for_data_never_sent);
    RUN(test_limits);
    RUN(test_connections_close_with_their_vm);
    RUN(test_only_nat_networks_leave);
    TEST_MAIN_END();
}
