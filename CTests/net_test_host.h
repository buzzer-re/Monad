/* An in-memory mnd_net_host for tests: a manual clock and a log of the
 * frames delivered to each port. */
#ifndef NET_TEST_HOST_H
#define NET_TEST_HOST_H

#include <stdio.h>
#include "../Monad/Backend/net/mnd_net.h"

#include <stdlib.h>
#include <string.h>

#define TH_MAX_FRAMES 256

typedef struct {
    int port;
    size_t len;
    uint8_t data[MND_FRAME_MAX];
} th_frame;

typedef struct {
    uint64_t now;
    th_frame frames[TH_MAX_FRAMES];
    int count;
    /* DNS queries handed to the host. */
    int dns_count;
    uint32_t dns_id;
    uint8_t dns_msg[MND_FRAME_MAX];
    size_t dns_len;
    /* UDP sockets the core asked for. */
    struct {
        uint32_t flow;
        mnd_ip4 dst;
        uint16_t port;
        bool open;
        int sent;
        size_t last_len;
        uint8_t last[MND_FRAME_MAX];
    } udp[2048];
    int nudp, udp_opened, udp_closed;
    bool udp_refuse;
    /* ICMP echo sockets. */
    struct {
        uint32_t flow;
        mnd_ip4 dst;
        bool open;
        int sent;
        uint16_t last_seq;
        size_t last_len;
        uint8_t last[MND_FRAME_MAX];
    } icmp[64];
    int nicmp, icmp_closed;
    /* TCP sockets the core asked for. */
    struct {
        uint32_t conn;
        mnd_ip4 dst;
        uint16_t port;
        bool open, closed, aborted, shut, want_read, want_write;
        int interest_calls;
        /* Bytes the core wrote: the first 4096 kept, all checked against
         * the pattern byte (offset & 0xff) when `pattern` is set. */
        uint8_t written[4096];
        size_t nwritten;
        bool pattern, pattern_ok;
        size_t room; /* bytes accepted before the socket is full */
        bool write_error;
        /* Bytes the socket has to read. */
        const uint8_t *src;
        size_t src_len, src_off;
        bool eof, read_error;
    } tcp[640];
    int ntcp;
    bool tcp_refuse;
    /* Monitor-mode asks, in order. */
    struct {
        int port;
        uint8_t proto;
        mnd_ip4 dst;
        uint16_t dport;
    } asks[256];
    int nasks;
    /* Monitor-mode lookups asked about, in order. */
    char lookups[16][254];
    int lookup_ports[16];
    int nlookups;
} test_host;

static inline uint64_t th_now(void *ctx) { return ((test_host *)ctx)->now; }

static inline void th_send(void *ctx, int port, const uint8_t *frame, size_t len) {
    test_host *h = ctx;
    if (h->count >= TH_MAX_FRAMES || len > MND_FRAME_MAX) return;
    th_frame *f = &h->frames[h->count++];
    f->port = port;
    f->len = len;
    memcpy(f->data, frame, len);
}

static inline void th_dns(void *ctx, uint32_t id, const uint8_t *query, size_t len) {
    test_host *h = ctx;
    h->dns_count++;
    h->dns_id = id;
    h->dns_len = len <= sizeof h->dns_msg ? len : 0;
    memcpy(h->dns_msg, query, h->dns_len);
}

/* The socket for `flow` (open or not), or NULL. */
static inline int th_udp_find(test_host *h, uint32_t flow) {
    for (int i = h->nudp - 1; i >= 0; i--)
        if (h->udp[i].flow == flow) return i;
    return -1;
}

static inline int th_udp_open(void *ctx, uint32_t flow, mnd_ip4 dst, uint16_t port) {
    test_host *h = ctx;
    if (h->udp_refuse || h->nudp >= 2048) return -1;
    int i = h->nudp++;
    memset(&h->udp[i], 0, sizeof h->udp[i]);
    h->udp[i].flow = flow;
    h->udp[i].dst = dst;
    h->udp[i].port = port;
    h->udp[i].open = true;
    h->udp_opened++;
    return 0;
}

static inline void th_udp_send(void *ctx, uint32_t flow, const uint8_t *data, size_t len) {
    test_host *h = ctx;
    int i = th_udp_find(h, flow);
    if (i < 0 || !h->udp[i].open || len > MND_FRAME_MAX) return;
    h->udp[i].sent++;
    h->udp[i].last_len = len;
    memcpy(h->udp[i].last, data, len);
}

