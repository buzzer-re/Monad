/* Tests for DNS through the gateway: forwarding to the Mac, answers checked
 * and truncated, bounded pending queries, and the names remembered. */
#include "net_test_dns.h"
#include "net_test_gw.h"

/* A query from `port` (which has a lease) to the gateway. */
static void ask(fixture *f, int port, uint16_t sport, const uint8_t *q, size_t n) {
    mnd_ip4 ip = 0;
    CHECK(mnd_net_port_ip(f->net, port, &ip) == 0);
    send_udp(f, port, port_mac(f, port), f->gw_mac, ip, GW, sport, MND_DNS_PORT, q, n);
}

/* The last DNS reply delivered to `port`: its payload and UDP header. */
static int reply(fixture *f, int port, const uint8_t **payload, size_t *len, mnd_udp *udp_out) {
    const th_frame *fr = th_last(&f->h, port);
    mnd_eth eth;
    mnd_ip ip;
    static mnd_udp udp;
    if (!fr || mnd_eth_parse(fr->data, fr->len, &eth) || mnd_ip_parse(eth.payload, eth.len, &ip)) return -1;
    if (ip.proto != MND_IPPROTO_UDP || ip.src != GW || mnd_udp_parse(&ip, &udp) || udp.sport != MND_DNS_PORT) return -1;
    if (!mnd_mac_eq(eth.src, f->gw_mac)) return -1;
    *payload = udp.payload;
    *len = udp.len;
    if (udp_out) *udp_out = udp;
    return 0;
}

/* An answer to "name" with `count` A records starting at 10.9.0.1. */
static size_t answer_for(uint8_t *p, uint16_t id, const char *name, int count, uint32_t ttl) {
    size_t at = td_response(p, id, name, MND_DNS_TYPE_A);
    for (int i = 0; i < count; i++) at = td_a(p, at, 12, MND_IP4(10, 9, (uint8_t)(i >> 8), (uint8_t)(i + 1)), ttl);
    td_set_ancount(p, (uint16_t)count);
    return at;
}

static void test_forwarded_and_answered(void) {
    static fixture f;
    setup(&f);
    mnd_ip4 a_ip = lease(&f, f.a);
    uint8_t q[512], p[1500];
    size_t qn = td_query(q, 0x4242, "Example.COM", MND_DNS_TYPE_A, 0);
    ask(&f, f.a, 40000, q, qn);
    CHECK(f.h.count == 0); /* nothing until the Mac answers */
    CHECK(f.h.dns_count == 1 && f.h.dns_len == qn && memcmp(f.h.dns_msg, q, qn) == 0);
    uint32_t id = f.h.dns_id;
    size_t n = answer_for(p, 0x4242, "example.com", 2, 300);
    mnd_net_dns_answer(f.net, id, p, n);
    const uint8_t *got;
    size_t len;
    mnd_udp udp;
    CHECK(th_count(&f.h, f.a) == 1 && th_count(&f.h, f.b) == 0);
    CHECK(reply(&f, f.a, &got, &len, &udp) == 0 && udp.dport == 40000);
    CHECK(len == n && memcmp(got, p, n) == 0);
    const th_frame *fr = th_last(&f.h, f.a);
    mnd_eth eth;
    mnd_ip ip;
    CHECK(mnd_eth_parse(fr->data, fr->len, &eth) == 0 && mnd_ip_parse(eth.payload, eth.len, &ip) == 0);
    CHECK(ip.dst == a_ip && mnd_mac_eq(eth.dst, th_mac(1)));
    /* Answered once: a second answer for the same id is ignored. */
    th_clear(&f.h);
    mnd_net_dns_answer(f.net, id, p, n);
    mnd_net_dns_answer(f.net, id + 100, p, n);
    CHECK(f.h.count == 0);
    teardown(&f);
}

