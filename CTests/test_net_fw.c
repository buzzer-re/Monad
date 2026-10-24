/* Tests for the firewall: each VM's own (its port's), the Mac and its LAN
 * denied by default, rules by address, port and hostname, allowlist mode,
 * live changes. */
#include "net_test_dns.h"
#include "net_test_gw.h"

static mnd_ip4 vm_ip(fixture *f, int port) {
    mnd_ip4 ip = 0;
    mnd_net_port_ip(f->net, port, &ip);
    return ip;
}

static void udp_to(fixture *f, int port, mnd_ip4 dst, uint16_t dport) {
    send_udp(f, port, port_mac(f, port), f->gw_mac, vm_ip(f, port), dst, 5000, dport, (const uint8_t *)"q", 1);
}

static void syn_to(fixture *f, int port, mnd_ip4 dst, uint16_t dport, uint16_t sport) {
    uint8_t buf[MND_FRAME_MAX];
    mnd_ip_hdr_spec h = {.eth_dst = f->gw_mac, .eth_src = port_mac(f, port), .src = vm_ip(f, port), .dst = dst,
                         .ttl = 64};
    mnd_tcp_spec t = {.sport = sport, .dport = dport, .seq = 100, .flags = MND_TCP_SYN, .window = 65535,
                      .mss = 1400, .wscale = -1};
    size_t n = mnd_build_tcp(buf, sizeof buf, &h, &t, NULL, 0);
    mnd_net_input(f->net, port, buf, n);
}

static void ping_to(fixture *f, int port, mnd_ip4 dst) {
    uint8_t buf[MND_FRAME_MAX];
    mnd_ip_hdr_spec h = {.eth_dst = f->gw_mac, .eth_src = port_mac(f, port), .src = vm_ip(f, port), .dst = dst,
                         .ttl = 64};
    size_t n = mnd_build_icmp(buf, sizeof buf, &h, 8, 0, 1, 1, (const uint8_t *)"p", 1);
    mnd_net_input(f->net, port, buf, n);
}

/* What the VM got back last: an ICMP error (type/code) or a TCP reset. */
static int last_icmp(fixture *f, int port, uint8_t *type, uint8_t *code, mnd_ip4 *quoted_dst) {
    const th_frame *fr = th_last(&f->h, port);
    mnd_eth eth;
    mnd_ip ip;
    mnd_icmp icmp;
    if (!fr || mnd_eth_parse(fr->data, fr->len, &eth) || mnd_ip_parse(eth.payload, eth.len, &ip)) return -1;
    if (ip.proto != MND_IPPROTO_ICMP || ip.src != GW || mnd_icmp_parse(&ip, &icmp)) return -1;
    *type = icmp.type;
    *code = icmp.code;
    /* After the 4 unused bytes: the original IP header and 8 bytes of it. */
    const uint8_t *q = icmp.data;
    if (icmp.len != 20 + 8) return -1;
    *quoted_dst = (mnd_ip4)q[16] << 24 | (mnd_ip4)q[17] << 16 | (mnd_ip4)q[18] << 8 | q[19];
    return 0;
}

static bool last_is_reset(fixture *f, int port) {
    const th_frame *fr = th_last(&f->h, port);
    mnd_eth eth;
    mnd_ip ip;
    mnd_tcp t;
    if (!fr || mnd_eth_parse(fr->data, fr->len, &eth) || mnd_ip_parse(eth.payload, eth.len, &ip)) return false;
    return ip.proto == MND_IPPROTO_TCP && mnd_tcp_parse(&ip, &t) == 0 && (t.flags & MND_TCP_RST);
}

static void setup_fw(fixture *f) {
    setup(f);
    lease(f, f->a);
}

static mnd_fw_rule addr_rule(mnd_fw_action action, uint8_t proto, mnd_ip4 addr, uint8_t prefix, uint16_t lo,
                             uint16_t hi) {
    mnd_fw_rule r = {.action = action, .proto = proto, .addr = addr, .prefix = prefix, .port_min = lo, .port_max = hi};
    return r;
}

static mnd_fw_rule host_rule(mnd_fw_action action, const char *pattern) {
    mnd_fw_rule r = {.action = action};
    strcpy(r.host, pattern);
    return r;
}

/* ---- Defaults --------------------------------------------------------------------- */

