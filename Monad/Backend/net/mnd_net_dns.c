/*
 * mnd_net_dns.c — DNS message checks. See mnd_net_dns.h.
 */
#include "mnd_net_dns.h"

#include <string.h>

#define HDR_LEN 12
#define FLAG_QR 0x8000
#define FLAG_TC 0x0200
#define MAX_CHAIN 8 /* names followed through CNAMEs */

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

/* Decodes the name at *pos as lowercase text. Each pointer must go before
 * the previous one's target (or the name's start), so decoding ends. On
 * success *pos is just past the name where it started. */
static int read_name(const uint8_t *p, size_t n, size_t *pos, char out[MND_DNS_NAME_MAX + 1], bool pointers) {
    size_t at = *pos, resume = 0, limit = *pos, text = 0, wire = 1;
    for (;;) {
        if (at >= n) return -1;
        uint8_t len = p[at];
        if ((len & 0xc0) == 0xc0) {
            if (!pointers || at + 1 >= n) return -1;
            size_t target = (size_t)(len & 0x3f) << 8 | p[at + 1];
            if (target >= limit) return -1;
            if (!resume) resume = at + 2;
            limit = target;
            at = target;
            continue;
        }
        if (len & 0xc0) return -1; /* reserved label types; also any label over 63 */
        if (len == 0) {
            at++;
            break;
        }
        if (len > n - at - 1) return -1;
        wire += 1u + len;
        if (wire > 255) return -1;
        if (text) out[text++] = '.';
        for (size_t i = 0; i < len; i++) {
            uint8_t c = p[at + 1 + i];
            if (c < 0x21 || c > 0x7e || c == '.') return -1;
            out[text++] = (char)(c >= 'A' && c <= 'Z' ? c + 32 : c);
        }
        at += 1u + len;
    }
    out[text] = 0;
    *pos = resume ? resume : at;
    return 0;
}

int mnd_dns_parse_query(const uint8_t *p, size_t n, mnd_dns_query *out) {
    if (!p || !out || n < HDR_LEN) return -1;
    uint16_t flags = rd16(p + 2);
    if ((flags & FLAG_QR) || ((flags >> 11) & 0xf) != 0) return -1;
    uint16_t qd = rd16(p + 4), an = rd16(p + 6), ns = rd16(p + 8), ar = rd16(p + 10);
    if (qd != 1 || an || ns || ar > 1) return -1;
    memset(out, 0, sizeof *out);
    out->id = rd16(p);
    out->flags = flags;
    size_t pos = HDR_LEN;
    if (read_name(p, n, &pos, out->qname, false) != 0 || n - pos < 4) return -1;
    out->qtype = rd16(p + pos);
    out->qclass = rd16(p + pos + 2);
    pos += 4;
    out->question_end = pos;
    out->udp_size = 512;
    if (ar) {
        /* EDNS: root name, type OPT, class = UDP size, ttl, rdata. */
        if (pos >= n || p[pos] != 0 || n - pos - 1 < 10) return -1;
        pos++;
        if (rd16(p + pos) != MND_DNS_TYPE_OPT) return -1;
        uint16_t size = rd16(p + pos + 2);
        size_t rdlen = rd16(p + pos + 8);
        pos += 10;
        if (rdlen > n - pos) return -1;
        pos += rdlen;
        if (size > 512) out->udp_size = size;
    }
    return pos == n ? 0 : -1;
}

typedef struct {
    char owner[MND_DNS_NAME_MAX + 1];
    uint16_t type;
    uint32_t ttl;
    size_t rdata, rdlen;
} rr;

static int read_rr(const uint8_t *p, size_t n, size_t *pos, rr *out) {
    if (read_name(p, n, pos, out->owner, true) != 0 || n - *pos < 10) return -1;
    out->type = rd16(p + *pos);
    out->ttl = rd32(p + *pos + 4);
    out->rdlen = rd16(p + *pos + 8);
    *pos += 10;
    if (out->rdlen > n - *pos) return -1;
    out->rdata = *pos;
    *pos += out->rdlen;
    return 0;
}

static bool in_chain(char chain[][MND_DNS_NAME_MAX + 1], int count, const char *name) {
    for (int i = 0; i < count; i++)
        if (strcmp(chain[i], name) == 0) return true;
    return false;
}