static void test_answers_are_checked(void) {
    static fixture f;
    setup(&f);
    lease(&f, f.a);
    uint8_t q[512], p[1500];
    const uint8_t *got;
    size_t len;
    ask(&f, f.a, 40000, q, td_query(q, 7, "example.com", MND_DNS_TYPE_A, 0));
    /* An answer to another question: dropped, the query stays pending. */
    size_t n = answer_for(p, 7, "example.org", 1, 60);
    mnd_net_dns_answer(f.net, f.h.dns_id, p, n);
    CHECK(f.h.count == 0);
    /* The transaction id is the VM's, whatever the Mac's answer carries. */
    n = answer_for(p, 0x9999, "example.com", 1, 60);
    mnd_net_dns_answer(f.net, f.h.dns_id, p, n);
    CHECK(reply(&f, f.a, &got, &len, NULL) == 0 && len == n && got[0] == 0 && got[1] == 7);
    /* Resolution failed: SERVFAIL with the question. */
    th_clear(&f.h);
    size_t qn = td_query(q, 8, "down.example", MND_DNS_TYPE_A, 0);
    ask(&f, f.a, 40001, q, qn);
    mnd_net_dns_answer(f.net, f.h.dns_id, NULL, 0);
    CHECK(reply(&f, f.a, &got, &len, NULL) == 0 && len == qn && (got[3] & 0x0f) == MND_DNS_RCODE_SERVFAIL);
    teardown(&f);
}

static void test_truncation(void) {
    static fixture f;
    setup(&f);
    lease(&f, f.a);
    uint8_t q[512], p[2048];
    const uint8_t *got;
    size_t len;
    /* 40 records (669 bytes) for a client without EDNS: TC, question only. */
    size_t qn = td_query(q, 1, "big.example", MND_DNS_TYPE_A, 0);
    ask(&f, f.a, 40000, q, qn);
    size_t n = answer_for(p, 1, "big.example", 40, 60);
    CHECK(n > 512);
    mnd_net_dns_answer(f.net, f.h.dns_id, p, n);
    CHECK(reply(&f, f.a, &got, &len, NULL) == 0 && len == qn && (got[2] & 0x02));
    /* With EDNS 1232 it fits. */
    th_clear(&f.h);
    ask(&f, f.a, 40000, q, td_query(q, 1, "big.example", MND_DNS_TYPE_A, 1232));
    mnd_net_dns_answer(f.net, f.h.dns_id, p, n);
    CHECK(reply(&f, f.a, &got, &len, NULL) == 0 && len == n && !(got[2] & 0x02));
    /* 100 records (1629 bytes): more than one datagram holds, even with EDNS 4096. */
    th_clear(&f.h);
    ask(&f, f.a, 40000, q, td_query(q, 1, "big.example", MND_DNS_TYPE_A, 4096));
    n = answer_for(p, 1, "big.example", 100, 60);
    mnd_net_dns_answer(f.net, f.h.dns_id, p, n);
    CHECK(reply(&f, f.a, &got, &len, NULL) == 0 && len < 100 && (got[2] & 0x02));
    teardown(&f);
}

static void test_queries_that_are_not_forwarded(void) {
    static fixture f;
    setup(&f);
    lease(&f, f.a);
    uint8_t q[512];
    /* Malformed. */
    size_t qn = td_query(q, 1, "example.com", MND_DNS_TYPE_A, 0);
    q[2] |= 0x80;
    ask(&f, f.a, 40000, q, qn);
    CHECK(f.h.dns_count == 0 && f.h.count == 0 && stats(&f, f.a).dropped_malformed == 1);
    /* To another resolver: plain UDP through NAT, not the forwarder. */
    mnd_ip4 a_ip;
    mnd_net_port_ip(f.net, f.a, &a_ip);
    qn = td_query(q, 1, "example.com", MND_DNS_TYPE_A, 0);
    send_udp(&f, f.a, th_mac(1), f.gw_mac, a_ip, MND_IP4(8, 8, 8, 8), 40000, 53, q, qn);
    CHECK(f.h.dns_count == 0 && f.h.udp_opened == 1 && f.h.udp[0].dst == MND_IP4(8, 8, 8, 8));
    teardown(&f);

    /* Internal networks have no DNS. */
    setup_kind(&f, MND_NET_INTERNAL, 24);
    lease(&f, f.a);
    ask(&f, f.a, 40000, q, qn);
    CHECK(f.h.dns_count == 0 && f.h.count == 0 && stats(&f, f.a).dropped_policy == 1);
    teardown(&f);
}