static void test_the_lan_is_denied_by_default(void) {
    static fixture f;
    setup_fw(&f);
    const mnd_ip4 lan[] = {MND_IP4(192, 168, 1, 5), MND_IP4(10, 1, 2, 3),   MND_IP4(172, 16, 0, 1),
                           MND_IP4(172, 31, 255, 254), MND_IP4(100, 64, 0, 1), MND_IP4(100, 127, 1, 1)};
    int count = (int)(sizeof lan / sizeof lan[0]);
    for (int i = 0; i < count; i++) {
        th_clear(&f.h);
        udp_to(&f, f.a, lan[i], 53);
        uint8_t type = 0, code = 0;
        mnd_ip4 quoted = 0;
        CHECK(last_icmp(&f, f.a, &type, &code, &quoted) == 0 && type == 3 && code == 13 && quoted == lan[i]);
    }
    CHECK(f.h.nudp == 0 && stats(&f, f.a).dropped_firewall == (uint64_t)count);
    th_clear(&f.h);
    syn_to(&f, f.a, MND_IP4(192, 168, 1, 5), 22, 40000);
    CHECK(f.h.ntcp == 0 && last_is_reset(&f, f.a));
    th_clear(&f.h);
    ping_to(&f, f.a, MND_IP4(192, 168, 1, 5));
    uint8_t type = 0, code = 0;
    mnd_ip4 quoted = 0;
    CHECK(f.h.nicmp == 0 && last_icmp(&f, f.a, &type, &code, &quoted) == 0 && type == 3 && code == 13);
    /* Just outside the private ranges: the internet. */
    udp_to(&f, f.a, MND_IP4(172, 32, 0, 1), 53);
    udp_to(&f, f.a, MND_IP4(100, 128, 0, 1), 53);
    udp_to(&f, f.a, MND_IP4(11, 0, 0, 1), 53);
    syn_to(&f, f.a, MND_IP4(1, 1, 1, 1), 443, 40001);
    CHECK(f.h.nudp == 3 && f.h.ntcp == 1);
    teardown(&f);
}

static void test_the_macs_own_networks_count_as_lan(void) {
    static fixture f;
    setup_fw(&f);
    mnd_ip4 addrs[] = {MND_IP4(203, 0, 113, 0)};
    uint8_t prefixes[] = {24};
    CHECK(mnd_net_set_host_networks(f.net, addrs, prefixes, 1) == 0);
    udp_to(&f, f.a, MND_IP4(203, 0, 113, 9), 53);
    CHECK(f.h.nudp == 0);
    udp_to(&f, f.a, MND_IP4(203, 0, 114, 1), 53);
    CHECK(f.h.nudp == 1);
    /* Invalid lists are refused and change nothing. */
    uint8_t bad[] = {33};
    CHECK(mnd_net_set_host_networks(f.net, addrs, bad, 1) == -1);
    mnd_ip4 host_bits[] = {MND_IP4(203, 0, 113, 7)};
    CHECK(mnd_net_set_host_networks(f.net, host_bits, prefixes, 1) == -1);
    CHECK(mnd_net_set_host_networks(f.net, addrs, prefixes, MND_NET_MAX_HOST_NETWORKS + 1) == -1);
    udp_to(&f, f.a, MND_IP4(203, 0, 113, 10), 53);
    CHECK(f.h.nudp == 1);
    /* A new list re-checks what is open. */
    CHECK(mnd_net_set_host_networks(f.net, NULL, NULL, 0) == 0);
    udp_to(&f, f.a, MND_IP4(203, 0, 113, 10), 53);
    CHECK(f.h.nudp == 2);
    mnd_ip4 now_lan[] = {MND_IP4(203, 0, 114, 0)};
    CHECK(mnd_net_set_host_networks(f.net, now_lan, prefixes, 1) == 0);
    CHECK(!f.h.udp[0].open && f.h.udp[1].open);
    teardown(&f);
}

static void test_allow_lan(void) {
    static fixture f;
    setup_fw(&f);
    mnd_fw_config cfg = {.allow_lan = true};
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    udp_to(&f, f.a, MND_IP4(192, 168, 1, 5), 53);
    syn_to(&f, f.a, MND_IP4(10, 0, 0, 1), 22, 40000);
    CHECK(f.h.nudp == 1 && f.h.ntcp == 1);
    teardown(&f);
}

/* ---- Rules -------------------------------------------------------------------------- */

