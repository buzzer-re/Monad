/*
 * mnd_netd_ctl.c — monad-netd's control channel. See mnd_netd_ctl.h.
 *
 * The channel is private (a socket pair MonadHost created), but every
 * field is still checked strictly: exact separators, no leading zeros or
 * signs, bounded numbers, and descriptors that are always either claimed
 * by a port or closed.
 */
#include "mnd_netd_ctl.h"

#include "mnd_net_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* The longest command: hostnets and every Mac network netd can enforce. */
#define MAX_TOKENS (1 + MND_NET_MAX_HOST_NETWORKS)
#define MIN_LEASE 60
#define MAX_LEASE (7 * 86400)

struct mnd_ctl {
    mnd_netd *d;
    mnd_ctl_reply_fn reply;
    void *ctx;
    char line[MND_CTL_MAX_LINE + 1];
    size_t len;
    int fds[MND_CTL_MAX_FDS];
    int nfds;
    /* A firewall rule list being built. */
    bool fw_open, fw_spoiled;
    int fw_port;
    mnd_fw_config fw;
};

mnd_ctl *mnd_ctl_create(mnd_netd *d, mnd_ctl_reply_fn reply, void *ctx) {
    if (!d) return NULL;
    mnd_ctl *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    c->d = d;
    c->reply = reply;
    c->ctx = ctx;
    return c;
}

void mnd_ctl_destroy(mnd_ctl *c) {
    if (!c) return;
    for (int i = 0; i < c->nfds; i++) close(c->fds[i]);
    free(c);
}

/* ---- Fields ----------------------------------------------------------------------- */

/* A decimal number without sign or leading zeros, at most `max`. */
static bool parse_uint(const char *s, size_t len, uint32_t max, uint32_t *out) {
    if (!len || len > 10 || (len > 1 && s[0] == '0')) return false;
    uint64_t v = 0;
    for (size_t i = 0; i < len; i++) {
        if (s[i] < '0' || s[i] > '9') return false;
        v = v * 10 + (uint64_t)(s[i] - '0');
    }
    if (v > max) return false;
    *out = (uint32_t)v;
    return true;
}

static bool parse_uint_str(const char *s, uint32_t max, uint32_t *out) { return parse_uint(s, strlen(s), max, out); }

/* a.b.c.d, up to `end` (exclusive). */
static bool parse_ip_n(const char *s, size_t len, mnd_ip4 *out) {
    mnd_ip4 ip = 0;
    size_t start = 0;
    for (int part = 0; part < 4; part++) {
        size_t i = start;
        while (i < len && s[i] != '.') i++;
        if ((part < 3) != (i < len)) return false; /* three dots, exactly */
        uint32_t v;
        if (!parse_uint(s + start, i - start, 255, &v)) return false;
        ip = ip << 8 | v;
        start = i + 1;
    }
    *out = ip;
    return true;
}

static bool parse_ip(const char *s, mnd_ip4 *out) { return parse_ip_n(s, strlen(s), out); }

static bool split_at(const char *s, char sep, size_t *at) {
    const char *p = strchr(s, sep);
    if (!p || strchr(p + 1, sep)) return false;
    *at = (size_t)(p - s);
    return true;
}

/* a.b.c.d/prefix */
static bool parse_cidr(const char *s, mnd_ip4 *addr, uint8_t *prefix) {
    size_t at;
    uint32_t p;
    if (!split_at(s, '/', &at) || !parse_ip_n(s, at, addr) || !parse_uint_str(s + at + 1, 32, &p)) return false;
    *prefix = (uint8_t)p;
    return true;
}

static int hexval(char ch) {
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    return -1;
}

/* xx:xx:xx:xx:xx:xx */
static bool parse_mac(const char *s, mnd_mac *out) {
    if (strlen(s) != 17) return false;
    for (int i = 0; i < 6; i++) {
        int hi = hexval(s[i * 3]), lo = hexval(s[i * 3 + 1]);
        if (hi < 0 || lo < 0 || (i < 5 && s[i * 3 + 2] != ':')) return false;
        out->b[i] = (uint8_t)(hi << 4 | lo);
    }
    return true;
}

