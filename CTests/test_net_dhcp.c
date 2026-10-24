/* Tests for the DHCP message codec. */
#include "../Monad/Backend/net/mnd_net_dhcp.h"
#include "test_util.h"

static const mnd_mac MAC = {{0x02, 0x4d, 0x4f, 0x4e, 0x00, 0x01}};

static mnd_dhcp request(void) {
    mnd_dhcp m = {0};
    m.op = 1;
    m.xid = 0x11223344;
    m.flags = MND_DHCP_FLAG_BROADCAST;
    m.chaddr = MAC;
    m.type = MND_DHCP_REQUEST;
    m.requested = MND_IP4(10, 77, 0, 2);
    m.server_id = MND_IP4(10, 77, 0, 1);
    strcpy(m.hostname, "dev-box");
    return m;
}

static void test_round_trip(void) {
    uint8_t p[600];
    mnd_dhcp m = request();
    size_t n = mnd_dhcp_build(p, sizeof p, &m);
    CHECK(n >= 240 + 3);
    CHECK(p[0] == 1 && p[1] == 1 && p[2] == 6);
    CHECK(p[236] == 99 && p[237] == 130 && p[238] == 83 && p[239] == 99); /* magic cookie */
    CHECK(p[n - 1] == 255);                                                /* end option */
    mnd_dhcp got;
    CHECK(mnd_dhcp_parse(p, n, &got) == 0);
    CHECK(got.op == 1 && got.xid == 0x11223344 && got.flags == MND_DHCP_FLAG_BROADCAST);
    CHECK(mnd_mac_eq(got.chaddr, MAC) && got.type == MND_DHCP_REQUEST);
    CHECK(got.requested == m.requested && got.server_id == m.server_id);
    CHECK_STR(got.hostname, "dev-box");
    CHECK(got.router == 0 && got.dns == 0 && got.lease_secs == 0);

    mnd_dhcp r = {0};
    r.op = 2;
    r.xid = 7;
    r.chaddr = MAC;
    r.type = MND_DHCP_ACK;
    r.yiaddr = MND_IP4(10, 77, 0, 2);
    r.server_id = MND_IP4(10, 77, 0, 1);
    r.subnet_mask = MND_IP4(255, 255, 255, 0);
    r.router = MND_IP4(10, 77, 0, 1);
    r.dns = MND_IP4(10, 77, 0, 1);
    r.broadcast = MND_IP4(10, 77, 0, 255);
    r.lease_secs = 3600;
    r.t1 = 1800;
    r.t2 = 3150;
    n = mnd_dhcp_build(p, sizeof p, &r);
    CHECK(n > 0 && mnd_dhcp_parse(p, n, &got) == 0);
    CHECK(got.op == 2 && got.type == MND_DHCP_ACK && got.yiaddr == r.yiaddr);
    CHECK(got.subnet_mask == r.subnet_mask && got.router == r.router && got.dns == r.dns);
    CHECK(got.broadcast == r.broadcast && got.lease_secs == 3600 && got.t1 == 1800 && got.t2 == 3150);
    CHECK(mnd_dhcp_build(p, 240, &r) == 0); /* no room for the options */
}

/* A valid DISCOVER with the given options after the cookie. */
static size_t with_options(uint8_t *p, const uint8_t *opts, size_t len) {
    memset(p, 0, 240);
    p[0] = 1;
    p[1] = 1;
    p[2] = 6;
    memcpy(p + 28, MAC.b, 6);
    p[236] = 99;
    p[237] = 130;
    p[238] = 83;
    p[239] = 99;
    memcpy(p + 240, opts, len);
    return 240 + len;
}

static void test_options(void) {
    uint8_t p[400];
    mnd_dhcp m;
    /* Pad options, an unknown option, then the type. No end option is fine. */
    const uint8_t ok[] = {0, 0, 200, 2, 9, 9, 53, 1, 1};
    CHECK(mnd_dhcp_parse(p, with_options(p, ok, sizeof ok), &m) == 0 && m.type == MND_DHCP_DISCOVER);
    /* Anything after the end option is ignored. */
    const uint8_t after_end[] = {53, 1, 1, 255, 53, 7};
    CHECK(mnd_dhcp_parse(p, with_options(p, after_end, sizeof after_end), &m) == 0);
    /* Hostnames: control and non-ASCII bytes are rejected, not copied. */
    const uint8_t host_bad[] = {53, 1, 1, 12, 3, 'a', 0x1b, 'b'};
    CHECK(mnd_dhcp_parse(p, with_options(p, host_bad, sizeof host_bad), &m) == 0 && m.hostname[0] == 0);
    uint8_t host_long[2 + 3 + 80] = {53, 1, 1, 12, 80};
    memset(host_long + 5, 'x', 80);
    CHECK(mnd_dhcp_parse(p, with_options(p, host_long, sizeof host_long), &m) == 0 && m.hostname[0] == 0);
}

static void test_malformed(void) {
    uint8_t p[400];
    mnd_dhcp m;
    const uint8_t type[] = {53, 1, 1};
    size_t n = with_options(p, type, sizeof type);
    CHECK(mnd_dhcp_parse(p, 239, &m) == -1);  /* shorter than the header */
    CHECK(mnd_dhcp_parse(NULL, n, &m) == -1);
    p[236] = 0;                                /* no magic cookie */
    CHECK(mnd_dhcp_parse(p, n, &m) == -1);
    n = with_options(p, type, sizeof type);
    p[1] = 6;                                  /* not Ethernet */
    CHECK(mnd_dhcp_parse(p, n, &m) == -1);
    n = with_options(p, type, sizeof type);
    p[2] = 16;                                 /* hardware address length */
    CHECK(mnd_dhcp_parse(p, n, &m) == -1);
    n = with_options(p, type, sizeof type);
    p[0] = 3;                                  /* neither request nor reply */
    CHECK(mnd_dhcp_parse(p, n, &m) == -1);
    const uint8_t truncated[] = {53, 1, 1, 50, 4, 10, 77};
    CHECK(mnd_dhcp_parse(p, with_options(p, truncated, sizeof truncated), &m) == -1);
    const uint8_t no_len[] = {53, 1, 1, 50};
    CHECK(mnd_dhcp_parse(p, with_options(p, no_len, sizeof no_len), &m) == -1);
    const uint8_t bad_size[] = {53, 1, 1, 50, 3, 10, 77, 0};  /* an address needs 4 bytes */
    CHECK(mnd_dhcp_parse(p, with_options(p, bad_size, sizeof bad_size), &m) == -1);
    const uint8_t too_long[] = {53, 1, 1, 50, 8, 10, 77, 0, 2, 10, 77, 0, 3}; /* one address only */
    CHECK(mnd_dhcp_parse(p, with_options(p, too_long, sizeof too_long), &m) == -1);
    const uint8_t routers[] = {53, 1, 2, 3, 8, 10, 77, 0, 1, 10, 77, 0, 9}; /* a list: the first counts */
    CHECK(mnd_dhcp_parse(p, with_options(p, routers, sizeof routers), &m) == 0 && m.router == MND_IP4(10, 77, 0, 1));
    const uint8_t bad_type[] = {53, 2, 1, 1};
    CHECK(mnd_dhcp_parse(p, with_options(p, bad_type, sizeof bad_type), &m) == -1);
}

int main(void) {
    fprintf(stderr, "mnd_net DHCP message tests\n");
    RUN(test_round_trip);
    RUN(test_options);
    RUN(test_malformed);
    TEST_MAIN_END();
}