static void test_address_and_port_rules(void) {
    static fixture f;
    setup_fw(&f);
    mnd_fw_config cfg = {.nrules = 3};
    cfg.rules[0] = addr_rule(MND_FW_ALLOW, MND_IPPROTO_TCP, MND_IP4(192, 168, 1, 50), 32, 5432, 5432);
    cfg.rules[1] = addr_rule(MND_FW_ALLOW, 0, MND_IP4(192, 168, 1, 60), 32, 8000, 8100);
    cfg.rules[2] = addr_rule(MND_FW_DENY, 0, MND_IP4(1, 1, 1, 0), 24, 0, 0);
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    syn_to(&f, f.a, MND_IP4(192, 168, 1, 50), 5432, 40000);
    CHECK(f.h.ntcp == 1);
    syn_to(&f, f.a, MND_IP4(192, 168, 1, 50), 22, 40001);
    udp_to(&f, f.a, MND_IP4(192, 168, 1, 50), 5432); /* TCP only */
    CHECK(f.h.ntcp == 1 && f.h.nudp == 0);
    udp_to(&f, f.a, MND_IP4(192, 168, 1, 60), 8000);
    udp_to(&f, f.a, MND_IP4(192, 168, 1, 60), 8100);
    CHECK(f.h.nudp == 2);
    udp_to(&f, f.a, MND_IP4(192, 168, 1, 60), 8101);
    ping_to(&f, f.a, MND_IP4(192, 168, 1, 60)); /* a rule with ports never matches ping… */
    CHECK(f.h.nudp == 2 && f.h.nicmp == 0);
    mnd_fw_config low = {.nrules = 1};
    low.rules[0] = addr_rule(MND_FW_ALLOW, 0, MND_IP4(192, 168, 1, 60), 32, 0, 100);
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &low) == 0);
    ping_to(&f, f.a, MND_IP4(192, 168, 1, 60)); /* …even one starting at port 0 */
    CHECK(f.h.nicmp == 0);
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    udp_to(&f, f.a, MND_IP4(1, 1, 1, 1), 53);
    syn_to(&f, f.a, MND_IP4(1, 1, 1, 200), 443, 40002);
    CHECK(f.h.nudp == 2 && f.h.ntcp == 1);
    udp_to(&f, f.a, MND_IP4(1, 1, 2, 1), 53);
    CHECK(f.h.nudp == 3);
    teardown(&f);
}

static void test_the_first_match_decides(void) {
    static fixture f;
    setup_fw(&f);
    mnd_fw_config cfg = {.nrules = 2};
    cfg.rules[0] = addr_rule(MND_FW_DENY, 0, MND_IP4(8, 8, 8, 0), 24, 0, 0);
    cfg.rules[1] = addr_rule(MND_FW_ALLOW, 0, MND_IP4(8, 8, 8, 8), 32, 0, 0);
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    udp_to(&f, f.a, MND_IP4(8, 8, 8, 8), 53);
    CHECK(f.h.nudp == 0);
    cfg.rules[0] = addr_rule(MND_FW_ALLOW, 0, MND_IP4(10, 0, 0, 0), 8, 0, 0);
    cfg.rules[1] = addr_rule(MND_FW_DENY, MND_IPPROTO_ICMP, 0, 0, 0, 0); /* any address */
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    udp_to(&f, f.a, MND_IP4(10, 9, 9, 9), 53);
    udp_to(&f, f.a, MND_IP4(8, 8, 8, 8), 53);
    ping_to(&f, f.a, MND_IP4(8, 8, 8, 8));
    CHECK(f.h.nudp == 2 && f.h.nicmp == 0);
    teardown(&f);
}

static void resolve(fixture *f, int port, const char *name, mnd_ip4 ip) {
    uint8_t q[512], p[512];
    size_t qn = td_query(q, 1, name, MND_DNS_TYPE_A, 0);
    send_udp(f, port, port_mac(f, port), f->gw_mac, vm_ip(f, port), GW, 40000, MND_DNS_PORT, q, qn);
    size_t at = td_response(p, 1, name, MND_DNS_TYPE_A);
    at = td_a(p, at, 12, ip, 300);
    td_set_ancount(p, 1);
    mnd_net_dns_answer(f->net, f->h.dns_id, p, at);
}

static void test_allowlist_with_hostnames(void) {
    static fixture f;
    setup_fw(&f);
    mnd_fw_config cfg = {.allowlist = true, .nrules = 2};
    cfg.rules[0] = host_rule(MND_FW_ALLOW, "*.GitHub.com");
    cfg.rules[1] = host_rule(MND_FW_ALLOW, "pypi.org");
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    syn_to(&f, f.a, MND_IP4(140, 82, 112, 5), 443, 40000);
    CHECK(f.h.ntcp == 0); /* not resolved (yet): unknown */
    resolve(&f, f.a, "api.github.com", MND_IP4(140, 82, 112, 5));
    resolve(&f, f.a, "github.com", MND_IP4(140, 82, 112, 3));
    resolve(&f, f.a, "pypi.org", MND_IP4(151, 101, 0, 223));
    resolve(&f, f.a, "files.pypi.org", MND_IP4(151, 101, 64, 223));
    syn_to(&f, f.a, MND_IP4(140, 82, 112, 5), 443, 40001);
    CHECK(f.h.ntcp == 1);
    syn_to(&f, f.a, MND_IP4(140, 82, 112, 3), 443, 40002); /* "*." is for subdomains only */
    CHECK(f.h.ntcp == 1);
    syn_to(&f, f.a, MND_IP4(151, 101, 64, 223), 443, 40003); /* a name covers its subdomains */
    CHECK(f.h.ntcp == 2);
    syn_to(&f, f.a, MND_IP4(151, 101, 0, 223), 443, 40004);
    CHECK(f.h.ntcp == 3);
    udp_to(&f, f.a, MND_IP4(9, 9, 9, 9), 53); /* allowlist: nothing else */
    CHECK(f.h.nudp == 0);
    /* Names are per network: another network's answers do not count. */
    mnd_net_config other = {.kind = MND_NET_NAT, .subnet = MND_IP4(10, 88, 0, 0), .prefix = 24};
    int n2 = mnd_net_add_network(f.net, &other);
    int c = mnd_net_add_port(f.net, n2, th_mac(9));
    CHECK(mnd_net_set_port_firewall(f.net, c, &cfg) == 0);
    f.vms[f.nvms].port = c;
    f.vms[f.nvms].mac = th_mac(9);
    f.nvms++;
    mnd_mac gw2;
    mnd_net_gateway(f.net, n2, &gw2, NULL);
    uint8_t buf[MND_FRAME_MAX];
    mnd_ip_hdr_spec h = {.eth_dst = gw2, .eth_src = th_mac(9), .src = MND_IP4(10, 88, 0, 7),
                         .dst = MND_IP4(140, 82, 112, 5), .ttl = 64};
    mnd_tcp_spec t = {.sport = 1, .dport = 443, .seq = 1, .flags = MND_TCP_SYN, .window = 1000, .wscale = -1};
    size_t n = mnd_build_tcp(buf, sizeof buf, &h, &t, NULL, 0);
    mnd_net_input(f.net, c, buf, n);
    CHECK(f.h.ntcp == 3);
    teardown(&f);
}

