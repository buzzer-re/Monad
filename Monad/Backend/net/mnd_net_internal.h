/*
 * mnd_net_internal.h — state shared by the switch (mnd_net.c), the gateway
 * (mnd_net_gateway.c), DNS (mnd_net_dnsfwd.c) and NAT (mnd_net_nat.c). Not
 * part of the public API.
 */
#ifndef MND_NET_INTERNAL_H
#define MND_NET_INTERNAL_H

#include "mnd_net.h"
#include "mnd_net_dns.h"

#define MND_NET_PORT_SLOTS (MND_NET_MAX_NETWORKS * MND_NET_MAX_PORTS)

typedef struct {
    bool used;
    int network;
    mnd_mac mac;
    mnd_net_port_stats stats;
    int udp_flows; /* NAT flows open for this VM */
    mnd_fw_config *fw; /* the VM's firewall; NULL: the defaults (LAN denied, the rest allowed) */
    mnd_fw_rule *session; /* monitor-mode answers, oldest first (MND_NET_MAX_SESSION_RULES) */
    int nsession;
    int nconns; /* its entries in the connection log */
    /* VMs it sent unicast frames to (mnd_net_peers), in no order. */
    struct {
        int to;
        uint64_t frames, bytes, last_ms;
    } peers[MND_NET_MAX_PEERS];
    int npeers;
} mnd_net_port;

/* A monitor-mode question waiting for its answer: a connection (proto,
 * dst, dport), or a lookup (name set). */
typedef struct {
    bool used;
    int port;
    uint8_t proto;
    mnd_ip4 dst;
    uint16_t dport;
    uint64_t asked_ms;
    char name[MND_DNS_NAME_MAX + 1];
} mnd_fw_ask;

typedef enum {
    MND_LEASE_FREE = 0,
    MND_LEASE_OFFERED,  /* held for the client for a short while */
    MND_LEASE_BOUND,
    MND_LEASE_DECLINED, /* someone else answers for it; kept out of the pool */
} mnd_lease_state;

/* At most one record per address, and one active record per MAC. */
typedef struct {
    mnd_lease_state state;
    bool adopted; /* taken by sending from it: renewed by traffic, not DHCP */
    mnd_mac mac;
    mnd_ip4 ip;
    uint64_t expires_ms;
} mnd_lease;

typedef struct {
    mnd_mac mac;
    mnd_ip4 ip;
} mnd_reservation;

typedef struct {
    bool used;
    mnd_net_config cfg;
    int members[MND_NET_MAX_PORTS]; /* port ids, first `count` are valid */
    int count;
    /* Gateway (kind != MND_NET_NONE). */
    mnd_mac gw_mac;
    mnd_ip4 gw_ip, mask, bcast;
    mnd_ip4 pool_first, pool_last;
    mnd_lease leases[MND_NET_MAX_LEASES];
    mnd_reservation reservations[MND_NET_MAX_RESERVATIONS];
    int nreservations;
} mnd_net_network;

/* A VM's DNS query waiting for the Mac's answer. */
typedef struct {
    bool used;
    uint32_t id;
    int port, network;
    mnd_mac mac; /* the port's VM when asked: a reused port slot gets nothing */
    mnd_ip4 client_ip;
    uint16_t client_port;
    uint64_t deadline_ms;
    mnd_dns_query q;
    uint8_t question[12 + 255 + 4]; /* the query up to q.question_end */
} mnd_dns_pending;

/* A name a VM resolved to an address through the gateway. */
typedef struct {
    bool used;
    int port;
    mnd_ip4 ip;
    uint64_t expires_ms;
    uint64_t seq; /* newer is larger */
    char name[MND_DNS_NAME_MAX + 1];
} mnd_dns_name;

/* A datagram NAT flow: UDP (one host socket connected to dst:dst_port) or
 * ICMP echo (vm_port is the VM's echo identifier, dst_port 0). */
typedef struct {
    bool used;
    bool replied;
    uint8_t proto;
    uint16_t gen;  /* part of the flow id, so a stale id misses */
    uint16_t next; /* hash chain: index + 1, 0 ends */
    int network, port;
    mnd_mac mac;
    mnd_ip4 vm_ip, dst;
    uint16_t vm_port, dst_port;
    uint64_t expires_ms;
    uint16_t log; /* its connection log entry: index + 1, 0 none */
} mnd_udp_flow;

