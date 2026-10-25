# Portable tests for Monad's pure-C backend (runs on macOS and Linux).
#   make -C CTests          # build + run under ASan/UBSan
SRC := ../Monad/Backend
CC ?= cc
CFLAGS := -std=gnu11 -g -O1 -Wall -Wextra -Wshadow -Werror \
          -fsanitize=address,undefined -fno-omit-frame-pointer -I$(SRC)
LDFLAGS := -fsanitize=address,undefined -lpthread -lz
BUILD ?= build

VT_SRC := $(wildcard $(SRC)/vt/*.c)

TESTS := test_vt test_vt_images test_qcow2 test_iso9660 test_bridge test_pty test_xz test_tar test_unpack test_rotlog test_net_frame test_net_dhcp test_net_dns test_net_switch test_net_gateway test_net_dnsfwd test_net_udp test_net_icmp test_net_tcp test_net_fw test_net_conns test_net_peers fuzz_net fuzz_vt fuzz_decoders test_loop test_netd test_netd_ctl test_netd_serve test_netd_main test_guestd

all: run

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/test_vt: test_vt.c $(VT_SRC) | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

$(BUILD)/test_vt_images: test_vt_images.c $(VT_SRC) | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

$(BUILD)/test_qcow2: test_qcow2.c $(SRC)/mnd_qcow2.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

$(BUILD)/test_iso9660: test_iso9660.c $(SRC)/mnd_iso9660.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

$(BUILD)/test_bridge: test_bridge.c $(SRC)/mnd_bridge.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

$(BUILD)/test_pty: test_pty.c $(SRC)/mnd_pty.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS) -lutil

$(BUILD)/test_guestd: test_guestd.c $(SRC)/mnd_guestd.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

NET_SRC := $(wildcard $(SRC)/net/*.c)

$(BUILD)/test_net_frame: test_net_frame.c $(SRC)/net/mnd_net_frame.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

$(BUILD)/test_net_dhcp: test_net_dhcp.c $(SRC)/net/mnd_net_dhcp.c $(SRC)/net/mnd_net_frame.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

$(BUILD)/test_net_dns: test_net_dns.c net_test_dns.h $(SRC)/net/mnd_net_dns.c $(SRC)/net/mnd_net_frame.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $(filter %.c,$^) $(LDFLAGS)

$(BUILD)/test_net_dnsfwd: test_net_dnsfwd.c net_test_dns.h net_test_gw.h $(NET_SRC) $(wildcard $(SRC)/net/*.h) net_test_host.h | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $(filter %.c,$^) $(LDFLAGS)

$(BUILD)/test_net_udp: test_net_udp.c net_test_gw.h $(NET_SRC) $(wildcard $(SRC)/net/*.h) net_test_host.h | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $(filter %.c,$^) $(LDFLAGS)

$(BUILD)/test_net_tcp: test_net_tcp.c net_test_gw.h $(NET_SRC) $(wildcard $(SRC)/net/*.h) net_test_host.h | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $(filter %.c,$^) $(LDFLAGS)

$(BUILD)/test_net_icmp: test_net_icmp.c net_test_gw.h $(NET_SRC) $(wildcard $(SRC)/net/*.h) net_test_host.h | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $(filter %.c,$^) $(LDFLAGS)

$(BUILD)/test_net_fw: test_net_fw.c net_test_dns.h net_test_gw.h $(NET_SRC) $(wildcard $(SRC)/net/*.h) net_test_host.h | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $(filter %.c,$^) $(LDFLAGS)

$(BUILD)/test_net_conns: test_net_conns.c net_test_gw.h $(NET_SRC) $(wildcard $(SRC)/net/*.h) net_test_host.h | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $(filter %.c,$^) $(LDFLAGS)

$(BUILD)/test_net_peers: test_net_peers.c net_test_gw.h $(NET_SRC) $(wildcard $(SRC)/net/*.h) net_test_host.h | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $(filter %.c,$^) $(LDFLAGS)

$(BUILD)/fuzz_net: fuzz_net.c $(NET_SRC) $(wildcard $(SRC)/net/*.h) | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $(filter %.c,$^) $(LDFLAGS)

$(BUILD)/fuzz_decoders: fuzz_decoders.c $(SRC)/mnd_qcow2.c $(SRC)/mnd_tar.c $(SRC)/mnd_xz.c $(SRC)/mnd_unpack.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

$(BUILD)/fuzz_vt: fuzz_vt.c $(VT_SRC) $(wildcard $(SRC)/vt/*.h) | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $(filter %.c,$^) $(LDFLAGS)

# Longer runs: make fuzz FUZZ_ITERS=200000 [FUZZ_SEED=n]
fuzz: $(BUILD)/fuzz_net $(BUILD)/fuzz_vt $(BUILD)/fuzz_decoders $(BUILD)/fx_v3_512.qcow2 $(BUILD)/xz_mixed.xz $(BUILD)/tar_plain.tar
	FUZZ_ITERS=$(or $(FUZZ_ITERS),100000) $(BUILD)/fuzz_net
	FUZZ_ITERS=$(or $(FUZZ_ITERS),100000) $(BUILD)/fuzz_vt
	FUZZ_ITERS=$(or $(FUZZ_ITERS),20000) $(BUILD)/fuzz_decoders $(BUILD)

$(BUILD)/test_loop: test_loop.c $(SRC)/net/mnd_loop.c $(SRC)/net/mnd_loop.h | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $(filter %.c,$^) $(LDFLAGS)

$(BUILD)/test_netd: test_netd.c net_test_dns.h $(NET_SRC) $(wildcard $(SRC)/net/*.h) | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $(filter %.c,$^) $(LDFLAGS)

$(BUILD)/test_netd_ctl: test_netd_ctl.c $(NET_SRC) $(wildcard $(SRC)/net/*.h) | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $(filter %.c,$^) $(LDFLAGS)

$(BUILD)/test_netd_serve: test_netd_serve.c $(NET_SRC) $(wildcard $(SRC)/net/*.h) | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $(filter %.c,$^) $(LDFLAGS)

$(BUILD)/test_netd_main: test_netd_main.c $(NET_SRC) $(wildcard $(SRC)/net/*.h) | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $(filter %.c,$^) $(LDFLAGS)

$(BUILD)/test_net_switch: test_net_switch.c $(NET_SRC) $(wildcard $(SRC)/net/*.h) net_test_host.h | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $(filter %.c,$^) $(LDFLAGS)

$(BUILD)/test_net_gateway: test_net_gateway.c net_test_gw.h $(NET_SRC) $(wildcard $(SRC)/net/*.h) net_test_host.h | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $(filter %.c,$^) $(LDFLAGS)

$(BUILD)/test_rotlog: test_rotlog.c $(SRC)/mnd_rotlog.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

$(BUILD)/test_xz: test_xz.c $(SRC)/mnd_xz.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

$(BUILD)/test_tar: test_tar.c $(SRC)/mnd_tar.c $(SRC)/mnd_xz.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

$(BUILD)/test_unpack: test_unpack.c $(SRC)/mnd_unpack.c $(SRC)/mnd_xz.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

$(BUILD)/tar_plain.tar: gen_tar_fixtures.py | $(BUILD)
	python3 gen_tar_fixtures.py $(BUILD)

$(BUILD)/xz_mixed.xz: gen_xz_fixtures.py | $(BUILD)
	python3 gen_xz_fixtures.py $(BUILD)

$(BUILD)/fx_v3_512.qcow2: gen_qcow2_fixture.py | $(BUILD)
	python3 gen_qcow2_fixture.py $(BUILD)

run: $(addprefix $(BUILD)/,$(TESTS)) $(BUILD)/fx_v3_512.qcow2 $(BUILD)/xz_mixed.xz $(BUILD)/tar_plain.tar
	@set -e; for t in $(addprefix $(BUILD)/,$(TESTS)); do $$t $(BUILD); done
	@AGENT_SHELL=sh sh test_agent.sh $(BUILD)/agent-sh
	@if command -v bash >/dev/null; then AGENT_SHELL=bash sh test_agent.sh $(BUILD)/agent-bash; fi
	@AGENT_SHELL=sh sh test_agent_macos.sh $(BUILD)/agent-macos-sh
	@if command -v bash >/dev/null; then AGENT_SHELL=bash sh test_agent_macos.sh $(BUILD)/agent-macos-bash; fi
	@sh test_macsetup.sh $(BUILD)/macsetup-sh
	@if command -v bash >/dev/null; then bash test_macsetup.sh $(BUILD)/macsetup-bash; fi
	@REPORT_SHELL=sh sh test_report.sh $(BUILD)/report-sh
	@if command -v bash >/dev/null; then REPORT_SHELL=bash sh test_report.sh $(BUILD)/report-bash; fi
	@SELINUX_SHELL=sh sh test_selinux.sh $(BUILD)/selinux-sh
	@if command -v bash >/dev/null; then SELINUX_SHELL=bash sh test_selinux.sh $(BUILD)/selinux-bash; fi
	@CONSOLE_SHELL=sh sh test_console.sh $(BUILD)/console-sh
	@if command -v bash >/dev/null; then CONSOLE_SHELL=bash sh test_console.sh $(BUILD)/console-bash; fi
	@INSTALL_SHELL=sh sh test_install.sh $(BUILD)/install-sh
	@if command -v bash >/dev/null; then INSTALL_SHELL=bash sh test_install.sh $(BUILD)/install-bash; fi
	@HYGIENE_SHELL=sh sh test_hygiene.sh $(BUILD)/hygiene-sh
	@if command -v bash >/dev/null; then HYGIENE_SHELL=bash sh test_hygiene.sh $(BUILD)/hygiene-bash; fi
	@sh test_agent_live.sh

clean:
	rm -rf $(BUILD)

.PHONY: all run clean fuzz