/* A rule by name never opens the Mac or its LAN: DNS can point any name
 * there (F-01). A range the user typed may; with "allow LAN" on, names
 * count as usual; in monitor mode the question is asked. */
static void test_a_name_never_opens_the_lan(void) {
    static fixture f;
    setup_fw(&f);
    mnd_ip4 macnet[] = {MND_IP4(203, 0, 113, 0)};
    uint8_t prefixes[] = {24};
    CHECK(mnd_net_set_host_networks(f.net, macnet, prefixes, 1) == 0);
    mnd_fw_config cfg = {.nrules = 1};
    cfg.rules[0] = host_rule(MND_FW_ALLOW, "example.com");
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    resolve(&f, f.a, "a.example.com", MND_IP4(192, 168, 1, 1));
    resolve(&f, f.a, "b.example.com", MND_IP4(203, 0, 113, 9));
    resolve(&f, f.a, "www.example.com", MND_IP4(93, 184, 216, 34));
    syn_to(&f, f.a, MND_IP4(192, 168, 1, 1), 80, 40000);
    syn_to(&f, f.a, MND_IP4(203, 0, 113, 9), 80, 40001);
    udp_to(&f, f.a, MND_IP4(192, 168, 1, 1), 5000);
    ping_to(&f, f.a, MND_IP4(203, 0, 113, 9));
    CHECK(f.h.ntcp == 0 && f.h.nudp == 0 && f.h.nicmp == 0);
    CHECK(stats(&f, f.a).dropped_firewall == 4);
    syn_to(&f, f.a, MND_IP4(93, 184, 216, 34), 443, 40002); /* the internet: the rule holds */
    CHECK(f.h.ntcp == 1);
    /* A session rule (a monitor-mode answer) by name: the same. */
    mnd_fw_config plain = {0};
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &plain) == 0);
    mnd_fw_rule answer = host_rule(MND_FW_ALLOW, "example.com");
    CHECK(mnd_net_add_session_rule(f.net, f.a, &answer) == 0);
    syn_to(&f, f.a, MND_IP4(192, 168, 1, 1), 80, 40003);
    CHECK(f.h.ntcp == 1);
    /* Monitor mode asks about the LAN address instead of allowing it. */
    mnd_fw_config monitor = {.monitor = true, .nrules = 1};
    monitor.rules[0] = host_rule(MND_FW_ALLOW, "example.com");
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &monitor) == 0);
    int asks = f.h.nasks;
    syn_to(&f, f.a, MND_IP4(192, 168, 1, 1), 80, 40004);
    CHECK(f.h.ntcp == 1 && f.h.nasks == asks + 1);
    /* A range the user typed opens it; so does "allow LAN". */
    mnd_fw_config range = {.nrules = 1};
    range.rules[0] = addr_rule(MND_FW_ALLOW, 0, MND_IP4(192, 168, 1, 0), 24, 0, 0);
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &range) == 0);
    syn_to(&f, f.a, MND_IP4(192, 168, 1, 1), 80, 40005);
    CHECK(f.h.ntcp == 2);
    cfg.allow_lan = true;
    cfg.allowlist = true;
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    syn_to(&f, f.a, MND_IP4(203, 0, 113, 9), 80, 40006);
    CHECK(f.h.ntcp == 3);
    teardown(&f);
}

/* "deny tcp google.com": the name and every subdomain, whichever address
 * they resolved to, but not a name that merely ends the same way. */