bool mnd_dns_name_is_plain(const char *name) {
    size_t label = 0;
    if (!name || !*name) return false;
    for (const char *c = name; *c; c++) {
        if (*c == '.') {
            if (!label) return false;
            label = 0;
        } else if ((*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') || (*c >= '0' && *c <= '9') || *c == '-' ||
                   *c == '_') {
            label++;
        } else {
            return false;
        }
    }
    return label > 0;
}

int mnd_dns_parse_answer(const uint8_t *p, size_t n, const mnd_dns_query *q, mnd_dns_a_fn fn, void *ctx) {
    if (!p || !q || n < HDR_LEN) return -1;
    uint16_t flags = rd16(p + 2);
    if (!(flags & FLAG_QR) || ((flags >> 11) & 0xf) != 0 || rd16(p + 4) != 1) return -1;
    uint16_t an = rd16(p + 6);
    char name[MND_DNS_NAME_MAX + 1];
    size_t pos = HDR_LEN;
    if (read_name(p, n, &pos, name, false) != 0 || n - pos < 4) return -1;
    if (strcmp(name, q->qname) != 0 || rd16(p + pos) != q->qtype || rd16(p + pos + 2) != q->qclass) return -1;
    /* Labels hold no dots, so the same name has the same encoded length:
     * the question ends at q->question_end here too. */
    size_t answers = pos + 4;

    /* The CNAME chain from the query's name; records may come in any order. */
    char chain[MAX_CHAIN][MND_DNS_NAME_MAX + 1];
    int nchain = 1;
    strcpy(chain[0], q->qname);
    bool grew = true;
    for (int pass = 0; grew && pass < MAX_CHAIN; pass++) {
        grew = false;
        pos = answers;
        for (uint16_t i = 0; i < an; i++) {
            rr r;
            if (read_rr(p, n, &pos, &r) != 0) return -1;
            if (r.type == MND_DNS_TYPE_A && r.rdlen != 4) return -1;
            if (r.type != MND_DNS_TYPE_CNAME || nchain >= MAX_CHAIN || !in_chain(chain, nchain, r.owner)) continue;
            size_t at = r.rdata;
            if (read_name(p, r.rdata + r.rdlen, &at, name, true) != 0 || at != r.rdata + r.rdlen) return -1;
            if (in_chain(chain, nchain, name)) continue;
            strcpy(chain[nchain++], name);
            grew = true;
        }
    }
    if (!fn) return 0;
    pos = answers;
    for (uint16_t i = 0; i < an; i++) {
        rr r;
        read_rr(p, n, &pos, &r); /* checked above */
        if (r.type != MND_DNS_TYPE_A || !in_chain(chain, nchain, r.owner)) continue;
        mnd_ip4 ip = rd32(p + r.rdata);
        fn(ctx, q->qname, ip, r.ttl);
        if (strcmp(r.owner, q->qname) != 0) fn(ctx, r.owner, ip, r.ttl);
    }
    return 0;
}

static void clear_counts(uint8_t *p) {
    p[4] = 0;
    p[5] = 1;
    memset(p + 6, 0, 6);
}

size_t mnd_dns_truncate(uint8_t *p, size_t n, const mnd_dns_query *q) {
    if (!p || !q || n < q->question_end) return 0;
    p[2] |= FLAG_TC >> 8;
    clear_counts(p);
    return q->question_end;
}

size_t mnd_dns_error(uint8_t *out, size_t cap, const uint8_t *query, const mnd_dns_query *q, uint8_t rcode) {
    if (!out || !query || !q || cap < q->question_end) return 0;
    memcpy(out, query, q->question_end);
    out[2] = (uint8_t)(0x80 | (query[2] & 0x01)); /* QR, RD as asked */
    out[3] = (uint8_t)(0x80 | (rcode & 0x0f));    /* RA */
    clear_counts(out);
    return q->question_end;
}

size_t mnd_dns_servfail(uint8_t *out, size_t cap, const uint8_t *query, const mnd_dns_query *q) {
    return mnd_dns_error(out, cap, query, q, MND_DNS_RCODE_SERVFAIL);
}
