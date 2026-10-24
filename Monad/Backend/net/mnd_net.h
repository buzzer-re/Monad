/*
 * mnd_net.h — Monad's user-space network: virtual switches between VM NICs
 * and each network's gateway (added in later layers: ARP, DHCP, DNS, NAT).
 *
 * The core never touches the operating system directly: time and frame
 * delivery go through mnd_net_host, so it runs the same on a real event
 * loop and in tests with an in-memory host and a manual clock.
 *
 * Isolation rules of the switch:
 *   - a port is bound to its VM's MAC address; frames with any other source
 *     are dropped (no spoofing, and a guest cannot fill any table);
 *   - frames never cross networks;
 *   - unknown unicast destinations are dropped, not flooded;
 *   - broadcast and multicast reach every other port of the same network.
 *
 * Every kind but MND_NET_NONE also has a gateway at the subnet's first
 * address, which answers ARP, ICMP echo and DHCP. On those networks:
 *   - a port sends from its own IPv4 address only (its lease), or from
 *     0.0.0.0 for DHCP. A port without a lease may take one free address
 *     of the subnet (after netd restarts, or a static address), never one
 *     leased or reserved for another VM: one address per port;
 *   - DHCP is answered by the gateway alone: client messages never reach
 *     other VMs, DHCP server messages from VMs are dropped, and a client may
 *     only ask for its own MAC;
 *   - only ARP and IPv4 are carried (IPv6 is dropped for now).
 *
 * NAT gateways carry UDP to the outside through host sockets (one socket per
 * flow, connected, so only the destination can answer), and TCP by ending
 * the VM's connection here and splicing it to a host socket: the VM gets
 * its SYN-ACK once the destination accepted, or a reset. Each direction
 * has a fixed buffer; the window the VM sees is the room left, and the
 * host socket is read only when there is room towards the VM. Destinations that
 * are never routed: 0/8, loopback, link-local, multicast, reserved,
 * broadcast, and the network's own subnet.
 *
 * Host-only and NAT gateways also forward DNS (UDP port 53) to the Mac
 * through mnd_net_host.dns_query, and remember which names resolved to
 * which addresses (for hostname firewall rules). Only answers that came
 * through the gateway are remembered, so a VM cannot plant a pair.
 * Not thread-safe: drive one mnd_net from one thread.
 */
#ifndef MND_NET_H
#define MND_NET_H

#include "mnd_net_dns.h"
#include "mnd_net_frame.h"

#include <sys/types.h>

#define MND_NET_MAX_NETWORKS 32
#define MND_NET_MAX_PORTS 64 /* per network */
#define MND_NET_MAX_LEASES 256 /* per network; also bounds the dynamic range */
#define MND_NET_MAX_RESERVATIONS 64 /* per network */
#define MND_NET_DEFAULT_LEASE_SECS 3600
#define MND_NET_MAX_DNS_PENDING 256         /* queries waiting for the Mac */
#define MND_NET_MAX_DNS_PENDING_PER_PORT 32
#define MND_NET_DNS_TIMEOUT_MS 5000
#define MND_NET_MAX_DNS_NAMES 1024          /* hostname ↔ address pairs remembered */
#define MND_NET_DNS_MIN_TTL 60              /* seconds a pair is kept at least… */
#define MND_NET_DNS_MAX_TTL 86400           /* …and at most */
#define MND_NET_MAX_UDP_FLOWS 1024
#define MND_NET_MAX_UDP_FLOWS_PER_PORT 256
#define MND_NET_UDP_TIMEOUT_MS 30000          /* idle, never answered */
#define MND_NET_UDP_REPLIED_TIMEOUT_MS 180000 /* idle, answered at least once */
#define MND_NET_MAX_TCP_CONNS 512
#define MND_NET_MAX_TCP_CONNS_PER_PORT 256
#define MND_NET_TCP_BUF 32768                 /* per direction, per connection */
#define MND_NET_TCP_MSS 1460
#define MND_NET_TCP_CONNECT_TIMEOUT_MS 60000
#define MND_NET_TCP_RTO_MS 300                /* first retransmission… */
#define MND_NET_TCP_RTO_MAX_MS 30000          /* …doubling up to this */
#define MND_NET_TCP_MAX_RETRIES 10            /* then the connection is reset */
#define MND_NET_MAX_FW_RULES 64
/* Monitor mode: questions waiting for an answer (each VM, all VMs), how long
 * one waits before it may be asked again, and the answers kept per VM. */
