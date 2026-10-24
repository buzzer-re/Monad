#!/bin/sh
# Tests for the guest report (Monad/Guest/monad-report.sh): what a guest
# prints on its console about Monad's setup (MONAD| lines in the boot tab),
# against a fake root and stand-ins for systemctl, journalctl, getent, uname
# and sshd. Usage: test_report.sh [workdir]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPORT="$HERE/../Monad/Guest/monad-report.sh"
SH=${REPORT_SHELL:-sh}
WORK=${1:-$(mktemp -d)}
rm -rf "$WORK"
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
checks=0
failures=0

check() { # check NAME EXPECTED ACTUAL
    checks=$((checks + 1))
    if [ "$2" != "$3" ]; then
        failures=$((failures + 1))
        printf '%s: FAIL\n--- expected\n%s\n--- got\n%s\n' "$1" "$2" "$3" >&2
    fi
}

check_has() { # check_has NAME NEEDLE HAYSTACK
    checks=$((checks + 1))
    case "$3" in
        *"$2"*) ;;
        *) failures=$((failures + 1))
           printf '%s: FAIL\n--- missing\n%s\n--- in\n%s\n' "$1" "$2" "$3" >&2 ;;
    esac
}

check_lacks() { # check_lacks NAME NEEDLE HAYSTACK
    checks=$((checks + 1))
    case "$3" in
        *"$2"*) failures=$((failures + 1))
           printf '%s: FAIL\n--- unexpected\n%s\n--- in\n%s\n' "$1" "$2" "$3" >&2 ;;
    esac
}

BIN="$WORK/bin"
STATE="$WORK/state"
ROOT="$WORK/root"
SSHD="$WORK/sshd"
mkdir -p "$BIN"

stub() { # stub NAME (body on stdin)
    { echo '#!/bin/sh'; cat; } >"$BIN/$1"
    chmod +x "$BIN/$1"
}
stub uname <<'EOF'
echo 6.12.0-test
EOF
stub sleep <<'EOF'
:
EOF
# systemctl is-active/is-enabled UNIT: $STATE/units holds "UNIT STATE" lines.
stub systemctl <<'EOF'
v=$(awk -v u="$2" '$1 == u { print $2 }' "$FAKE_STATE/units" 2>/dev/null)
case "$1" in
    is-active) echo "${v:-inactive}"; [ "$v" = active ] ;;
    is-enabled) if [ -z "$v" ]; then echo not-found; exit 4; fi; echo "$v" ;;
esac
EOF
# journalctl: the Nth call for sshd (-u monad-sshd@*) or the kernel (-k)
# prints $STATE/sshd.N or $STATE/kernel.N.
stub journalctl <<'EOF'
kind=kernel
for a; do case "$a" in monad-sshd@*) kind=sshd ;; esac; done
n=$(($(cat "$FAKE_STATE/$kind.calls" 2>/dev/null || echo 0) + 1))
echo "$n" >"$FAKE_STATE/$kind.calls"
cat "$FAKE_STATE/$kind.$n" 2>/dev/null || true
EOF
stub getent <<'EOF'
[ "$1" = passwd ] && [ -e "$FAKE_STATE/user-$2" ] || exit 2
echo "$2:x:1000:1000::/home/$2:/bin/bash"
EOF
cat >"$SSHD" <<'EOF'
#!/bin/sh
[ "$1" = -t ] || exit 1
if [ -s "$FAKE_STATE/sshd-error" ]; then cat "$FAKE_STATE/sshd-error" >&2; exit 255; fi
EOF
chmod +x "$SSHD"

# A guest where everything is in place.
reset() {
    rm -rf "$STATE" "$ROOT"
    mkdir -p "$STATE" "$ROOT/etc/ssh" "$ROOT/sys/fs/selinux" "$ROOT/dev" "$ROOT/home/dev/.ssh" "$ROOT/var/log/audit"
    printf 'NAME="openSUSE Leap"\nPRETTY_NAME="openSUSE Leap 16.0"\n' >"$ROOT/etc/os-release"
    echo 1 >"$ROOT/sys/fs/selinux/enforce"
    : >"$ROOT/dev/vsock"
    for k in rsa ecdsa ed25519; do : >"$ROOT/etc/ssh/ssh_host_${k}_key"; : >"$ROOT/etc/ssh/ssh_host_${k}_key.pub"; done
    echo "ssh-ed25519 AAAA monad-test" >"$ROOT/home/dev/.ssh/authorized_keys"
    : >"$ROOT/var/log/audit/audit.log"
    touch "$STATE/user-dev"
    printf '%s\n' "monad-sshd.socket active" "monad-agent.socket active" \
        "sshd.service masked" "sshd.socket masked" >"$STATE/units"
}

run() { # run MODE ARGS...: sets $out (the console) and $st
    : >"$WORK/console"
    PATH="$BIN:$PATH" FAKE_STATE="$STATE" MONAD_ROOT="$ROOT" MONAD_CONSOLE="$WORK/console" \
        MONAD_REPORT_INTERVAL=10 $SH "$REPORT" "$@" >"$WORK/stdout" 2>"$WORK/stderr"
    st=$?
    out=$(cat "$WORK/console")
}

echo "monad-report tests ($SH)" >&2

