/*
 * mnd_netd_ctl.h — monad-netd's control channel: MonadHost configures
 * networks and hands over VM NICs over a private socket pair it created
 * when it started netd. One command per line, one reply per command.
 *
 *   network <nat|host-only|internal|none> <a.b.c.d>/<prefix> [lease=<secs>]
 *                                        -> ok <network>
 *   port <network> <mac>                 -> ok <port>   (claims one passed NIC fd;
 *                                                         nothing leaves until its firewall is set)
 *   unport <port>                        -> ok
 *   reserve <network> <mac> <a.b.c.d>    -> ok
 *   nameservers [<a.b.c.d>[:port] ...]   -> ok          (up to 4)
 *   hostnets [<a.b.c.d>/<prefix> ...]    -> ok          (the Mac's own networks)
 *   firewall <port> allowlist=<0|1> lan=<0|1> [monitor=<0|1>]   (starts the VM's rule list)
 *   rule <allow|deny> <any|tcp|udp|icmp> <a.b.c.d/prefix|name|*.name> [ports=<lo>-<hi>]
 *   commit                               -> ok          (applies the rule list)
 *   session <port> <rule as above, without "rule">  -> ok   (a monitor-mode answer)
 *   forget <port>                        -> ok          (the VM's answers and questions go)
 *   stats <port>                         -> ok rx=… tx=… spoofed=… malformed=… unknown=… policy=… firewall=…
 *   conns <port> [from=<n>]              -> ok next=<n> <entry> …   (the VM's connection log, most
 *                                           recent first, from the n-th entry, as many as fit a
 *                                           line; next=0: no more. Entries: mnd_netd_format_conn)
 *   peers <network> [from=<n>]           -> ok next=<n> <entry> …   (VM-to-VM traffic by sender
 *                                           and receiver port, paged as conns; mnd_netd_format_peer)
 *   ping                                 -> ok pong
 *
 * Replies are "ok …" or "err <reason>". netd also sends lines of its own,
 * between replies, which start with "event " (see mnd_netd_set_event_sink). Anything malformed or unknown is
 * refused. Lines are printable ASCII, at most MND_CTL_MAX_LINE bytes; a
 * longer line, a control byte, or too many unclaimed descriptors is a
 * protocol violation that ends the session (mnd_ctl_feed returns -1).
 */
#ifndef MND_NETD_CTL_H
#define MND_NETD_CTL_H

#include "mnd_netd.h"

#define MND_CTL_MAX_LINE 1024
#define MND_CTL_MAX_FDS 8 /* NIC descriptors received and not yet claimed */

typedef struct mnd_ctl mnd_ctl;

/* A session on top of netd; `write_reply` sends one reply line (without
 * the newline) back to MonadHost. */
typedef void (*mnd_ctl_reply_fn)(void *ctx, const char *line);
mnd_ctl *mnd_ctl_create(mnd_netd *d, mnd_ctl_reply_fn reply, void *ctx);
/* Closes any descriptors still waiting to be claimed. */
void mnd_ctl_destroy(mnd_ctl *c);

/* Bytes and descriptors as they came off the channel (fds in arrival
 * order; the session owns them from here). Handles every complete line.
 * Returns 0, or -1 on a protocol violation (the caller ends the session). */
int mnd_ctl_feed(mnd_ctl *c, const char *data, size_t len, const int *fds, int nfds);

/* One command, for tests: runs `line` (no newline) and writes the reply. */
void mnd_ctl_command(mnd_ctl *c, const char *line, char *reply, size_t cap);

#endif /* MND_NETD_CTL_H */
