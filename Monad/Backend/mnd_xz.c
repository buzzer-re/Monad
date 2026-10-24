/*
 * mnd_xz.c — .xz / LZMA2 decoder. See mnd_xz.h.
 *
 * Structure:
 *   - integrity checks (CRC32, CRC64, SHA-256)
 *   - LZMA: range decoder over a fully buffered LZMA2 chunk, probability
 *     models, literal/match/rep decoding into a circular dictionary
 *   - LZMA2: chunk control bytes, dictionary/state/property resets
 *   - .xz container: stream header, block headers, block padding and check,
 *     index (validated against the decoded blocks), stream footer, padding
 *
 * Every LZMA2 chunk is buffered completely (at most 64 KiB of compressed
 * data) before it is decoded, so the range decoder never runs out of input
 * in the middle of a symbol; output is limited by the space left before the
 * end of the dictionary buffer and flushed to the caller between rounds.
 */
#include "mnd_xz.h"

#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ------------------------------------------------------------------------ */
/* Integrity checks                                                          */

static uint32_t crc32_tab[256];
static uint64_t crc64_tab[256];
static pthread_once_t tables_once = PTHREAD_ONCE_INIT;

static void make_tables(void) {
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        uint64_t d = i;
        for (int k = 0; k < 8; k++) {
            c = (c >> 1) ^ ((c & 1) ? 0xEDB88320u : 0);
            d = (d >> 1) ^ ((d & 1) ? 0xC96C5795D7870F42ull : 0);
        }
        crc32_tab[i] = c;
        crc64_tab[i] = d;
    }
}

static uint32_t crc32_update(uint32_t crc, const uint8_t *p, size_t n) {
    crc = ~crc;
    while (n--) crc = crc32_tab[(crc ^ *p++) & 0xFF] ^ (crc >> 8);
    return ~crc;
}

static uint64_t crc64_update(uint64_t crc, const uint8_t *p, size_t n) {
    crc = ~crc;
    while (n--) crc = crc64_tab[(crc ^ *p++) & 0xFF] ^ (crc >> 8);
    return ~crc;
}

typedef struct {
    uint32_t h[8];
    uint64_t len;
    uint8_t buf[64];
    size_t n;
} sha256_ctx;

static const uint32_t K256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

