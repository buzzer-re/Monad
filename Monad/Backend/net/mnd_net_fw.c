/*
 * mnd_net_fw.c — each VM's firewall: which destinations its new flows and
 * connections through a NAT network may reach. See mnd_net.h for the rules.
 *
 * Checked when a flow or connection is created, and again for everything
 * open whenever the VM's rules or the Mac's networks change. A port's rules
 * are allocated when set (MonadHost sets them, never a guest) and freed
 * with the port.
 */
#include "mnd_net_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const mnd_fw_config default_fw; /* LAN denied, the rest allowed */

static bool in_net(mnd_ip4 ip, mnd_ip4 addr, uint8_t prefix) {
    uint32_t mask = prefix ? ~((1u << (32 - prefix)) - 1) : 0;
    return (ip & mask) == addr;
}

static bool host_bits_clear(mnd_ip4 addr, uint8_t prefix) {
    return prefix <= 32 && in_net(addr, addr, prefix) && (prefix || !addr);
}

/* The Mac and its LAN: private ranges, carrier-grade NAT, and the Mac's
 * own networks. */
static bool is_lan(const mnd_net *net, mnd_ip4 ip) {
    if (in_net(ip, MND_IP4(10, 0, 0, 0), 8) || in_net(ip, MND_IP4(172, 16, 0, 0), 12) ||
        in_net(ip, MND_IP4(192, 168, 0, 0), 16) || in_net(ip, MND_IP4(100, 64, 0, 0), 10))
        return true;
    for (int i = 0; i < net->nhost_nets; i++)
        if (in_net(ip, net->host_nets[i].addr, net->host_nets[i].prefix)) return true;
    return false;
}

/* Whether `name` is a subdomain of `domain` ("a.b.example.com" of
 * "example.com"; not "badexample.com"). */
static bool is_subdomain(const char *name, const char *domain) {
    size_t dlen = strlen(domain), nlen = strlen(name);
    return nlen > dlen + 1 && name[nlen - dlen - 1] == '.' && strcmp(name + nlen - dlen, domain) == 0;
}

/* "example.com" matches itself and its subdomains, as people mean a domain;
 * "*.example.com" its subdomains only. */
static bool name_matches(const char *pattern, const char *name) {
    if (pattern[0] == '*') return is_subdomain(name, pattern + 2);
    return strcmp(pattern, name) == 0 || is_subdomain(name, pattern);
}

/* Every name the VM resolved to the destination, gathered once per decision
 * (all of them: a deny holds however many other names point there). */
typedef struct {
    const mnd_net *net;
    int port;
    mnd_ip4 dst;
    bool gathered;
    int n;
    const char *names[MND_NET_MAX_DNS_NAMES];
} dst_names;

static void gather(dst_names *d) {
    if (d->gathered) return;
    d->gathered = true;
    d->n = mnd_net_dns_names(d->net, d->port, d->dst, d->names, MND_NET_MAX_DNS_NAMES);
}

static bool rule_matches(dst_names *d, const mnd_fw_rule *r, uint8_t proto, uint16_t dport) {
    if (r->proto && r->proto != proto) return false;
    if (r->port_min || r->port_max) {
        if (proto == MND_IPPROTO_ICMP || dport < r->port_min || dport > r->port_max) return false;
    }
    if (!r->host[0]) return in_net(d->dst, r->addr, r->prefix);
    gather(d);
    for (int i = 0; i < d->n; i++)
        if (name_matches(r->host, d->names[i])) return true;
    return false;
}

typedef enum { ALLOW, DENY, ASK } verdict;