reset
run setup dev "$SSHD"
check "setup: status" 0 "$st"
check "setup: all well" "MONAD| guest: openSUSE Leap 16.0, kernel 6.12.0-test
MONAD| selinux: enforcing
MONAD| vsock: yes
MONAD| sshd: $SSHD, config ok, 3 host keys
MONAD| units: monad-sshd.socket active, monad-agent.socket active
MONAD| network sshd: sshd.service masked, sshd.socket masked
MONAD| user: dev, key installed
MONAD| setup done: waiting for Monad to log in over vsock" "$out"
check "setup: also on stdout (the journal)" "$out" "$(cat "$WORK/stdout")"

# Each thing that keeps Monad out says so.
reset
rm "$ROOT/dev/vsock" "$ROOT/sys/fs/selinux/enforce"
rmdir "$ROOT/sys/fs/selinux"
echo "sshd: no hostkeys available -- exiting." >"$STATE/sshd-error"
rm "$ROOT"/etc/ssh/ssh_host_*
rm "$ROOT/home/dev/.ssh/authorized_keys"
printf '%s\n' "monad-sshd.socket failed" "monad-agent.socket active" "ssh.service enabled" >"$STATE/units"
run setup dev "$SSHD"
check_has "no selinux" "MONAD| selinux: off" "$out"
check_has "no vsock" "MONAD| vsock: missing (no /dev/vsock): Monad cannot reach sshd" "$out"
check_has "sshd config error" "MONAD| sshd: $SSHD, config error: sshd: no hostkeys available -- exiting." "$out"
check_has "failed socket" "MONAD| units: monad-sshd.socket failed, monad-agent.socket active" "$out"
check_has "network sshd on" "MONAD| network sshd: ssh.service enabled" "$out"
check_has "no key" "MONAD| user: dev, no ssh key in /home/dev/.ssh/authorized_keys" "$out"
reset
echo 0 >"$ROOT/sys/fs/selinux/enforce"
rm "$STATE/user-dev"
run setup dev "$WORK/no-such-sshd"
check_has "permissive" "MONAD| selinux: permissive" "$out"
check_has "no user" "MONAD| user: dev missing" "$out"
check_has "no sshd" "MONAD| sshd: $WORK/no-such-sshd not found" "$out"

# Watching: sshd's errors and SELinux denials, each once, until Monad logs in.
reset
cat >"$STATE/sshd.1" <<'EOF'
pam_selinux(sshd:session): Unable to set executable context
pam_selinux(sshd:session): Unable to set executable context
EOF
printf '%s\n' 'audit: type=1400 audit(1760000000.123:45): avc:  denied  { read write } for  pid=812 comm="sshd-session" path="socket:[1234]" dev="sockfs" ino=1234 scontext=system_u:system_r:sshd_session_t:s0 tcontext=system_u:system_r:init_t:s0 tclass=vsock_socket permissive=0' >"$STATE/kernel.1"
printf '%s\n' 'type=AVC msg=audit(1760000001.5:46): avc:  denied  { create } for  pid=1 comm="systemd" scontext=system_u:system_r:init_t:s0 tcontext=system_u:system_r:sshd_t:s0 tclass=vsock_socket permissive=0' \
    'type=AVC msg=audit(1760000001.6:47): avc:  denied  { read } for  pid=99 comm="chronyd" scontext=system_u:system_r:chronyd_t:s0 tcontext=system_u:object_r:etc_t:s0 tclass=file permissive=0' \
    >>"$ROOT/var/log/audit/audit.log"
printf 'Accepted publickey for dev from UNKNOWN port 65535 ssh2: ED25519 SHA256:abc\n' >"$STATE/sshd.2"
printf 'pam_selinux(sshd:session): never seen\n' >"$STATE/sshd.3"
run watch 600
check "watch: status" 0 "$st"
check "watch: until the login" "MONAD| sshd: pam_selinux(sshd:session): Unable to set executable context
MONAD| selinux denied { read write } to sshd-session: sshd_session_t -> init_t vsock_socket
MONAD| selinux denied { create } to systemd: init_t -> sshd_t vsock_socket
MONAD| login: accepted for dev, Monad takes over" "$out"

# No login: it stops at its deadline and says so.
reset
printf 'error: kex_exchange_identification: Connection closed\n' >"$STATE/sshd.1"
run watch 30
check "deadline: status" 0 "$st"
check "deadline: says so" "MONAD| sshd: error: kex_exchange_identification: Connection closed
MONAD| no login from Monad after 30 s" "$out"
check "deadline: three rounds" 3 "$(cat "$STATE/sshd.calls")"

# What the guest prints is plain text: no control characters, bounded lines.
reset
printf 'evil \033]52;c;aGk=\007 \033[2J end\n' >"$STATE/sshd.1"
awk 'BEGIN { s = ""; for (i = 0; i < 2000; i++) s = s "x"; print s }' >"$STATE/sshd.2"
run watch 20
check_lacks "no escape sequences" "$(printf '\033')" "$out"
check_lacks "no bell" "$(printf '\007')" "$out"
check_has "the text stays" "MONAD| sshd: evil ]52;c;aGk= [2J end" "$out"
check "lines are bounded" "" "$(printf '%s\n' "$out" | awk 'length > 300')"

printf '%d checks, %d failures\n' "$checks" "$failures" >&2
[ "$failures" -eq 0 ]
