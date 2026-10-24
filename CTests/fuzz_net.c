/*
 * fuzz_net.c — fuzz targets for the network core.
 *
 *   fuzz_parsers: any bytes through every parser.
 *   fuzz_stack:   the input is a script of operations on a whole mnd_net
 *                 (VM frames, host events, time, firewall and port changes),
 *                 with invariants checked after every step.
 *
 * Built with -fsanitize=fuzzer (clang), LLVMFuzzerTestOneInput drives
 * fuzz_stack and fuzz_parsers. Otherwise main() is a deterministic
 * mutation driver: `fuzz_net [iterations] [seed]`, default a short run.
 */
#include "../Monad/Backend/net/mnd_net.h"
#include "../Monad/Backend/net/mnd_net_dhcp.h"
#include "../Monad/Backend/net/mnd_net_dns.h"
#include "../Monad/Backend/net/mnd_netd_ctl.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void fail(const char *what) {
    fprintf(stderr, "fuzz_net: invariant broken: %s\n", what);
    abort();
}

/* A standard query for example.com, type A. */
static const uint8_t EXAMPLE_QUERY[] = {0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7, 'e', 'x', 'a', 'm', 'p',
                                        'l', 'e', 3, 'c', 'o', 'm', 0, 0, 1, 0, 1};

/* ---- Parsers ------------------------------------------------------------------ */

/* Checksums left to the NIC: once finished, a segment is finished for good.
 * Also tried with the pseudo-header sum put where the checksum goes, as a
 * guest using offload would. */
static void fuzz_offload(uint8_t *frame, size_t n, const mnd_ip *ip) {
    uint8_t fin[MND_FRAME_MAX], again[MND_FRAME_MAX];
    size_t at = ip->proto == MND_IPPROTO_TCP ? 16 : ip->proto == MND_IPPROTO_UDP ? 6 : 0;
    for (int round = 0; round < 2; round++) {
        if (mnd_csum_offload_finish(frame, n, fin) && mnd_csum_offload_finish(fin, n, again))
            fail("a finished checksum is finished again");
        if (!at || ip->len < at + 2) return;
        size_t len = ip->len;
        if (ip->proto == MND_IPPROTO_UDP) len = (size_t)ip->payload[4] << 8 | ip->payload[5];
        uint16_t partial = (uint16_t)~mnd_csum_finish(mnd_csum_pseudo(ip->src, ip->dst, ip->proto, (uint16_t)len));
        uint8_t *c = frame + (ip->payload - frame) + at;
        c[0] = (uint8_t)(partial >> 8);
        c[1] = (uint8_t)partial;
    }
}

static void fuzz_parsers(const uint8_t *data, size_t size) {
    mnd_eth eth;
    mnd_arp arp;
    mnd_ip ip;
    mnd_icmp icmp;
    mnd_udp udp;
    mnd_tcp tcp;
    mnd_dhcp dhcp;
    mnd_dns_query q;
    (void)mnd_eth_parse(data, size, &eth);
    (void)mnd_arp_parse(data, size, &arp);
    if (mnd_ip_parse(data, size, &ip) == 0) {
        (void)mnd_icmp_parse(&ip, &icmp);
        (void)mnd_udp_parse(&ip, &udp);
        (void)mnd_tcp_parse(&ip, &tcp);
    }
    /* Parsers that skip checksums: build a valid IP packet around the bytes. */
    if (size >= 1) {
        uint8_t frame[MND_FRAME_MAX];
        mnd_ip_hdr_spec h = {.src = 1, .dst = 2, .ttl = 64};
        size_t n = mnd_build_ip(frame, sizeof frame, &h, data[0] % 3 == 0 ? MND_IPPROTO_TCP
                                                         : data[0] % 3 == 1 ? MND_IPPROTO_UDP
                                                                            : MND_IPPROTO_ICMP,
                                data + 1, size - 1 > MND_ETH_MTU - 20 ? MND_ETH_MTU - 20 : size - 1);
        if (n && mnd_ip_parse(frame + MND_ETH_HLEN, n - MND_ETH_HLEN, &ip) == 0) {
            (void)mnd_tcp_parse(&ip, &tcp);
            (void)mnd_udp_parse(&ip, &udp);
            (void)mnd_icmp_parse(&ip, &icmp);
            fuzz_offload(frame, n, &ip);
        }
    }
    (void)mnd_dhcp_parse(data, size, &dhcp);
    if (mnd_dns_parse_query(data, size, &q) == 0) {
        uint8_t copy[4096];
        size_t n = size < sizeof copy ? size : sizeof copy;
        memcpy(copy, data, n);
        (void)mnd_dns_truncate(copy, n, &q);
        (void)mnd_dns_servfail(copy, sizeof copy, data, &q);
    }
    /* Answers are checked against a query; use a fixed one. */
    if (mnd_dns_parse_query(EXAMPLE_QUERY, sizeof EXAMPLE_QUERY, &q) == 0)
        (void)mnd_dns_parse_answer(data, size, &q, NULL, NULL);

    /* Valid messages with a few bytes changed: reaches the deep paths. */
    static const uint8_t answer[] = {
        0, 1, 0x81, 0x80, 0, 1, 0, 3, 0, 0, 0, 0,                            /* header */
        7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0, 0, 1, 0, 1, /* question */
        0xc0, 12, 0, 5, 0, 1, 0, 0, 0, 60, 0, 6, 3, 'c', 'd', 'n', 0xc0, 20,  /* CNAME cdn.com */
        0xc0, 41, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 1, 2, 3, 4,                  /* cdn.com A */
        0xc0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 5, 6, 7, 8};                 /* example.com A */
    uint8_t m[sizeof answer];
    memcpy(m, answer, sizeof m);
    for (size_t i = 0; i + 1 < size && i < 16; i += 2) m[data[i] % sizeof m] = data[i + 1];
    if (mnd_dns_parse_query(EXAMPLE_QUERY, sizeof EXAMPLE_QUERY, &q) == 0) {
        (void)mnd_dns_parse_answer(m, sizeof m, &q, NULL, NULL);
        (void)mnd_dns_parse_answer(m, size % (sizeof m + 1), &q, NULL, NULL);
    }
    mnd_dhcp d = {.op = 1, .xid = 7, .chaddr = {{2, 0, 0, 0, 0, 1}}, .type = MND_DHCP_REQUEST,
                  .requested = MND_IP4(10, 0, 0, 2), .server_id = MND_IP4(10, 0, 0, 1)};
    strcpy(d.hostname, "box");
    uint8_t dm[400];
    size_t dn = mnd_dhcp_build(dm, sizeof dm, &d);
    for (size_t i = 0; i + 1 < size && i < 16; i += 2) dm[236 + data[i] % (dn - 236)] = data[i + 1];
    (void)mnd_dhcp_parse(dm, dn, &dhcp);
    (void)mnd_dhcp_parse(dm, 240 + size % (dn - 239), &dhcp);
}