/* The verdict, and what gave it (`why`, and for a rule which: `rule`). */
static verdict decide(const mnd_net *net, int port, uint8_t proto, mnd_ip4 dst, uint16_t dport,
                      mnd_conn_reason *why, int *rule) {
    const mnd_net_port *p = &net->ports[port];
    const mnd_fw_config *fw = p->fw ? p->fw : &default_fw;
    bool lan = is_lan(net, dst);
    /* A rule by name never decides for the Mac and its LAN unless the VM
     * may reach them: DNS can point any name there. A range the user typed
     * still does. */
    bool names = !lan || fw->allow_lan;
    dst_names d = {.net = net, .port = port, .dst = dst};
    *rule = 0;
    for (int i = 0; i < fw->nrules; i++)
        if ((names || !fw->rules[i].host[0]) && rule_matches(&d, &fw->rules[i], proto, dport)) {
            *why = MND_CONN_BY_RULE;
            *rule = i;
            return fw->rules[i].action == MND_FW_ALLOW ? ALLOW : DENY;
        }
    *why = MND_CONN_BY_SESSION;
    for (int i = p->nsession - 1; i >= 0; i--) /* the newest answer first */
        if ((names || !p->session[i].host[0]) && rule_matches(&d, &p->session[i], proto, dport))
            return p->session[i].action == MND_FW_ALLOW ? ALLOW : DENY;
    if (lan) {
        *why = fw->allow_lan || !fw->monitor ? MND_CONN_BY_LAN : MND_CONN_BY_MONITOR;
        return fw->allow_lan ? ALLOW : fw->monitor ? ASK : DENY;
    }
    *why = fw->monitor ? MND_CONN_BY_MONITOR : MND_CONN_BY_DEFAULT;
    if (fw->monitor) return ASK;
    return fw->allowlist ? DENY : ALLOW;
}

bool mnd_net_fw_allows(const mnd_net *net, int port, uint8_t proto, mnd_ip4 dst, uint16_t dport) {
    mnd_conn_reason why;
    int rule;
    return decide(net, port, proto, dst, dport, &why, &rule) != DENY;
}

static bool ask_live(const mnd_net *net, const mnd_fw_ask *a) {
    return a->used && net->host.now_ms(net->host.ctx) - a->asked_ms <= MND_NET_ASK_TTL_MS;
}

static mnd_fw_admission ask(mnd_net *net, int port, uint8_t proto, mnd_ip4 dst, uint16_t dport);

mnd_fw_admission mnd_net_fw_admit(mnd_net *net, int port, uint8_t proto, mnd_ip4 dst, uint16_t dport, uint16_t *log) {
    mnd_conn_reason why;
    int rule;
    verdict v = decide(net, port, proto, dst, dport, &why, &rule);
    mnd_fw_admission a = v == ALLOW ? MND_FW_ADMIT : v == DENY ? MND_FW_REFUSE : ask(net, port, proto, dst, dport);
    *log = mnd_net_conn_entry(net, port, proto, dst, dport);
    mnd_net_conn_decided(net, *log,
                         a == MND_FW_ADMIT ? MND_CONN_ALLOWED : a == MND_FW_HOLD ? MND_CONN_ASKED : MND_CONN_DENIED,
                         why, rule);
    return a;
}

/* Monitor mode: asks about it unless asked already. Held, or refused when
 * no question fits. */
static mnd_fw_admission ask(mnd_net *net, int port, uint8_t proto, mnd_ip4 dst, uint16_t dport) {
    if (!net->host.ask) return MND_FW_REFUSE;
    int mine = 0, free_slot = -1;
    for (int i = 0; i < MND_NET_MAX_ASKS; i++) {
        mnd_fw_ask *a = &net->asks[i];
        if (!ask_live(net, a)) {
            a->used = false;
            if (free_slot < 0) free_slot = i;
            continue;
        }
        if (a->port != port) continue;
        if (!a->name[0] && a->proto == proto && a->dst == dst && a->dport == dport) return MND_FW_HOLD; /* already asked */
        mine++;
    }
    if (mine >= MND_NET_MAX_ASKS_PER_PORT || free_slot < 0) return MND_FW_REFUSE; /* cannot ask: refused */
    net->asks[free_slot] = (mnd_fw_ask){.used = true, .port = port, .proto = proto, .dst = dst, .dport = dport,
                                        .asked_ms = net->host.now_ms(net->host.ctx)};
    net->host.ask(net->host.ctx, port, proto, dst, dport);
    return MND_FW_HOLD;
}

/* What a rule says about looking `name` up: 1 allow (an allow of any
 * protocol or port: the name is needed to connect), -1 refuse (a deny of
 * every protocol and port), 0 nothing. */
