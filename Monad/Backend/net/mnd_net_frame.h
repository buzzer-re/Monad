/*
 * mnd_net_frame.h — Ethernet, ARP, IPv4, ICMP, UDP and TCP: parsing (views
 * into the frame, nothing copied) and building (into a caller's buffer).
 *
 * Frames come from guests and are untrusted: every parser checks lengths
 * before reading and verifies checksums; anything malformed is rejected.
 * IPv4 addresses are in host byte order; everything on the wire is big
 * endian. IPv4 fragments are not supported (rejected).
 */
#ifndef MND_NET_FRAME_H
#define MND_NET_FRAME_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define MND_ETH_HLEN 14
#define MND_ETH_MTU 1500
#define MND_FRAME_MAX (MND_ETH_HLEN + MND_ETH_MTU)
#define MND_ETHERTYPE_IPV4 0x0800
#define MND_ETHERTYPE_ARP 0x0806
#define MND_ETHERTYPE_IPV6 0x86DD

#define MND_IPPROTO_ICMP 1
#define MND_IPPROTO_TCP 6
#define MND_IPPROTO_UDP 17

#define MND_TCP_FIN 0x01
#define MND_TCP_SYN 0x02
#define MND_TCP_RST 0x04
#define MND_TCP_PSH 0x08
#define MND_TCP_ACK 0x10
#define MND_TCP_URG 0x20

typedef struct {
    uint8_t b[6];
} mnd_mac;

extern const mnd_mac MND_MAC_BROADCAST;
bool mnd_mac_eq(mnd_mac a, mnd_mac b);
bool mnd_mac_is_multicast(mnd_mac m); /* includes broadcast */

typedef uint32_t mnd_ip4;
#define MND_IP4(a, b, c, d) (((mnd_ip4)(a) << 24) | ((mnd_ip4)(b) << 16) | ((mnd_ip4)(c) << 8) | (mnd_ip4)(d))

/* RFC 1071 one's-complement sum; fold with mnd_csum_finish. */
uint32_t mnd_csum_add(uint32_t sum, const void *data, size_t len);
uint16_t mnd_csum_finish(uint32_t sum);
/* Pseudo-header sum for UDP/TCP. */
uint32_t mnd_csum_pseudo(mnd_ip4 src, mnd_ip4 dst, uint8_t proto, uint16_t len);

/* ---- Parsing ------------------------------------------------------------ */

typedef struct {
    mnd_mac dst, src;
    uint16_t type;
    const uint8_t *payload;
    size_t len;
} mnd_eth;

typedef struct {
    uint16_t op; /* 1 request, 2 reply */
    mnd_mac sha, tha;
    mnd_ip4 spa, tpa;
} mnd_arp;

typedef struct {
    uint8_t tos, ttl, proto;
    uint16_t id;
    mnd_ip4 src, dst;
    const uint8_t *payload;
    size_t len; /* payload length, from the header's total length */
    const uint8_t *header; /* the header itself (quoted by ICMP errors) */
    size_t header_len;
} mnd_ip;

typedef struct {
    uint8_t type, code;
    uint16_t id, seq; /* echo request/reply */
    const uint8_t *data;
    size_t len;
} mnd_icmp;

typedef struct {
    uint16_t sport, dport;
    const uint8_t *payload;
    size_t len;
} mnd_udp;

typedef struct {
    uint16_t sport, dport;
    uint32_t seq, ack;
    uint8_t flags;
    uint16_t window;
    uint16_t mss;         /* 0 when absent */
    int wscale;           /* -1 when absent */
    bool sack_permitted;
    const uint8_t *payload;
    size_t len;
} mnd_tcp;

/* All return 0 on success, -1 if the input is malformed. */
int mnd_eth_parse(const uint8_t *frame, size_t n, mnd_eth *out);
int mnd_arp_parse(const uint8_t *p, size_t n, mnd_arp *out);
/* Verifies version, header length, total length, checksum; rejects fragments. */
int mnd_ip_parse(const uint8_t *p, size_t n, mnd_ip *out);
/* The ip's payload; verifies the ICMP checksum. */
int mnd_icmp_parse(const mnd_ip *ip, mnd_icmp *out);
/* Verifies length and (when non-zero) the checksum. */
int mnd_udp_parse(const mnd_ip *ip, mnd_udp *out);
/* Verifies data offset, options and checksum. */
int mnd_tcp_parse(const mnd_ip *ip, mnd_tcp *out);

/* Checksum offload: a guest may hand its NIC a TCP or UDP segment whose
 * checksum holds only the pseudo-header sum (not complemented), for the NIC
 * to finish. The parsers accept exactly that value in place of the finished
 * checksum. This finishes it: if the Ethernet frame is such a segment, it is
 * copied into `out` (MND_FRAME_MAX bytes) with the checksum finished, and
 * true is returned; otherwise `out` is untouched. */
bool mnd_csum_offload_finish(const uint8_t *frame, size_t n, uint8_t *out);

/* ---- Building ------------------------------------------------------------
 * Each writes a complete Ethernet frame into buf and returns its length, or
 * 0 if it does not fit in cap. */

size_t mnd_build_arp(uint8_t *buf, size_t cap, uint16_t op, mnd_mac eth_dst, mnd_mac sha, mnd_ip4 spa, mnd_mac tha,
                     mnd_ip4 tpa);

typedef struct {
    mnd_mac eth_dst, eth_src;
    mnd_ip4 src, dst;
    uint8_t ttl;
    uint16_t id;
} mnd_ip_hdr_spec;

size_t mnd_build_ip(uint8_t *buf, size_t cap, const mnd_ip_hdr_spec *h, uint8_t proto, const uint8_t *payload,
                    size_t len);
size_t mnd_build_icmp(uint8_t *buf, size_t cap, const mnd_ip_hdr_spec *h, uint8_t type, uint8_t code, uint16_t id,
                      uint16_t seq, const uint8_t *data, size_t len);
size_t mnd_build_udp(uint8_t *buf, size_t cap, const mnd_ip_hdr_spec *h, uint16_t sport, uint16_t dport,
                     const uint8_t *payload, size_t len);

typedef struct {
    uint16_t sport, dport;
    uint32_t seq, ack;
    uint8_t flags;
    uint16_t window;
    uint16_t mss;   /* written as an option when non-zero */
    int wscale;     /* written as an option when >= 0 */
} mnd_tcp_spec;

size_t mnd_build_tcp(uint8_t *buf, size_t cap, const mnd_ip_hdr_spec *h, const mnd_tcp_spec *t,
                     const uint8_t *payload, size_t len);

#endif /* MND_NET_FRAME_H */
