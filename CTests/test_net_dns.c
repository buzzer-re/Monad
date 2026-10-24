/* Tests for the DNS message checks used by the gateway's forwarder. */
#include "net_test_dns.h"
#include "test_util.h"

typedef struct {
    int count;
    char names[8][MND_DNS_NAME_MAX + 1];
    mnd_ip4 ips[8];
    uint32_t ttls[8];
} seen;

static void on_a(void *ctx, const char *name, mnd_ip4 ip, uint32_t ttl) {
    seen *s = ctx;
    if (s->count >= 8) return;
    strcpy(s->names[s->count], name);
    s->ips[s->count] = ip;
    s->ttls[s->count] = ttl;
    s->count++;
}

static void test_query(void) {
    uint8_t p[512];
    mnd_dns_query q;
    size_t n = td_query(p, 0x1234, "WWW.Example.com", MND_DNS_TYPE_A, 0);
    CHECK(mnd_dns_parse_query(p, n, &q) == 0);
    CHECK(q.id == 0x1234 && q.qtype == MND_DNS_TYPE_A && q.qclass == 1 && q.udp_size == 512);
    CHECK_STR(q.qname, "www.example.com");
    CHECK(q.question_end == n);
    n = td_query(p, 1, "github.com", MND_DNS_TYPE_AAAA, 1232);
    CHECK(mnd_dns_parse_query(p, n, &q) == 0 && q.udp_size == 1232 && q.qtype == MND_DNS_TYPE_AAAA);
    n = td_query(p, 1, "tiny.example", MND_DNS_TYPE_A, 100); /* below 512 means 512 */
    CHECK(mnd_dns_parse_query(p, n, &q) == 0 && q.udp_size == 512);
    n = td_query(p, 1, "_sip._tcp.example.com", 33, 0);
    CHECK(mnd_dns_parse_query(p, n, &q) == 0);
    n = td_query(p, 1, "", 2, 0); /* the root */
    CHECK(mnd_dns_parse_query(p, n, &q) == 0 && q.qname[0] == 0);
}

static void test_malformed_queries(void) {
    uint8_t p[600];
    mnd_dns_query q;
    size_t n = td_query(p, 1, "example.com", MND_DNS_TYPE_A, 0);
    CHECK(mnd_dns_parse_query(p, 11, &q) == -1);
    CHECK(mnd_dns_parse_query(p, n - 1, &q) == -1); /* question cut short */
    CHECK(mnd_dns_parse_query(NULL, n, &q) == -1);
    uint8_t c[600];
#define MUTATE(stmt)                                                                               \
    do {                                                                                           \
        memcpy(c, p, n);                                                                           \
        stmt;                                                                                      \
        CHECK(mnd_dns_parse_query(c, n, &q) == -1);                                                \
    } while (0)
    MUTATE(c[2] |= 0x80);         /* a response */
    MUTATE(c[2] |= 0x08);         /* opcode 1 */
    MUTATE(c[5] = 2);             /* two questions */
    MUTATE(c[5] = 0);             /* none */
    MUTATE(c[7] = 1);             /* answers in a query */
    MUTATE(c[9] = 1);             /* authority records */
    MUTATE(c[12] = 0xc0);         /* a compression pointer */
    MUTATE(c[12] = 70);           /* a label longer than 63 */
    MUTATE(c[13] = '.');          /* a dot inside a label */
    MUTATE(c[13] = 0x07);         /* a control byte */
    MUTATE(c[13] = 0xe9);         /* not ASCII */
    /* Trailing bytes. */
    memcpy(c, p, n);
    c[n] = 0;
    CHECK(mnd_dns_parse_query(c, n + 1, &q) == -1);
    /* An additional record that is not OPT, or two of them. */
    n = td_query(p, 1, "example.com", MND_DNS_TYPE_A, 1232);
    MUTATE(c[n - 10] = 1);        /* OPT's type becomes 0x0129 */
    MUTATE(c[11] = 2);
    /* Name longer than 253 characters. */
    char name[300];
    memset(name, 0, sizeof name);
    for (int i = 0; i < 5; i++) {
        memset(name + i * 51, 'a', 50);
        if (i < 4) name[i * 51 + 50] = '.';
    }
    n = td_query(p, 1, name, MND_DNS_TYPE_A, 0); /* 254 characters */
    CHECK(mnd_dns_parse_query(p, n, &q) == -1);
    name[253] = 0; /* 253 characters */
    n = td_query(p, 1, name, MND_DNS_TYPE_A, 0);
    CHECK(mnd_dns_parse_query(p, n, &q) == 0 && strlen(q.qname) == 253);
#undef MUTATE
}

