/*
 * mnd_net_frame.c — parsing and building Ethernet, ARP, IPv4, ICMP, UDP and
 * TCP. Parsers check every length before reading and verify checksums
 * (TCP and UDP ones may also be left for the NIC to finish, see
 * mnd_csum_offload_finish).
 */
#include "mnd_net_frame.h"

#include <string.h>

const mnd_mac MND_MAC_BROADCAST = {{0xff, 0xff, 0xff, 0xff, 0xff, 0xff}};

bool mnd_mac_eq(mnd_mac a, mnd_mac b) { return memcmp(a.b, b.b, 6) == 0; }

bool mnd_mac_is_multicast(mnd_mac m) { return (m.b[0] & 1) != 0; }

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

/* ---- Checksums ---------------------------------------------------------- */

uint32_t mnd_csum_add(uint32_t sum, const void *data, size_t len) {
    const uint8_t *p = data;
    while (len > 1) {
        sum += rd16(p);
        if (sum & 0x80000000u) sum = (sum & 0xffff) + (sum >> 16);
        p += 2;
        len -= 2;
    }
    if (len) sum += (uint32_t)p[0] << 8;
    return sum;
}

uint16_t mnd_csum_finish(uint32_t sum) {
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    return (uint16_t)~sum;
}

uint32_t mnd_csum_pseudo(mnd_ip4 src, mnd_ip4 dst, uint8_t proto, uint16_t len) {
    return (src >> 16) + (src & 0xffff) + (dst >> 16) + (dst & 0xffff) + proto + len;
}

/* A TCP or UDP checksum, at `at` in the `len`-byte segment `p`, is either
 * finished (the whole segment sums to zero) or, from a guest using checksum
 * offload, the pseudo-header sum alone. One's complement has two zeros, so
 * 0x0000 and 0xffff are the same sum. */
static uint16_t ones_norm(uint16_t v) { return v == 0xffff ? 0 : v; }

static bool l4_finished(const mnd_ip *ip, uint8_t proto, const uint8_t *p, size_t len) {
    uint32_t sum = mnd_csum_pseudo(ip->src, ip->dst, proto, (uint16_t)len);
    return mnd_csum_finish(mnd_csum_add(sum, p, len)) == 0;
}

static bool l4_offloaded(const mnd_ip *ip, uint8_t proto, const uint8_t *p, size_t len, size_t at) {
    uint16_t partial = (uint16_t)~mnd_csum_finish(mnd_csum_pseudo(ip->src, ip->dst, proto, (uint16_t)len));
    return ones_norm(rd16(p + at)) == ones_norm(partial) && !l4_finished(ip, proto, p, len);
}

static bool l4_checksum_ok(const mnd_ip *ip, uint8_t proto, const uint8_t *p, size_t len, size_t at) {
    return l4_finished(ip, proto, p, len) || l4_offloaded(ip, proto, p, len, at);
}

/* ---- Parsing ------------------------------------------------------------ */

int mnd_eth_parse(const uint8_t *f, size_t n, mnd_eth *out) {
    if (!f || n < MND_ETH_HLEN || n > MND_FRAME_MAX) return -1;
    memcpy(out->dst.b, f, 6);
    memcpy(out->src.b, f + 6, 6);
    out->type = rd16(f + 12);
    /* VLAN tags are not used on Monad's networks. */
    if (out->type == 0x8100 || out->type == 0x88a8) return -1;
    out->payload = f + MND_ETH_HLEN;
    out->len = n - MND_ETH_HLEN;
    return 0;
}

int mnd_arp_parse(const uint8_t *p, size_t n, mnd_arp *out) {
    if (!p || n < 28) return -1;
    if (rd16(p) != 1 || rd16(p + 2) != MND_ETHERTYPE_IPV4 || p[4] != 6 || p[5] != 4) return -1;
    out->op = rd16(p + 6);
    if (out->op != 1 && out->op != 2) return -1;
    memcpy(out->sha.b, p + 8, 6);
    out->spa = rd32(p + 14);
    memcpy(out->tha.b, p + 18, 6);
    out->tpa = rd32(p + 24);
    return 0;
}