static int lookup_verdict(const mnd_fw_rule *r, const char *name) {
    if (!r->host[0] || !name_matches(r->host, name)) return 0;
    if (r->action == MND_FW_ALLOW) return 1;
    return !r->proto && !r->port_min && !r->port_max ? -1 : 0;
}

static mnd_fw_admission ask_lookup(mnd_net *net, int port, const char *name) {
    if (!net->host.ask_lookup || !mnd_dns_name_is_plain(name)) return MND_FW_REFUSE;
    int mine = 0, free_slot = -1;
    for (int i = 0; i < MND_NET_MAX_ASKS; i++) {
        mnd_fw_ask *a = &net->asks[i];
        if (!ask_live(net, a)) {
            a->used = false;
            if (free_slot < 0) free_slot = i;
            continue;
        }
        if (a->port != port) continue;
        if (a->name[0] && strcmp(a->name, name) == 0) return MND_FW_HOLD; /* already asked */
        mine++;
    }
    if (mine >= MND_NET_MAX_ASKS_PER_PORT || free_slot < 0) return MND_FW_REFUSE;
    mnd_fw_ask *a = &net->asks[free_slot];
    *a = (mnd_fw_ask){.used = true, .port = port, .asked_ms = net->host.now_ms(net->host.ctx)};
    snprintf(a->name, sizeof a->name, "%s", name);
    net->host.ask_lookup(net->host.ctx, port, name);
    return MND_FW_HOLD;
}

/* A confined VM (only what the rules allow, or monitor mode) could send
 * anything out as names under a domain someone runs, so its lookups follow
 * the rules: the first rule by name with something to say decides, then
 * this session's answers (newest first), then the mode (monitor asks,
 * allowlist refuses). Otherwise every lookup goes: a deny by name holds on
 * the connection, which needs the name learned from the answer. */
mnd_fw_admission mnd_net_fw_admit_lookup(mnd_net *net, int port, const char *name) {
    const mnd_net_port *p = &net->ports[port];
    const mnd_fw_config *fw = p->fw ? p->fw : &default_fw;
    if (!fw->allowlist && !fw->monitor) return MND_FW_ADMIT;
    int v = 0;
    for (int i = 0; i < fw->nrules && !v; i++) v = lookup_verdict(&fw->rules[i], name);
    for (int i = p->nsession - 1; i >= 0 && !v; i--) v = lookup_verdict(&p->session[i], name);
    if (v) return v > 0 ? MND_FW_ADMIT : MND_FW_REFUSE;
    return fw->monitor ? ask_lookup(net, port, name) : MND_FW_REFUSE;
}

/* Copies a pattern lowercased; refuses anything but labels of letters,
 * digits, '-' and '_', optionally after a leading "*.". */
static bool clean_pattern(const char *in, char out[MND_DNS_NAME_MAX + 1]) {
    size_t len = strnlen(in, MND_DNS_NAME_MAX + 1);
    if (len == 0 || len > MND_DNS_NAME_MAX) return false;
    size_t i = 0;
    if (in[0] == '*') {
        if (in[1] != '.') return false;
        out[0] = '*';
        out[1] = '.';
        i = 2;
    }
    size_t label = 0;
    for (; i < len; i++) {
        char c = in[i];
        if (c >= 'A' && c <= 'Z') c = (char)(c + 32);
        if (c == '.') {
            if (!label) return false;
            label = 0;
        } else if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_') {
            label++;
        } else {
            return false;
        }
        out[i] = c;
    }
    if (!label) return false; /* empty, or ends with a dot */
    out[len] = 0;
    return true;
}

static bool rule_valid(const mnd_fw_rule *in, mnd_fw_rule *out) {
    *out = *in;
    if (in->action != MND_FW_ALLOW && in->action != MND_FW_DENY) return false;
    if (in->proto && in->proto != MND_IPPROTO_TCP && in->proto != MND_IPPROTO_UDP && in->proto != MND_IPPROTO_ICMP)
        return false;
    if ((in->port_min || in->port_max) && in->port_min > in->port_max) return false;
    if (strnlen(in->host, sizeof in->host) == sizeof in->host) return false;
    if (in->host[0]) return clean_pattern(in->host, out->host);
    return host_bits_clear(in->addr, in->prefix);
}