static void test_answer(void) {
    uint8_t qb[512], p[512];
    mnd_dns_query q;
    CHECK(mnd_dns_parse_query(qb, td_query(qb, 7, "www.github.com", MND_DNS_TYPE_A, 0), &q) == 0);
    /* www.github.com CNAME github.com; github.com A 140.82.112.3 and .4 */
    size_t at = td_response(p, 7, "WWW.GitHub.com", MND_DNS_TYPE_A);
    size_t cname_at = at;
    uint8_t target[2] = {0xc0, 16}; /* "github.com" inside the question: 12 + 1 + 3 */
    at = td_rr_ptr(p, at, 12, MND_DNS_TYPE_CNAME, 60, target, 2);
    (void)cname_at;
    at = td_a(p, at, 16, MND_IP4(140, 82, 112, 3), 300);
    at = td_a(p, at, 16, MND_IP4(140, 82, 112, 4), 0);
    td_set_ancount(p, 3);
    seen s = {0};
    CHECK(mnd_dns_parse_answer(p, at, &q, on_a, &s) == 0);
    CHECK(s.count == 4);
    CHECK_STR(s.names[0], "www.github.com");
    CHECK_STR(s.names[1], "github.com");
    CHECK(s.ips[0] == MND_IP4(140, 82, 112, 3) && s.ips[1] == s.ips[0] && s.ttls[0] == 300);
    CHECK_STR(s.names[2], "www.github.com");
    CHECK(s.ips[2] == MND_IP4(140, 82, 112, 4) && s.ttls[2] == 0);
    /* The record's own name equal to the query's: reported once. */
    at = td_response(p, 7, "www.github.com", MND_DNS_TYPE_A);
    at = td_a(p, at, 12, MND_IP4(1, 2, 3, 4), 60);
    td_set_ancount(p, 1);
    memset(&s, 0, sizeof s);
    CHECK(mnd_dns_parse_answer(p, at, &q, on_a, &s) == 0 && s.count == 1);
    /* NXDOMAIN: nothing, and fine. */
    at = td_response(p, 7, "www.github.com", MND_DNS_TYPE_A);
    p[3] = 0x83;
    memset(&s, 0, sizeof s);
    CHECK(mnd_dns_parse_answer(p, at, &q, on_a, &s) == 0 && s.count == 0);
    /* Records outside the CNAME chain are not the query's addresses. */
    at = td_response(p, 7, "www.github.com", MND_DNS_TYPE_A);
    at = td_put16(p, at, 0xc000 | 12);
    at = td_put16(p, at, MND_DNS_TYPE_CNAME);
    at = td_put16(p, at, 1);
    at = td_put32(p, at, 60);
    at = td_put16(p, at, 16); /* rdata: "cdn.fastly.net" as labels, uncompressed */
    at = td_name(p, at, "cdn.fastly.net");
    size_t owner_at = at;
    at = td_a(p, at, (uint16_t)(owner_at - 16), MND_IP4(5, 5, 5, 5), 60); /* owner "cdn.fastly.net" */
    at = td_name(p, at, "evil.example");
    at = td_put16(p, at, MND_DNS_TYPE_A);
    at = td_put16(p, at, 1);
    at = td_put32(p, at, 60);
    at = td_put16(p, at, 4);
    const uint8_t evil[4] = {6, 6, 6, 6};
    memcpy(p + at, evil, 4);
    at += 4;
    td_set_ancount(p, 3);
    memset(&s, 0, sizeof s);
    CHECK(mnd_dns_parse_answer(p, at, &q, on_a, &s) == 0);
    CHECK(s.count == 2 && s.ips[0] == MND_IP4(5, 5, 5, 5) && s.ips[1] == s.ips[0]);
    CHECK_STR(s.names[0], "www.github.com");
    CHECK_STR(s.names[1], "cdn.fastly.net");
    /* AAAA records are not reported. */
    at = td_response(p, 7, "www.github.com", MND_DNS_TYPE_A);
    uint8_t v6[16] = {0x20, 0x01};
    at = td_rr_ptr(p, at, 12, MND_DNS_TYPE_AAAA, 60, v6, 16);
    td_set_ancount(p, 1);
    memset(&s, 0, sizeof s);
    CHECK(mnd_dns_parse_answer(p, at, &q, on_a, &s) == 0 && s.count == 0);
}