#define MND_NET_MAX_ASKS_PER_PORT 16
#define MND_NET_MAX_ASKS 256
#define MND_NET_ASK_TTL_MS 60000
#define MND_NET_MAX_SESSION_RULES 64
#define MND_NET_MAX_HOST_NETWORKS 16

typedef struct mnd_net mnd_net;

typedef struct {
    void *ctx;
    /* Monotonic milliseconds. */
    uint64_t (*now_ms)(void *ctx);
    /* Deliver a frame to a VM's NIC. The frame is only valid during the call. */
    void (*send_frame)(void *ctx, int port, const uint8_t *frame, size_t len);
    /* Optional: resolve a DNS query (a complete, checked message) through
     * the Mac and answer with mnd_net_dns_answer(id), now or later, or not
     * at all (the query times out). NULL: queries are answered SERVFAIL. */
    void (*dns_query)(void *ctx, uint32_t id, const uint8_t *query, size_t len);
    /* Optional, NAT networks: a UDP flow from a VM. Open a socket connected
     * to dst:port for `flow` (0, or -1 to refuse), send the VM's datagrams
     * on it, close it when told. What the socket receives goes to
     * mnd_net_udp_input(flow). NULL udp_open: no UDP leaves. */
    int (*udp_open)(void *ctx, uint32_t flow, mnd_ip4 dst, uint16_t port);
    void (*udp_send)(void *ctx, uint32_t flow, const uint8_t *data, size_t len);
    void (*udp_close)(void *ctx, uint32_t flow);
    /* Optional, NAT networks: ICMP echo (ping) from a VM, one flow per VM
     * address, destination and echo identifier, sharing the UDP flows'
     * limits and timeouts. The host sends echo requests to dst with its own
     * identifier and reports replies with mnd_net_icmp_input(flow). NULL
     * icmp_open: pings do not leave. */
    int (*icmp_open)(void *ctx, uint32_t flow, mnd_ip4 dst);
    void (*icmp_send)(void *ctx, uint32_t flow, uint16_t seq, const uint8_t *data, size_t len);
    void (*icmp_close)(void *ctx, uint32_t flow);
    /* Optional, NAT networks: TCP from a VM, terminated here and spliced to
     * a host socket. tcp_connect starts a non-blocking connect for `conn`
     * (0, or -1 to refuse) and the host reports the outcome with
     * mnd_net_tcp_connected. tcp_read returns bytes read, 0 at end of
     * stream, MND_NET_IO_AGAIN or MND_NET_IO_ERROR; tcp_write returns bytes
     * accepted (0 when the socket is full) or MND_NET_IO_ERROR.
     * tcp_interest says which readiness events the core wants; the host
     * reports them with mnd_net_tcp_readable / mnd_net_tcp_writable and
     * sends nothing else, so an idle connection costs no wakeups.
     * tcp_shutdown ends the stream towards the destination; tcp_close
     * releases the socket (abort: reset rather than an orderly close).
     * NULL tcp_connect: no TCP leaves. */
    int (*tcp_connect)(void *ctx, uint32_t conn, mnd_ip4 dst, uint16_t port);
    ssize_t (*tcp_read)(void *ctx, uint32_t conn, uint8_t *buf, size_t cap);
    ssize_t (*tcp_write)(void *ctx, uint32_t conn, const uint8_t *data, size_t len);
    void (*tcp_interest)(void *ctx, uint32_t conn, bool read, bool write);
    void (*tcp_shutdown)(void *ctx, uint32_t conn);
    void (*tcp_close)(void *ctx, uint32_t conn, bool abort);
    /* Optional, monitor mode: a VM wants to reach dst (dport 0 for ping)
     * and nothing decides. Asked once while the question is pending; the
     * answer comes back with mnd_net_add_session_rule. NULL: refused. */
    void (*ask)(void *ctx, int port, uint8_t proto, mnd_ip4 dst, uint16_t dport);
    /* Optional, monitor mode: a VM looks up `name` (lowercase, plain) and
     * no rule decides. Asked once while pending; the answer is a session
     * rule by name. NULL: refused. */
    void (*ask_lookup)(void *ctx, int port, const char *name);
} mnd_net_host;