#define ROR32(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_block(sha256_ctx *s, const uint8_t *p) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
        w[i] = (uint32_t)p[4 * i] << 24 | (uint32_t)p[4 * i + 1] << 16 | (uint32_t)p[4 * i + 2] << 8 | p[4 * i + 3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ROR32(w[i - 15], 7) ^ ROR32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ROR32(w[i - 2], 17) ^ ROR32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = s->h[0], b = s->h[1], c = s->h[2], d = s->h[3];
    uint32_t e = s->h[4], f = s->h[5], g = s->h[6], h = s->h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = h + (ROR32(e, 6) ^ ROR32(e, 11) ^ ROR32(e, 25)) + ((e & f) ^ (~e & g)) + K256[i] + w[i];
        uint32_t t2 = (ROR32(a, 2) ^ ROR32(a, 13) ^ ROR32(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
        h = g;
        g = f;
        f = e;
        e = d + t1;
        d = c;
        c = b;
        b = a;
        a = t1 + t2;
    }
    s->h[0] += a;
    s->h[1] += b;
    s->h[2] += c;
    s->h[3] += d;
    s->h[4] += e;
    s->h[5] += f;
    s->h[6] += g;
    s->h[7] += h;
}

static void sha256_init(sha256_ctx *s) {
    static const uint32_t iv[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                   0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    memcpy(s->h, iv, sizeof iv);
    s->len = 0;
    s->n = 0;
}

static void sha256_update(sha256_ctx *s, const uint8_t *p, size_t n) {
    s->len += n;
    while (n > 0) {
        if (s->n == 0 && n >= 64) {
            sha256_block(s, p);
            p += 64;
            n -= 64;
            continue;
        }
        size_t take = 64 - s->n < n ? 64 - s->n : n;
        memcpy(s->buf + s->n, p, take);
        s->n += take;
        p += take;
        n -= take;
        if (s->n == 64) {
            sha256_block(s, s->buf);
            s->n = 0;
        }
    }
}

static void sha256_final(sha256_ctx *s, uint8_t out[32]) {
    uint64_t bits = s->len * 8;
    uint8_t pad = 0x80;
    sha256_update(s, &pad, 1);
    uint8_t zero = 0;
    while (s->n != 56) sha256_update(s, &zero, 1);
    uint8_t len[8];
    for (int i = 0; i < 8; i++) len[i] = (uint8_t)(bits >> (56 - 8 * i));
    sha256_update(s, len, 8);
    for (int i = 0; i < 8; i++) {
        out[4 * i] = (uint8_t)(s->h[i] >> 24);
        out[4 * i + 1] = (uint8_t)(s->h[i] >> 16);
        out[4 * i + 2] = (uint8_t)(s->h[i] >> 8);
        out[4 * i + 3] = (uint8_t)s->h[i];
    }
}

enum { CHECK_NONE = 0, CHECK_CRC32 = 1, CHECK_CRC64 = 4, CHECK_SHA256 = 10 };

static int check_size(int type) {
    switch (type) {
    case CHECK_NONE: return 0;
    case CHECK_CRC32: return 4;
    case CHECK_CRC64: return 8;
    case CHECK_SHA256: return 32;
    default: return -1;
    }
}

/* ------------------------------------------------------------------------ */
/* LZMA                                                                      */

enum {
    STATES = 12,
    LIT_STATES = 7,
    POS_STATES_MAX = 16,
    LEN_LOW = 8,
    LEN_MID = 8,
    LEN_HIGH = 256,
    MATCH_LEN_MIN = 2,
    DIST_STATES = 4,
    DIST_SLOTS = 64,
    DIST_MODEL_START = 4,
    DIST_MODEL_END = 14,
    FULL_DISTANCES = 128,
    ALIGN_BITS = 4,
    ALIGN_SIZE = 16,
    LITERAL_CODERS_MAX = 16,
    LITERAL_CODER_SIZE = 0x300,
    PROB_INIT = 1024,
    RC_TOP = 1u << 24,
    COMPRESSED_MAX = 1 << 16,
};

typedef uint16_t prob;

typedef struct {
    prob choice, choice2;
    prob low[POS_STATES_MAX][LEN_LOW];
    prob mid[POS_STATES_MAX][LEN_MID];
    prob high[LEN_HIGH];
} len_dec;

typedef struct {
    /* range decoder over buf[pos..size) */
    const uint8_t *in;
    size_t in_pos, in_size;
    uint32_t range, code;
    bool overrun;

    int state;
    uint32_t rep0, rep1, rep2, rep3;
    uint32_t len; /* bytes of the current match still to copy */
    unsigned lc, lp, pb;

    prob is_match[STATES][POS_STATES_MAX];
    prob is_rep[STATES], is_rep0[STATES], is_rep1[STATES], is_rep2[STATES];
    prob is_rep0_long[STATES][POS_STATES_MAX];
    prob dist_slot[DIST_STATES][DIST_SLOTS];
    prob dist_special[FULL_DISTANCES - DIST_MODEL_END];
    prob dist_align[ALIGN_SIZE];
    len_dec match_len, rep_len;
    prob literal[LITERAL_CODERS_MAX][LITERAL_CODER_SIZE];
} lzma_dec;

/* Circular dictionary. [start, pos) is decoded but not yet flushed. */
typedef struct {
    uint8_t *buf;
    size_t size;  /* allocated bytes */
    size_t start; /* first unflushed byte */
    size_t pos;   /* next write position */
    size_t limit; /* decode no further than this in the current round */
    size_t full;  /* valid history bytes (<= size) */
    uint64_t total; /* bytes written since the last dictionary reset */
} dictionary;

static void lzma_reset(lzma_dec *z) {
    z->state = 0;
    z->rep0 = z->rep1 = z->rep2 = z->rep3 = 0;
    z->len = 0;
    prob *p = &z->is_match[0][0];
    prob *end = (prob *)((uint8_t *)&z->literal[0][0] + sizeof z->literal);
    /* All probability arrays are contiguous uint16 fields from is_match on. */
    while (p < end) *p++ = PROB_INIT;
}

static inline void rc_normalize(lzma_dec *z) {
    if (z->range < RC_TOP) {
        z->range <<= 8;
        if (z->in_pos < z->in_size) {
            z->code = (z->code << 8) | z->in[z->in_pos++];
        } else {
            z->code <<= 8;
            z->overrun = true;
        }
    }
}

static inline int rc_bit(lzma_dec *z, prob *p) {
    rc_normalize(z);
    uint32_t bound = (z->range >> 11) * *p;
    if (z->code < bound) {
        z->range = bound;
        *p += (prob)((2048 - *p) >> 5);
        return 0;
    }
    z->range -= bound;
    z->code -= bound;
    *p -= (prob)(*p >> 5);
    return 1;
}

static inline uint32_t rc_bittree(lzma_dec *z, prob *probs, unsigned bits) {
    uint32_t symbol = 1;
    do symbol = (symbol << 1) | (uint32_t)rc_bit(z, &probs[symbol]);
    while (symbol < (1u << bits));
    return symbol - (1u << bits);
}

static inline void rc_bittree_reverse(lzma_dec *z, prob *probs, uint32_t *dest, unsigned bits) {
    uint32_t symbol = 1;
    for (unsigned i = 0; i < bits; i++) {
        if (rc_bit(z, &probs[symbol])) {
            symbol = (symbol << 1) + 1;
            *dest += 1u << i;
        } else {
            symbol <<= 1;
        }
    }
}

static inline void rc_direct(lzma_dec *z, uint32_t *dest, unsigned count) {
    while (count--) {
        rc_normalize(z);
        z->range >>= 1;
        z->code -= z->range;
        uint32_t mask = 0u - (z->code >> 31);
        z->code += z->range & mask;
        *dest = (*dest << 1) + (mask + 1);
    }
}

static uint32_t len_decode(lzma_dec *z, len_dec *l, unsigned pos_state) {
    if (!rc_bit(z, &l->choice)) return rc_bittree(z, l->low[pos_state], 3) + MATCH_LEN_MIN;
    if (!rc_bit(z, &l->choice2)) return rc_bittree(z, l->mid[pos_state], 3) + MATCH_LEN_MIN + LEN_LOW;
    return rc_bittree(z, l->high, 8) + MATCH_LEN_MIN + LEN_LOW + LEN_MID;
}

static inline uint8_t dict_get(const dictionary *d, uint32_t dist) {
    size_t off = d->pos >= (size_t)dist + 1 ? d->pos - dist - 1 : d->pos + d->size - dist - 1;
    return d->buf[off];
}

static inline void dict_put(dictionary *d, uint8_t b) {
    d->buf[d->pos++] = b;
    d->total++;
    if (d->full < d->pos) d->full = d->pos;
}

/* Copy up to z->len bytes of a match at distance dist, bounded by the limit. */
static void dict_repeat(dictionary *d, uint32_t *len, uint32_t dist) {
    size_t left = d->limit - d->pos;
    size_t n = *len < left ? *len : left;
    for (size_t i = 0; i < n; i++) dict_put(d, dict_get(d, dist));
    *len -= (uint32_t)n;
}

/* Decode symbols until the dictionary limit. Returns false on corrupt data. */
static bool lzma_decode(lzma_dec *z, dictionary *d) {
    const uint32_t pos_mask = (1u << z->pb) - 1;
    const uint32_t lit_pos_mask = (1u << z->lp) - 1;
    if (z->len > 0) dict_repeat(d, &z->len, z->rep0);
    while (d->pos < d->limit) {
        if (z->overrun) return false;
        unsigned pos_state = (unsigned)(d->total & pos_mask);
        if (!rc_bit(z, &z->is_match[z->state][pos_state])) {
            /* literal */
            uint8_t prev = d->full > 0 ? dict_get(d, 0) : 0;
            unsigned idx = (((unsigned)d->total & lit_pos_mask) << z->lc) + (prev >> (8 - z->lc));
            prob *probs = z->literal[idx];
            uint32_t symbol = 1;
            if (z->state < LIT_STATES) {
                do symbol = (symbol << 1) | (uint32_t)rc_bit(z, &probs[symbol]);
                while (symbol < 0x100);
            } else {
                uint32_t match_byte = (uint32_t)dict_get(d, z->rep0) << 1;
                uint32_t offset = 0x100;
                do {
                    uint32_t match_bit = match_byte & offset;
                    match_byte <<= 1;
                    uint32_t i = offset + match_bit + symbol;
                    if (rc_bit(z, &probs[i])) {
                        symbol = (symbol << 1) | 1;
                        offset &= match_bit;
                    } else {
                        symbol <<= 1;
                        offset &= ~match_bit;
                    }
                } while (symbol < 0x100);
            }
            dict_put(d, (uint8_t)symbol);
            z->state = z->state < 4 ? 0 : (z->state < 10 ? z->state - 3 : z->state - 6);
            continue;
        }
        uint32_t len;
        if (!rc_bit(z, &z->is_rep[z->state])) {
            /* simple match */
            z->state = z->state < LIT_STATES ? 7 : 10;
            z->rep3 = z->rep2;
            z->rep2 = z->rep1;
            z->rep1 = z->rep0;
            len = len_decode(z, &z->match_len, pos_state);
            unsigned dist_state = len - MATCH_LEN_MIN < DIST_STATES ? len - MATCH_LEN_MIN : DIST_STATES - 1;
            uint32_t slot = rc_bittree(z, z->dist_slot[dist_state], 6);
            if (slot < DIST_MODEL_START) {
                z->rep0 = slot;
            } else {
                unsigned limit = (slot >> 1) - 1;
                z->rep0 = 2 | (slot & 1);
                if (slot < DIST_MODEL_END) {
                    z->rep0 <<= limit;
                    rc_bittree_reverse(z, z->dist_special + z->rep0 - slot - 1, &z->rep0, limit);
                } else {
                    rc_direct(z, &z->rep0, limit - ALIGN_BITS);
                    z->rep0 <<= ALIGN_BITS;
                    rc_bittree_reverse(z, z->dist_align, &z->rep0, ALIGN_BITS);
                    if (z->rep0 == UINT32_MAX) return false; /* end marker: not used by LZMA2 */
                }
            }
        } else {
            if (!rc_bit(z, &z->is_rep0[z->state])) {
                if (!rc_bit(z, &z->is_rep0_long[z->state][pos_state])) {
                    /* short rep: one byte at rep0 */
                    if ((size_t)z->rep0 >= d->full) return false;
                    z->state = z->state < LIT_STATES ? 9 : 11;
                    dict_put(d, dict_get(d, z->rep0));
                    continue;
                }
            } else {
                uint32_t tmp;
                if (!rc_bit(z, &z->is_rep1[z->state])) {
                    tmp = z->rep1;
                } else {
                    if (!rc_bit(z, &z->is_rep2[z->state])) {
                        tmp = z->rep2;
                    } else {
                        tmp = z->rep3;
                        z->rep3 = z->rep2;
                    }
                    z->rep2 = z->rep1;
                }
                z->rep1 = z->rep0;
                z->rep0 = tmp;
            }
            z->state = z->state < LIT_STATES ? 8 : 11;
            len = len_decode(z, &z->rep_len, pos_state);
        }
        if ((size_t)z->rep0 >= d->full) return false; /* distance before the start of data */
        z->len = len;
        dict_repeat(d, &z->len, z->rep0);
    }
    return !z->overrun;
}

/* ------------------------------------------------------------------------ */
/* Decoder state                                                             */

typedef enum {
    S_STREAM_HEADER,
    S_BLOCK_START,  /* block header size byte or index indicator */
    S_BLOCK_HEADER,
    S_LZMA2_CONTROL,
    S_LZMA2_HEADER, /* size and property bytes of a chunk */
    S_LZMA2_UNCOMPRESSED,
    S_LZMA2_COMPRESSED, /* buffering compressed chunk data */
    S_LZMA2_DECODE,
    S_BLOCK_PADDING,
    S_BLOCK_CHECK,
    S_INDEX,
    S_STREAM_FOOTER,
    S_STREAM_PADDING,
    S_ERROR,
} seq;

typedef enum { IX_COUNT, IX_UNPADDED, IX_UNCOMPRESSED, IX_PADDING, IX_CRC } index_seq;

typedef struct {
    uint64_t count;
    uint64_t unpadded_sum;
    uint64_t uncompressed_sum;
    uint32_t hash; /* CRC32 over (unpadded, uncompressed) of every record */
} records;

struct mnd_xz {
    uint64_t memlimit;
    seq seq;
    int error;
    char msg[160];

    /* small fixed-size pieces (headers, footer, check) are collected here */
    uint8_t tmp[1024];
    size_t tmp_need, tmp_have;

    /* stream */
    uint8_t stream_flags[2];
    int check_type;
    uint64_t streams, blocks_in_stream;
    records decoded;
    uint64_t padding;

    /* block */
    uint64_t header_size;
    uint64_t declared_compressed, declared_uncompressed; /* UINT64_MAX: absent */
    uint64_t block_compressed, block_uncompressed;
    uint32_t dict_size;
    union {
        uint32_t crc32;
        uint64_t crc64;
        sha256_ctx sha;
    } check;

    /* LZMA2 */
    uint8_t control;
    bool need_dict_reset, need_props;
    uint32_t chunk_uncompressed, chunk_compressed;
    uint8_t *cbuf; /* COMPRESSED_MAX */
    size_t cbuf_have;
    lzma_dec *lzma;
    dictionary dict;

    /* index */
    index_seq ix;
    uint64_t ix_vli;
    unsigned ix_shift;
    uint64_t ix_records_left, ix_unpadded;
    uint64_t ix_size; /* bytes of index so far, including the indicator */
    uint32_t ix_crc;
    records listed;
    uint8_t ix_crc_bytes[4];
    unsigned ix_crc_have;
};

static int fail(mnd_xz *d, int code, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(d->msg, sizeof d->msg, fmt, ap);
    va_end(ap);
    d->error = code;
    d->seq = S_ERROR;
    return code;
}

mnd_xz *mnd_xz_new(uint64_t memlimit) {
    pthread_once(&tables_once, make_tables);
    mnd_xz *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    d->lzma = calloc(1, sizeof *d->lzma);
    d->cbuf = malloc(COMPRESSED_MAX);
    if (!d->lzma || !d->cbuf) {
        mnd_xz_free(d);
        return NULL;
    }
    d->memlimit = memlimit;
    d->seq = S_STREAM_HEADER;
    d->tmp_need = 12;
    return d;
}

void mnd_xz_free(mnd_xz *d) {
    if (!d) return;
    free(d->dict.buf);
    free(d->lzma);
    free(d->cbuf);
    free(d);
}

const char *mnd_xz_error(const mnd_xz *d) { return d->msg; }

static uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

/* Variable-length integer from buf[*pos..end); false if malformed. */
static bool read_vli(const uint8_t *buf, size_t end, size_t *pos, uint64_t *out) {
    uint64_t v = 0;
    for (unsigned i = 0; i < 9; i++) {
        if (*pos >= end) return false;
        uint8_t b = buf[(*pos)++];
        v |= (uint64_t)(b & 0x7F) << (7 * i);
        if (!(b & 0x80)) {
            if (b == 0 && i > 0) return false; /* not the shortest encoding */
            *out = v;
            return true;
        }
    }
    return false;
}

static void records_add(records *r, uint64_t unpadded, uint64_t uncompressed) {
    uint8_t buf[16];
    for (int i = 0; i < 8; i++) {
        buf[i] = (uint8_t)(unpadded >> (8 * i));
        buf[8 + i] = (uint8_t)(uncompressed >> (8 * i));
    }
    r->count++;
    r->unpadded_sum += unpadded;
    r->uncompressed_sum += uncompressed;
    r->hash = crc32_update(r->hash, buf, sizeof buf);
}

static void check_init(mnd_xz *d) {
    if (d->check_type == CHECK_SHA256) sha256_init(&d->check.sha);
    else d->check.crc64 = 0;
}

static void check_update(mnd_xz *d, const uint8_t *p, size_t n) {
    switch (d->check_type) {
    case CHECK_CRC32: d->check.crc32 = crc32_update(d->check.crc32, p, n); break;
    case CHECK_CRC64: d->check.crc64 = crc64_update(d->check.crc64, p, n); break;
    case CHECK_SHA256: sha256_update(&d->check.sha, p, n); break;
    default: break;
    }
}

/* ------------------------------------------------------------------------ */
/* Headers                                                                   */

static int parse_stream_header(mnd_xz *d) {
    static const uint8_t magic[6] = {0xFD, '7', 'z', 'X', 'Z', 0x00};
    if (memcmp(d->tmp, magic, 6) != 0) return fail(d, MND_XZ_EFORMAT, "not an .xz stream");
    if (crc32_update(0, d->tmp + 6, 2) != le32(d->tmp + 8))
        return fail(d, MND_XZ_EFORMAT, "stream header CRC32 mismatch");
    if (d->tmp[6] != 0 || (d->tmp[7] & 0xF0)) return fail(d, MND_XZ_EUNSUPPORTED, "unknown stream flags");
    d->check_type = d->tmp[7] & 0x0F;
    if (check_size(d->check_type) < 0)
        return fail(d, MND_XZ_EUNSUPPORTED, "unsupported check type %d", d->check_type);
    memcpy(d->stream_flags, d->tmp + 6, 2);
    memset(&d->decoded, 0, sizeof d->decoded);
    d->blocks_in_stream = 0;
    d->seq = S_BLOCK_START;
    return MND_XZ_OK;
}

static int parse_block_header(mnd_xz *d) {
    size_t size = d->tmp_need;
    if (crc32_update(0, d->tmp, size - 4) != le32(d->tmp + size - 4))
        return fail(d, MND_XZ_EFORMAT, "block header CRC32 mismatch");
    uint8_t flags = d->tmp[1];
    if (flags & 0x3C) return fail(d, MND_XZ_EUNSUPPORTED, "unknown block flags");
    size_t pos = 2, end = size - 4;
    d->declared_compressed = d->declared_uncompressed = UINT64_MAX;
    if ((flags & 0x40) && (!read_vli(d->tmp, end, &pos, &d->declared_compressed) || d->declared_compressed == 0))
        return fail(d, MND_XZ_EFORMAT, "bad compressed size in block header");
    if ((flags & 0x80) && !read_vli(d->tmp, end, &pos, &d->declared_uncompressed))
        return fail(d, MND_XZ_EFORMAT, "bad uncompressed size in block header");
    unsigned filters = (flags & 3) + 1;
    if (filters != 1) return fail(d, MND_XZ_EUNSUPPORTED, "filter chains other than LZMA2 alone");
    uint64_t id, props_size;
    if (!read_vli(d->tmp, end, &pos, &id) || !read_vli(d->tmp, end, &pos, &props_size))
        return fail(d, MND_XZ_EFORMAT, "bad filter flags");
    if (id != 0x21) return fail(d, MND_XZ_EUNSUPPORTED, "filter 0x%llx", (unsigned long long)id);
    if (props_size != 1 || pos >= end) return fail(d, MND_XZ_EFORMAT, "bad LZMA2 properties");
    uint8_t p = d->tmp[pos++];
    if (p > 40) return fail(d, MND_XZ_EFORMAT, "bad LZMA2 dictionary size");
    uint64_t dict = p == 40 ? UINT32_MAX : (uint64_t)(2 | (p & 1)) << (p / 2 + 11);
    while (pos < end)
        if (d->tmp[pos++] != 0) return fail(d, MND_XZ_EFORMAT, "non-zero block header padding");
    if (dict > d->memlimit)
        return fail(d, MND_XZ_EMEMLIMIT, "dictionary of %llu bytes exceeds the %llu byte limit",
                    (unsigned long long)dict, (unsigned long long)d->memlimit);

    /* A block never refers back past its own start: its uncompressed size
     * (when declared) bounds the dictionary actually needed. */
    size_t need = (size_t)dict;
    if (d->declared_uncompressed != UINT64_MAX && d->declared_uncompressed < need)
        need = (size_t)d->declared_uncompressed;
    if (need < 4096) need = 4096;
    if (d->dict.size < need) {
        uint8_t *buf = realloc(d->dict.buf, need);
        if (!buf) return fail(d, MND_XZ_ENOMEM, "out of memory for a %zu byte dictionary", need);
        d->dict.buf = buf;
        d->dict.size = need;
    }
    d->dict_size = (uint32_t)dict;
    d->header_size = size;
    d->block_compressed = d->block_uncompressed = 0;
    d->padding = 0;
    d->need_dict_reset = true;
    d->need_props = true;
    check_init(d);
    d->seq = S_LZMA2_CONTROL;
    return MND_XZ_OK;
}

static int finish_block(mnd_xz *d) {
    const uint8_t *got = d->tmp;
    uint8_t want[32];
    int n = check_size(d->check_type);
    switch (d->check_type) {
    case CHECK_CRC32:
        for (int i = 0; i < 4; i++) want[i] = (uint8_t)(d->check.crc32 >> (8 * i));
        break;
    case CHECK_CRC64:
        for (int i = 0; i < 8; i++) want[i] = (uint8_t)(d->check.crc64 >> (8 * i));
        break;
    case CHECK_SHA256: sha256_final(&d->check.sha, want); break;
    default: break;
    }
    if (n > 0 && memcmp(got, want, (size_t)n) != 0)
        return fail(d, MND_XZ_ECORRUPT, "block %llu: check value mismatch", (unsigned long long)d->blocks_in_stream);
    records_add(&d->decoded, d->header_size + d->block_compressed + (uint64_t)n, d->block_uncompressed);
    d->blocks_in_stream++;
    d->seq = S_BLOCK_START;
    return MND_XZ_OK;
}

static int parse_stream_footer(mnd_xz *d) {
    const uint8_t *f = d->tmp;
    if (f[10] != 'Y' || f[11] != 'Z') return fail(d, MND_XZ_EFORMAT, "bad stream footer magic");
    if (crc32_update(0, f + 4, 6) != le32(f)) return fail(d, MND_XZ_EFORMAT, "stream footer CRC32 mismatch");
    if (memcmp(f + 8, d->stream_flags, 2) != 0) return fail(d, MND_XZ_EFORMAT, "stream flags differ in footer");
    if (((uint64_t)le32(f + 4) + 1) * 4 != d->ix_size) return fail(d, MND_XZ_EFORMAT, "backward size mismatch");
    d->streams++;
    d->padding = 0;
    d->seq = S_STREAM_PADDING;
    return MND_XZ_OK;
}

/* ------------------------------------------------------------------------ */
/* Index                                                                     */

static void index_begin(mnd_xz *d) {
    d->ix = IX_COUNT;
    d->ix_vli = 0;
    d->ix_shift = 0;
    d->ix_size = 1;
    d->ix_crc = crc32_update(0, (const uint8_t *)"\0", 1);
    memset(&d->listed, 0, sizeof d->listed);
    d->ix_crc_have = 0;
    d->seq = S_INDEX;
}

static int index_byte(mnd_xz *d, uint8_t b) {
    if (d->ix == IX_CRC) {
        d->ix_crc_bytes[d->ix_crc_have++] = b;
        d->ix_size++;
        if (d->ix_crc_have < 4) return MND_XZ_OK;
        if (le32(d->ix_crc_bytes) != d->ix_crc) return fail(d, MND_XZ_EFORMAT, "index CRC32 mismatch");
        if (d->listed.count != d->decoded.count || d->listed.unpadded_sum != d->decoded.unpadded_sum ||
            d->listed.uncompressed_sum != d->decoded.uncompressed_sum || d->listed.hash != d->decoded.hash)
            return fail(d, MND_XZ_EFORMAT, "index does not match the decoded blocks");
        d->seq = S_STREAM_FOOTER;
        d->tmp_need = 12;
        d->tmp_have = 0;
        return MND_XZ_OK;
    }
    d->ix_crc = crc32_update(d->ix_crc, &b, 1);
    d->ix_size++;
    if (d->ix == IX_PADDING) {
        if (b != 0) return fail(d, MND_XZ_EFORMAT, "non-zero index padding");
        if (d->ix_size % 4 == 0) d->ix = IX_CRC;
        return MND_XZ_OK;
    }
    if (d->ix_shift >= 63) return fail(d, MND_XZ_EFORMAT, "index integer too large");
    d->ix_vli |= (uint64_t)(b & 0x7F) << d->ix_shift;
    if (b & 0x80) {
        d->ix_shift += 7;
        return MND_XZ_OK;
    }
    if (b == 0 && d->ix_shift > 0) return fail(d, MND_XZ_EFORMAT, "non-minimal integer in index");
    uint64_t v = d->ix_vli;
    d->ix_vli = 0;
    d->ix_shift = 0;
    switch (d->ix) {
    case IX_COUNT:
        if (v != d->decoded.count) return fail(d, MND_XZ_EFORMAT, "index lists %llu blocks, stream has %llu",
                                               (unsigned long long)v, (unsigned long long)d->decoded.count);
        d->ix_records_left = v;
        d->ix = v ? IX_UNPADDED : IX_PADDING;
        break;
    case IX_UNPADDED:
        if (v == 0) return fail(d, MND_XZ_EFORMAT, "zero unpadded size in index");
        d->ix_unpadded = v;
        d->ix = IX_UNCOMPRESSED;
        break;
    case IX_UNCOMPRESSED:
        records_add(&d->listed, d->ix_unpadded, v);
        d->ix = --d->ix_records_left ? IX_UNPADDED : IX_PADDING;
        break;
    default: break;
    }
    if (d->ix == IX_PADDING && d->ix_size % 4 == 0) d->ix = IX_CRC;
    return MND_XZ_OK;
}

/* ------------------------------------------------------------------------ */
/* LZMA2                                                                     */

static void dict_reset(dictionary *dict) {
    dict->start = dict->pos = dict->limit = 0;
    dict->full = 0;
    dict->total = 0;
}

/* Copy [start, pos) of the dictionary to out; wrap when the end is reached. */
static size_t dict_flush(mnd_xz *d, uint8_t *out, size_t out_len) {
    dictionary *dict = &d->dict;
    size_t n = dict->pos - dict->start;
    if (n > out_len) n = out_len;
    if (n) {
        memcpy(out, dict->buf + dict->start, n);
        check_update(d, dict->buf + dict->start, n);
        dict->start += n;
        d->block_uncompressed += n;
    }
    if (dict->start == dict->pos && dict->pos == dict->size) dict->start = dict->pos = 0;
    return n;
}

static bool dict_flushed(const dictionary *dict) { return dict->start == dict->pos; }

/* Room to decode before unflushed data or the buffer end is reached. */
static size_t dict_room(const dictionary *dict) { return dict->size - dict->pos; }

static int lzma2_control(mnd_xz *d, uint8_t c) {
    d->block_compressed++;
    if (c == 0x00) {
        if (d->declared_compressed != UINT64_MAX && d->declared_compressed != d->block_compressed)
            return fail(d, MND_XZ_EFORMAT, "compressed size differs from the block header");
        d->seq = S_BLOCK_PADDING;
        return MND_XZ_OK;
    }
    if (c >= 0xE0 || c == 0x01) {
        d->need_props = true;
        d->need_dict_reset = false;
        dict_reset(&d->dict);
    } else if (d->need_dict_reset) {
        return fail(d, MND_XZ_ECORRUPT, "LZMA2 data does not start with a dictionary reset");
    }
    d->control = c;
    d->tmp_have = 0;
    if (c >= 0x80) {
        if (c < 0xC0 && d->need_props) return fail(d, MND_XZ_ECORRUPT, "LZMA2 chunk without properties");
        d->tmp_need = c >= 0xC0 ? 5 : 4;
    } else if (c <= 0x02) {
        d->tmp_need = 2;
    } else {
        return fail(d, MND_XZ_ECORRUPT, "invalid LZMA2 control byte 0x%02x", c);
    }
    d->seq = S_LZMA2_HEADER;
    return MND_XZ_OK;
}

static int lzma2_header(mnd_xz *d) {
    uint8_t c = d->control;
    const uint8_t *h = d->tmp;
    d->block_compressed += d->tmp_need;
    if (c < 0x80) {
        d->chunk_uncompressed = ((uint32_t)h[0] << 8 | h[1]) + 1;
        d->seq = S_LZMA2_UNCOMPRESSED;
        return MND_XZ_OK;
    }
    d->chunk_uncompressed = ((uint32_t)(c & 0x1F) << 16 | (uint32_t)h[0] << 8 | h[1]) + 1;
    d->chunk_compressed = ((uint32_t)h[2] << 8 | h[3]) + 1;
    lzma_dec *z = d->lzma;
    if (c >= 0xC0) {
        uint8_t p = h[4];
        if (p > (4 * 5 + 4) * 9 + 8) return fail(d, MND_XZ_ECORRUPT, "bad LZMA properties");
        z->pb = p / 45;
        p %= 45;
        z->lp = p / 9;
        z->lc = p % 9;
        if (z->lc + z->lp > 4) return fail(d, MND_XZ_ECORRUPT, "lc + lp > 4");
        d->need_props = false;
    }
    if (c >= 0xA0) lzma_reset(z);
    d->cbuf_have = 0;
    d->seq = S_LZMA2_COMPRESSED;
    return MND_XZ_OK;
}

static int lzma2_start_decode(mnd_xz *d) {
    lzma_dec *z = d->lzma;
    d->block_compressed += d->chunk_compressed;
    if (d->chunk_compressed < 5 || d->cbuf[0] != 0) return fail(d, MND_XZ_ECORRUPT, "bad range coder start");
    z->in = d->cbuf;
    z->in_size = d->chunk_compressed;
    z->in_pos = 5;
    z->range = UINT32_MAX;
    z->code = (uint32_t)d->cbuf[1] << 24 | (uint32_t)d->cbuf[2] << 16 | (uint32_t)d->cbuf[3] << 8 | d->cbuf[4];
    z->overrun = false;
    z->len = 0;
    d->seq = S_LZMA2_DECODE;
    return MND_XZ_OK;
}

/* One decode round; true when the chunk is complete. */
static int lzma2_decode_round(mnd_xz *d, bool *chunk_done) {
    dictionary *dict = &d->dict;
    lzma_dec *z = d->lzma;
    *chunk_done = false;
    if (dict->pos == dict->size) return MND_XZ_OK; /* must flush first */
    size_t room = dict_room(dict);
    size_t n = d->chunk_uncompressed < room ? d->chunk_uncompressed : room;
    size_t before = dict->pos;
    dict->limit = dict->pos + n;
    if (!lzma_decode(z, dict)) return fail(d, MND_XZ_ECORRUPT, "corrupt LZMA data");
    d->chunk_uncompressed -= (uint32_t)(dict->pos - before);
    if (d->chunk_uncompressed == 0) {
        rc_normalize(z); /* the encoder flushes a normalized range coder */
        if (z->len != 0 || z->overrun || z->in_pos != z->in_size || z->code != 0)
            return fail(d, MND_XZ_ECORRUPT, "LZMA2 chunk sizes do not match its data");
        *chunk_done = true;
    }
    return MND_XZ_OK;
}

/* ------------------------------------------------------------------------ */
/* Main loop                                                                 */

/* Collect d->tmp_need bytes into d->tmp; true when complete. */
static bool collect(mnd_xz *d, const uint8_t *in, size_t in_len, size_t *ip) {
    size_t take = d->tmp_need - d->tmp_have;
    if (take > in_len - *ip) take = in_len - *ip;
    if (take == 0) return d->tmp_have == d->tmp_need;
    memcpy(d->tmp + d->tmp_have, in + *ip, take);
    d->tmp_have += take;
    *ip += take;
    return d->tmp_have == d->tmp_need;
}

int mnd_xz_run(mnd_xz *d, const uint8_t *in, size_t in_len, size_t *in_used, uint8_t *out, size_t out_len,
               size_t *out_written, bool finish) {
    size_t ip = 0, op = 0;
    int rc = MND_XZ_OK;
    *in_used = 0;
    *out_written = 0;
    if (d->seq == S_ERROR) return d->error;

    for (;;) {
        /* Hand decoded bytes to the caller before anything else. */
        if (!dict_flushed(&d->dict) || d->dict.pos == d->dict.size) {
            op += dict_flush(d, out + op, out_len - op);
            if (!dict_flushed(&d->dict)) break; /* out is full */
        }
        bool progressed = false;
        switch (d->seq) {
        case S_STREAM_HEADER: {
            size_t had = d->tmp_have;
            bool complete = collect(d, in, in_len, &ip);
            /* Check the magic as it arrives, so trailing garbage is a format
             * error rather than a truncated header. */
            static const uint8_t magic[6] = {0xFD, '7', 'z', 'X', 'Z', 0x00};
            size_t m = d->tmp_have < 6 ? d->tmp_have : 6;
            if (memcmp(d->tmp, magic, m) != 0) {
                rc = fail(d, MND_XZ_EFORMAT, "not an .xz stream");
                break;
            }
            if (complete) rc = parse_stream_header(d);
            progressed = complete || d->tmp_have != had;
            break;
        }
        case S_BLOCK_START:
            if (ip == in_len) break;
            if (in[ip] == 0x00) {
                ip++;
                index_begin(d);
            } else {
                d->tmp_need = ((size_t)in[ip] + 1) * 4;
                d->tmp_have = 0;
                d->seq = S_BLOCK_HEADER;
            }
            progressed = true;
            break;
        case S_BLOCK_HEADER:
            if (!collect(d, in, in_len, &ip)) break;
            rc = parse_block_header(d);
            progressed = true;
            break;
        case S_LZMA2_CONTROL:
            if (ip == in_len) break;
            rc = lzma2_control(d, in[ip++]);
            progressed = true;
            break;
        case S_LZMA2_HEADER:
            if (!collect(d, in, in_len, &ip)) break;
            rc = lzma2_header(d);
            progressed = true;
            break;
        case S_LZMA2_UNCOMPRESSED: {
            if (d->dict.pos == d->dict.size) break; /* waits for a flush */
            size_t n = d->chunk_uncompressed;
            size_t room = dict_room(&d->dict);
            if (n > room) n = room;
            if (n > in_len - ip) n = in_len - ip;
            if (n == 0) break;
            for (size_t i = 0; i < n; i++) dict_put(&d->dict, in[ip + i]);
            ip += n;
            d->block_compressed += n;
            d->chunk_uncompressed -= (uint32_t)n;
            if (d->chunk_uncompressed == 0) d->seq = S_LZMA2_CONTROL;
            progressed = true;
            break;
        }
        case S_LZMA2_COMPRESSED: {
            size_t n = d->chunk_compressed - d->cbuf_have;
            if (n > in_len - ip) n = in_len - ip;
            if (n) memcpy(d->cbuf + d->cbuf_have, in + ip, n);
            d->cbuf_have += n;
            ip += n;
            if (d->cbuf_have < d->chunk_compressed) break;
            rc = lzma2_start_decode(d);
            progressed = true;
            break;
        }
        case S_LZMA2_DECODE: {
            bool done;
            size_t before = d->dict.pos;
            rc = lzma2_decode_round(d, &done);
            if (done) d->seq = S_LZMA2_CONTROL;
            progressed = done || d->dict.pos != before;
            break;
        }
        case S_BLOCK_PADDING: {
            /* Zero bytes until header + compressed data is a multiple of four. */
            if (d->declared_uncompressed != UINT64_MAX && d->declared_uncompressed != d->block_uncompressed) {
                rc = fail(d, MND_XZ_EFORMAT, "uncompressed size differs from the block header");
                break;
            }
            if ((d->header_size + d->block_compressed + d->padding) % 4 == 0) {
                d->padding = 0;
                d->tmp_need = (size_t)check_size(d->check_type);
                d->tmp_have = 0;
                d->seq = S_BLOCK_CHECK;
                progressed = true;
                break;
            }
            if (ip == in_len) break;
            if (in[ip++] != 0) {
                rc = fail(d, MND_XZ_EFORMAT, "non-zero block padding");
                break;
            }
            d->padding++;
            progressed = true;
            break;
        }
        case S_BLOCK_CHECK:
            if (!collect(d, in, in_len, &ip)) break;
            rc = finish_block(d);
            progressed = true;
            break;
        case S_INDEX:
            while (ip < in_len && d->seq == S_INDEX && rc == MND_XZ_OK) {
                rc = index_byte(d, in[ip++]);
                progressed = true;
            }
            break;
        case S_STREAM_FOOTER:
            if (!collect(d, in, in_len, &ip)) break;
            rc = parse_stream_footer(d);
            progressed = true;
            break;
        case S_STREAM_PADDING:
            while (ip < in_len && in[ip] == 0) {
                ip++;
                d->padding++;
                progressed = true;
            }
            if (ip < in_len) {
                if (d->padding % 4 != 0) {
                    rc = fail(d, MND_XZ_EFORMAT, "stream padding is not a multiple of four bytes");
                    break;
                }
                d->seq = S_STREAM_HEADER;
                d->tmp_need = 12;
                d->tmp_have = 0;
                progressed = true;
            }
            break;
        case S_ERROR:
            break;
        }
        if (rc != MND_XZ_OK) break;
        if (!progressed) break;
    }

    *in_used = ip;
    *out_written = op;
    if (rc != MND_XZ_OK) return rc;
    if (finish && ip == in_len && dict_flushed(&d->dict)) {
        if (d->seq == S_STREAM_PADDING) {
            if (d->padding % 4 != 0) return fail(d, MND_XZ_EFORMAT, "stream padding is not a multiple of four bytes");
            return MND_XZ_END;
        }
        /* Every other state is waiting for input that will never come. */
        return fail(d, MND_XZ_ETRUNCATED, "input ends inside a stream");
    }
    return MND_XZ_OK;
}

/* ------------------------------------------------------------------------ */
/* File reader                                                               */

struct mnd_xz_file {
    int fd;
    mnd_xz *dec;
    uint8_t in[1 << 16];
    size_t in_pos, in_len;
    bool eof, done;
    int error;
    uint64_t consumed;
    char msg[160];
};

mnd_xz_file *mnd_xz_file_open(int fd, uint64_t memlimit) {
    mnd_xz_file *f = calloc(1, sizeof *f);
    if (!f) return NULL;
    f->fd = fd;
    f->dec = mnd_xz_new(memlimit);
    if (!f->dec) {
        free(f);
        return NULL;
    }
    return f;
}

ssize_t mnd_xz_file_read(mnd_xz_file *f, void *buf, size_t n) {
    if (f->error) return f->error;
    if (f->done || n == 0) return 0;
    size_t produced = 0;
    while (produced == 0) {
        if (f->in_pos == f->in_len && !f->eof) {
            ssize_t r;
            do r = read(f->fd, f->in, sizeof f->in);
            while (r < 0 && errno == EINTR);
            if (r < 0) {
                snprintf(f->msg, sizeof f->msg, "read: %s", strerror(errno));
                return f->error = MND_XZ_EIO;
            }
            f->in_pos = 0;
            f->in_len = (size_t)r;
            if (r == 0) f->eof = true;
        }
        size_t used, wrote;
        int rc = mnd_xz_run(f->dec, f->in + f->in_pos, f->in_len - f->in_pos, &used, (uint8_t *)buf + produced,
                            n - produced, &wrote, f->eof);
        f->in_pos += used;
        f->consumed += used;
        produced += wrote;
        if (rc == MND_XZ_END) {
            f->done = true;
            break;
        }
        if (rc < 0) {
            snprintf(f->msg, sizeof f->msg, "%s", mnd_xz_error(f->dec));
            f->error = rc;
            return produced > 0 ? (ssize_t)produced : rc;
        }
        if (used == 0 && wrote == 0 && f->eof) {
            snprintf(f->msg, sizeof f->msg, "decoder made no progress");
            return f->error = MND_XZ_ECORRUPT;
        }
    }
    return (ssize_t)produced;
}

const char *mnd_xz_file_error(const mnd_xz_file *f) { return f->error ? f->msg : ""; }

uint64_t mnd_xz_file_position(const mnd_xz_file *f) { return f->consumed; }

void mnd_xz_file_close(mnd_xz_file *f) {
    if (!f) return;
    mnd_xz_free(f->dec);
    free(f);
}