static void test_blocking_a_domain(void) {
    static fixture f;
    setup_fw(&f);
    mnd_fw_config cfg = {.nrules = 1};
    cfg.rules[0] = host_rule(MND_FW_DENY, "google.com");
    cfg.rules[0].proto = MND_IPPROTO_TCP;
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    resolve(&f, f.a, "google.com", MND_IP4(142, 250, 1, 1));
    resolve(&f, f.a, "www.google.com", MND_IP4(142, 250, 1, 2));
    resolve(&f, f.a, "notgoogle.com", MND_IP4(142, 250, 1, 3));
    th_clear(&f.h);
    syn_to(&f, f.a, MND_IP4(142, 250, 1, 1), 443, 40000);
    CHECK(last_is_reset(&f, f.a));
    th_clear(&f.h);
    syn_to(&f, f.a, MND_IP4(142, 250, 1, 2), 80, 40001);
    CHECK(last_is_reset(&f, f.a));
    CHECK(f.h.ntcp == 0);
    syn_to(&f, f.a, MND_IP4(142, 250, 1, 3), 443, 40002);
    CHECK(f.h.ntcp == 1);
    udp_to(&f, f.a, MND_IP4(142, 250, 1, 1), 443); /* TCP only */
    CHECK(f.h.nudp == 1);
    teardown(&f);
}

/* Every name an address had counts, however many names point there since:
 * a guest's own domain can point anywhere (F-11). */
static void test_a_deny_by_name_holds_whatever_else_points_there(void) {
    static fixture f;
    setup_fw(&f);
    mnd_fw_config cfg = {.nrules = 1};
    cfg.rules[0] = host_rule(MND_FW_DENY, "google.com");
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    resolve(&f, f.a, "www.google.com", MND_IP4(142, 250, 1, 2));
    for (int i = 0; i < 40; i++) {
        char name[32];
        snprintf(name, sizeof name, "n%d.attacker.test", i);
        resolve(&f, f.a, name, MND_IP4(142, 250, 1, 2));
    }
    th_clear(&f.h);
    syn_to(&f, f.a, MND_IP4(142, 250, 1, 2), 443, 40000);
    CHECK(last_is_reset(&f, f.a));
    CHECK(f.h.ntcp == 0);
    teardown(&f);
}

/* Names are each VM's own: another VM's lookups neither count for it nor
 * push its names out of the table (F-11). */
static void test_names_are_each_vms_own(void) {
    static fixture f;
    setup_fw(&f);
    lease(&f, f.b);
    mnd_fw_config gh = {.allowlist = true, .nrules = 1};
    gh.rules[0] = host_rule(MND_FW_ALLOW, "github.com");
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &gh) == 0);
    CHECK(mnd_net_set_port_firewall(f.net, f.b, &gh) == 0);
    resolve(&f, f.a, "github.com", MND_IP4(140, 82, 112, 3));
    syn_to(&f, f.b, MND_IP4(140, 82, 112, 3), 443, 40000);
    CHECK(f.h.ntcp == 0); /* b never looked it up */
    for (int i = 0; i < 2000; i++) {
        char name[32];
        snprintf(name, sizeof name, "n%d.example", i);
        resolve(&f, f.b, name, MND_IP4(198, 18, (uint8_t)(i >> 8), (uint8_t)i));
    }
    syn_to(&f, f.a, MND_IP4(140, 82, 112, 3), 443, 40001);
    CHECK(f.h.ntcp == 1 && f.h.tcp[0].dst == MND_IP4(140, 82, 112, 3));
    teardown(&f);
}

static void test_changes_apply_to_what_is_open(void) {
    static fixture f;
    setup_fw(&f);
    syn_to(&f, f.a, MND_IP4(1, 1, 1, 1), 443, 40000);
    syn_to(&f, f.a, MND_IP4(9, 9, 9, 9), 443, 40001);
    udp_to(&f, f.a, MND_IP4(1, 1, 1, 1), 53);
    udp_to(&f, f.a, MND_IP4(9, 9, 9, 9), 53);
    ping_to(&f, f.a, MND_IP4(1, 1, 1, 1));
    CHECK(f.h.ntcp == 2 && f.h.nudp == 2 && f.h.nicmp == 1);
    mnd_net_tcp_connected(f.net, f.h.tcp[0].conn, true);
    th_clear(&f.h);
    mnd_fw_config cfg = {.nrules = 1};
    cfg.rules[0] = addr_rule(MND_FW_DENY, 0, MND_IP4(1, 1, 1, 1), 32, 0, 0);
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    CHECK(f.h.tcp[0].closed && f.h.tcp[0].aborted && last_is_reset(&f, f.a));
    CHECK(!f.h.udp[0].open && !f.h.icmp[0].open);
    CHECK(f.h.tcp[1].open && f.h.udp[1].open);
    teardown(&f);
}