#define MND_NET_IO_AGAIN (-1)
#define MND_NET_IO_ERROR (-2)

typedef enum {
    MND_NET_NONE = 0,  /* a switch without a gateway */
    MND_NET_INTERNAL,  /* VMs and a gateway for DHCP (no router, no DNS); nothing leaves */
    MND_NET_HOST_ONLY, /* VMs and the gateway as router and DNS; nothing leaves */
    MND_NET_NAT,       /* internet through the Mac, behind the firewall */
} mnd_net_kind;

typedef struct {
    mnd_net_kind kind;
    mnd_ip4 subnet; /* e.g. 10.77.0.0 */
    uint8_t prefix; /* 8 to 30, e.g. 24 */
    uint32_t lease_secs; /* DHCP lease time; 0 means MND_NET_DEFAULT_LEASE_SECS */
    /* VMs reach the gateway only, never each other (unicast, ARP, broadcast). */
    bool isolated;
    /* Host-only networks: the gateway forwards lookups to the Mac too
     * (otherwise REFUSED: nothing leaves). NAT networks always do. */
    bool host_only_dns;
} mnd_net_config;

/* Firewall: each VM's own, set on its port (it decides only on NAT networks,
 * the only ones that route out). Rules are checked in order, the first match
 * decides. Without a match: the Mac and its LAN (private ranges, and the
 * networks set with mnd_net_set_host_networks) follow allow_lan, anything
 * else is allowed unless allowlist is set. Denied TCP gets a reset, denied
 * UDP and ping an ICMP "administratively prohibited". */
typedef enum { MND_FW_ALLOW = 1, MND_FW_DENY = 2 } mnd_fw_action;

typedef struct {
    mnd_fw_action action;
    uint8_t proto;   /* 0 any, or MND_IPPROTO_TCP / _UDP / _ICMP */
    /* What it matches: a hostname pattern when set ("example.com" and its
     * subdomains, "*.example.com" its subdomains only; names learned from
     * DNS answers through the gateway), else addr/prefix (prefix 0: any
     * address). */
    char host[MND_DNS_NAME_MAX + 1];
    mnd_ip4 addr;
    uint8_t prefix;
    uint16_t port_min, port_max; /* 0, 0: any; a rule with ports never matches ICMP */
} mnd_fw_rule;

/* Monitor mode: what neither the rules nor the session's answers decide
 * (and is not the LAN with allow_lan) is asked about through the host's
 * `ask`, instead of falling back; its packets are dropped quietly meanwhile
 * so the VM retries. More questions than fit are refused. */
typedef struct {
    bool allowlist; /* no match: deny */
    bool allow_lan; /* no match on the Mac or its LAN: allow */
    bool monitor;   /* no match: ask */
    int nrules;
    mnd_fw_rule rules[MND_NET_MAX_FW_RULES];
} mnd_fw_config;

typedef struct {
    uint64_t rx, tx;           /* frames from / to the VM */
    uint64_t dropped_spoofed;  /* source MAC not the port's */
    uint64_t dropped_malformed;
    uint64_t dropped_unknown;  /* unicast to no one on this network */
    uint64_t dropped_policy;   /* not allowed here: IPv6, another VM's IP, DHCP server messages… */
    uint64_t dropped_firewall; /* denied by the VM's firewall */
} mnd_net_port_stats;