/* ---- The control channel ------------------------------------------------------------ */

static void ignore_reply(void *ctx, const char *line) {
    (void)ctx;
    if (strlen(line) >= 256) fail("reply longer than its buffer");
}

/* Lines from the input, mostly command-shaped, into one long-lived session. */
static void fuzz_ctl(const uint8_t *data, size_t size) {
    static mnd_netd *d;
    static mnd_ctl *c;
    static const char *const verbs[] = {"network nat ", "network internal ", "port ", "unport ", "reserve 0 ",
                                        "nameservers ", "hostnets ", "firewall 0 ", "rule allow any ", "rule deny tcp ",
                                        "commit", "stats ", "ping", "session 0 allow any ", "forget ",
                                        "conns ", "conns 0 from=", "peers ", "peers 0 from=",
                                        "firewall 0 allowlist=0 lan=0 monitor=", ""};
    if (!d) d = mnd_netd_create();
    if (!c) {
        c = mnd_ctl_create(d, ignore_reply, NULL);
        mnd_ctl_command(c, "network nat 10.77.0.0/24", (char[256]){0}, 256);
    }
    char line[MND_CTL_MAX_LINE + 64];
    size_t i = 0;
    while (i < size) {
        const char *verb = verbs[data[i++] % (sizeof verbs / sizeof verbs[0])];
        size_t n = strlen(verb);
        memcpy(line, verb, n);
        while (i < size && data[i] != '\n' && n < sizeof line - 1) line[n++] = (char)data[i++];
        i++;
        line[n++] = '\n';
        if (mnd_ctl_feed(c, line, n, NULL, 0) != 0) {
            mnd_ctl_destroy(c); /* a violation ends the session */
            c = NULL;
            return;
        }
    }
}

/* ---- The whole stack ------------------------------------------------------------ */

#define VMS 4
#define SOCKS 1024

typedef struct {
    uint64_t now;
    mnd_net *net;
    int network;
    int ports[VMS];
    mnd_mac macs[VMS];
    mnd_mac gw_mac;
    /* Host sockets: flow/conn ids, open or not. */
    uint32_t tcp_ids[SOCKS];
    bool tcp_open[SOCKS];
    int ntcp;
    uint32_t udp_ids[SOCKS];
    bool udp_open[SOCKS];
    int nudp;
    uint32_t icmp_ids[SOCKS];
    bool icmp_open[SOCKS];
    int nicmp;
    uint32_t dns_ids[64];
    int ndns;
    /* The last TCP segment each VM got from the gateway, so scripts can
     * answer it the way a TCP stack would. */
    struct {
        bool valid;
        mnd_ip4 remote;
        uint16_t remote_port, vm_port;
        uint32_t next_seq, next_ack;
    } last_tcp[VMS];
    long delivered, opened_tcp, established;
    /* What the host's sockets return. */
    size_t write_room;
    int read_mode; /* 0 data once, 1 again, 2 eof, 3 error, 4 data always */
    const uint8_t *script;
    size_t script_len;
} world;

static world W;

static uint64_t h_now(void *ctx) { return ((world *)ctx)->now; }

