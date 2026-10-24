/*
 * mnd_net_dhcp.h — DHCP messages (RFC 2131/2132): the fixed BOOTP header
 * and the options Monad's gateway reads or writes.
 *
 * Messages come from guests and are untrusted: the parser checks every
 * option's length against the message and rejects anything inconsistent.
 * Unknown options are skipped; option overloading (sname/file) is ignored.
 */
#ifndef MND_NET_DHCP_H
#define MND_NET_DHCP_H

#include "mnd_net_frame.h"

#define MND_DHCP_SERVER_PORT 67
#define MND_DHCP_CLIENT_PORT 68
#define MND_DHCP_FLAG_BROADCAST 0x8000

enum {
    MND_DHCP_DISCOVER = 1,
    MND_DHCP_OFFER = 2,
    MND_DHCP_REQUEST = 3,
    MND_DHCP_DECLINE = 4,
    MND_DHCP_ACK = 5,
    MND_DHCP_NAK = 6,
    MND_DHCP_RELEASE = 7,
    MND_DHCP_INFORM = 8,
};

#define MND_DHCP_HOSTNAME_MAX 63

typedef struct {
    uint8_t op; /* 1 request, 2 reply */
    uint32_t xid;
    uint16_t flags;
    mnd_ip4 ciaddr, yiaddr, siaddr;
    mnd_mac chaddr;
    uint8_t type; /* option 53; 0 when absent */
    /* Options below are 0 / empty when absent; the builder writes the
     * non-zero ones. */
    mnd_ip4 requested, server_id, subnet_mask, router, dns, broadcast;
    uint32_t lease_secs, t1, t2;
    char hostname[MND_DHCP_HOSTNAME_MAX + 1]; /* printable ASCII only */
} mnd_dhcp;

/* The UDP payload of a DHCP message. Returns 0, or -1 if malformed. */
int mnd_dhcp_parse(const uint8_t *p, size_t n, mnd_dhcp *out);

/* Writes the UDP payload; returns its length, or 0 if it does not fit. */
size_t mnd_dhcp_build(uint8_t *p, size_t cap, const mnd_dhcp *m);

#endif /* MND_NET_DHCP_H */