static void test_without_a_resolver_the_answer_is_servfail(void) {
    static fixture f;
    setup(&f);
    lease(&f, f.a);
    mnd_net_destroy(f.net);
    /* The same network, from a host without dns_query. */
    mnd_net_host host = {.ctx = &f.h, .now_ms = th_now, .send_frame = th_send};
    f.net = mnd_net_create(&host);
    mnd_net_config cfg = {.kind = MND_NET_NAT, .subnet = MND_IP4(10, 77, 0, 0), .prefix = 24};
    f.n = mnd_net_add_network(f.net, &cfg);
    f.nvms = 0;
    f.a = add_vm(&f, th_mac(1));
    CHECK(lease(&f, f.a) != 0);
    uint8_t q[512];
    const uint8_t *got;
    size_t len;
    size_t qn = td_query(q, 3, "example.com", MND_DNS_TYPE_A, 0);
    ask(&f, f.a, 40000, q, qn);
    CHECK(reply(&f, f.a, &got, &len, NULL) == 0 && len == qn && (got[3] & 0x0f) == MND_DNS_RCODE_SERVFAIL);
    teardown(&f);
}

static void test_pending_queries_are_bounded(void) {
    static fixture f;
    setup(&f);
    uint8_t q[512];
    size_t qn = td_query(q, 1, "example.com", MND_DNS_TYPE_A, 0);
    lease(&f, f.a);
    for (int i = 0; i < MND_NET_MAX_DNS_PENDING_PER_PORT + 8; i++) ask(&f, f.a, (uint16_t)(40000 + i), q, qn);
    CHECK(f.h.dns_count == MND_NET_MAX_DNS_PENDING_PER_PORT);
    CHECK(stats(&f, f.a).dropped_policy == 8);
    /* Across ports too. */
    int per = MND_NET_MAX_DNS_PENDING_PER_PORT;
    int ports = MND_NET_MAX_DNS_PENDING / per; /* a already fills one share */
    for (int v = 0; v < ports; v++) {
        int port = add_vm(&f, th_mac((uint8_t)(10 + v)));
        CHECK(lease(&f, port) != 0);
        for (int i = 0; i < per; i++) ask(&f, port, (uint16_t)(40000 + i), q, qn);
    }
    CHECK(f.h.dns_count == MND_NET_MAX_DNS_PENDING);
    /* Unanswered queries time out and free their place. */
    f.h.now += MND_NET_DNS_TIMEOUT_MS + 1;
    int before = f.h.dns_count;
    uint32_t stale = f.h.dns_id;
    ask(&f, f.a, 50000, q, qn);
    CHECK(f.h.dns_count == before + 1);
    /* A late answer to an expired query is ignored. */
    th_clear(&f.h);
    uint8_t p[512];
    size_t n = answer_for(p, 1, "example.com", 1, 60);
    mnd_net_dns_answer(f.net, stale, p, n);
    CHECK(f.h.count == 0);
    teardown(&f);
}

static void test_answers_for_a_vm_that_left(void) {
    static fixture f;
    setup(&f);
    lease(&f, f.a);
    uint8_t q[512], p[512];
    ask(&f, f.a, 40000, q, td_query(q, 1, "example.com", MND_DNS_TYPE_A, 0));
    uint32_t id = f.h.dns_id;
    int gone = f.a;
    mnd_net_remove_port(f.net, f.a);
    /* Another VM ends up in the same port slot. */
    int c = -1;
    for (int i = 0; i < 4 * MND_NET_MAX_NETWORKS * MND_NET_MAX_PORTS && c != gone; i++) {
        c = mnd_net_add_port(f.net, f.n, th_mac(3));
        if (c != gone) mnd_net_remove_port(f.net, c);
    }
    CHECK(c == gone);
    mnd_net_dns_answer(f.net, id, p, answer_for(p, 1, "example.com", 1, 60));
    CHECK(f.h.count == 0);
    teardown(&f);
}