static void h_send(void *ctx, int port, const uint8_t *frame, size_t len) {
    world *w = ctx;
    int vm = -1;
    for (int i = 0; i < VMS; i++)
        if (w->ports[i] == port) vm = i;
    if (vm < 0) fail("frame to a port that is not a VM");
    mnd_eth eth;
    if (mnd_eth_parse(frame, len, &eth) != 0) fail("frame to a VM does not parse");
    if (!mnd_mac_eq(eth.dst, w->macs[vm]) && !mnd_mac_is_multicast(eth.dst)) fail("frame to the wrong MAC");
    w->delivered++;
    if (mnd_mac_eq(eth.src, w->gw_mac)) {
        /* The gateway's own frames are always well formed. */
        mnd_ip ip;
        mnd_arp arp;
        if (eth.type == MND_ETHERTYPE_IPV4) {
            if (mnd_ip_parse(eth.payload, eth.len, &ip) != 0) fail("gateway IP packet does not parse");
            mnd_tcp t;
            mnd_udp u;
            mnd_icmp c;
            if (ip.proto == MND_IPPROTO_TCP && mnd_tcp_parse(&ip, &t) != 0) fail("gateway TCP segment");
            if (ip.proto == MND_IPPROTO_TCP && t.window > MND_NET_TCP_BUF) fail("window larger than the buffer");
            if (ip.proto == MND_IPPROTO_TCP && !(t.flags & MND_TCP_RST)) {
                if (t.flags & MND_TCP_SYN) w->established++;
                w->last_tcp[vm].valid = true;
                w->last_tcp[vm].remote = ip.src;
                w->last_tcp[vm].remote_port = t.sport;
                w->last_tcp[vm].vm_port = t.dport;
                w->last_tcp[vm].next_seq = t.ack;
                w->last_tcp[vm].next_ack =
                    t.seq + (uint32_t)t.len + ((t.flags & MND_TCP_SYN) ? 1 : 0) + ((t.flags & MND_TCP_FIN) ? 1 : 0);
            }
            if (ip.proto == MND_IPPROTO_UDP && mnd_udp_parse(&ip, &u) != 0) fail("gateway UDP datagram");
            if (ip.proto == MND_IPPROTO_ICMP && mnd_icmp_parse(&ip, &c) != 0) fail("gateway ICMP message");
        } else if (eth.type == MND_ETHERTYPE_ARP) {
            if (mnd_arp_parse(eth.payload, eth.len, &arp) != 0) fail("gateway ARP does not parse");
        } else {
            fail("gateway sent neither IPv4 nor ARP");
        }
    }
}

static void h_dns(void *ctx, uint32_t id, const uint8_t *q, size_t len) {
    world *w = ctx;
    mnd_dns_query parsed;
    if (mnd_dns_parse_query(q, len, &parsed) != 0) fail("an unchecked query reached the host");
    if (w->ndns < 64) w->dns_ids[w->ndns++] = id;
}

static int find_id(const uint32_t *ids, const bool *open, int n, uint32_t id) {
    for (int i = n - 1; i >= 0; i--)
        if (ids[i] == id && open[i]) return i;
    return -1;
}

static int h_udp_open(void *ctx, uint32_t flow, mnd_ip4 dst, uint16_t port) {
    world *w = ctx;
    (void)dst;
    (void)port;
    if (find_id(w->udp_ids, w->udp_open, w->nudp, flow) >= 0) fail("UDP flow opened twice");
    if (w->nudp >= SOCKS) return -1;
    w->udp_ids[w->nudp] = flow;
    w->udp_open[w->nudp++] = true;
    return 0;
}

static void h_udp_send(void *ctx, uint32_t flow, const uint8_t *data, size_t len) {
    world *w = ctx;
    (void)data;
    if (find_id(w->udp_ids, w->udp_open, w->nudp, flow) < 0) fail("send on a closed UDP flow");
    if (len > MND_ETH_MTU) fail("UDP datagram too large");
}

static void h_udp_close(void *ctx, uint32_t flow) {
    world *w = ctx;
    int i = find_id(w->udp_ids, w->udp_open, w->nudp, flow);
    if (i < 0) fail("close of a closed UDP flow");
    w->udp_open[i] = false;
}

static int h_icmp_open(void *ctx, uint32_t flow, mnd_ip4 dst) {
    world *w = ctx;
    (void)dst;
    if (find_id(w->icmp_ids, w->icmp_open, w->nicmp, flow) >= 0) fail("ICMP flow opened twice");
    if (w->nicmp >= SOCKS) return -1;
    w->icmp_ids[w->nicmp] = flow;
    w->icmp_open[w->nicmp++] = true;
    return 0;
}

static void h_icmp_send(void *ctx, uint32_t flow, uint16_t seq, const uint8_t *data, size_t len) {
    world *w = ctx;
    (void)seq;
    (void)data;
    (void)len;
    if (find_id(w->icmp_ids, w->icmp_open, w->nicmp, flow) < 0) fail("send on a closed ICMP flow");
}

static void h_icmp_close(void *ctx, uint32_t flow) {
    world *w = ctx;
    int i = find_id(w->icmp_ids, w->icmp_open, w->nicmp, flow);
    if (i < 0) fail("close of a closed ICMP flow");
    w->icmp_open[i] = false;
}

static int h_tcp_connect(void *ctx, uint32_t conn, mnd_ip4 dst, uint16_t port) {
    world *w = ctx;
    (void)dst;
    (void)port;
    if (find_id(w->tcp_ids, w->tcp_open, w->ntcp, conn) >= 0) fail("TCP connection opened twice");
    if (w->ntcp >= SOCKS) return -1;
    w->tcp_ids[w->ntcp] = conn;
    w->tcp_open[w->ntcp++] = true;
    w->opened_tcp++;
    return 0;
}

