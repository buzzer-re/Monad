#!/bin/sh
# monad-report.sh — what this guest tells the boot tab about Monad's setup.
#
# Monad reaches a guest only through its own sshd over vsock. When that
# fails, the guest's console is the one place left to say why, and the boot
# tab shows the console. So every line here starts with "MONAD| " and goes
# to the console (and stdout, the journal):
#
#   monad-report setup USER SSHD    the facts Monad's ssh needs, once
#   monad-report watch [SECS]       sshd's errors and SELinux denials, each
#                                   once, until someone logs in (Monad is the
#                                   only one who can, over vsock) or SECS pass
#
# It only reads, and prints plain text: control characters are dropped and
# lines cut at 300 bytes. MONAD_ROOT, MONAD_CONSOLE and
# MONAD_REPORT_INTERVAL exist for its tests (CTests/test_report.sh).

set -u
ROOT=${MONAD_ROOT:-}
CONSOLE=${MONAD_CONSOLE:-/dev/console}
INTERVAL=${MONAD_REPORT_INTERVAL:-10}

say() {
    line=$(printf 'MONAD| %s' "$*" | tr -d '\000-\010\013-\037\177' | cut -c1-300)
    printf '%s\n' "$line"
    { printf '%s\n' "$line" >>"$CONSOLE"; } 2>/dev/null || true
}

setup() { # USER SSHD
    user=$1
    sshd=$2
    pretty=$(sed -n 's/^PRETTY_NAME=//p' "$ROOT/etc/os-release" 2>/dev/null | tr -d '"')
    say "guest: ${pretty:-unknown}, kernel $(uname -r)"

    if [ -r "$ROOT/sys/fs/selinux/enforce" ]; then
        if [ "$(cat "$ROOT/sys/fs/selinux/enforce")" = 1 ]; then say "selinux: enforcing"; else say "selinux: permissive"; fi
    else
        say "selinux: off"
    fi

    if [ -e "$ROOT/dev/vsock" ]; then say "vsock: yes"; else say "vsock: missing (no /dev/vsock): Monad cannot reach sshd"; fi

    keys=0
    for k in "$ROOT"/etc/ssh/ssh_host_*_key; do
        if [ -e "$k" ]; then keys=$((keys + 1)); fi
    done
    if [ ! -x "$sshd" ]; then
        say "sshd: $sshd not found"
    elif err=$("$sshd" -t 2>&1); then
        say "sshd: $sshd, config ok, $keys host keys"
    else
        say "sshd: $sshd, config error: $(printf '%s\n' "$err" | head -1)"
    fi

    units=""
    for u in monad-sshd.socket monad-agent.socket; do
        units="$units${units:+, }$u $(systemctl is-active "$u" 2>/dev/null)"
    done
    say "units: $units"
    net=""
    for u in ssh.service sshd.service ssh.socket sshd.socket; do
        s=$(systemctl is-enabled "$u" 2>/dev/null) || true
        case "$s" in
            '' | not-found) ;;
            *) net="$net${net:+, }$u $s" ;;
        esac
    done
    say "network sshd: ${net:-none installed}"

    if ! pw=$(getent passwd "$user"); then
        say "user: $user missing"
    else
        home=$(printf '%s\n' "$pw" | cut -d: -f6)
        if [ -s "$ROOT$home/.ssh/authorized_keys" ]; then
            say "user: $user, key installed"
        else
            say "user: $user, no ssh key in $home/.ssh/authorized_keys"
        fi
    fi
    say "setup done: waiting for Monad to log in over vsock"
}

# Lines on stdin not printed before, at most 6, each after PREFIX.
emit() { # PREFIX
    n=0
    while IFS= read -r l; do
        [ -n "$l" ] || continue
        if grep -qxF -- "$l" "$seen/lines"; then continue; fi
        printf '%s\n' "$l" >>"$seen/lines"
        [ "$n" -lt 6 ] || continue
        n=$((n + 1))
        say "$1$l"
    done
}

# SELinux denials that concern ssh or vsock, one short line each.
denials() {
    grep 'avc: *denied' | grep -E 'sshd|vsock|monad|ssh-keygen' |
        sed -n 's/.*avc: *denied *{ \([^}]*\) } for .*comm="\([^"]*\)".* scontext=[^:]*:[^:]*:\([^: ]*\)[^ ]* tcontext=[^:]*:[^:]*:\([^: ]*\)[^ ]* tclass=\([^ ]*\).*/selinux denied { \1 } to \2: \3 -> \4 \5/p'
}

watch() { # [SECS]
    secs=${1:-900}
    rounds=$((secs / INTERVAL))
    if [ "$rounds" -lt 1 ]; then rounds=1; fi
    seen=$(mktemp -d "${TMPDIR:-/tmp}/monad-report.XXXXXX") || return 0
    trap 'rm -rf "$seen"' EXIT
    : >"$seen/lines"
    audit="$ROOT/var/log/audit/audit.log"
    audited=0
    range="-b"
    i=0
    while [ "$i" -lt "$rounds" ]; do
        i=$((i + 1))
        now=$(date +%s)
        journalctl -q -o cat $range -u 'monad-sshd@*' >"$seen/sshd" 2>/dev/null || true
        grep -v "^Accepted publickey for " "$seen/sshd" | emit "sshd: "
        journalctl -q -o cat $range -k 2>/dev/null | denials | emit ""
        if [ -r "$audit" ]; then
            total=$(wc -l <"$audit")
            if [ "$total" -lt "$audited" ]; then audited=0; fi
            sed -n "$((audited + 1)),${total}p" "$audit" | denials | emit ""
            audited=$total
        fi
        user=$(sed -n 's/^Accepted publickey for \([^ ]*\) .*/\1/p' "$seen/sshd" | head -1)
        if [ -n "$user" ]; then
            say "login: accepted for $user, Monad takes over"
            return 0
        fi
        range="--since=@$now"
        if [ "$i" -lt "$rounds" ]; then sleep "$INTERVAL"; fi
    done
    say "no login from Monad after $secs s"
}

case "${1:-}" in
    setup) [ $# -eq 3 ] && setup "$2" "$3" ;;
    watch) watch "${2:-900}" ;;
    *) echo "usage: monad-report setup USER SSHD | watch [SECONDS]" >&2; exit 2 ;;
esac
exit 0
