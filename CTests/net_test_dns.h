/* Builders for DNS messages in tests. */
#ifndef NET_TEST_DNS_H
#define NET_TEST_DNS_H

#include "../Monad/Backend/net/mnd_net_dns.h"

#include <string.h>

static inline size_t td_put16(uint8_t *p, size_t at, uint16_t v) {
    p[at] = (uint8_t)(v >> 8);
    p[at + 1] = (uint8_t)v;
    return at + 2;
}

static inline size_t td_put32(uint8_t *p, size_t at, uint32_t v) {
    at = td_put16(p, at, (uint16_t)(v >> 16));
    return td_put16(p, at, (uint16_t)v);
}

/* "www.example.com" as labels. */
static inline size_t td_name(uint8_t *p, size_t at, const char *name) {
    while (*name) {
        const char *dot = strchr(name, '.');
        size_t len = dot ? (size_t)(dot - name) : strlen(name);
        p[at++] = (uint8_t)len;
        memcpy(p + at, name, len);
        at += len;
        name += len + (dot ? 1 : 0);
    }
    p[at++] = 0;
    return at;
}

static inline size_t td_header(uint8_t *p, uint16_t id, uint16_t flags, uint16_t qd, uint16_t an, uint16_t ns, uint16_t ar) {
    size_t at = td_put16(p, 0, id);
    at = td_put16(p, at, flags);
    at = td_put16(p, at, qd);
    at = td_put16(p, at, an);
    at = td_put16(p, at, ns);
    return td_put16(p, at, ar);
}

/* A query, optionally with an EDNS OPT record advertising udp_size. */
static inline size_t td_query(uint8_t *p, uint16_t id, const char *name, uint16_t qtype, uint16_t udp_size) {
    size_t at = td_header(p, id, 0x0100, 1, 0, 0, udp_size ? 1 : 0);
    at = td_name(p, at, name);
    at = td_put16(p, at, qtype);
    at = td_put16(p, at, 1);
    if (udp_size) {
        p[at++] = 0; /* root */
        at = td_put16(p, at, MND_DNS_TYPE_OPT);
        at = td_put16(p, at, udp_size);
        at = td_put32(p, at, 0);
        at = td_put16(p, at, 0);
    }
    return at;
}

/* Starts a response to `name`: header (ancount set by td_set_ancount) and
 * the question at offset 12, so 0xc00c points at the name. */
static inline size_t td_response(uint8_t *p, uint16_t id, const char *name, uint16_t qtype) {
    size_t at = td_header(p, id, 0x8180, 1, 0, 0, 0);
    at = td_name(p, at, name);
    at = td_put16(p, at, qtype);
    return td_put16(p, at, 1);
}

/* An answer record whose owner is a pointer (0xc000 | ptr). */
static inline size_t td_rr_ptr(uint8_t *p, size_t at, uint16_t ptr, uint16_t type, uint32_t ttl, const uint8_t *rdata,
                               uint16_t rdlen) {
    at = td_put16(p, at, (uint16_t)(0xc000 | ptr));
    at = td_put16(p, at, type);
    at = td_put16(p, at, 1);
    at = td_put32(p, at, ttl);
    at = td_put16(p, at, rdlen);
    memcpy(p + at, rdata, rdlen);
    return at + rdlen;
}

static inline size_t td_a(uint8_t *p, size_t at, uint16_t owner_ptr, mnd_ip4 ip, uint32_t ttl) {
    uint8_t rd[4] = {(uint8_t)(ip >> 24), (uint8_t)(ip >> 16), (uint8_t)(ip >> 8), (uint8_t)ip};
    return td_rr_ptr(p, at, owner_ptr, MND_DNS_TYPE_A, ttl, rd, 4);
}

static inline void td_set_ancount(uint8_t *p, uint16_t an) { td_put16(p, 6, an); }

#endif