static ssize_t h_tcp_read(void *ctx, uint32_t conn, uint8_t *buf, size_t cap) {
    world *w = ctx;
    if (find_id(w->tcp_ids, w->tcp_open, w->ntcp, conn) < 0) fail("read on a closed TCP connection");
    if (cap == 0) fail("read of nothing");
    switch (w->read_mode) {
    case 0: {
        size_t n = cap < 3000 ? cap : 3000;
        memset(buf, 'd', n);
        w->read_mode = 1; /* one chunk per readiness */
        return (ssize_t)n;
    }
    case 1:
        return MND_NET_IO_AGAIN;
    case 2:
        return 0;
    case 4: {
        size_t n = cap < 3000 ? cap : 3000;
        memset(buf, 'D', n);
        return (ssize_t)n;
    }
    default:
        return MND_NET_IO_ERROR;
    }
}

static ssize_t h_tcp_write(void *ctx, uint32_t conn, const uint8_t *data, size_t len) {
    world *w = ctx;
    (void)data;
    if (find_id(w->tcp_ids, w->tcp_open, w->ntcp, conn) < 0) fail("write on a closed TCP connection");
    if (w->write_room == (size_t)-2) return MND_NET_IO_ERROR;
    size_t n = len < w->write_room ? len : w->write_room;
    return (ssize_t)n;
}

static void h_tcp_interest(void *ctx, uint32_t conn, bool r, bool wr) {
    world *w = ctx;
    (void)r;
    (void)wr;
    if (find_id(w->tcp_ids, w->tcp_open, w->ntcp, conn) < 0) fail("interest on a closed TCP connection");
}

static void h_tcp_shutdown(void *ctx, uint32_t conn) {
    world *w = ctx;
    if (find_id(w->tcp_ids, w->tcp_open, w->ntcp, conn) < 0) fail("shutdown of a closed TCP connection");
}

static void h_tcp_close(void *ctx, uint32_t conn, bool abort_) {
    world *w = ctx;
    (void)abort_;
    int i = find_id(w->tcp_ids, w->tcp_open, w->ntcp, conn);
    if (i < 0) fail("close of a closed TCP connection");
    w->tcp_open[i] = false;
}

/* Script reading: bytes run out as zeros. */
static uint8_t take8(void) {
    if (!W.script_len) return 0;
    W.script_len--;
    return *W.script++;
}

static uint16_t take16(void) { return (uint16_t)(take8() << 8 | take8()); }
static uint32_t take32(void) { return (uint32_t)take16() << 16 | take16(); }

static int pick_vm(void) { return take8() % VMS; }

static mnd_ip4 vm_ip(int vm) { return MND_IP4(10, 77, 0, (uint8_t)(10 + vm)); }

/* A destination: another VM, the gateway, the LAN or the internet. */
static mnd_ip4 pick_dst(void) {
    switch (take8() % 6) {
    case 0: return vm_ip(take8() % VMS);
    case 1: return MND_IP4(10, 77, 0, 1);
    case 2: return MND_IP4(192, 168, 1, take8());
    case 3: return MND_IP4(10, 77, 0, 255);
    default: return MND_IP4(93, 184, take8() % 4, take8() % 4);
    }
}

static mnd_mac pick_eth_dst(void) {
    switch (take8() % 4) {
    case 0: return MND_MAC_BROADCAST;
    case 1: return W.macs[take8() % VMS];
    default: return W.gw_mac;
    }
}

/* A standard query for example.com A, with a fuzzed id. */
static size_t td_like_query(uint8_t *p) {
    memcpy(p, EXAMPLE_QUERY, sizeof EXAMPLE_QUERY);
    p[0] = take8();
    p[1] = take8();
    return sizeof EXAMPLE_QUERY;
}

/* A well-formed answer to it: k A records (and maybe a CNAME) for the name. */
static size_t example_answer(uint8_t *p, size_t cap) {
    size_t at = sizeof EXAMPLE_QUERY;
    memcpy(p, EXAMPLE_QUERY, at);
    p[2] = 0x81;
    p[3] = 0x80;
    int k = take8() % 4 ? take8() % 8 : take8() % 121; /* sometimes more than one datagram holds */
    if (cap < sizeof EXAMPLE_QUERY + (size_t)k * 16) return 0;
    for (int i = 0; i < k; i++) {
        mnd_ip4 ip = pick_dst();
        const uint8_t rr[] = {0xc0, 12, 0, 1, 0, 1, 0, 0, take8(), take8(), 0, 4,
                              (uint8_t)(ip >> 24), (uint8_t)(ip >> 16), (uint8_t)(ip >> 8), (uint8_t)ip};
        memcpy(p + at, rr, sizeof rr);
        at += sizeof rr;
    }
    p[7] = (uint8_t)k;
    return at;
}

static void vm_frame(int vm, const uint8_t *frame, size_t len) {
    if (W.ports[vm] >= 0) mnd_net_input(W.net, W.ports[vm], frame, len);
}