/* Each VM has its own firewall: a change to one leaves the others and what
 * they have open alone, and a new VM starts from the defaults. */
static void test_each_vm_has_its_own_firewall(void) {
    static fixture f;
    setup_fw(&f);
    lease(&f, f.b);
    mnd_fw_config open_lan = {.allow_lan = true};
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &open_lan) == 0);
    udp_to(&f, f.a, MND_IP4(192, 168, 1, 5), 53);
    CHECK(f.h.nudp == 1);
    udp_to(&f, f.b, MND_IP4(192, 168, 1, 5), 53);
    CHECK(f.h.nudp == 1 && stats(&f, f.b).dropped_firewall == 1);
    /* Hostname rules use the names this VM resolved. */
    mnd_fw_config gh = {.allowlist = true, .nrules = 1};
    gh.rules[0] = host_rule(MND_FW_ALLOW, "github.com");
    CHECK(mnd_net_set_port_firewall(f.net, f.b, &gh) == 0);
    resolve(&f, f.b, "github.com", MND_IP4(140, 82, 112, 3));
    syn_to(&f, f.b, MND_IP4(140, 82, 112, 3), 443, 40000);
    syn_to(&f, f.a, MND_IP4(1, 1, 1, 1), 443, 40001);
    syn_to(&f, f.b, MND_IP4(1, 1, 1, 1), 443, 40002); /* b: allowlist */
    CHECK(f.h.ntcp == 2 && f.h.tcp[0].dst == MND_IP4(140, 82, 112, 3) && f.h.tcp[1].dst == MND_IP4(1, 1, 1, 1));
    /* Denying 1.1.1.1 for b closes nothing of a's. */
    udp_to(&f, f.a, MND_IP4(1, 1, 1, 1), 53);
    mnd_fw_config no_one = {.nrules = 1};
    no_one.rules[0] = addr_rule(MND_FW_DENY, 0, MND_IP4(1, 1, 1, 1), 32, 0, 0);
    CHECK(mnd_net_set_port_firewall(f.net, f.b, &no_one) == 0);
    CHECK(f.h.tcp[1].open && f.h.udp[1].open);
    CHECK(f.h.tcp[0].open); /* 140.82.112.3 is still fine for b */
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &no_one) == 0);
    CHECK(f.h.tcp[1].closed && !f.h.udp[1].open);
    /* A VM that leaves takes its firewall with it; the next one starts afresh. */
    mnd_net_remove_port(f.net, f.a);
    int c = add_vm(&f, th_mac(1));
    CHECK(c >= 0);
    mnd_ip4 c_ip = lease(&f, c);
    CHECK(c_ip != 0);
    udp_to(&f, c, MND_IP4(1, 1, 1, 1), 53);
    udp_to(&f, c, MND_IP4(192, 168, 1, 5), 53);
    CHECK(f.h.nudp == 3 && f.h.udp[2].dst == MND_IP4(1, 1, 1, 1));
    teardown(&f);
}

/* Ports on networks that do not leave may have one too (it has nothing to
 * decide there), so a VM's firewall can be set whatever it joined. */
static void test_any_port_takes_a_firewall(void) {
    static fixture f;
    setup_kind(&f, MND_NET_INTERNAL, 24);
    mnd_fw_config cfg = {.allow_lan = true};
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    teardown(&f);
}

/* ---- Monitor mode ---------------------------------------------------------------------- */

/* What no rule decides is asked about (once while pending), not refused:
 * the packet is dropped quietly so the VM retries, and the answer comes
 * back as a session rule. */