#define MND_UDP_BUCKETS 2048

typedef enum {
    MND_TCP_FREE = 0,
    MND_TCP_CONNECTING, /* waiting for the host's connect */
    MND_TCP_SYN_RCVD,   /* SYN-ACK sent to the VM */
    MND_TCP_OPEN,
} mnd_tcp_state;

/* A VM's TCP connection, ended here and spliced to a host socket. */
typedef struct {
    mnd_tcp_state state;
    bool vm_fin;     /* the VM's FIN arrived (in order) */
    bool mac_eof;    /* the host socket reached end of stream */
    bool fin_sent;   /* our FIN is in [snd_una, snd_nxt) */
    bool fin_acked;
    bool shut;       /* tcp_shutdown was called */
    bool want_read, want_write; /* the interest the host was told */
    bool persist;    /* the timer is a window probe, not a retransmission */
    uint16_t gen, next; /* flow id generation; hash chain (index + 1) */
    int network, port;
    mnd_mac mac;
    mnd_ip4 vm_ip, dst;
    uint16_t vm_port, dst_port;
    /* VM → Mac */
    uint32_t rcv_nxt;
    uint32_t adv_wnd; /* the window last advertised */
    uint8_t *rx;
    uint32_t rx_head, rx_len;
    /* Mac → VM: tx holds the bytes from snd_una on */
    uint32_t iss, snd_una, snd_nxt, snd_wnd;
    uint16_t mss;
    uint8_t *tx;
    uint32_t tx_head, tx_len;
    uint64_t timer_at; /* 0: none */
    uint32_t rto_ms, persist_ms;
    uint8_t retries;
    uint16_t log; /* its connection log entry: index + 1, 0 none */
} mnd_tcp_conn;

#define MND_TCP_BUCKETS 1024

/* An entry of the connection log (see mnd_net.h), in a hash by
 * (port, proto, dst, dport). */
typedef struct {
    bool used;
    uint16_t next; /* hash chain: index + 1, 0 ends */
    int port;
    mnd_net_conn c;
} mnd_conn_entry;

#define MND_CONN_BUCKETS 4096

struct mnd_net {
    mnd_net_host host;
    mnd_net_network networks[MND_NET_MAX_NETWORKS];
    mnd_net_port ports[MND_NET_PORT_SLOTS];
    int next_port;  /* where the port allocator looks first */
    uint16_t ip_id; /* for packets the gateway sends */
    mnd_dns_pending dns_pending[MND_NET_MAX_DNS_PENDING];
    uint32_t dns_next_id;
    mnd_dns_name dns_names[MND_NET_MAX_DNS_NAMES];
    uint64_t dns_name_seq;
    mnd_udp_flow udp[MND_NET_MAX_UDP_FLOWS];
    uint16_t udp_bucket[MND_UDP_BUCKETS]; /* index + 1, 0 is empty */
    mnd_tcp_conn tcp[MND_NET_MAX_TCP_CONNS];
    uint16_t tcp_bucket[MND_TCP_BUCKETS];
    uint32_t tcp_iss_seed;
    struct {
        mnd_ip4 addr;
        uint8_t prefix;
    } host_nets[MND_NET_MAX_HOST_NETWORKS];
    int nhost_nets;
    mnd_fw_ask asks[MND_NET_MAX_ASKS];
    mnd_conn_entry conns[MND_NET_MAX_CONN_LOG];
    uint16_t conn_bucket[MND_CONN_BUCKETS];
    int nconns;
};

/* Sends a frame to a VM and counts it. */
void mnd_net_deliver(mnd_net *net, int port, const uint8_t *frame, size_t len);

/* Switching within the sender's network (after all checks passed). */
void mnd_net_switch(mnd_net *net, int port, const mnd_eth *eth, const uint8_t *frame, size_t len);

bool mnd_net_gateway_mac_range(mnd_mac mac);
void mnd_net_gateway_init(mnd_net_network *nw, int id);
/* A frame from a VM on a network with a gateway; the source MAC is checked. */
void mnd_net_gateway_input(mnd_net *net, int port, const mnd_eth *eth, const uint8_t *frame, size_t len);
/* A UDP datagram to a VM, through the gateway (its MAC, any source address). */
void mnd_net_send_udp(mnd_net *net, const mnd_net_network *nw, int port, mnd_ip4 src, uint16_t sport, mnd_ip4 dst,
                      uint16_t dport, const uint8_t *payload, size_t len);