static void test_names_are_remembered(void) {
    static fixture f;
    setup(&f);
    lease(&f, f.a);
    uint8_t q[512], p[512];
    const char *names[4];
    /* www.github.com CNAME github.com, A 140.82.112.3 */
    ask(&f, f.a, 40000, q, td_query(q, 5, "www.github.com", MND_DNS_TYPE_A, 0));
    size_t at = td_response(p, 5, "www.github.com", MND_DNS_TYPE_A);
    uint8_t target[2] = {0xc0, 16};
    at = td_rr_ptr(p, at, 12, MND_DNS_TYPE_CNAME, 60, target, 2);
    at = td_a(p, at, 16, MND_IP4(140, 82, 112, 3), 300);
    td_set_ancount(p, 2);
    mnd_net_dns_answer(f.net, f.h.dns_id, p, at);
    int n = mnd_net_dns_names(f.net, f.a, MND_IP4(140, 82, 112, 3), names, 4);
    CHECK(n == 2);
    if (n == 2) {
        CHECK_STR(names[0], "github.com");
        CHECK_STR(names[1], "www.github.com");
    }
    CHECK(mnd_net_dns_names(f.net, f.a, MND_IP4(140, 82, 112, 4), names, 4) == 0);
    CHECK(mnd_net_dns_names(f.net, f.a, MND_IP4(140, 82, 112, 3), names, 1) == 1);
    /* Per VM: another VM on the network learns its own pairs. */
    CHECK(mnd_net_dns_names(f.net, f.b, MND_IP4(140, 82, 112, 3), names, 4) == 0);
    lease(&f, f.b);
    ask(&f, f.b, 40000, q, td_query(q, 5, "github.com", MND_DNS_TYPE_A, 0));
    mnd_net_dns_answer(f.net, f.h.dns_id, p, answer_for(p, 5, "github.com", 1, 300));
    CHECK(mnd_net_dns_names(f.net, f.b, MND_IP4(10, 9, 0, 1), names, 4) == 1);
    CHECK(mnd_net_dns_names(f.net, f.a, MND_IP4(10, 9, 0, 1), names, 4) == 0);
    /* A VM that leaves takes its names: the next one in its slot has none. */
    int gone = f.b;
    mnd_net_remove_port(f.net, f.b);
    int c = -1;
    for (int i = 0; i < 4 * MND_NET_MAX_NETWORKS * MND_NET_MAX_PORTS && c != gone; i++) {
        c = mnd_net_add_port(f.net, f.n, th_mac(3));
        if (c != gone) mnd_net_remove_port(f.net, c);
    }
    CHECK(c == gone);
    CHECK(mnd_net_dns_names(f.net, c, MND_IP4(10, 9, 0, 1), names, 4) == 0);
    /* Kept for the TTL (300 s)… */
    f.h.now += 299 * 1000;
    CHECK(mnd_net_dns_names(f.net, f.a, MND_IP4(140, 82, 112, 3), names, 4) == 2);
    f.h.now += 2 * 1000;
    CHECK(mnd_net_dns_names(f.net, f.a, MND_IP4(140, 82, 112, 3), names, 4) == 0);
    /* …and at least a minute, even with TTL 0. */
    ask(&f, f.a, 40000, q, td_query(q, 6, "zero.example", MND_DNS_TYPE_A, 0));
    mnd_net_dns_answer(f.net, f.h.dns_id, p, answer_for(p, 6, "zero.example", 1, 0));
    f.h.now += 59 * 1000;
    CHECK(mnd_net_dns_names(f.net, f.a, MND_IP4(10, 9, 0, 1), names, 4) == 1);
    f.h.now += 2 * 1000;
    CHECK(mnd_net_dns_names(f.net, f.a, MND_IP4(10, 9, 0, 1), names, 4) == 0);
    teardown(&f);
}

/* Names with characters no rule can use (a comma, "!") are answered but
 * never remembered: the monitor-mode question must not show a name the
 * guest made up to look like another (F-04). */
static void test_odd_names_are_not_remembered(void) {
    static fixture f;
    setup(&f);
    lease(&f, f.a);
    uint8_t q[512], p[512];
    const char *names[4];
    const char *odd[] = {"github.com,x.attacker.test", "git!hub.com", "a~b.example"};
    for (int i = 0; i < 3; i++) {
        th_clear(&f.h);
        ask(&f, f.a, 40000, q, td_query(q, (uint16_t)(7 + i), odd[i], MND_DNS_TYPE_A, 0));
        mnd_net_dns_answer(f.net, f.h.dns_id, p, answer_for(p, (uint16_t)(7 + i), odd[i], 1, 300));
        CHECK(th_count(&f.h, f.a) == 1); /* the VM still gets its answer */
    }
    CHECK(mnd_net_dns_names(f.net, f.a, MND_IP4(10, 9, 0, 1), names, 4) == 0);
    ask(&f, f.a, 40000, q, td_query(q, 11, "ok_name-1.example", MND_DNS_TYPE_A, 0));
    mnd_net_dns_answer(f.net, f.h.dns_id, p, answer_for(p, 11, "ok_name-1.example", 1, 300));
    CHECK(mnd_net_dns_names(f.net, f.a, MND_IP4(10, 9, 0, 1), names, 4) == 1);
    teardown(&f);
}

