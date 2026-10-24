/* Tests for mnd_net_frame: parsing and building Ethernet, ARP, IPv4, ICMP,
 * UDP and TCP. Everything a guest sends is untrusted. */
#include "../Monad/Backend/net/mnd_net_frame.h"
#include "net_test_host.h"
#include "test_util.h"

static const mnd_mac A = {{0x02, 0, 0, 0, 0, 0x0a}};
static const mnd_mac B = {{0x02, 0, 0, 0, 0, 0x0b}};

static const mnd_ip_hdr_spec HDR = {
    .eth_dst = {{0x02, 0, 0, 0, 0, 0x0b}},
    .eth_src = {{0x02, 0, 0, 0, 0, 0x0a}},
    .src = MND_IP4(10, 77, 0, 10),
    .dst = MND_IP4(93, 184, 216, 34),
    .ttl = 64,
    .id = 7,
};

/* Parse a frame down to its IPv4 header. */
static int to_ip(const uint8_t *f, size_t n, mnd_ip *ip) {
    mnd_eth e;
    if (mnd_eth_parse(f, n, &e) != 0 || e.type != MND_ETHERTYPE_IPV4) return -1;
    return mnd_ip_parse(e.payload, e.len, ip);
}

static void test_checksum(void) {
    /* RFC 1071, section 3: the sum of these words is 0xddf2. */
    const uint8_t data[] = {0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7};
    CHECK(mnd_csum_finish(mnd_csum_add(0, data, sizeof data)) == (uint16_t)~0xddf2);
    /* Odd length pads with a zero byte; summing in pieces gives the same result. */
    const uint8_t odd[] = {0x12, 0x34, 0x56};
    uint32_t whole = mnd_csum_add(0, odd, 3);
    CHECK(mnd_csum_finish(whole) == (uint16_t)~(0x1234 + 0x5600));
    uint32_t split = mnd_csum_add(mnd_csum_add(0, data, 4), data + 4, 4);
    CHECK(mnd_csum_finish(split) == mnd_csum_finish(mnd_csum_add(0, data, 8)));
}

static void test_ethernet(void) {
    uint8_t f[64] = {0};
    memcpy(f, B.b, 6);
    memcpy(f + 6, A.b, 6);
    f[12] = 0x08, f[13] = 0x06;
    mnd_eth e;
    CHECK(mnd_eth_parse(f, sizeof f, &e) == 0);
    CHECK(mnd_mac_eq(e.dst, B) && mnd_mac_eq(e.src, A));
    CHECK(e.type == MND_ETHERTYPE_ARP && e.len == sizeof f - 14 && e.payload == f + 14);
    CHECK(mnd_eth_parse(f, 13, &e) == -1);
    CHECK(mnd_eth_parse(f, 14 + MND_ETH_MTU + 1, &e) == -1); /* larger than any frame we accept */
    f[12] = 0x81, f[13] = 0x00; /* 802.1Q tags are not used on our networks */
    CHECK(mnd_eth_parse(f, sizeof f, &e) == -1);
    CHECK(mnd_mac_is_multicast(MND_MAC_BROADCAST) && !mnd_mac_is_multicast(A));
}

static void test_arp(void) {
    uint8_t f[MND_FRAME_MAX];
    size_t n = mnd_build_arp(f, sizeof f, 1, MND_MAC_BROADCAST, A, MND_IP4(10, 77, 0, 10), (mnd_mac){{0}},
                             MND_IP4(10, 77, 0, 1));
    CHECK(n == 42);
    mnd_eth e;
    mnd_arp a;
    CHECK(mnd_eth_parse(f, n, &e) == 0 && e.type == MND_ETHERTYPE_ARP);
    CHECK(mnd_arp_parse(e.payload, e.len, &a) == 0);
    CHECK(a.op == 1 && mnd_mac_eq(a.sha, A) && a.spa == MND_IP4(10, 77, 0, 10) && a.tpa == MND_IP4(10, 77, 0, 1));
    uint8_t bad[28];
    memcpy(bad, e.payload, 28);
    bad[4] = 8; /* hardware address length */
    CHECK(mnd_arp_parse(bad, 28, &a) == -1);
    memcpy(bad, e.payload, 28);
    bad[1] = 6; /* hardware type */
    CHECK(mnd_arp_parse(bad, 28, &a) == -1);
    CHECK(mnd_arp_parse(e.payload, 27, &a) == -1);
    CHECK(mnd_build_arp(f, 41, 1, MND_MAC_BROADCAST, A, 0, B, 0) == 0);
}