static void op_raw(void) {
    int vm = pick_vm();
    uint8_t frame[MND_FRAME_MAX + 16];
    size_t len = take16() % sizeof frame;
    for (size_t i = 0; i < len; i++) frame[i] = take8();
    /* Mostly a valid Ethernet header from this VM, so deeper code runs. */
    if (len >= 14 && take8() % 4) {
        mnd_mac dst = pick_eth_dst();
        memcpy(frame, dst.b, 6);
        memcpy(frame + 6, W.macs[vm].b, 6);
    }
    vm_frame(vm, frame, len);
}

static void op_ip(void) {
    int vm = pick_vm();
    uint8_t frame[MND_FRAME_MAX], payload[MND_ETH_MTU];
    mnd_ip_hdr_spec h = {.eth_dst = pick_eth_dst(), .eth_src = W.macs[vm], .ttl = 64};
    h.src = take8() % 8 ? vm_ip(vm) : pick_dst();
    h.dst = pick_dst();
    /* Mostly small, sometimes a full segment (bytes beyond the script are zeros). */
    size_t len = take8() % 4 ? take16() % 64 : take16() % (MND_NET_TCP_MSS + 1);
    for (size_t i = 0; i < len; i++) payload[i] = take8();
    uint8_t kind = take8() % 6;
    size_t n = 0;
    if (kind == 5 && W.last_tcp[vm].valid) {
        /* Answer the last segment like a TCP stack: ACK, data, FIN or RST. */
        h.eth_dst = W.gw_mac;
        h.src = vm_ip(vm);
        h.dst = W.last_tcp[vm].remote;
        static const uint8_t flags[] = {MND_TCP_ACK, MND_TCP_ACK | MND_TCP_PSH, MND_TCP_ACK | MND_TCP_FIN,
                                        MND_TCP_RST, MND_TCP_ACK, MND_TCP_ACK | MND_TCP_PSH};
        uint8_t f = flags[take8() % sizeof flags];
        mnd_tcp_spec t = {.sport = W.last_tcp[vm].vm_port, .dport = W.last_tcp[vm].remote_port,
                          .seq = W.last_tcp[vm].next_seq + (take8() % 8 == 0 ? take16() : 0),
                          .ack = W.last_tcp[vm].next_ack, .flags = f,
                          .window = take8() % 8 ? 65535 : take16(), .wscale = -1};
        if (!(f & MND_TCP_PSH)) len = take8() % 4 ? 0 : len;
        n = mnd_build_tcp(frame, sizeof frame, &h, &t, payload, len);
        W.last_tcp[vm].next_seq += (uint32_t)len + ((f & MND_TCP_FIN) ? 1 : 0);
    } else if (kind == 0 || kind == 5) {
        /* Mostly a clean SYN to the internet. */
        if (take8() % 2) {
            h.eth_dst = W.gw_mac;
            h.src = vm_ip(vm);
            h.dst = MND_IP4(93, 184, 0, take8() % 4);
        }
        mnd_tcp_spec t = {.sport = (uint16_t)(40000 + take8() % 4), .dport = (uint16_t)(take8() % 2 ? 80 : 53),
                          .seq = take8() % 2 ? 1000u + take16() : take32(), .ack = take32(),
                          .flags = take8() % 2 ? MND_TCP_SYN : take8() & 0x3f, .window = take16(),
                          .mss = take8() % 2 ? take16() : 0,
                          .wscale = -1};
        n = mnd_build_tcp(frame, sizeof frame, &h, &t, payload, len);
    } else if (kind == 1) {
        uint16_t dport = take8() % 3 == 0 ? 53 : take8() % 2 ? 67 : take16();
        uint16_t sport = dport == 67 ? 68 : (uint16_t)(5000 + take8() % 4);
        if (dport == 53 && take8() % 4) {
            /* A real question to the gateway's resolver. */
            len = td_like_query(payload);
            h.eth_dst = W.gw_mac;
            h.src = vm_ip(vm);
            h.dst = MND_IP4(10, 77, 0, 1);
        }
        n = mnd_build_udp(frame, sizeof frame, &h, sport, dport, payload, len);
    } else if (kind == 2) {
        n = mnd_build_icmp(frame, sizeof frame, &h, take8() % 2 ? 8 : take8(), 0, take16() % 4, take16(), payload,
                           len);
    } else if (kind == 3) {
        mnd_dhcp m = {.op = 1, .xid = take32(), .flags = take16(), .ciaddr = take8() % 2 ? vm_ip(vm) : 0,
                      .chaddr = take8() % 8 ? W.macs[vm] : W.macs[take8() % VMS], .type = (uint8_t)(1 + take8() % 8),
                      .requested = take8() % 2 ? vm_ip(take8() % VMS) : 0,
                      .server_id = take8() % 2 ? MND_IP4(10, 77, 0, 1) : 0};
        uint8_t dhcp[600];
        size_t dl = mnd_dhcp_build(dhcp, sizeof dhcp, &m);
        h.src = take8() % 2 ? 0 : h.src;
        h.dst = MND_IP4(255, 255, 255, 255);
        n = mnd_build_udp(frame, sizeof frame, &h, 68, 67, dhcp, dl);
    } else {
        n = mnd_build_arp(frame, sizeof frame, (uint16_t)(1 + take8() % 2), pick_eth_dst(), W.macs[vm],
                          take8() % 2 ? vm_ip(vm) : pick_dst(), W.macs[take8() % VMS], pick_dst());
    }
    if (n) vm_frame(vm, frame, n);
}