/* key=value with the expected key. */
static const char *value_of(const char *tok, const char *key) {
    size_t n = strlen(key);
    return strncmp(tok, key, n) == 0 && tok[n] == '=' ? tok + n + 1 : NULL;
}

static bool parse_bit(const char *tok, const char *key, bool *out) {
    const char *v = value_of(tok, key);
    if (!v || (strcmp(v, "0") != 0 && strcmp(v, "1") != 0)) return false;
    *out = v[0] == '1';
    return true;
}

static bool port_exists(const mnd_ctl *c, uint32_t id) {
    mnd_net_port_stats s;
    return id < MND_NET_PORT_SLOTS && mnd_net_port_stats_get(mnd_netd_net(c->d), (int)id, &s) == 0;
}

/* ---- Commands ------------------------------------------------------------------------ */

typedef struct {
    char *tok[MAX_TOKENS];
    int n;
} tokens;

/* Splits on single spaces; empty fields are refused. */
static bool tokenize(char *line, tokens *t) {
    t->n = 0;
    char *p = line;
    for (;;) {
        if (t->n == MAX_TOKENS || !*p || *p == ' ') return false;
        t->tok[t->n++] = p;
        char *sp = strchr(p, ' ');
        if (!sp) return true;
        *sp = 0;
        p = sp + 1;
    }
}

#define ERR(msg)                                   \
    do {                                           \
        snprintf(out, cap, "err %s", (msg));       \
        return;                                    \
    } while (0)

#define NETWORK_USAGE "usage: network <kind> <a.b.c.d/prefix> [lease=<secs>] [peers=<0|1>] [dns=<0|1>]"

/* network <kind> <subnet> [lease=<secs>] [peers=<0|1>] [dns=<0|1>]: peers
 * says whether VMs reach each other (without it, only where nothing leaves:
 * internal, none); dns whether a host-only network's lookups reach the Mac
 * (without it, they do not). */
static void do_network(mnd_ctl *c, const tokens *t, char *out, size_t cap) {
    if (t->n < 3 || t->n > 6) ERR(NETWORK_USAGE);
    mnd_net_config cfg = {0};
    const char *k = t->tok[1];
    if (!strcmp(k, "nat")) cfg.kind = MND_NET_NAT;
    else if (!strcmp(k, "host-only")) cfg.kind = MND_NET_HOST_ONLY;
    else if (!strcmp(k, "internal")) cfg.kind = MND_NET_INTERNAL;
    else if (!strcmp(k, "none")) cfg.kind = MND_NET_NONE;
    else ERR("unknown network kind");
    if (!parse_cidr(t->tok[2], &cfg.subnet, &cfg.prefix)) ERR("bad subnet");
    bool peers = cfg.kind == MND_NET_INTERNAL || cfg.kind == MND_NET_NONE;
    bool have_lease = false, have_peers = false, have_dns = false;
    for (int i = 3; i < t->n; i++) {
        const char *v;
        if ((v = value_of(t->tok[i], "lease")) && !have_lease) {
            if (!parse_uint_str(v, MAX_LEASE, &cfg.lease_secs) || cfg.lease_secs < MIN_LEASE) ERR("bad lease");
            have_lease = true;
        } else if (value_of(t->tok[i], "peers") && !have_peers) {
            if (!parse_bit(t->tok[i], "peers", &peers)) ERR("bad peers");
            have_peers = true;
        } else if (value_of(t->tok[i], "dns") && !have_dns) {
            if (!parse_bit(t->tok[i], "dns", &cfg.host_only_dns)) ERR("bad dns");
            have_dns = true;
        } else {
            ERR(NETWORK_USAGE);
        }
    }
    cfg.isolated = !peers;
    int id = mnd_net_add_network(mnd_netd_net(c->d), &cfg);
    if (id < 0) ERR("network refused");
    snprintf(out, cap, "ok %d", id);
}