static inline void th_udp_close(void *ctx, uint32_t flow) {
    test_host *h = ctx;
    int i = th_udp_find(h, flow);
    if (i < 0 || !h->udp[i].open) return;
    h->udp[i].open = false;
    h->udp_closed++;
}

static inline int th_icmp_find(test_host *h, uint32_t flow) {
    for (int i = h->nicmp - 1; i >= 0; i--)
        if (h->icmp[i].flow == flow) return i;
    return -1;
}

static inline int th_icmp_open(void *ctx, uint32_t flow, mnd_ip4 dst) {
    test_host *h = ctx;
    if (h->nicmp >= 64) return -1;
    int i = h->nicmp++;
    memset(&h->icmp[i], 0, sizeof h->icmp[i]);
    h->icmp[i].flow = flow;
    h->icmp[i].dst = dst;
    h->icmp[i].open = true;
    return 0;
}

static inline void th_icmp_send(void *ctx, uint32_t flow, uint16_t seq, const uint8_t *data, size_t len) {
    test_host *h = ctx;
    int i = th_icmp_find(h, flow);
    if (i < 0 || !h->icmp[i].open || len > MND_FRAME_MAX) return;
    h->icmp[i].sent++;
    h->icmp[i].last_seq = seq;
    h->icmp[i].last_len = len;
    memcpy(h->icmp[i].last, data, len);
}

static inline void th_icmp_close(void *ctx, uint32_t flow) {
    test_host *h = ctx;
    int i = th_icmp_find(h, flow);
    if (i < 0 || !h->icmp[i].open) return;
    h->icmp[i].open = false;
    h->icmp_closed++;
}

static inline int th_tcp_find(test_host *h, uint32_t conn) {
    for (int i = h->ntcp - 1; i >= 0; i--)
        if (h->tcp[i].conn == conn && h->tcp[i].open) return i;
    return -1;
}

static inline int th_tcp_connect(void *ctx, uint32_t conn, mnd_ip4 dst, uint16_t port) {
    test_host *h = ctx;
    if (h->tcp_refuse || h->ntcp >= 640) return -1;
    int i = h->ntcp++;
    memset(&h->tcp[i], 0, sizeof h->tcp[i]);
    h->tcp[i].conn = conn;
    h->tcp[i].dst = dst;
    h->tcp[i].port = port;
    h->tcp[i].open = true;
    h->tcp[i].room = (size_t)-1;
    h->tcp[i].pattern_ok = true;
    return 0;
}

static inline ssize_t th_tcp_read(void *ctx, uint32_t conn, uint8_t *buf, size_t cap) {
    test_host *h = ctx;
    int i = th_tcp_find(h, conn);
    if (i < 0) return MND_NET_IO_ERROR;
    if (h->tcp[i].read_error) return MND_NET_IO_ERROR;
    size_t left = h->tcp[i].src_len - h->tcp[i].src_off;
    if (!left) return h->tcp[i].eof ? 0 : MND_NET_IO_AGAIN;
    size_t n = left < cap ? left : cap;
    memcpy(buf, h->tcp[i].src + h->tcp[i].src_off, n);
    h->tcp[i].src_off += n;
    return (ssize_t)n;
}

static inline ssize_t th_tcp_write(void *ctx, uint32_t conn, const uint8_t *data, size_t len) {
    test_host *h = ctx;
    int i = th_tcp_find(h, conn);
    if (i < 0 || h->tcp[i].write_error) return MND_NET_IO_ERROR;
    size_t n = len < h->tcp[i].room ? len : h->tcp[i].room;
    for (size_t k = 0; k < n; k++) {
        size_t at = h->tcp[i].nwritten + k;
        if (at < sizeof h->tcp[i].written) h->tcp[i].written[at] = data[k];
        if (h->tcp[i].pattern && data[k] != (uint8_t)at) h->tcp[i].pattern_ok = false;
    }
    h->tcp[i].nwritten += n;
    if (h->tcp[i].room != (size_t)-1) h->tcp[i].room -= n;
    return (ssize_t)n;
}

static inline void th_tcp_interest(void *ctx, uint32_t conn, bool read, bool write) {
    test_host *h = ctx;
    int i = th_tcp_find(h, conn);
    if (i < 0) return;
    h->tcp[i].want_read = read;
    h->tcp[i].want_write = write;
    h->tcp[i].interest_calls++;
}