/* A VM sends a run of full, in-order segments on its last connection. */
static void op_burst(void) {
    int vm = pick_vm();
    if (!W.last_tcp[vm].valid) return;
    static uint8_t payload[MND_NET_TCP_MSS];
    memset(payload, 'v', sizeof payload);
    int count = 1 + take8() % 40;
    for (int i = 0; i < count && W.last_tcp[vm].valid; i++) {
        uint8_t frame[MND_FRAME_MAX];
        mnd_ip_hdr_spec h = {.eth_dst = W.gw_mac, .eth_src = W.macs[vm], .src = vm_ip(vm),
                             .dst = W.last_tcp[vm].remote, .ttl = 64};
        mnd_tcp_spec t = {.sport = W.last_tcp[vm].vm_port, .dport = W.last_tcp[vm].remote_port,
                          .seq = W.last_tcp[vm].next_seq, .ack = W.last_tcp[vm].next_ack,
                          .flags = MND_TCP_ACK | MND_TCP_PSH, .window = 65535, .wscale = -1};
        size_t n = mnd_build_tcp(frame, sizeof frame, &h, &t, payload, sizeof payload);
        W.last_tcp[vm].next_seq += sizeof payload; /* as if all were taken */
        vm_frame(vm, frame, n);
    }
}

static uint32_t pick_id(const uint32_t *ids, int n) {
    if (!n || take8() % 8 == 0) return take32(); /* anything, stale or unknown */
    return ids[take16() % n];
}

static void op_host(void) {
    uint8_t buf[2048];
    switch (take8() % 7) {
    case 0:
        mnd_net_tcp_connected(W.net, pick_id(W.tcp_ids, W.ntcp), take8() % 4 != 0);
        break;
    case 1:
        W.read_mode = take8() % 5;
        mnd_net_tcp_readable(W.net, pick_id(W.tcp_ids, W.ntcp));
        break;
    case 2: {
        uint8_t r = take8() % 4;
        W.write_room = r == 0 ? 0 : r == 1 ? (size_t)take16() : r == 2 ? (size_t)-1 : (size_t)-2;
        mnd_net_tcp_writable(W.net, pick_id(W.tcp_ids, W.ntcp));
        break;
    }
    case 3: {
        size_t len = take16() % sizeof buf;
        for (size_t i = 0; i < len; i++) buf[i] = take8();
        uint32_t id = pick_id(W.udp_ids, W.nudp);
        long before = W.delivered;
        mnd_net_udp_input(W.net, id, buf, len);
        if (find_id(W.udp_ids, W.udp_open, W.nudp, id) < 0 && W.delivered != before)
            fail("a closed or unknown UDP flow delivered a datagram");
        break;
    }
    case 4: {
        size_t len = take16() % 256;
        for (size_t i = 0; i < len; i++) buf[i] = take8();
        uint32_t id = pick_id(W.icmp_ids, W.nicmp);
        long before = W.delivered;
        mnd_net_icmp_input(W.net, id, take16(), buf, len);
        if (find_id(W.icmp_ids, W.icmp_open, W.nicmp, id) < 0 && W.delivered != before)
            fail("a closed or unknown ICMP flow delivered a reply");
        break;
    }
    case 5: {
        size_t len;
        if (take8() % 2) {
            len = example_answer(buf, sizeof buf); /* passes the checks: names get remembered */
        } else {
            len = take16() % sizeof buf;
            for (size_t i = 0; i < len; i++) buf[i] = take8();
        }
        mnd_net_dns_answer(W.net, pick_id(W.dns_ids, W.ndns), buf, len);
        break;
    }
    default:
        break;
    }
}

static void op_time(void) {
    static const uint64_t steps[] = {1, 300, 1000, 5001, 30000, 60000, 180000, 3600000};
    W.now += steps[take8() % 8];
    uint64_t next = mnd_net_poll(W.net);
    if (next != UINT64_MAX && next <= W.now) fail("poll left work that is already due");
    if (mnd_net_deadline(W.net) != next) fail("deadline disagrees with poll");
}

/* A monitor-mode question: only about a VM that is there, and a protocol
 * the firewall knows. */
static void h_ask(void *ctx, int port, uint8_t proto, mnd_ip4 dst, uint16_t dport) {
    (void)ctx;
    (void)dst;
    bool known = false;
    for (int i = 0; i < VMS; i++) known |= W.ports[i] == port;
    if (!known) fail("asked about a port that is gone");
    if (proto != MND_IPPROTO_TCP && proto != MND_IPPROTO_UDP && proto != MND_IPPROTO_ICMP) fail("ask: protocol");
    if (proto == MND_IPPROTO_ICMP && dport) fail("ask: ping with a port");
}