static void do_port(mnd_ctl *c, const tokens *t, char *out, size_t cap) {
    if (!c->nfds) ERR("no nic descriptor");
    /* The oldest descriptor is this command's, whatever happens next. */
    int fd = c->fds[0];
    memmove(c->fds, c->fds + 1, (size_t)(c->nfds - 1) * sizeof c->fds[0]);
    c->nfds--;
    uint32_t network;
    mnd_mac mac;
    if (t->n != 3 || !parse_uint_str(t->tok[1], MND_NET_MAX_NETWORKS - 1, &network) || !parse_mac(t->tok[2], &mac)) {
        close(fd);
        ERR("usage: port <network> <mac>");
    }
    int port = mnd_netd_add_port(c->d, (int)network, mac, fd); /* owns fd from here */
    if (port < 0) ERR("port refused");
    /* Closed until MonadHost sends the VM's own firewall (it does next):
     * nothing leaves on the defaults in between, not even after a restart. */
    static const mnd_fw_config closed = {.allowlist = true};
    if (mnd_net_set_port_firewall(mnd_netd_net(c->d), port, &closed) != 0) {
        mnd_netd_remove_port(c->d, port);
        ERR("port refused");
    }
    snprintf(out, cap, "ok %d", port);
}

static bool port_arg(const mnd_ctl *c, const tokens *t, uint32_t *port) {
    mnd_net_port_stats s;
    return t->n == 2 && parse_uint_str(t->tok[1], MND_NET_PORT_SLOTS - 1, port) &&
           mnd_net_port_stats_get(mnd_netd_net(c->d), (int)*port, &s) == 0;
}

static void do_unport(mnd_ctl *c, const tokens *t, char *out, size_t cap) {
    uint32_t port;
    if (!port_arg(c, t, &port)) ERR("unknown port");
    mnd_netd_remove_port(c->d, (int)port);
    snprintf(out, cap, "ok");
}

static void do_stats(mnd_ctl *c, const tokens *t, char *out, size_t cap) {
    uint32_t port;
    mnd_net_port_stats s;
    if (!port_arg(c, t, &port)) ERR("unknown port");
    mnd_net_port_stats_get(mnd_netd_net(c->d), (int)port, &s);
    snprintf(out, cap, "ok rx=%llu tx=%llu spoofed=%llu malformed=%llu unknown=%llu policy=%llu firewall=%llu",
             (unsigned long long)s.rx, (unsigned long long)s.tx, (unsigned long long)s.dropped_spoofed,
             (unsigned long long)s.dropped_malformed, (unsigned long long)s.dropped_unknown,
             (unsigned long long)s.dropped_policy, (unsigned long long)s.dropped_firewall);
}

/* conns <port> [from=<n>]: a page of the VM's connection log. */
static void do_conns(mnd_ctl *c, const tokens *t, char *out, size_t cap) {
    uint32_t port, from = 0;
    if (t->n < 2 || t->n > 3 || !parse_uint_str(t->tok[1], MND_NET_PORT_SLOTS - 1, &port) || !port_exists(c, port))
        ERR("unknown port");
    if (t->n == 3) {
        const char *v = value_of(t->tok[2], "from");
        if (!v || !parse_uint_str(v, 65535, &from)) ERR("bad from");
    }
    mnd_net *net = mnd_netd_net(c->d);
    mnd_net_conn *all = malloc(MND_NET_MAX_CONN_LOG_PER_PORT * sizeof *all);
    if (!all) ERR("no memory");
    int n = mnd_net_conns(net, (int)port, all, MND_NET_MAX_CONN_LOG_PER_PORT);
    uint64_t now = net->host.now_ms(net->host.ctx);
    /* "ok next=" and up to five digits, then the entries that fit. */
    char head[32];
    size_t len = 0, room = cap > sizeof head ? cap - sizeof head : 0;
    char *body = malloc(room + 1);
    if (!body) {
        free(all);
        ERR("no memory");
    }
    body[0] = 0;
    uint32_t next = 0;
    for (int i = (int)from; i < n; i++) {
        const char *names[1];
        int named = mnd_net_dns_names(net, (int)port, all[i].dst, names, 1);
        char entry[512];
        int el = mnd_netd_format_conn(entry, sizeof entry, &all[i], named > 0 ? names[0] : NULL, now);
        if (el < 0) continue;
        if (len + 1 + (size_t)el > room) {
            next = (uint32_t)i;
            break;
        }
        body[len++] = ' ';
        memcpy(body + len, entry, (size_t)el + 1);
        len += (size_t)el;
    }
    snprintf(head, sizeof head, "ok next=%u", next);
    snprintf(out, cap, "%s%s", head, body);
    free(body);
    free(all);
}