static void test_ipv4(void) {
    uint8_t f[MND_FRAME_MAX];
    const uint8_t payload[] = "hello";
    size_t n = mnd_build_ip(f, sizeof f, &HDR, 200, payload, 5);
    CHECK(n == 14 + 20 + 5);
    mnd_ip ip;
    CHECK(to_ip(f, n, &ip) == 0);
    CHECK(ip.proto == 200 && ip.ttl == 64 && ip.id == 7 && ip.src == HDR.src && ip.dst == HDR.dst);
    CHECK(ip.len == 5 && memcmp(ip.payload, "hello", 5) == 0);
    /* Ethernet padding after the IP packet is ignored. */
    uint8_t padded[80] = {0};
    memcpy(padded, f, n);
    CHECK(to_ip(padded, 60, &ip) == 0 && ip.len == 5);

    uint8_t *h = f + 14;
    uint8_t save[20];
    memcpy(save, h, 20);
#define MUTATE(stmt)            \
    do {                        \
        memcpy(h, save, 20);    \
        stmt;                   \
        CHECK(to_ip(f, n, &ip) == -1); \
    } while (0)
    MUTATE(h[0] = 0x65);                 /* version 6 */
    MUTATE(h[0] = 0x44);                 /* header length 16 < 20 */
    MUTATE(h[10] ^= 0xff);               /* checksum */
    MUTATE((h[2] = 0x00, h[3] = 0xff));  /* total length beyond the frame */
    MUTATE((h[2] = 0x00, h[3] = 0x10));  /* total length below the header */
    memcpy(h, save, 20);
    CHECK(to_ip(f, n, &ip) == 0);
    CHECK(to_ip(f, 14 + 19, &ip) == -1); /* truncated header */

    /* Fragments (MF set or an offset) are rejected; DF alone is fine. */
    uint8_t fr[MND_FRAME_MAX];
    size_t fn;
    uint16_t flags[] = {0x2000, 0x0001, 0x4000};
    int want[] = {-1, -1, 0};
    for (int i = 0; i < 3; i++) {
        fn = mnd_build_ip(fr, sizeof fr, &HDR, 200, payload, 5);
        fr[14 + 6] = (uint8_t)(flags[i] >> 8), fr[14 + 7] = (uint8_t)flags[i];
        fr[14 + 10] = fr[14 + 11] = 0;
        uint16_t c = mnd_csum_finish(mnd_csum_add(0, fr + 14, 20));
        fr[14 + 10] = (uint8_t)(c >> 8), fr[14 + 11] = (uint8_t)c;
        CHECK(to_ip(fr, fn, &ip) == want[i]);
    }

    /* IPv4 options (header longer than 20 bytes) are skipped. */
    uint8_t opt[MND_FRAME_MAX] = {0};
    memcpy(opt, f, 14);
    uint8_t *oh = opt + 14;
    memcpy(oh, save, 20);
    oh[0] = 0x46;                        /* 24-byte header */
    oh[2] = 0, oh[3] = 24 + 5;
    oh[20] = 1, oh[21] = 1, oh[22] = 1, oh[23] = 0; /* NOPs, EOL */
    oh[10] = oh[11] = 0;
    uint16_t c = mnd_csum_finish(mnd_csum_add(0, oh, 24));
    oh[10] = (uint8_t)(c >> 8), oh[11] = (uint8_t)c;
    memcpy(oh + 24, "hello", 5);
    CHECK(to_ip(opt, 14 + 29, &ip) == 0 && ip.len == 5 && memcmp(ip.payload, "hello", 5) == 0);
}