static void op_config(void) {
    switch (take8() % 6) {
    case 0: {
        mnd_fw_config cfg = {.allowlist = take8() % 2, .allow_lan = take8() % 2, .monitor = take8() % 2,
                             .nrules = take8() % 4};
        for (int i = 0; i < cfg.nrules; i++) {
            mnd_fw_rule *r = &cfg.rules[i];
            r->action = (mnd_fw_action)(1 + take8() % 2);
            r->proto = (uint8_t)(take8() % 2 ? 0 : MND_IPPROTO_TCP);
            if (take8() % 3 == 0) {
                strcpy(r->host, take8() % 2 ? "*.example.com" : "example.com");
            } else {
                r->prefix = (uint8_t)(take8() % 33);
                r->addr = pick_dst() & (r->prefix ? ~((1u << (32 - r->prefix)) - 1) : 0);
            }
        }
        int vm = pick_vm();
        if (W.ports[vm] >= 0) (void)mnd_net_set_port_firewall(W.net, W.ports[vm], &cfg);
        break;
    }
    case 1: {
        int vm = pick_vm();
        if (W.ports[vm] >= 0) {
            mnd_net_remove_port(W.net, W.ports[vm]);
            W.ports[vm] = -1;
        } else {
            W.ports[vm] = mnd_net_add_port(W.net, W.network, W.macs[vm]);
        }
        break;
    }
    case 4: { /* an answer */
        int vm = pick_vm();
        mnd_fw_rule r = {.action = (mnd_fw_action)(1 + take8() % 2), .proto = (uint8_t)(take8() % 2 ? 0 : MND_IPPROTO_TCP)};
        if (take8() % 2) strcpy(r.host, "example.com");
        else r.addr = pick_dst(), r.prefix = 32;
        if (W.ports[vm] >= 0) (void)mnd_net_add_session_rule(W.net, W.ports[vm], &r);
        break;
    }
    case 5: {
        int vm = pick_vm();
        if (W.ports[vm] >= 0) mnd_net_clear_session(W.net, W.ports[vm]);
        break;
    }
    case 2: {
        mnd_ip4 a[] = {MND_IP4(93, 184, 0, 0)};
        uint8_t p[] = {16};
        (void)mnd_net_set_host_networks(W.net, a, p, take8() % 2);
        break;
    }
    default:
        (void)mnd_net_reserve(W.net, W.network, W.macs[pick_vm()], vm_ip(pick_vm()));
        break;
    }
}

static void check_limits(void) {
    int tcp = 0, udp = 0, icmp = 0;
    for (int i = 0; i < W.ntcp; i++) tcp += W.tcp_open[i];
    for (int i = 0; i < W.nudp; i++) udp += W.udp_open[i];
    for (int i = 0; i < W.nicmp; i++) icmp += W.icmp_open[i];
    if (tcp > MND_NET_MAX_TCP_CONNS) fail("too many TCP connections");
    if (udp + icmp > MND_NET_MAX_UDP_FLOWS) fail("too many datagram flows");
}

/* The connection log: bounded per VM, never more open than is open, and
 * every entry one token of the conns reply. */
static void check_log(void) {
    static mnd_net_conn all[MND_NET_MAX_CONN_LOG_PER_PORT + 1];
    int open = 0;
    for (int i = 0; i < W.ntcp; i++) open += W.tcp_open[i];
    for (int i = 0; i < W.nudp; i++) open += W.udp_open[i];
    for (int i = 0; i < W.nicmp; i++) open += W.icmp_open[i];
    long active = 0;
    for (int v = 0; v < VMS; v++) {
        int n = mnd_net_conns(W.net, W.ports[v], all, MND_NET_MAX_CONN_LOG_PER_PORT + 1);
        if (W.ports[v] < 0) {
            if (n != -1) fail("a log for a VM that left");
            continue;
        }
        if (n < 0 || n > MND_NET_MAX_CONN_LOG_PER_PORT) fail("connection log over its bound");
        for (int i = 0; i < n; i++) {
            active += all[i].active;
            if (i && all[i].last_ms > all[i - 1].last_ms) fail("connection log out of order");
            char token[512];
            if (mnd_netd_format_conn(token, sizeof token, &all[i], "x.example", W.now) < 0) fail("entry too long");
            if (strpbrk(token, " \n")) fail("entry is not one token");
        }
    }
    if (active > open) fail("connection log counts more open than is open");
}

/* VM-to-VM traffic: only VMs on the network, never a VM with itself, at
 * most MND_NET_MAX_PEERS per sender, in order, every entry one token. */
static void check_peers(void) {
    static mnd_net_peer all[MND_NET_MAX_PORTS * MND_NET_MAX_PEERS + 1];
    int n = mnd_net_peers(W.net, W.network, all, (int)(sizeof all / sizeof all[0]));
    if (n < 0) fail("no peers for the network");
    int per_sender = 0;
    for (int i = 0; i < n; i++) {
        bool from_known = false, to_known = false;
        for (int v = 0; v < VMS; v++) {
            from_known |= W.ports[v] >= 0 && W.ports[v] == all[i].from;
            to_known |= W.ports[v] >= 0 && W.ports[v] == all[i].to;
        }
        if (!from_known || !to_known) fail("a peer entry for a VM not on the network");
        if (all[i].from == all[i].to) fail("a VM as its own peer");
        if (!all[i].frames || all[i].bytes < all[i].frames * 14) fail("peer counts smaller than the frames");
        const mnd_net_peer *b = i ? &all[i - 1] : NULL;
        if (b && (all[i].from < b->from || (all[i].from == b->from && all[i].to <= b->to))) fail("peers out of order");
        per_sender = b && all[i].from == b->from ? per_sender + 1 : 1;
        if (per_sender > MND_NET_MAX_PEERS) fail("more peers than a VM keeps");
        char token[96];
        if (mnd_netd_format_peer(token, sizeof token, &all[i], W.now) < 0) fail("peer entry too long");
        if (strpbrk(token, " \n")) fail("peer entry is not one token");
    }
}

