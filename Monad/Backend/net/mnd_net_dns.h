/*
 * mnd_net_dns.h — the DNS messages the gateway forwards: a guest's query
 * (checked strictly), the answer from the Mac (checked against the query),
 * the A records in it, and truncation to what fits in one datagram.
 *
 * Names are handled as text: labels of printable ASCII without dots,
 * lowercased, at most 253 characters. Compression pointers are followed
 * only backwards, so every name decodes in bounded time.
 */
#ifndef MND_NET_DNS_H
#define MND_NET_DNS_H

#include "mnd_net_frame.h"

#define MND_DNS_PORT 53
#define MND_DNS_NAME_MAX 253
#define MND_DNS_TYPE_A 1
#define MND_DNS_TYPE_CNAME 5
#define MND_DNS_TYPE_AAAA 28
#define MND_DNS_TYPE_OPT 41
#define MND_DNS_RCODE_SERVFAIL 2
#define MND_DNS_RCODE_REFUSED 5

typedef struct {
    uint16_t id;
    uint16_t flags;
    char qname[MND_DNS_NAME_MAX + 1]; /* lowercase, no trailing dot; "" is the root */
    uint16_t qtype, qclass;
    uint16_t udp_size;   /* the client's EDNS buffer size; 512 without EDNS */
    size_t question_end; /* offset just past the question section */
} mnd_dns_query;

/* A standard query with one question and at most an EDNS OPT record.
 * Returns 0, or -1 if malformed. */
int mnd_dns_parse_query(const uint8_t *p, size_t n, mnd_dns_query *out);

typedef void (*mnd_dns_a_fn)(void *ctx, const char *name, mnd_ip4 ip, uint32_t ttl);

/* Checks that p is a response to q (QR set, same question, any case) and
 * calls fn for each A record, with the query's name and with the record's
 * own name when it differs (a CNAME chain). Returns 0, or -1. */
int mnd_dns_parse_answer(const uint8_t *p, size_t n, const mnd_dns_query *q, mnd_dns_a_fn fn, void *ctx);

/* Whether name is labels of letters, digits, '-' and '_' joined by dots:
 * what firewall rules use, and all a name shown to the user may hold. */
bool mnd_dns_name_is_plain(const char *name);

/* Rewrites the response in p (n bytes, already checked) into its header
 * and question with TC set. Returns the new length. */
size_t mnd_dns_truncate(uint8_t *p, size_t n, const mnd_dns_query *q);

/* Writes an answer without records and with `rcode` to the query in `query`
 * (checked). Returns the length, or 0 if it does not fit. */
size_t mnd_dns_error(uint8_t *out, size_t cap, const uint8_t *query, const mnd_dns_query *q, uint8_t rcode);

/* mnd_dns_error with SERVFAIL. */
size_t mnd_dns_servfail(uint8_t *out, size_t cap, const uint8_t *query, const mnd_dns_query *q);

#endif /* MND_NET_DNS_H */