static void test_icmp(void) {
    uint8_t f[MND_FRAME_MAX];
    const uint8_t data[] = {1, 2, 3, 4, 5, 6, 7};
    size_t n = mnd_build_icmp(f, sizeof f, &HDR, 8, 0, 0x1234, 3, data, sizeof data);
    mnd_ip ip;
    mnd_icmp ic;
    CHECK(to_ip(f, n, &ip) == 0 && ip.proto == MND_IPPROTO_ICMP);
    CHECK(mnd_icmp_parse(&ip, &ic) == 0);
    CHECK(ic.type == 8 && ic.code == 0 && ic.id == 0x1234 && ic.seq == 3);
    CHECK(ic.len == sizeof data && memcmp(ic.data, data, sizeof data) == 0);
    f[14 + 20 + 2] ^= 1; /* ICMP checksum */
    CHECK(to_ip(f, n, &ip) == 0 && mnd_icmp_parse(&ip, &ic) == -1);
    ip.len = 7;
    CHECK(mnd_icmp_parse(&ip, &ic) == -1); /* shorter than an ICMP header */
}

static void test_udp(void) {
    uint8_t f[MND_FRAME_MAX];
    const uint8_t q[] = "query";
    size_t n = mnd_build_udp(f, sizeof f, &HDR, 40000, 53, q, 5);
    CHECK(n == 14 + 20 + 8 + 5);
    mnd_ip ip;
    mnd_udp u;
    CHECK(to_ip(f, n, &ip) == 0 && ip.proto == MND_IPPROTO_UDP);
    CHECK(mnd_udp_parse(&ip, &u) == 0);
    CHECK(u.sport == 40000 && u.dport == 53 && u.len == 5 && memcmp(u.payload, "query", 5) == 0);

    uint8_t *uh = f + 14 + 20;
    uh[6] ^= 1; /* checksum */
    CHECK(mnd_udp_parse(&ip, &u) == -1);
    uh[6] = uh[7] = 0; /* checksum 0 means "none" for UDP over IPv4 */
    CHECK(mnd_udp_parse(&ip, &u) == 0);
    uh[4] = 0, uh[5] = 7; /* length below the header */
    CHECK(mnd_udp_parse(&ip, &u) == -1);
    uh[4] = 0, uh[5] = 200; /* beyond the IP payload */
    CHECK(mnd_udp_parse(&ip, &u) == -1);
}

static void test_tcp(void) {
    uint8_t f[MND_FRAME_MAX];
    mnd_tcp_spec s = {.sport = 40001, .dport = 443, .seq = 1000, .ack = 0, .flags = MND_TCP_SYN,
                      .window = 65535, .mss = 1460, .wscale = 7};
    size_t n = mnd_build_tcp(f, sizeof f, &HDR, &s, NULL, 0);
    mnd_ip ip;
    mnd_tcp t;
    CHECK(to_ip(f, n, &ip) == 0 && ip.proto == MND_IPPROTO_TCP);
    CHECK(mnd_tcp_parse(&ip, &t) == 0);
    CHECK(t.sport == 40001 && t.dport == 443 && t.seq == 1000 && t.flags == MND_TCP_SYN);
    CHECK(t.window == 65535 && t.mss == 1460 && t.wscale == 7 && t.len == 0);

    mnd_tcp_spec d = {.sport = 443, .dport = 40001, .seq = 5, .ack = 1001, .flags = MND_TCP_ACK | MND_TCP_PSH,
                      .window = 1024, .wscale = -1};
    n = mnd_build_tcp(f, sizeof f, &HDR, &d, (const uint8_t *)"data", 4);
    CHECK(to_ip(f, n, &ip) == 0 && mnd_tcp_parse(&ip, &t) == 0);
    CHECK(t.len == 4 && memcmp(t.payload, "data", 4) == 0 && t.mss == 0 && t.wscale == -1 && t.ack == 1001);

    uint8_t *th = f + 14 + 20;
    th[16] ^= 1; /* checksum */
    CHECK(mnd_tcp_parse(&ip, &t) == -1);
    th[16] ^= 1;
    uint8_t off = th[12];
    th[12] = 4 << 4; /* data offset below 20 bytes */
    CHECK(mnd_tcp_parse(&ip, &t) == -1);
    th[12] = 15 << 4; /* data offset beyond the segment */
    CHECK(mnd_tcp_parse(&ip, &t) == -1);
    th[12] = off;
    ip.len = 19;
    CHECK(mnd_tcp_parse(&ip, &t) == -1);
}