int mnd_ip_parse(const uint8_t *p, size_t n, mnd_ip *out) {
    if (!p || n < 20) return -1;
    if ((p[0] >> 4) != 4) return -1;
    size_t hlen = (size_t)(p[0] & 0x0f) * 4;
    if (hlen < 20 || hlen > n) return -1;
    size_t total = rd16(p + 2);
    if (total < hlen || total > n) return -1;
    if ((rd16(p + 6) & 0x3fff) != 0) return -1; /* MF set or an offset: a fragment */
    if (mnd_csum_finish(mnd_csum_add(0, p, hlen)) != 0) return -1;
    out->tos = p[1];
    out->id = rd16(p + 4);
    out->ttl = p[8];
    out->proto = p[9];
    out->src = rd32(p + 12);
    out->dst = rd32(p + 16);
    out->payload = p + hlen;
    out->len = total - hlen;
    out->header = p;
    out->header_len = hlen;
    return 0;
}

int mnd_icmp_parse(const mnd_ip *ip, mnd_icmp *out) {
    if (!ip || ip->len < 8) return -1;
    const uint8_t *p = ip->payload;
    if (mnd_csum_finish(mnd_csum_add(0, p, ip->len)) != 0) return -1;
    out->type = p[0];
    out->code = p[1];
    out->id = rd16(p + 4);
    out->seq = rd16(p + 6);
    out->data = p + 8;
    out->len = ip->len - 8;
    return 0;
}

int mnd_udp_parse(const mnd_ip *ip, mnd_udp *out) {
    if (!ip || ip->len < 8) return -1;
    const uint8_t *p = ip->payload;
    size_t ulen = rd16(p + 4);
    if (ulen < 8 || ulen > ip->len) return -1;
    if (rd16(p + 6) != 0 && !l4_checksum_ok(ip, MND_IPPROTO_UDP, p, ulen, 6)) return -1;
    out->sport = rd16(p);
    out->dport = rd16(p + 2);
    out->payload = p + 8;
    out->len = ulen - 8;
    return 0;
}

/* TCP options: kinds 0 (end) and 1 (no-op) are one byte; every other kind
 * has a length byte covering itself, which must fit inside the header. */
static int tcp_options(const uint8_t *o, size_t n, mnd_tcp *out) {
    size_t i = 0;
    while (i < n) {
        uint8_t kind = o[i];
        if (kind == 0) break;
        if (kind == 1) {
            i++;
            continue;
        }
        if (i + 1 >= n) return -1;
        size_t len = o[i + 1];
        if (len < 2 || i + len > n) return -1;
        switch (kind) {
        case 2:
            if (len != 4) return -1;
            out->mss = rd16(o + i + 2);
            break;
        case 3:
            if (len != 3) return -1;
            out->wscale = o[i + 2] > 14 ? 14 : o[i + 2];
            break;
        case 4:
            if (len != 2) return -1;
            out->sack_permitted = true;
            break;
        default:
            break; /* timestamps, SACK blocks, …: not used */
        }
        i += len;
    }
    return 0;
}

int mnd_tcp_parse(const mnd_ip *ip, mnd_tcp *out) {
    if (!ip || ip->len < 20) return -1;
    const uint8_t *p = ip->payload;
    size_t doff = (size_t)(p[12] >> 4) * 4;
    if (doff < 20 || doff > ip->len) return -1;
    if (ip->len > 0xffff) return -1;
    if (!l4_checksum_ok(ip, MND_IPPROTO_TCP, p, ip->len, 16)) return -1;
    out->sport = rd16(p);
    out->dport = rd16(p + 2);
    out->seq = rd32(p + 4);
    out->ack = rd32(p + 8);
    out->flags = p[13] & 0x3f;
    out->window = rd16(p + 14);
    out->mss = 0;
    out->wscale = -1;
    out->sack_permitted = false;
    if (tcp_options(p + 20, doff - 20, out) != 0) return -1;
    out->payload = p + doff;
    out->len = ip->len - doff;
    return 0;
}