/* A datagram to the gateway's DNS port (source address already checked). */
void mnd_net_dns_input(mnd_net *net, mnd_net_network *nw, int port, const mnd_ip *ip);

/* NAT (mnd_net_nat.c): a packet to the gateway's MAC for another address. */
void mnd_net_route(mnd_net *net, mnd_net_network *nw, int port, const mnd_ip *ip);
/* Closes the VM's flows and connections (its port is going away). */
void mnd_net_nat_port_removed(mnd_net *net, int port);
void mnd_net_nat_close_all(mnd_net *net);
uint32_t mnd_net_flow_hash(int network, mnd_ip4 vm_ip, uint16_t vm_port, mnd_ip4 dst, uint16_t dst_port);

/* An ICMP error from the gateway to a VM about `ip` (which it sent). */
void mnd_net_send_icmp_error(mnd_net *net, const mnd_net_network *nw, int port, uint8_t type, uint8_t code,
                             const mnd_ip *ip);

/* Firewall (mnd_net_fw.c). For what is open: false only when denied (a
 * question in monitor mode keeps it). */
bool mnd_net_fw_allows(const mnd_net *net, int port, uint8_t proto, mnd_ip4 dst, uint16_t dport);
/* For a new flow or connection: allowed, denied, or held (asked about in
 * monitor mode: drop the packet quietly, the VM retries). The attempt goes
 * in the connection log; `log` gets its entry (index + 1, 0 none), for the
 * flow the caller opens. */
typedef enum { MND_FW_ADMIT, MND_FW_REFUSE, MND_FW_HOLD } mnd_fw_admission;
mnd_fw_admission mnd_net_fw_admit(mnd_net *net, int port, uint8_t proto, mnd_ip4 dst, uint16_t dport, uint16_t *log);
/* Whether the VM on `port` may look `name` up through the Mac (lowercase). */
mnd_fw_admission mnd_net_fw_admit_lookup(mnd_net *net, int port, const char *name);
/* A port goes away: its answers and questions with it. */
void mnd_net_fw_port_removed(mnd_net *net, int port);
/* The VM on `port` left: the names it resolved go. */
void mnd_net_dns_port_removed(mnd_net *net, int port);
/* Whether mnd_net_set_port_firewall would accept cfg (rules checked, nothing applied). */
bool mnd_net_fw_config_valid(const mnd_fw_config *cfg);
/* Closes the port's flows / connections (port -1: every port's) its firewall
 * no longer allows. */
void mnd_net_nat_recheck(mnd_net *net, int port);
void mnd_net_tcp_recheck(mnd_net *net, int port);

/* Connection log (mnd_net_conns.c). The entry for a destination of the
 * VM, made if missing (making room as mnd_net.h says): index + 1, or 0
 * when there is none to give. */
uint16_t mnd_net_conn_entry(mnd_net *net, int port, uint8_t proto, mnd_ip4 dst, uint16_t dport);
/* What the firewall said about an attempt. */
void mnd_net_conn_decided(mnd_net *net, uint16_t log, mnd_conn_verdict v, mnd_conn_reason why, int rule);
/* A flow or connection of the entry opened, closed; bytes it carried. */
void mnd_net_conn_opened(mnd_net *net, uint16_t log);
void mnd_net_conn_closed(mnd_net *net, uint16_t log);
void mnd_net_conn_bytes(mnd_net *net, uint16_t log, uint64_t out, uint64_t in);
/* The VM left: its entries go (after its flows and connections closed). */
void mnd_net_conns_port_removed(mnd_net *net, int port);

/* TCP (mnd_net_tcp.c). */
void mnd_net_tcp_input(mnd_net *net, mnd_net_network *nw, int port, const mnd_ip *ip);
void mnd_net_tcp_port_removed(mnd_net *net, int port);
void mnd_net_tcp_close_all(mnd_net *net);
/* Fires due timers; returns the next one (UINT64_MAX: none). */
uint64_t mnd_net_tcp_poll(mnd_net *net, uint64_t now);
uint64_t mnd_net_tcp_deadline(const mnd_net *net);

#endif /* MND_NET_INTERNAL_H */