static void test_monitor_asks(void) {
    static fixture f;
    setup_fw(&f);
    mnd_fw_config cfg = {.monitor = true, .nrules = 1};
    cfg.rules[0] = addr_rule(MND_FW_ALLOW, MND_IPPROTO_TCP, MND_IP4(1, 1, 1, 1), 32, 443, 443);
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    syn_to(&f, f.a, MND_IP4(1, 1, 1, 1), 443, 40000); /* a rule decides */
    CHECK(f.h.ntcp == 1 && f.h.nasks == 0);
    th_clear(&f.h);
    syn_to(&f, f.a, MND_IP4(8, 8, 8, 8), 443, 40001);
    CHECK(f.h.ntcp == 1 && f.h.count == 0); /* no reset: the VM retries */
    CHECK(f.h.nasks == 1 && f.h.asks[0].port == f.a && f.h.asks[0].proto == MND_IPPROTO_TCP);
    CHECK(f.h.asks[0].dst == MND_IP4(8, 8, 8, 8) && f.h.asks[0].dport == 443);
    syn_to(&f, f.a, MND_IP4(8, 8, 8, 8), 443, 40001); /* retransmitted: still pending */
    CHECK(f.h.nasks == 1);
    udp_to(&f, f.a, MND_IP4(8, 8, 8, 8), 53);
    ping_to(&f, f.a, MND_IP4(8, 8, 8, 8));
    udp_to(&f, f.a, MND_IP4(192, 168, 1, 1), 53); /* the LAN too, unless allowed */
    CHECK(f.h.nasks == 4 && f.h.count == 0 && f.h.nudp == 0 && f.h.nicmp == 0);
    CHECK(f.h.asks[1].proto == MND_IPPROTO_UDP && f.h.asks[1].dport == 53);
    CHECK(f.h.asks[2].proto == MND_IPPROTO_ICMP && f.h.asks[2].dport == 0);
    /* Answers. */
    mnd_fw_rule allow = addr_rule(MND_FW_ALLOW, MND_IPPROTO_TCP, MND_IP4(8, 8, 8, 8), 32, 443, 443);
    CHECK(mnd_net_add_session_rule(f.net, f.a, &allow) == 0);
    syn_to(&f, f.a, MND_IP4(8, 8, 8, 8), 443, 40001);
    CHECK(f.h.ntcp == 2);
    mnd_fw_rule deny = addr_rule(MND_FW_DENY, MND_IPPROTO_UDP, MND_IP4(8, 8, 8, 8), 32, 0, 0);
    CHECK(mnd_net_add_session_rule(f.net, f.a, &deny) == 0);
    th_clear(&f.h);
    udp_to(&f, f.a, MND_IP4(8, 8, 8, 8), 53);
    uint8_t type = 0, code = 0;
    mnd_ip4 quoted = 0;
    CHECK(last_icmp(&f, f.a, &type, &code, &quoted) == 0 && type == 3 && code == 13);
    CHECK(f.h.nasks == 4);
    /* Forgetting the session (the VM stopped): asked again. */
    mnd_net_clear_session(f.net, f.a);
    syn_to(&f, f.a, MND_IP4(8, 8, 8, 8), 443, 40002);
    CHECK(f.h.ntcp == 2 && f.h.nasks == 5);
    /* Monitor off: the usual fallback. */
    cfg.monitor = false;
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    syn_to(&f, f.a, MND_IP4(8, 8, 8, 8), 443, 40003);
    CHECK(f.h.ntcp == 3 && f.h.nasks == 5);
    teardown(&f);
}

/* A session rule by name: the domain and its subdomains, at any address.
 * In monitor mode the lookup is asked about first, and its answer covers
 * the connections to what the name resolved to. */
static void test_monitor_answers_by_name(void) {
    static fixture f;
    setup_fw(&f);
    mnd_fw_config cfg = {.monitor = true};
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    resolve(&f, f.a, "www.example.com", MND_IP4(93, 184, 216, 34));
    CHECK(f.h.nlookups == 1 && f.h.dns_count == 0); /* held, asked by name */
    mnd_fw_rule r = host_rule(MND_FW_ALLOW, "example.com");
    CHECK(mnd_net_add_session_rule(f.net, f.a, &r) == 0);
    resolve(&f, f.a, "www.example.com", MND_IP4(93, 184, 216, 34));
    CHECK(f.h.dns_count == 1);
    syn_to(&f, f.a, MND_IP4(93, 184, 216, 34), 443, 40000);
    CHECK(f.h.ntcp == 1 && f.h.nasks == 0);
    syn_to(&f, f.a, MND_IP4(93, 184, 216, 35), 443, 40001); /* no name known: asked */
    CHECK(f.h.ntcp == 1 && f.h.nasks == 1);
    /* Invalid answers and unknown ports are refused. */
    mnd_fw_rule bad = host_rule(MND_FW_ALLOW, "no way");
    CHECK(mnd_net_add_session_rule(f.net, f.a, &bad) == -1);
    CHECK(mnd_net_add_session_rule(f.net, 2047, &r) == -1);
    CHECK(mnd_net_add_session_rule(f.net, f.a, NULL) == -1);
    mnd_net_clear_session(f.net, 2047); /* harmless */
    teardown(&f);
}

/* Asks are bounded per VM and expire: a VM cannot flood the user, and a
 * question left unanswered is asked again later. Turning monitor mode on
 * closes nothing that is open. */