static void test_names_table_is_bounded(void) {
    static fixture f;
    setup(&f);
    lease(&f, f.a);
    uint8_t q[512], p[2048];
    /* 20 answers of 100 addresses each: 2000 pairs into a 1024 table. */
    for (int i = 0; i < 20; i++) {
        char name[32];
        snprintf(name, sizeof name, "host%d.example", i);
        ask(&f, f.a, 40000, q, td_query(q, 1, name, MND_DNS_TYPE_A, 4096));
        size_t at = td_response(p, 1, name, MND_DNS_TYPE_A);
        for (int k = 0; k < 90; k++) at = td_a(p, at, 12, MND_IP4(10, 50, (uint8_t)i, (uint8_t)k), 600);
        td_set_ancount(p, 90);
        mnd_net_dns_answer(f.net, f.h.dns_id, p, at);
    }
    int total = 0;
    const char *names[4];
    for (int i = 0; i < 20; i++)
        for (int k = 0; k < 90; k++) total += mnd_net_dns_names(f.net, f.a, MND_IP4(10, 50, (uint8_t)i, (uint8_t)k), names, 4);
    CHECK(total == MND_NET_MAX_DNS_NAMES);
    /* The newest answer is there. */
    CHECK(mnd_net_dns_names(f.net, f.a, MND_IP4(10, 50, 19, 89), names, 4) == 1);
    teardown(&f);
}

/* The rcode of the last DNS reply to `port`, or -1. */
static int last_rcode(fixture *f, int port) {
    const uint8_t *got;
    size_t len;
    if (reply(f, port, &got, &len, NULL) != 0 || len < 12) return -1;
    return got[3] & 0x0f;
}

static mnd_fw_rule name_rule(mnd_fw_action action, const char *pattern) {
    mnd_fw_rule r = {.action = action};
    snprintf(r.host, sizeof r.host, "%s", pattern);
    return r;
}

/* Lookups follow the VM's firewall (F-10): with only what the rules allow,
 * a name no allow rule covers is refused before it leaves (an allow for
 * some ports covers the lookup). Otherwise every lookup goes: a deny by name
 * holds on the connection, which needs the name learned from the answer. */
static void test_lookups_follow_the_firewall(void) {
    static fixture f;
    setup(&f);
    lease(&f, f.a);
    uint8_t q[512];
    mnd_fw_config cfg = {.allowlist = true, .nrules = 1};
    cfg.rules[0] = name_rule(MND_FW_ALLOW, "example.com");
    cfg.rules[0].proto = MND_IPPROTO_TCP;
    cfg.rules[0].port_min = cfg.rules[0].port_max = 443;
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    ask(&f, f.a, 40000, q, td_query(q, 1, "a.example.com", MND_DNS_TYPE_A, 0));
    CHECK(f.h.dns_count == 1 && th_count(&f.h, f.a) == 0); /* forwarded, waiting for the Mac */
    ask(&f, f.a, 40001, q, td_query(q, 2, "c2VjcmV0.exfil.attacker.test", MND_DNS_TYPE_A, 0));
    CHECK(f.h.dns_count == 1);
    CHECK(last_rcode(&f, f.a) == MND_DNS_RCODE_REFUSED);
    CHECK(stats(&f, f.a).dropped_firewall == 1);
    /* A deny of the whole name refuses it here too; one about some ports does not. */
    mnd_fw_config strict = {.allowlist = true, .nrules = 3};
    strict.rules[0] = name_rule(MND_FW_DENY, "blocked.test");
    strict.rules[1] = name_rule(MND_FW_DENY, "mail.test");
    strict.rules[1].proto = MND_IPPROTO_TCP;
    strict.rules[1].port_min = strict.rules[1].port_max = 25;
    strict.rules[2] = name_rule(MND_FW_ALLOW, "test");
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &strict) == 0);
    th_clear(&f.h);
    ask(&f, f.a, 40002, q, td_query(q, 3, "www.blocked.test", MND_DNS_TYPE_A, 0));
    CHECK(f.h.dns_count == 1 && last_rcode(&f, f.a) == MND_DNS_RCODE_REFUSED);
    ask(&f, f.a, 40003, q, td_query(q, 4, "mail.test", MND_DNS_TYPE_A, 0));
    CHECK(f.h.dns_count == 2);
    /* Not confined: every lookup goes, denied names included. */
    mnd_fw_config open = {.nrules = 1};
    open.rules[0] = name_rule(MND_FW_DENY, "blocked.test");
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &open) == 0);
    ask(&f, f.a, 40004, q, td_query(q, 5, "www.blocked.test", MND_DNS_TYPE_A, 0));
    ask(&f, f.a, 40005, q, td_query(q, 6, "anything.example.org", MND_DNS_TYPE_A, 0));
    CHECK(f.h.dns_count == 4);
    teardown(&f);
}