mnd_net *mnd_net_create(const mnd_net_host *host);
void mnd_net_destroy(mnd_net *net);

/* Returns a network id >= 0, or -1 (invalid config, or too many). */
int mnd_net_add_network(mnd_net *net, const mnd_net_config *cfg);

/* The gateway's MAC and IP. Returns -1 for an unknown network or one of
 * kind MND_NET_NONE. */
int mnd_net_gateway(const mnd_net *net, int network, mnd_mac *mac, mnd_ip4 *ip);

/* A fixed address for a MAC: DHCP always offers it to that MAC and never
 * to anyone else. The address must be a host of the subnet other than the
 * gateway. Returns 0, or -1 (invalid, taken, or too many). */
int mnd_net_reserve(mnd_net *net, int network, mnd_mac mac, mnd_ip4 ip);

/* Replaces a port's firewall (a new port starts with the defaults: LAN
 * denied, the rest allowed; the firewall goes with the port). Open flows and
 * connections it now denies are closed (TCP with a reset). Returns 0, or -1
 * (unknown port, or an invalid rule: bad pattern, prefix, host bits set,
 * ports). */
int mnd_net_set_port_firewall(mnd_net *net, int port, const mnd_fw_config *cfg);

/* An answer in monitor mode: a rule for this VM until the session is
 * cleared, checked after its firewall's rules (the newest answer first).
 * Questions it answers are dropped. Returns 0, or -1 (unknown port, invalid
 * rule). Past MND_NET_MAX_SESSION_RULES the oldest answer goes. */
int mnd_net_add_session_rule(mnd_net *net, int port, const mnd_fw_rule *rule);
/* Forgets the VM's answers and questions (it stopped). */
void mnd_net_clear_session(mnd_net *net, int port);

/* The Mac's own networks (address/prefix), treated as LAN by every
 * firewall, re-checked at once. Returns 0, or -1 (too many or invalid). */
int mnd_net_set_host_networks(mnd_net *net, const mnd_ip4 *addrs, const uint8_t *prefixes, int count);

/* A VM NIC with the given MAC joins a network. Returns a port id >= 0 (unique
 * across networks), or -1 (unknown network, full, invalid or duplicate MAC). */
int mnd_net_add_port(mnd_net *net, int network, mnd_mac mac);
void mnd_net_remove_port(mnd_net *net, int port);

/* A frame from a VM's NIC. */
void mnd_net_input(mnd_net *net, int port, const uint8_t *frame, size_t len);

/* The port's current IPv4 address (its unexpired lease). Returns 0, or -1. */
int mnd_net_port_ip(const mnd_net *net, int port, mnd_ip4 *out);

/* The answer to dns_query(id): a DNS message from the Mac, checked against
 * the query before it reaches the VM; len 0 means resolution failed (the VM
 * gets SERVFAIL). Unknown, answered or expired ids are ignored. */
void mnd_net_dns_answer(mnd_net *net, uint32_t id, const uint8_t *answer, size_t len);

/* The names the VM on `port` resolved to `ip` through the gateway (each VM
 * has its own), lowercase, most recent first. Writes up to max pointers,
 * valid until the next call into net, and returns how many. */
int mnd_net_dns_names(const mnd_net *net, int port, mnd_ip4 ip, const char **names, int max);

/* A datagram the host's socket for `flow` received. Unknown or closed flows
 * are ignored; datagrams larger than one frame holds are dropped. */
void mnd_net_udp_input(mnd_net *net, uint32_t flow, const uint8_t *data, size_t len);

/* An echo reply the host's socket for `flow` received. */
void mnd_net_icmp_input(mnd_net *net, uint32_t flow, uint16_t seq, const uint8_t *data, size_t len);