/* peers <network> [from=<n>]: a page of the network's VM-to-VM traffic. */
static void do_peers(mnd_ctl *c, const tokens *t, char *out, size_t cap) {
    enum { MAX = MND_NET_MAX_PORTS * MND_NET_MAX_PEERS };
    uint32_t network, from = 0;
    mnd_net *net = mnd_netd_net(c->d);
    if (t->n < 2 || t->n > 3 || !parse_uint_str(t->tok[1], MND_NET_MAX_NETWORKS - 1, &network) ||
        mnd_net_peers(net, (int)network, NULL, 0) < 0)
        ERR("unknown network");
    if (t->n == 3) {
        const char *v = value_of(t->tok[2], "from");
        if (!v || !parse_uint_str(v, 65535, &from)) ERR("bad from");
    }
    mnd_net_peer *all = malloc(MAX * sizeof *all);
    if (!all) ERR("no memory");
    int n = mnd_net_peers(net, (int)network, all, MAX);
    uint64_t now = net->host.now_ms(net->host.ctx);
    /* "ok next=" and up to five digits, then the entries that fit. */
    char head[32];
    size_t len = 0, room = cap > sizeof head ? cap - sizeof head : 0;
    char *body = malloc(room + 1);
    if (!body) {
        free(all);
        ERR("no memory");
    }
    body[0] = 0;
    uint32_t next = 0;
    for (int i = (int)from; i < n; i++) {
        char entry[96];
        int el = mnd_netd_format_peer(entry, sizeof entry, &all[i], now);
        if (el < 0) continue;
        if (len + 1 + (size_t)el > room) {
            next = (uint32_t)i;
            break;
        }
        body[len++] = ' ';
        memcpy(body + len, entry, (size_t)el + 1);
        len += (size_t)el;
    }
    snprintf(head, sizeof head, "ok next=%u", next);
    snprintf(out, cap, "%s%s", head, body);
    free(body);
    free(all);
}

static void do_reserve(mnd_ctl *c, const tokens *t, char *out, size_t cap) {
    uint32_t network;
    mnd_mac mac;
    mnd_ip4 ip;
    if (t->n != 4 || !parse_uint_str(t->tok[1], MND_NET_MAX_NETWORKS - 1, &network) || !parse_mac(t->tok[2], &mac) ||
        !parse_ip(t->tok[3], &ip))
        ERR("usage: reserve <network> <mac> <a.b.c.d>");
    if (mnd_net_reserve(mnd_netd_net(c->d), (int)network, mac, ip) != 0) ERR("reservation refused");
    snprintf(out, cap, "ok");
}

static void do_nameservers(mnd_ctl *c, const tokens *t, char *out, size_t cap) {
    mnd_ip4 addrs[MND_NETD_MAX_NAMESERVERS];
    uint16_t ports[MND_NETD_MAX_NAMESERVERS];
    int n = t->n - 1;
    if (n > MND_NETD_MAX_NAMESERVERS) ERR("too many nameservers");
    for (int i = 0; i < n; i++) {
        const char *s = t->tok[i + 1];
        const char *colon = strchr(s, ':');
        uint32_t port = 53;
        if (!parse_ip_n(s, colon ? (size_t)(colon - s) : strlen(s), &addrs[i])) ERR("bad nameserver");
        if (colon && (!parse_uint_str(colon + 1, 65535, &port) || !port)) ERR("bad nameserver port");
        ports[i] = (uint16_t)port;
    }
    if (mnd_netd_set_nameservers(c->d, addrs, ports, n) != 0) ERR("nameservers refused");
    snprintf(out, cap, "ok");
}

static void do_hostnets(mnd_ctl *c, const tokens *t, char *out, size_t cap) {
    mnd_ip4 addrs[MND_NET_MAX_HOST_NETWORKS];
    uint8_t prefixes[MND_NET_MAX_HOST_NETWORKS];
    int n = t->n - 1;
    if (n > MND_NET_MAX_HOST_NETWORKS) ERR("too many networks");
    for (int i = 0; i < n; i++)
        if (!parse_cidr(t->tok[i + 1], &addrs[i], &prefixes[i])) ERR("bad network");
    if (mnd_net_set_host_networks(mnd_netd_net(c->d), addrs, prefixes, n) != 0) ERR("networks refused");
    snprintf(out, cap, "ok");
}