/* In monitor mode a lookup no rule decides is asked about once, by name,
 * and waits; the answer decides the next try. */
static void test_lookups_in_monitor_mode_are_asked(void) {
    static fixture f;
    setup(&f);
    lease(&f, f.a);
    uint8_t q[512];
    mnd_fw_config cfg = {.monitor = true};
    CHECK(mnd_net_set_port_firewall(f.net, f.a, &cfg) == 0);
    ask(&f, f.a, 40000, q, td_query(q, 1, "new.example", MND_DNS_TYPE_A, 0));
    ask(&f, f.a, 40000, q, td_query(q, 1, "new.example", MND_DNS_TYPE_A, 0));
    CHECK(f.h.dns_count == 0 && th_count(&f.h, f.a) == 0); /* held: the resolver tries again */
    CHECK(f.h.nlookups == 1 && f.h.lookup_ports[0] == f.a);
    CHECK_STR(f.h.lookups[0], "new.example");
    mnd_fw_rule allow = name_rule(MND_FW_ALLOW, "new.example");
    CHECK(mnd_net_add_session_rule(f.net, f.a, &allow) == 0);
    ask(&f, f.a, 40000, q, td_query(q, 1, "new.example", MND_DNS_TYPE_A, 0));
    CHECK(f.h.dns_count == 1);
    /* Blocked: refused at once. */
    mnd_fw_rule deny = name_rule(MND_FW_DENY, "bad.example");
    CHECK(mnd_net_add_session_rule(f.net, f.a, &deny) == 0);
    ask(&f, f.a, 40001, q, td_query(q, 2, "x.bad.example", MND_DNS_TYPE_A, 0));
    CHECK(f.h.dns_count == 1 && last_rcode(&f, f.a) == MND_DNS_RCODE_REFUSED && f.h.nlookups == 1);
    teardown(&f);
}

/* Host-only networks: nothing leaves, lookups included, unless the network
 * says its VMs may look names up through the Mac. */
static void test_host_only_networks_look_up_only_when_allowed(void) {
    static fixture f;
    setup_kind(&f, MND_NET_HOST_ONLY, 24);
    lease(&f, f.a);
    uint8_t q[512];
    ask(&f, f.a, 40000, q, td_query(q, 1, "example.com", MND_DNS_TYPE_A, 0));
    CHECK(f.h.dns_count == 0 && last_rcode(&f, f.a) == MND_DNS_RCODE_REFUSED);
    teardown(&f);
    setup_cfg(&f, (mnd_net_config){.kind = MND_NET_HOST_ONLY, .subnet = MND_IP4(10, 77, 0, 0), .prefix = 24,
                                   .host_only_dns = true});
    lease(&f, f.a);
    ask(&f, f.a, 40000, q, td_query(q, 1, "example.com", MND_DNS_TYPE_A, 0));
    CHECK(f.h.dns_count == 1);
    teardown(&f);
}

int main(void) {
    fprintf(stderr, "mnd_net DNS forwarding tests\n");
    RUN(test_forwarded_and_answered);
    RUN(test_answers_are_checked);
    RUN(test_truncation);
    RUN(test_queries_that_are_not_forwarded);
    RUN(test_without_a_resolver_the_answer_is_servfail);
    RUN(test_pending_queries_are_bounded);
    RUN(test_answers_for_a_vm_that_left);
    RUN(test_names_are_remembered);
    RUN(test_odd_names_are_not_remembered);
    RUN(test_names_table_is_bounded);
    RUN(test_lookups_follow_the_firewall);
    RUN(test_lookups_in_monitor_mode_are_asked);
    RUN(test_host_only_networks_look_up_only_when_allowed);
    TEST_MAIN_END();
}