/* The outcome of tcp_connect. On failure the VM's connection is refused. */
void mnd_net_tcp_connected(mnd_net *net, uint32_t conn, bool ok);
/* Readiness the core asked for with tcp_interest. */
void mnd_net_tcp_readable(mnd_net *net, uint32_t conn);
void mnd_net_tcp_writable(mnd_net *net, uint32_t conn);

/* Time-driven work (expiring flows, retransmissions, timeouts). Runs what
 * is due and returns mnd_net_deadline(). */
uint64_t mnd_net_poll(mnd_net *net);

/* When mnd_net_poll next has work: a time on the host clock (ms), or
 * UINT64_MAX. It can move earlier after any input, so read it again then.
 * Calling mnd_net_poll early is harmless. */
uint64_t mnd_net_deadline(const mnd_net *net);

/* Returns 0 and fills stats, or -1 for an unknown port. */
int mnd_net_port_stats_get(const mnd_net *net, int port, mnd_net_port_stats *out);

/* Connection log: for each VM, every destination (protocol, address, port)
 * it tried to reach through a NAT gateway, what its firewall said last and
 * why, the flows or connections it opened, those refused or held for a
 * question, those open now, the bytes each way, and when. Bounded: at most
 * MND_NET_MAX_CONN_LOG entries, MND_NET_MAX_CONN_LOG_PER_PORT per VM. An
 * entry with something open stays; otherwise the least recently seen of the
 * VM goes, or, when the whole log is full, that of the VM with the most
 * entries, so a busy VM cannot push the others' out. Gone with the port. */
#define MND_NET_MAX_CONN_LOG 4096
#define MND_NET_MAX_CONN_LOG_PER_PORT 256

typedef enum { MND_CONN_ALLOWED = 1, MND_CONN_DENIED, MND_CONN_ASKED } mnd_conn_verdict;

typedef enum {
    MND_CONN_BY_RULE = 1, /* the VM's rule `rule` (0-based) */
    MND_CONN_BY_SESSION,  /* an answer given this session (monitor mode) */
    MND_CONN_BY_LAN,      /* the Mac or its LAN: the VM's allow_lan */
    MND_CONN_BY_DEFAULT,  /* no rule: allowlist mode refuses, otherwise allowed */
    MND_CONN_BY_MONITOR,  /* monitor mode: asked (or refused when no question fits) */
} mnd_conn_reason;

typedef struct {
    uint8_t proto;            /* MND_IPPROTO_TCP / _UDP / _ICMP */
    mnd_ip4 dst;
    uint16_t dport;           /* 0 for ICMP */
    mnd_conn_verdict verdict; /* the last decision */
    mnd_conn_reason reason;
    int rule;                 /* for MND_CONN_BY_RULE */
    uint32_t opened, refused, asked, active;
    uint64_t bytes_out, bytes_in; /* payload, VM → destination and back */
    uint64_t first_ms, last_ms;   /* host clock */
} mnd_net_conn;

/* The VM's log, most recently seen first: up to `max` entries. Returns
 * how many, or -1 for an unknown port. */
int mnd_net_conns(const mnd_net *net, int port, mnd_net_conn *out, int max);

/* VM-to-VM traffic on a network (Phase 13, the canvas's live edges): per
 * VM, the VMs it sent unicast frames to, with frames, bytes and when last
 * seen. At most MND_NET_MAX_PEERS per VM, the least recently seen giving
 * way; gone with either VM. Broadcast and multicast, frames to no one and
 * frames a network keeps from other VMs are not counted. */
#define MND_NET_MAX_PEERS 16

typedef struct {
    int from, to;           /* ports */
    uint64_t frames, bytes; /* bytes: whole frames */
    uint64_t last_ms;       /* host clock */
} mnd_net_peer;

/* The network's VM-to-VM traffic by sender, then receiver, in port order
 * (the same order page after page): up to `max` entries. Returns how many,
 * or -1 for an unknown network. */
int mnd_net_peers(const mnd_net *net, int network, mnd_net_peer *out, int max);

#endif /* MND_NET_H */