/* Options: NOP, EOL, SACK-permitted, unknown ones skipped; lengths that run
 * past the header or are too short are malformed. */
static void test_tcp_options(void) {
    struct {
        uint8_t opts[12];
        int ok;
        uint16_t mss;
        int wscale;
        bool sack;
    } cases[] = {
        {{1, 1, 4, 2, 2, 4, 5, 0xb4, 0, 0, 0, 0}, 1, 1460, -1, true},  /* NOP NOP SACKOK MSS EOL */
        {{8, 10, 0, 0, 0, 1, 0, 0, 0, 2, 1, 0}, 1, 0, -1, false},     /* timestamps, NOP, EOL */
        {{2, 4, 5, 0xb4, 3, 3, 14, 1, 0, 0, 0, 0}, 1, 1460, 14, false},
        {{2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, 0, 0, 0, false},       /* length 1 */
        {{2, 30, 5, 0xb4, 0, 0, 0, 0, 0, 0, 0, 0}, 0, 0, 0, false},   /* runs past the header */
        {{3, 3, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0}, 1, 0, 14, false},     /* shift clamped to 14 */
        {{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 9}, 0, 0, 0, false},       /* kind without a length byte */
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        uint8_t f[MND_FRAME_MAX];
        mnd_tcp_spec s = {.sport = 1, .dport = 2, .flags = MND_TCP_SYN, .window = 1, .wscale = -1};
        size_t n = mnd_build_tcp(f, sizeof f, &HDR, &s, NULL, 0);
        /* Rebuild with a 32-byte header carrying the case's options. */
        uint8_t g[MND_FRAME_MAX];
        memcpy(g, f, 14 + 20 + 20);
        uint8_t *ih = g + 14, *th = g + 14 + 20;
        ih[2] = 0, ih[3] = 20 + 32;
        ih[10] = ih[11] = 0;
        uint16_t ic = mnd_csum_finish(mnd_csum_add(0, ih, 20));
        ih[10] = (uint8_t)(ic >> 8), ih[11] = (uint8_t)ic;
        th[12] = 8 << 4;
        memcpy(th + 20, cases[i].opts, 12);
        th[16] = th[17] = 0;
        uint32_t sum = mnd_csum_pseudo(HDR.src, HDR.dst, MND_IPPROTO_TCP, 32);
        uint16_t tc = mnd_csum_finish(mnd_csum_add(sum, th, 32));
        th[16] = (uint8_t)(tc >> 8), th[17] = (uint8_t)tc;
        (void)n;
        mnd_ip ip;
        mnd_tcp t;
        CHECK(to_ip(g, 14 + 20 + 32, &ip) == 0);
        int r = mnd_tcp_parse(&ip, &t);
        CHECK(r == (cases[i].ok ? 0 : -1));
        if (r == 0) {
            CHECK(t.mss == cases[i].mss);
            CHECK(t.wscale == cases[i].wscale);
            CHECK(t.sack_permitted == cases[i].sack);
        }
    }
}

/* A guest using checksum offload (the Linux default on virtio-net) leaves
 * only the pseudo-header sum in TCP and UDP checksums for the NIC to finish.
 * The parsers accept that exact value; the switch finishes it before the
 * frame reaches another VM. Any other wrong checksum is still refused. */
static void test_offloaded_checksums(void) {
    uint8_t f[MND_FRAME_MAX], done[MND_FRAME_MAX];
    mnd_ip ip;
    mnd_udp u;
    mnd_tcp t;
    size_t n = mnd_build_udp(f, sizeof f, &HDR, 40000, 53, (const uint8_t *)"query", 5);
    uint8_t *uh = f + 14 + 20;
    uint8_t whole[2] = {uh[6], uh[7]};
    CHECK(!mnd_csum_offload_finish(f, n, done)); /* already finished */
    th_offload(f);
    CHECK(uh[6] != whole[0] || uh[7] != whole[1]);
    CHECK(to_ip(f, n, &ip) == 0 && mnd_udp_parse(&ip, &u) == 0 && u.len == 5);
    CHECK(mnd_csum_offload_finish(f, n, done));
    CHECK(memcmp(done + 14 + 20 + 6, whole, 2) == 0 && memcmp(done, f, 14 + 20 + 6) == 0);
    CHECK(to_ip(done, n, &ip) == 0 && mnd_udp_parse(&ip, &u) == 0);
    uh[7] ^= 1;
    CHECK(to_ip(f, n, &ip) == 0 && mnd_udp_parse(&ip, &u) == -1);
    CHECK(!mnd_csum_offload_finish(f, n, done));
    uh[6] = uh[7] = 0; /* no checksum: nothing to finish */
    CHECK(!mnd_csum_offload_finish(f, n, done));

    mnd_tcp_spec s = {.sport = 40001, .dport = 443, .seq = 9, .ack = 3, .flags = MND_TCP_ACK | MND_TCP_PSH,
                      .window = 512, .wscale = -1};
    n = mnd_build_tcp(f, sizeof f, &HDR, &s, (const uint8_t *)"odd", 3);
    uint8_t *th = f + 14 + 20;
    whole[0] = th[16], whole[1] = th[17];
    th_offload(f);
    CHECK(to_ip(f, n, &ip) == 0 && mnd_tcp_parse(&ip, &t) == 0 && t.len == 3);
    CHECK(mnd_csum_offload_finish(f, n, done));
    CHECK(memcmp(done + 14 + 20 + 16, whole, 2) == 0);
    th[16] ^= 0x80;
    CHECK(to_ip(f, n, &ip) == 0 && mnd_tcp_parse(&ip, &t) == -1);
    CHECK(!mnd_csum_offload_finish(f, n, done));

    /* Not TCP or UDP, not IPv4, malformed: left alone. */
    n = mnd_build_icmp(f, sizeof f, &HDR, 8, 0, 1, 1, (const uint8_t *)"p", 1);
    CHECK(!mnd_csum_offload_finish(f, n, done));
    n = mnd_build_arp(f, sizeof f, 1, MND_MAC_BROADCAST, A, HDR.src, B, HDR.dst);
    CHECK(!mnd_csum_offload_finish(f, n, done));
    CHECK(!mnd_csum_offload_finish(f, 10, done));
}

static void test_builders_respect_capacity(void) {
    uint8_t f[MND_FRAME_MAX];
    uint8_t big[MND_ETH_MTU];
    memset(big, 'x', sizeof big);
    CHECK(mnd_build_udp(f, sizeof f, &HDR, 1, 2, big, MND_ETH_MTU - 28) == MND_FRAME_MAX);
    CHECK(mnd_build_udp(f, sizeof f, &HDR, 1, 2, big, MND_ETH_MTU - 27) == 0); /* over the MTU */
    CHECK(mnd_build_ip(f, 33, &HDR, 200, big, 0) == 0);
    mnd_tcp_spec s = {.sport = 1, .dport = 2, .flags = MND_TCP_ACK, .window = 1, .wscale = -1};
    CHECK(mnd_build_tcp(f, 50, &HDR, &s, big, 10) == 0);
}

int main(void) {
    fprintf(stderr, "mnd_net_frame tests\n");
    RUN(test_checksum);
    RUN(test_ethernet);
    RUN(test_arp);
    RUN(test_ipv4);
    RUN(test_icmp);
    RUN(test_udp);
    RUN(test_tcp);
    RUN(test_tcp_options);
    RUN(test_offloaded_checksums);
    RUN(test_builders_respect_capacity);
    TEST_MAIN_END();
}