bool mnd_csum_offload_finish(const uint8_t *frame, size_t n, uint8_t *out) {
    mnd_eth eth;
    mnd_ip ip;
    if (mnd_eth_parse(frame, n, &eth) != 0 || eth.type != MND_ETHERTYPE_IPV4) return false;
    if (mnd_ip_parse(eth.payload, eth.len, &ip) != 0) return false;
    size_t len, at;
    if (ip.proto == MND_IPPROTO_TCP) {
        if (ip.len < 20 || ip.len > 0xffff) return false;
        len = ip.len;
        at = 16;
    } else if (ip.proto == MND_IPPROTO_UDP) {
        if (ip.len < 8) return false;
        len = rd16(ip.payload + 4);
        at = 6;
        if (len < 8 || len > ip.len || rd16(ip.payload + 6) == 0) return false;
    } else {
        return false;
    }
    if (!l4_offloaded(&ip, ip.proto, ip.payload, len, at)) return false;
    memcpy(out, frame, n);
    uint8_t *l4 = out + (ip.payload - frame);
    wr16(l4 + at, 0);
    uint16_t c = mnd_csum_finish(mnd_csum_add(mnd_csum_pseudo(ip.src, ip.dst, ip.proto, (uint16_t)len), l4, len));
    if (ip.proto == MND_IPPROTO_UDP && c == 0) c = 0xffff; /* 0 would mean "no checksum" */
    wr16(l4 + at, c);
    return true;
}

/* ---- Building ----------------------------------------------------------- */

static void eth_header(uint8_t *buf, mnd_mac dst, mnd_mac src, uint16_t type) {
    memcpy(buf, dst.b, 6);
    memcpy(buf + 6, src.b, 6);
    wr16(buf + 12, type);
}

size_t mnd_build_arp(uint8_t *buf, size_t cap, uint16_t op, mnd_mac eth_dst, mnd_mac sha, mnd_ip4 spa, mnd_mac tha,
                     mnd_ip4 tpa) {
    const size_t n = MND_ETH_HLEN + 28;
    if (!buf || cap < n) return 0;
    eth_header(buf, eth_dst, sha, MND_ETHERTYPE_ARP);
    uint8_t *p = buf + MND_ETH_HLEN;
    wr16(p, 1);
    wr16(p + 2, MND_ETHERTYPE_IPV4);
    p[4] = 6;
    p[5] = 4;
    wr16(p + 6, op);
    memcpy(p + 8, sha.b, 6);
    wr32(p + 14, spa);
    memcpy(p + 18, tha.b, 6);
    wr32(p + 24, tpa);
    return n;
}

/* Ethernet + IPv4 header for a payload of `len` bytes; 0 if it does not fit. */
static size_t ip_header(uint8_t *buf, size_t cap, const mnd_ip_hdr_spec *h, uint8_t proto, size_t len) {
    if (!buf || !h || len > MND_ETH_MTU - 20) return 0;
    size_t n = MND_ETH_HLEN + 20 + len;
    if (cap < n) return 0;
    eth_header(buf, h->eth_dst, h->eth_src, MND_ETHERTYPE_IPV4);
    uint8_t *p = buf + MND_ETH_HLEN;
    p[0] = 0x45;
    p[1] = 0;
    wr16(p + 2, (uint16_t)(20 + len));
    wr16(p + 4, h->id);
    wr16(p + 6, 0x4000); /* don't fragment */
    p[8] = h->ttl;
    p[9] = proto;
    wr16(p + 10, 0);
    wr32(p + 12, h->src);
    wr32(p + 16, h->dst);
    wr16(p + 10, mnd_csum_finish(mnd_csum_add(0, p, 20)));
    return n;
}