bool mnd_net_fw_config_valid(const mnd_fw_config *cfg) {
    if (!cfg || cfg->nrules < 0 || cfg->nrules > MND_NET_MAX_FW_RULES) return false;
    mnd_fw_rule tmp;
    for (int i = 0; i < cfg->nrules; i++)
        if (!rule_valid(&cfg->rules[i], &tmp)) return false;
    return true;
}

/* Closes what the port's firewall (port -1: any port's) no longer allows. */
static void recheck(mnd_net *net, int port) {
    mnd_net_nat_recheck(net, port);
    mnd_net_tcp_recheck(net, port);
}

int mnd_net_set_port_firewall(mnd_net *net, int port, const mnd_fw_config *cfg) {
    if (!net || !cfg || port < 0 || port >= MND_NET_PORT_SLOTS || !net->ports[port].used) return -1;
    if (cfg->nrules < 0 || cfg->nrules > MND_NET_MAX_FW_RULES) return -1;
    mnd_fw_config *next = calloc(1, sizeof *next);
    if (!next) return -1;
    next->allowlist = cfg->allowlist;
    next->allow_lan = cfg->allow_lan;
    next->monitor = cfg->monitor;
    next->nrules = cfg->nrules;
    for (int i = 0; i < cfg->nrules; i++) {
        if (!rule_valid(&cfg->rules[i], &next->rules[i])) {
            free(next);
            return -1;
        }
    }
    free(net->ports[port].fw);
    net->ports[port].fw = next;
    recheck(net, port);
    return 0;
}

int mnd_net_add_session_rule(mnd_net *net, int port, const mnd_fw_rule *rule) {
    if (!net || !rule || port < 0 || port >= MND_NET_PORT_SLOTS || !net->ports[port].used) return -1;
    mnd_fw_rule r;
    if (!rule_valid(rule, &r)) return -1;
    mnd_net_port *p = &net->ports[port];
    if (!p->session) {
        p->session = calloc(MND_NET_MAX_SESSION_RULES, sizeof *p->session);
        if (!p->session) return -1;
    }
    if (p->nsession == MND_NET_MAX_SESSION_RULES) {
        memmove(p->session, p->session + 1, (MND_NET_MAX_SESSION_RULES - 1) * sizeof *p->session);
        p->nsession--;
    }
    p->session[p->nsession++] = r;
    /* The questions it answers are settled: the VM's next try is decided. */
    for (int i = 0; i < MND_NET_MAX_ASKS; i++) {
        mnd_fw_ask *a = &net->asks[i];
        if (!a->used || a->port != port) continue;
        if (a->name[0]) {
            if (lookup_verdict(&r, a->name)) a->used = false;
            continue;
        }
        dst_names d = {.net = net, .port = port, .dst = a->dst};
        if (rule_matches(&d, &r, a->proto, a->dport)) a->used = false;
    }
    recheck(net, port);
    return 0;
}

static void forget(mnd_net *net, int port) {
    mnd_net_port *p = &net->ports[port];
    free(p->session);
    p->session = NULL;
    p->nsession = 0;
    for (int i = 0; i < MND_NET_MAX_ASKS; i++)
        if (net->asks[i].used && net->asks[i].port == port) net->asks[i].used = false;
}

void mnd_net_clear_session(mnd_net *net, int port) {
    if (!net || port < 0 || port >= MND_NET_PORT_SLOTS || !net->ports[port].used) return;
    forget(net, port);
    recheck(net, port);
}

void mnd_net_fw_port_removed(mnd_net *net, int port) { forget(net, port); }

int mnd_net_set_host_networks(mnd_net *net, const mnd_ip4 *addrs, const uint8_t *prefixes, int count) {
    if (!net || count < 0 || count > MND_NET_MAX_HOST_NETWORKS || (count && (!addrs || !prefixes))) return -1;
    for (int i = 0; i < count; i++)
        if (!host_bits_clear(addrs[i], prefixes[i])) return -1;
    for (int i = 0; i < count; i++) {
        net->host_nets[i].addr = addrs[i];
        net->host_nets[i].prefix = prefixes[i];
    }
    net->nhost_nets = count;
    recheck(net, -1);
    return 0;
}