static void test_answers_that_do_not_match_or_are_malformed(void) {
    uint8_t qb[512], p[512];
    mnd_dns_query q;
    CHECK(mnd_dns_parse_query(qb, td_query(qb, 7, "example.com", MND_DNS_TYPE_A, 0), &q) == 0);
    seen s = {0};
    size_t at = td_response(p, 7, "example.org", MND_DNS_TYPE_A);
    CHECK(mnd_dns_parse_answer(p, at, &q, on_a, &s) == -1); /* another question */
    at = td_response(p, 7, "example.com", MND_DNS_TYPE_AAAA);
    CHECK(mnd_dns_parse_answer(p, at, &q, on_a, &s) == -1); /* another type */
    at = td_response(p, 7, "example.com", MND_DNS_TYPE_A);
    p[2] &= 0x7f;
    CHECK(mnd_dns_parse_answer(p, at, &q, on_a, &s) == -1); /* not a response */
    at = td_response(p, 7, "example.com", MND_DNS_TYPE_A);
    CHECK(mnd_dns_parse_answer(p, at - 1, &q, on_a, &s) == -1); /* question cut short */

    /* Records: counts beyond the data, bad rdlength, bad pointers. */
    size_t base = td_response(p, 7, "example.com", MND_DNS_TYPE_A);
    at = td_a(p, base, 12, MND_IP4(1, 1, 1, 1), 60);
    td_set_ancount(p, 2);
    CHECK(mnd_dns_parse_answer(p, at, &q, on_a, &s) == -1);
    td_set_ancount(p, 1);
    CHECK(mnd_dns_parse_answer(p, at - 1, &q, on_a, &s) == -1);
    p[base + 10] = 0;
    p[base + 11] = 5; /* rdlength 5 for an A record */
    uint8_t five[5] = {1, 1, 1, 1, 1};
    at = td_rr_ptr(p, base, 12, MND_DNS_TYPE_A, 60, five, 5);
    CHECK(mnd_dns_parse_answer(p, at, &q, on_a, &s) == -1);
    at = td_a(p, base, (uint16_t)base, MND_IP4(1, 1, 1, 1), 60); /* points at itself */
    CHECK(mnd_dns_parse_answer(p, at, &q, on_a, &s) == -1);
    at = td_a(p, base, 400, MND_IP4(1, 1, 1, 1), 60); /* forward, past the end */
    CHECK(mnd_dns_parse_answer(p, at, &q, on_a, &s) == -1);
    CHECK(s.count == 0);
}

static void test_truncate_and_servfail(void) {
    uint8_t qb[512], p[1024];
    mnd_dns_query q;
    size_t qn = td_query(qb, 9, "example.com", MND_DNS_TYPE_A, 0);
    CHECK(mnd_dns_parse_query(qb, qn, &q) == 0);
    size_t at = td_response(p, 9, "example.com", MND_DNS_TYPE_A);
    size_t question_end = at;
    for (int i = 0; i < 40; i++) at = td_a(p, at, 12, MND_IP4(10, 0, 0, (uint8_t)i), 60);
    td_set_ancount(p, 40);
    CHECK(mnd_dns_parse_answer(p, at, &q, NULL, NULL) == 0);
    size_t n = mnd_dns_truncate(p, at, &q);
    CHECK(n == question_end);
    CHECK((p[2] & 0x02) && p[0] == 0 && p[1] == 9);
    CHECK(p[6] == 0 && p[7] == 0 && p[8] == 0 && p[9] == 0 && p[10] == 0 && p[11] == 0);
    CHECK(mnd_dns_parse_answer(p, n, &q, NULL, NULL) == 0);

    n = mnd_dns_servfail(p, sizeof p, qb, &q);
    CHECK(n == qn);
    CHECK(p[0] == 0 && p[1] == 9 && (p[2] & 0x80) && (p[3] & 0x0f) == MND_DNS_RCODE_SERVFAIL);
    CHECK(mnd_dns_parse_answer(p, n, &q, NULL, NULL) == 0);
    CHECK(mnd_dns_servfail(p, qn - 1, qb, &q) == 0);
    /* With EDNS in the query, the OPT record is not echoed. */
    qn = td_query(qb, 9, "example.com", MND_DNS_TYPE_A, 1232);
    CHECK(mnd_dns_parse_query(qb, qn, &q) == 0);
    n = mnd_dns_servfail(p, sizeof p, qb, &q);
    CHECK(n == q.question_end && p[11] == 0);
}

int main(void) {
    fprintf(stderr, "mnd_net DNS message tests\n");
    RUN(test_query);
    RUN(test_malformed_queries);
    RUN(test_answer);
    RUN(test_answers_that_do_not_match_or_are_malformed);
    RUN(test_truncate_and_servfail);
    TEST_MAIN_END();
}
