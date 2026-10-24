/*
 * mnd_net_dhcp.c — DHCP message parsing and building. See mnd_net_dhcp.h.
 */
#include "mnd_net_dhcp.h"

#include <string.h>

#define BOOTP_LEN 236
#define OPTIONS_AT (BOOTP_LEN + 4)

enum {
    OPT_PAD = 0,
    OPT_SUBNET_MASK = 1,
    OPT_ROUTER = 3,
    OPT_DNS = 6,
    OPT_HOSTNAME = 12,
    OPT_BROADCAST = 28,
    OPT_REQUESTED_IP = 50,
    OPT_LEASE_TIME = 51,
    OPT_MESSAGE_TYPE = 53,
    OPT_SERVER_ID = 54,
    OPT_T1 = 58,
    OPT_T2 = 59,
    OPT_END = 255,
};

static const uint8_t COOKIE[4] = {99, 130, 83, 99};

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}
static void wr16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)v;
}
static void wr32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)v;
}

/* Hostnames end up in logs and later in DNS: printable ASCII or nothing. */
static void copy_hostname(char *dst, const uint8_t *src, size_t len) {
    dst[0] = 0;
    if (len > MND_DHCP_HOSTNAME_MAX) return;
    for (size_t i = 0; i < len; i++)
        if (src[i] < 0x21 || src[i] > 0x7e) return;
    memcpy(dst, src, len);
    dst[len] = 0;
}

static int read_option(mnd_dhcp *m, uint8_t code, const uint8_t *v, size_t len) {
    switch (code) {
    case OPT_MESSAGE_TYPE:
        if (len != 1 || v[0] < MND_DHCP_DISCOVER || v[0] > MND_DHCP_INFORM) return -1;
        m->type = v[0];
        return 0;
    case OPT_SUBNET_MASK:
    case OPT_ROUTER:
    case OPT_DNS:
    case OPT_BROADCAST:
    case OPT_REQUESTED_IP:
    case OPT_SERVER_ID: {
        /* Router and DNS may list several addresses; the first one counts. */
        bool list = code == OPT_ROUTER || code == OPT_DNS;
        if (list ? (len < 4 || len % 4) : len != 4) return -1;
        mnd_ip4 ip = rd32(v);
        if (code == OPT_SUBNET_MASK) m->subnet_mask = ip;
        else if (code == OPT_ROUTER) m->router = ip;
        else if (code == OPT_DNS) m->dns = ip;
        else if (code == OPT_BROADCAST) m->broadcast = ip;
        else if (code == OPT_REQUESTED_IP) m->requested = ip;
        else m->server_id = ip;
        return 0;
    }
    case OPT_LEASE_TIME:
    case OPT_T1:
    case OPT_T2:
        if (len != 4) return -1;
        if (code == OPT_LEASE_TIME) m->lease_secs = rd32(v);
        else if (code == OPT_T1) m->t1 = rd32(v);
        else m->t2 = rd32(v);
        return 0;
    case OPT_HOSTNAME:
        copy_hostname(m->hostname, v, len);
        return 0;
    default:
        return 0;
    }
}

int mnd_dhcp_parse(const uint8_t *p, size_t n, mnd_dhcp *out) {
    if (!p || !out || n < OPTIONS_AT) return -1;
    if ((p[0] != 1 && p[0] != 2) || p[1] != 1 || p[2] != 6) return -1;
    if (memcmp(p + BOOTP_LEN, COOKIE, 4) != 0) return -1;
    memset(out, 0, sizeof *out);
    out->op = p[0];
    out->xid = rd32(p + 4);
    out->flags = rd16(p + 10);
    out->ciaddr = rd32(p + 12);
    out->yiaddr = rd32(p + 16);
    out->siaddr = rd32(p + 20);
    memcpy(out->chaddr.b, p + 28, 6);
    size_t i = OPTIONS_AT;
    while (i < n) {
        uint8_t code = p[i++];
        if (code == OPT_PAD) continue;
        if (code == OPT_END) break;
        if (i >= n) return -1;
        size_t len = p[i++];
        if (len > n - i) return -1;
        if (read_option(out, code, p + i, len) != 0) return -1;
        i += len;
    }
    return 0;
}

typedef struct {
    uint8_t *p;
    size_t cap, len;
    bool full;
} writer;

static void put(writer *w, uint8_t code, const uint8_t *v, size_t len) {
    if (w->full || w->len + 2 + len > w->cap) {
        w->full = true;
        return;
    }
    w->p[w->len++] = code;
    w->p[w->len++] = (uint8_t)len;
    memcpy(w->p + w->len, v, len);
    w->len += len;
}

static void put32(writer *w, uint8_t code, uint32_t v) {
    if (!v) return;
    uint8_t b[4];
    wr32(b, v);
    put(w, code, b, 4);
}

size_t mnd_dhcp_build(uint8_t *p, size_t cap, const mnd_dhcp *m) {
    if (!p || !m || cap < OPTIONS_AT + 1) return 0;
    memset(p, 0, OPTIONS_AT);
    p[0] = m->op;
    p[1] = 1;
    p[2] = 6;
    wr32(p + 4, m->xid);
    wr16(p + 10, m->flags);
    wr32(p + 12, m->ciaddr);
    wr32(p + 16, m->yiaddr);
    wr32(p + 20, m->siaddr);
    memcpy(p + 28, m->chaddr.b, 6);
    memcpy(p + BOOTP_LEN, COOKIE, 4);
    writer w = {.p = p, .cap = cap - 1, .len = OPTIONS_AT}; /* one byte kept for END */
    if (m->type) put(&w, OPT_MESSAGE_TYPE, &m->type, 1);
    put32(&w, OPT_SERVER_ID, m->server_id);
    put32(&w, OPT_REQUESTED_IP, m->requested);
    put32(&w, OPT_LEASE_TIME, m->lease_secs);
    put32(&w, OPT_T1, m->t1);
    put32(&w, OPT_T2, m->t2);
    put32(&w, OPT_SUBNET_MASK, m->subnet_mask);
    put32(&w, OPT_ROUTER, m->router);
    put32(&w, OPT_DNS, m->dns);
    put32(&w, OPT_BROADCAST, m->broadcast);
    size_t hn = strnlen(m->hostname, sizeof m->hostname);
    if (hn) put(&w, OPT_HOSTNAME, (const uint8_t *)m->hostname, hn);
    if (w.full) return 0;
    p[w.len++] = OPT_END;
    return w.len;
}