static inline void th_tcp_shutdown(void *ctx, uint32_t conn) {
    test_host *h = ctx;
    int i = th_tcp_find(h, conn);
    if (i >= 0) h->tcp[i].shut = true;
}

static inline void th_tcp_close(void *ctx, uint32_t conn, bool abort) {
    test_host *h = ctx;
    int i = th_tcp_find(h, conn);
    if (i < 0) return;
    h->tcp[i].open = false;
    h->tcp[i].closed = true;
    h->tcp[i].aborted = abort;
}

static inline void th_ask(void *ctx, int port, uint8_t proto, mnd_ip4 dst, uint16_t dport) {
    test_host *h = ctx;
    if (h->nasks >= 256) return;
    h->asks[h->nasks].port = port;
    h->asks[h->nasks].proto = proto;
    h->asks[h->nasks].dst = dst;
    h->asks[h->nasks].dport = dport;
    h->nasks++;
}

static inline void th_ask_lookup(void *ctx, int port, const char *name) {
    test_host *h = ctx;
    if (h->nlookups >= 16) return;
    snprintf(h->lookups[h->nlookups], sizeof h->lookups[0], "%s", name);
    h->lookup_ports[h->nlookups] = port;
    h->nlookups++;
}

static inline mnd_net_host th_host(test_host *h) {
    memset(h, 0, sizeof *h);
    return (mnd_net_host){.ctx = h, .now_ms = th_now, .send_frame = th_send, .dns_query = th_dns,
                          .udp_open = th_udp_open, .udp_send = th_udp_send, .udp_close = th_udp_close,
                          .icmp_open = th_icmp_open, .icmp_send = th_icmp_send, .icmp_close = th_icmp_close,
                          .tcp_connect = th_tcp_connect, .tcp_read = th_tcp_read, .tcp_write = th_tcp_write,
                          .tcp_interest = th_tcp_interest, .tcp_shutdown = th_tcp_shutdown,
                          .tcp_close = th_tcp_close, .ask = th_ask, .ask_lookup = th_ask_lookup};
}

/* Frames delivered to `port` since the last th_clear. */
static inline int th_count(const test_host *h, int port) {
    int n = 0;
    for (int i = 0; i < h->count; i++)
        if (h->frames[i].port == port) n++;
    return n;
}

static inline const th_frame *th_last(const test_host *h, int port) {
    for (int i = h->count - 1; i >= 0; i--)
        if (h->frames[i].port == port) return &h->frames[i];
    return NULL;
}

static inline void th_clear(test_host *h) { h->count = 0; }

/* Leaves an IPv4 TCP or UDP frame's checksum the way a guest using checksum
 * offload hands it to its NIC: only the pseudo-header sum, not complemented,
 * for the NIC to finish. */
static inline void th_offload(uint8_t *frame) {
    uint8_t *ih = frame + MND_ETH_HLEN;
    size_t hlen = (size_t)(ih[0] & 0x0f) * 4;
    uint8_t *l4 = ih + hlen;
    uint8_t proto = ih[9];
    uint16_t len = (uint16_t)(((ih[2] << 8) | ih[3]) - hlen);
    mnd_ip4 src = (mnd_ip4)ih[12] << 24 | (mnd_ip4)ih[13] << 16 | (mnd_ip4)ih[14] << 8 | ih[15];
    mnd_ip4 dst = (mnd_ip4)ih[16] << 24 | (mnd_ip4)ih[17] << 16 | (mnd_ip4)ih[18] << 8 | ih[19];
    uint16_t partial = (uint16_t)~mnd_csum_finish(mnd_csum_pseudo(src, dst, proto, len));
    size_t at = proto == MND_IPPROTO_TCP ? 16 : 6;
    l4[at] = (uint8_t)(partial >> 8);
    l4[at + 1] = (uint8_t)partial;
}

static inline mnd_mac th_mac(uint8_t last) { return (mnd_mac){{0x02, 0x4d, 0x4f, 0x4e, 0x00, last}}; }

/* A minimal Ethernet frame from src to dst with a payload of 46 bytes. */
static inline size_t th_eth(uint8_t *buf, mnd_mac dst, mnd_mac src, uint16_t type) {
    memset(buf, 0, 60);
    memcpy(buf, dst.b, 6);
    memcpy(buf + 6, src.b, 6);
    buf[12] = (uint8_t)(type >> 8);
    buf[13] = (uint8_t)type;
    return 60;
}

#endif