static void fuzz_stack(const uint8_t *data, size_t size) {
    memset(&W, 0, sizeof W);
    W.now = 1000;
    /* Often a socket that takes nothing: buffers fill, windows close. */
    W.write_room = size && data[0] % 3 == 0 ? 0 : (size_t)-1;
    W.script = data;
    W.script_len = size;
    mnd_net_host host = {.ctx = &W, .now_ms = h_now, .send_frame = h_send, .dns_query = h_dns,
                         .udp_open = h_udp_open, .udp_send = h_udp_send, .udp_close = h_udp_close,
                         .icmp_open = h_icmp_open, .icmp_send = h_icmp_send, .icmp_close = h_icmp_close,
                         .tcp_connect = h_tcp_connect, .tcp_read = h_tcp_read, .tcp_write = h_tcp_write,
                         .tcp_interest = h_tcp_interest, .tcp_shutdown = h_tcp_shutdown,
                         .tcp_close = h_tcp_close, .ask = h_ask};
    W.net = mnd_net_create(&host);
    if (!W.net) fail("create");
    mnd_net_config cfg = {.kind = MND_NET_NAT, .subnet = MND_IP4(10, 77, 0, 0), .prefix = 24, .lease_secs = 600};
    W.network = mnd_net_add_network(W.net, &cfg);
    mnd_net_gateway(W.net, W.network, &W.gw_mac, NULL);
    for (int i = 0; i < VMS; i++) {
        W.macs[i] = (mnd_mac){{0x02, 0x4d, 0x4f, 0x4e, 0x00, (uint8_t)(i + 1)}};
        W.ports[i] = mnd_net_add_port(W.net, W.network, W.macs[i]);
    }
    for (int steps = 0; W.script_len && steps < 4096; steps++) {
        switch (take8() % 9) {
        case 0: op_raw(); break;
        case 1:
        case 2:
        case 3: op_ip(); break;
        case 4:
        case 5: op_host(); break;
        case 6: op_time(); break;
        case 7: op_burst(); break;
        default: op_config(); break;
        }
        check_limits();
        if (steps % 64 == 63) {
            check_log();
            check_peers();
        }
    }
    check_log();
    check_peers();
    mnd_net_destroy(W.net);
    for (int i = 0; i < W.ntcp; i++)
        if (W.tcp_open[i]) fail("TCP socket left open after destroy");
    for (int i = 0; i < W.nudp; i++)
        if (W.udp_open[i]) fail("UDP socket left open after destroy");
    for (int i = 0; i < W.nicmp; i++)
        if (W.icmp_open[i]) fail("ICMP socket left open after destroy");
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size && data[0] % 4 == 1) fuzz_parsers(data + 1, size - 1);
    else if (size && data[0] % 4 == 2) fuzz_ctl(data + 1, size - 1);
    else fuzz_stack(size ? data + 1 : data, size ? size - 1 : 0);
    return 0;
}

#ifndef MND_LIBFUZZER
/* ---- The built-in driver: random scripts and mutated frames ------------------------- */

static uint64_t rng_state;

static uint32_t rnd(void) {
    rng_state = rng_state * 6364136223846793005ull + 1442695040888963407ull;
    return (uint32_t)(rng_state >> 33);
}

/* A decimal number, or `fallback` (make passes the build directory). */
static long number(const char *s, long fallback) {
    if (!s || !*s) return fallback;
    char *end = NULL;
    long v = strtol(s, &end, 10);
    return *end ? fallback : v;
}

int main(int argc, char **argv) {
    long iterations = number(argc > 1 ? argv[1] : getenv("FUZZ_ITERS"), number(getenv("FUZZ_ITERS"), 3000));
    rng_state = (uint64_t)number(argc > 2 ? argv[2] : getenv("FUZZ_SEED"), 0x4d4f4e4144);
    static uint8_t input[65536];
    long total_frames = 0, total_connects = 0, total_handshakes = 0;
    for (long it = 0; it < iterations; it++) {
        size_t len = rnd() % 2 ? 16 + rnd() % 2048 : 16 + rnd() % 16384;
        for (size_t i = 0; i < len; i++) input[i] = (uint8_t)rnd();
        /* Scripts lean on well-formed operations; parsers get raw bytes. */
        input[0] = (uint8_t)(it % 4 == 0 ? 1 : it % 4 == 1 ? 2 : 0);
        LLVMFuzzerTestOneInput(input, len);
        total_frames += W.delivered;
        total_connects += W.opened_tcp;
        total_handshakes += W.established;
    }
    fprintf(stderr, "fuzz_net: %ld inputs, no invariant broken\n", iterations);
    fprintf(stderr, "fuzz_net: reach: %ld frames to VMs, %ld TCP connects, %ld handshakes answered\n", total_frames,
            total_connects, total_handshakes);
    return 0;
}
#endif
