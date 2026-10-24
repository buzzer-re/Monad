/*
 * mnd_netd.h — the network core on real sockets: an mnd_net whose host
 * side is the operating system, driven by an mnd_loop.
 *
 *   VM NICs      datagram sockets (one Ethernet frame per datagram), the
 *                VM's end of a VZFileHandleNetworkDeviceAttachment
 *   UDP          one connected socket per flow
 *   ping         one unprivileged ICMP socket per flow
 *   TCP          one non-blocking socket per connection
 *   DNS          the configured nameservers, a fresh socket and a random
 *                transaction id per query (answers must come from the
 *                nameserver and carry that id)
 *
 * Single-threaded: everything runs from mnd_netd_run_once.
 */
#ifndef MND_NETD_H
#define MND_NETD_H

#include "mnd_loop.h"
#include "mnd_net.h"

#define MND_NETD_MAX_NAMESERVERS 4
#define MND_NETD_DNS_TIMEOUT_MS 4000 /* then the VM gets SERVFAIL */
#define MND_NETD_FRAMES_PER_WAKEUP 64 /* per VM NIC, bounding the work per event */

typedef struct mnd_netd mnd_netd;

mnd_netd *mnd_netd_create(void);
/* Closes every socket, including the VM NICs. */
void mnd_netd_destroy(mnd_netd *d);

/* The core, for networks, firewalls and reservations. Ports go through
 * mnd_netd_add_port / mnd_netd_remove_port. */
mnd_net *mnd_netd_net(mnd_netd *d);

/* A VM NIC joins a network. Takes ownership of fd (closed on failure and on
 * removal). Returns the port id, or -1. */
int mnd_netd_add_port(mnd_netd *d, int network, mnd_mac mac, int fd);
void mnd_netd_remove_port(mnd_netd *d, int port);

/* The nameservers DNS queries go to (address and port, usually 53). */
int mnd_netd_set_nameservers(mnd_netd *d, const mnd_ip4 *addrs, const uint16_t *ports, int count);

/* Waits for events or timers until `deadline` (mnd_loop_now clock;
 * UINT64_MAX: until something happens), handles them, and returns 0, or -1. */
int mnd_netd_run_once(mnd_netd *d, uint64_t deadline);

/* Lines netd sends MonadHost on its own (not replies): "event ask <port>
 * <tcp|udp|icmp> <a.b.c.d> <dport> [<name>,...]" when a VM in monitor mode
 * wants to reach a destination nothing decides (the names it was looked up
 * as, most recent first). The sink may drop a line (MonadHost not reading):
 * the question is asked again once it expires. */
typedef void (*mnd_netd_event_fn)(void *ctx, const char *line);
void mnd_netd_set_event_sink(mnd_netd *d, mnd_netd_event_fn fn, void *ctx);
#define MND_NETD_EVENT_MAX 255 /* the longest event line, without the newline */

/* Writes an ask line into out (cap bytes, at most MND_NETD_EVENT_MAX + 1);
 * names that do not fit are left out whole. */
void mnd_netd_format_ask(char *out, size_t cap, int port, uint8_t proto, mnd_ip4 dst, uint16_t dport,
                         const char *const *names, int count);

/* Writes a lookup line ("event lookup <port> <name>") into out; empty if the
 * name is not one a rule could use. */
void mnd_netd_format_lookup(char *out, size_t cap, int port, const char *name);

/* One connection log entry as a token of the conns reply (see
 * mnd_netd_ctl.h): proto,address,port,verdict,reason,opened,refused,asked,
 * active,bytes out,bytes in,seconds since first seen,since last seen,name.
 * `name` (the VM's lookup for the address) only if a rule could use it,
 * else "-". Returns its length, or -1 if it does not fit in cap. */
int mnd_netd_format_conn(char *out, size_t cap, const mnd_net_conn *c, const char *name, uint64_t now_ms);

/* One VM-to-VM entry as a token of the peers reply (see mnd_netd_ctl.h):
 * sender port,receiver port,frames,bytes,seconds since last seen. Returns
 * its length, or -1 if it does not fit in cap. */
int mnd_netd_format_peer(char *out, size_t cap, const mnd_net_peer *p, uint64_t now_ms);

/* Open descriptors besides the VM NICs (tests use it to see nothing leaks). */
int mnd_netd_open_sockets(const mnd_netd *d);

/* The loop netd runs on, for descriptors of its own (the control channel). */
mnd_loop *mnd_netd_loop(mnd_netd *d);

/* Serves the control channel on `control_fd` (a connected stream socket)
 * until it closes or breaks the protocol, then tears everything down and
 * closes the descriptor. Returns 0 when MonadHost closed the channel, 1 on
 * a protocol violation, -1 on an internal error. */
int mnd_netd_serve(int control_fd);

/* The netd process (MonadHost started with --netd): the control channel is
 * descriptor 3 and must be a socket. Closes every other inherited
 * descriptor but stderr, points stdin/stdout at /dev/null, disables core
 * dumps, then (macOS) enters a sandbox that allows the network and nothing
 * else — no files, no processes — and refuses to run if it cannot. Returns
 * the process exit status: 0 when MonadHost closed the channel, 1 on a
 * protocol violation, 64 without a control socket, 70 without a sandbox. */
int mnd_netd_main(void);
#define MND_NETD_CONTROL_FD 3

/* Debug builds of MonadHost (--netd-sandbox-check): enters netd's sandbox and
 * checks that UDP and TCP to 127.0.0.1 at these ports and ping to 127.0.0.1
 * work, while reading or writing a file, starting a process, listening on a
 * port and connecting to the unix socket at `unix_path` (a listener the
 * caller made: an ssh agent, another VM's ssh.sock) do not.
 * Prints one line per check; returns 0 if all are as expected. */
int mnd_netd_sandbox_check(uint16_t udp_port, uint16_t tcp_port, const char *unix_path);

/* MonadHost's side of the control channel: sends `line` (no newline) and,
 * when fd >= 0, that descriptor with it. Returns 0, or -1. */
int mnd_netd_send_command(int control, const char *line, int fd);

/* Starts `path --netd` (MonadHost's own binary) with `control` as its
 * descriptor 3, an empty environment, stdin/stdout on /dev/null, and no
 * other descriptor. Returns the pid, or -1. */
pid_t mnd_netd_spawn(const char *path, int control);

#endif /* MND_NETD_H */