static void do_firewall(mnd_ctl *c, const tokens *t, char *out, size_t cap) {
    uint32_t port;
    bool allowlist, lan, monitor = false;
    c->fw_open = false;
    if ((t->n != 4 && t->n != 5) || !parse_uint_str(t->tok[1], MND_NET_PORT_SLOTS - 1, &port) ||
        !port_exists(c, port) || !parse_bit(t->tok[2], "allowlist", &allowlist) || !parse_bit(t->tok[3], "lan", &lan) ||
        (t->n == 5 && !parse_bit(t->tok[4], "monitor", &monitor)))
        ERR("usage: firewall <port> allowlist=<0|1> lan=<0|1> [monitor=<0|1>]");
    memset(&c->fw, 0, sizeof c->fw);
    c->fw.allowlist = allowlist;
    c->fw.allow_lan = lan;
    c->fw.monitor = monitor;
    c->fw_port = (int)port;
    c->fw_open = true;
    c->fw_spoiled = false;
    snprintf(out, cap, "ok");
}

/* "<allow|deny> <proto> <target> [ports=lo-hi]" from token `from` on, the
 * last ones of the line. Returns NULL, or what is wrong. */
static const char *parse_rule(const tokens *t, int from, mnd_fw_rule *r) {
    memset(r, 0, sizeof *r);
    if (t->n < from + 3 || t->n > from + 4) return "usage: <allow|deny> <proto> <target> [ports=lo-hi]";
    if (!strcmp(t->tok[from], "allow")) r->action = MND_FW_ALLOW;
    else if (!strcmp(t->tok[from], "deny")) r->action = MND_FW_DENY;
    else return "bad action";
    const char *p = t->tok[from + 1];
    if (!strcmp(p, "any")) r->proto = 0;
    else if (!strcmp(p, "tcp")) r->proto = MND_IPPROTO_TCP;
    else if (!strcmp(p, "udp")) r->proto = MND_IPPROTO_UDP;
    else if (!strcmp(p, "icmp")) r->proto = MND_IPPROTO_ICMP;
    else return "bad protocol";
    const char *target = t->tok[from + 2];
    if (strchr(target, '/')) {
        if (!parse_cidr(target, &r->addr, &r->prefix)) return "bad network";
    } else {
        if (strlen(target) > MND_DNS_NAME_MAX) return "bad name";
        strcpy(r->host, target);
    }
    if (t->n == from + 4) {
        const char *v = value_of(t->tok[from + 3], "ports");
        size_t at;
        uint32_t lo, hi;
        if (!v || !split_at(v, '-', &at) || !parse_uint(v, at, 65535, &lo) || !parse_uint_str(v + at + 1, 65535, &hi))
            return "bad ports";
        r->port_min = (uint16_t)lo;
        r->port_max = (uint16_t)hi;
    }
    /* The core checks the rest (patterns, host bits, port order); check this
     * rule alone now so the error names it. */
    mnd_fw_config one;
    memset(&one, 0, sizeof one);
    one.nrules = 1;
    one.rules[0] = *r;
    return mnd_net_fw_config_valid(&one) ? NULL : "bad rule";
}

static void do_rule(mnd_ctl *c, const tokens *t, char *out, size_t cap) {
    if (!c->fw_open) ERR("no firewall being built");
    if (c->fw.nrules >= MND_NET_MAX_FW_RULES) {
        c->fw_spoiled = true;
        ERR("too many rules");
    }
    mnd_fw_rule r;
    c->fw_spoiled = true; /* until the rule is known to be good */
    const char *problem = parse_rule(t, 1, &r);
    if (problem) ERR(problem);
    c->fw.rules[c->fw.nrules++] = r;
    c->fw_spoiled = false;
    snprintf(out, cap, "ok");
}