static void test_monitor_limits(void) {
    static fixture f;
    setup_fw(&f);
    syn_to(&f, f.a, MND_IP4(9, 9, 9, 9), 443, 39999);
    CHECK(f.h.ntcp == 1);
    mnd_fw_config cfg = {.monitor = true};
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    CHECK(!f.h.tcp[0].closed);
    for (int i = 0; i < MND_NET_MAX_ASKS_PER_PORT + 4; i++) {
        th_clear(&f.h);
        syn_to(&f, f.a, MND_IP4(8, 8, 8, (uint8_t)(1 + i)), 443, (uint16_t)(40000 + i));
        if (i >= MND_NET_MAX_ASKS_PER_PORT) CHECK(last_is_reset(&f, f.a)); /* cannot ask: refused */
    }
    CHECK(f.h.nasks == MND_NET_MAX_ASKS_PER_PORT);
    f.h.now += MND_NET_ASK_TTL_MS + 1;
    syn_to(&f, f.a, MND_IP4(8, 8, 8, 1), 443, 40000);
    CHECK(f.h.nasks == MND_NET_MAX_ASKS_PER_PORT + 1);
    /* Another VM has its own room. */
    lease(&f, f.b);
    mnd_net_set_port_firewall(f.net, f.b, &cfg);
    syn_to(&f, f.b, MND_IP4(8, 8, 8, 1), 443, 40000);
    CHECK(f.h.nasks == MND_NET_MAX_ASKS_PER_PORT + 2 && f.h.asks[f.h.nasks - 1].port == f.b);
    /* Leaving frees everything (ASan checks). */
    mnd_fw_rule r = addr_rule(MND_FW_ALLOW, 0, MND_IP4(8, 8, 8, 1), 32, 0, 0);
    CHECK(mnd_net_add_session_rule(f.net, f.b, &r) == 0);
    mnd_net_remove_port(f.net, f.b);
    teardown(&f);
}

static void test_invalid_configurations(void) {
    static fixture f;
    setup_fw(&f);
    mnd_fw_config cfg = {.nrules = 1};
    const char *bad_patterns[] = {"ex ample.com", "*github.com", "a.*.com", "*",       "*.",
                                  ".com",         "a..com",      "com.",    "exa$mple.com", "*.*.com"};
    for (size_t i = 0; i < sizeof bad_patterns / sizeof bad_patterns[0]; i++) {
        cfg.rules[0] = host_rule(MND_FW_ALLOW, bad_patterns[i]);
        CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == -1);
    }
    cfg.rules[0] = addr_rule(MND_FW_ALLOW, 0, 0, 33, 0, 0); /* prefix */
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == -1);
    cfg.rules[0] = addr_rule(MND_FW_ALLOW, 0, MND_IP4(10, 0, 0, 1), 8, 0, 0); /* host bits */
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == -1);
    cfg.rules[0] = addr_rule(MND_FW_ALLOW, 0, MND_IP4(10, 0, 0, 0), 8, 9000, 8000); /* ports backwards */
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == -1);
    cfg.rules[0] = addr_rule(MND_FW_ALLOW, 99, 0, 0, 0, 0); /* protocol */
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == -1);
    cfg.rules[0] = addr_rule((mnd_fw_action)7, 0, 0, 0, 0, 0); /* action */
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == -1);
    cfg.rules[0] = addr_rule(MND_FW_ALLOW, 0, 0, 0, 0, 0);
    cfg.nrules = MND_NET_MAX_FW_RULES + 1;
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == -1);
    cfg.nrules = -1;
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == -1);
    cfg.nrules = 1;
    CHECK(mnd_net_set_port_firewall(f.net, 2047, &cfg) == -1); /* no such port */
    CHECK(mnd_net_set_port_firewall(f.net, -1, &cfg) == -1);
    CHECK(mnd_net_set_port_firewall(f.net, 1 << 20, &cfg) == -1);
    CHECK(mnd_net_set_port_firewall(f.net, f.a, NULL) == -1);
    /* A refused configuration leaves the old one in place: the LAN is still denied. */
    udp_to(&f, f.a, MND_IP4(192, 168, 1, 1), 53);
    CHECK(f.h.nudp == 0);
    /* Valid edge cases. */
    cfg.rules[0] = host_rule(MND_FW_ALLOW, "*.co.uk");
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    cfg.rules[0] = host_rule(MND_FW_ALLOW, "localhost");
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    cfg.rules[0] = addr_rule(MND_FW_DENY, MND_IPPROTO_UDP, 0, 0, 1, 65535);
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    teardown(&f);
}

int main(void) {
    fprintf(stderr, "mnd_net firewall tests\n");
    RUN(test_the_lan_is_denied_by_default);
    RUN(test_the_macs_own_networks_count_as_lan);
    RUN(test_allow_lan);
    RUN(test_address_and_port_rules);
    RUN(test_the_first_match_decides);
    RUN(test_allowlist_with_hostnames);
    RUN(test_a_name_never_opens_the_lan);
    RUN(test_blocking_a_domain);
    RUN(test_changes_apply_to_what_is_open);
    RUN(test_each_vm_has_its_own_firewall);
    RUN(test_a_deny_by_name_holds_whatever_else_points_there);
    RUN(test_names_are_each_vms_own);
    RUN(test_any_port_takes_a_firewall);
    RUN(test_monitor_asks);
    RUN(test_monitor_answers_by_name);
    RUN(test_monitor_limits);
    RUN(test_invalid_configurations);
    TEST_MAIN_END();
}