size_t mnd_build_ip(uint8_t *buf, size_t cap, const mnd_ip_hdr_spec *h, uint8_t proto, const uint8_t *payload,
                    size_t len) {
    size_t n = ip_header(buf, cap, h, proto, len);
    if (n && len) memcpy(buf + MND_ETH_HLEN + 20, payload, len);
    return n;
}

size_t mnd_build_icmp(uint8_t *buf, size_t cap, const mnd_ip_hdr_spec *h, uint8_t type, uint8_t code, uint16_t id,
                      uint16_t seq, const uint8_t *data, size_t len) {
    size_t n = ip_header(buf, cap, h, MND_IPPROTO_ICMP, 8 + len);
    if (!n) return 0;
    uint8_t *p = buf + MND_ETH_HLEN + 20;
    p[0] = type;
    p[1] = code;
    wr16(p + 2, 0);
    wr16(p + 4, id);
    wr16(p + 6, seq);
    if (len) memcpy(p + 8, data, len);
    wr16(p + 2, mnd_csum_finish(mnd_csum_add(0, p, 8 + len)));
    return n;
}

size_t mnd_build_udp(uint8_t *buf, size_t cap, const mnd_ip_hdr_spec *h, uint16_t sport, uint16_t dport,
                     const uint8_t *payload, size_t len) {
    size_t n = ip_header(buf, cap, h, MND_IPPROTO_UDP, 8 + len);
    if (!n) return 0;
    uint8_t *p = buf + MND_ETH_HLEN + 20;
    uint16_t ulen = (uint16_t)(8 + len);
    wr16(p, sport);
    wr16(p + 2, dport);
    wr16(p + 4, ulen);
    wr16(p + 6, 0);
    if (len) memcpy(p + 8, payload, len);
    uint16_t c = mnd_csum_finish(mnd_csum_add(mnd_csum_pseudo(h->src, h->dst, MND_IPPROTO_UDP, ulen), p, ulen));
    wr16(p + 6, c ? c : 0xffff); /* 0 would mean "no checksum" */
    return n;
}

size_t mnd_build_tcp(uint8_t *buf, size_t cap, const mnd_ip_hdr_spec *h, const mnd_tcp_spec *t,
                     const uint8_t *payload, size_t len) {
    if (!t) return 0;
    size_t opts = (t->mss ? 4 : 0) + (t->wscale >= 0 ? 4 : 0);
    size_t hlen = 20 + opts;
    size_t n = ip_header(buf, cap, h, MND_IPPROTO_TCP, hlen + len);
    if (!n) return 0;
    uint8_t *p = buf + MND_ETH_HLEN + 20;
    wr16(p, t->sport);
    wr16(p + 2, t->dport);
    wr32(p + 4, t->seq);
    wr32(p + 8, t->ack);
    p[12] = (uint8_t)((hlen / 4) << 4);
    p[13] = t->flags;
    wr16(p + 14, t->window);
    wr16(p + 16, 0);
    wr16(p + 18, 0);
    uint8_t *o = p + 20;
    if (t->mss) {
        o[0] = 2;
        o[1] = 4;
        wr16(o + 2, t->mss);
        o += 4;
    }
    if (t->wscale >= 0) {
        o[0] = 1;
        o[1] = 3;
        o[2] = 3;
        o[3] = (uint8_t)(t->wscale > 14 ? 14 : t->wscale);
    }
    if (len) memcpy(p + hlen, payload, len);
    uint16_t seglen = (uint16_t)(hlen + len);
    wr16(p + 16, mnd_csum_finish(mnd_csum_add(mnd_csum_pseudo(h->src, h->dst, MND_IPPROTO_TCP, seglen), p, seglen)));
    return n;
}