/* session <port> <rule>: a monitor-mode answer for the VM. */
static void do_session(mnd_ctl *c, const tokens *t, char *out, size_t cap) {
    uint32_t port;
    if (t->n < 2 || !parse_uint_str(t->tok[1], MND_NET_PORT_SLOTS - 1, &port) || !port_exists(c, port))
        ERR("unknown port");
    mnd_fw_rule r;
    const char *problem = parse_rule(t, 2, &r);
    if (problem) ERR(problem);
    if (mnd_net_add_session_rule(mnd_netd_net(c->d), (int)port, &r) != 0) ERR("rule refused");
    snprintf(out, cap, "ok");
}

/* forget <port>: the VM stopped, its answers and questions go. */
static void do_forget(mnd_ctl *c, const tokens *t, char *out, size_t cap) {
    uint32_t port;
    if (t->n != 2 || !parse_uint_str(t->tok[1], MND_NET_PORT_SLOTS - 1, &port) || !port_exists(c, port))
        ERR("unknown port");
    mnd_net_clear_session(mnd_netd_net(c->d), (int)port);
    snprintf(out, cap, "ok");
}

static void do_commit(mnd_ctl *c, const tokens *t, char *out, size_t cap) {
    bool ready = c->fw_open && !c->fw_spoiled && t->n == 1;
    c->fw_open = false;
    if (!ready) ERR("no valid firewall to commit");
    if (mnd_net_set_port_firewall(mnd_netd_net(c->d), c->fw_port, &c->fw) != 0) ERR("firewall refused");
    snprintf(out, cap, "ok");
}

void mnd_ctl_command(mnd_ctl *c, const char *line, char *out, size_t cap) {
    char buf[MND_CTL_MAX_LINE + 1];
    tokens t;
    snprintf(buf, sizeof buf, "%s", line);
    if (!tokenize(buf, &t)) ERR("unknown command");
    const char *verb = t.tok[0];
    /* A rule list is built by consecutive commands; anything else ends it. */
    if (strcmp(verb, "rule") != 0 && strcmp(verb, "commit") != 0 && strcmp(verb, "firewall") != 0) c->fw_open = false;
    if (!strcmp(verb, "network")) do_network(c, &t, out, cap);
    else if (!strcmp(verb, "port")) do_port(c, &t, out, cap);
    else if (!strcmp(verb, "unport")) do_unport(c, &t, out, cap);
    else if (!strcmp(verb, "reserve")) do_reserve(c, &t, out, cap);
    else if (!strcmp(verb, "nameservers")) do_nameservers(c, &t, out, cap);
    else if (!strcmp(verb, "hostnets")) do_hostnets(c, &t, out, cap);
    else if (!strcmp(verb, "firewall")) do_firewall(c, &t, out, cap);
    else if (!strcmp(verb, "rule")) do_rule(c, &t, out, cap);
    else if (!strcmp(verb, "commit")) do_commit(c, &t, out, cap);
    else if (!strcmp(verb, "session")) do_session(c, &t, out, cap);
    else if (!strcmp(verb, "forget")) do_forget(c, &t, out, cap);
    else if (!strcmp(verb, "stats")) do_stats(c, &t, out, cap);
    else if (!strcmp(verb, "conns")) do_conns(c, &t, out, cap);
    else if (!strcmp(verb, "peers")) do_peers(c, &t, out, cap);
    else if (!strcmp(verb, "ping") && t.n == 1) snprintf(out, cap, "ok pong");
    else ERR("unknown command");
}

/* ---- The stream ------------------------------------------------------------------------- */

int mnd_ctl_feed(mnd_ctl *c, const char *data, size_t len, const int *fds, int nfds) {
    int violation = 0;
    for (int i = 0; i < nfds; i++) {
        if (c->nfds < MND_CTL_MAX_FDS) c->fds[c->nfds++] = fds[i];
        else {
            close(fds[i]);
            violation = -1;
        }
    }
    if (violation) return -1;
    for (size_t i = 0; i < len; i++) {
        unsigned char ch = (unsigned char)data[i];
        if (ch == '\n') {
            char reply[MND_CTL_MAX_LINE];
            c->line[c->len] = 0;
            mnd_ctl_command(c, c->line, reply, sizeof reply);
            c->len = 0;
            if (c->reply) c->reply(c->ctx, reply);
            continue;
        }
        if (ch < 0x20 || ch > 0x7e || c->len >= MND_CTL_MAX_LINE) return -1;
        c->line[c->len++] = (char)ch;
    }
    return 0;
}
