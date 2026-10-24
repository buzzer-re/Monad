//
//  GuestShares.swift — mounting shared folders inside the guest. The
//  virtio-fs share is mounted once under /run/monad; each folder is a bind
//  mount of its directory there. The script reconciles: folders whose name,
//  mode and path are unchanged stay mounted (a shell inside one is not
//  disturbed), others are unmounted or mounted. Runs as root over ssh; the
//  guest agent keeps no privileges.
//

import Foundation

enum GuestShares {
    /// Remote command; the trailing word tells it apart from other scripts.
    static let command = "sudo -n sh -s -- monad-shares"
    /// virtio-fs tag of the sharing device (MNDVMConfig.sharingTag).
    static let tag = "monad"
    static let root = "/run/monad/virtiofs"
    static let list = "/run/monad/shares"
    /// Folders the script made to mount on; kept across reboots, so a share
    /// removed while the VM was off loses its folder too.
    static let made = "/var/lib/monad/shares-made"

    /// One line per folder: name, ro|rw, guest path, tab-separated.
    static func entries(_ shares: [SharedFolder]) -> [String] {
        SharingSettings.named(shares).map { named in
            "\(named.name)\t\(named.share.readOnly ? "ro" : "rw")\t\(InstanceConfig.normalizedGuestPath(named.share.guestPath))"
        }
    }

    /// Prints `shares-ok`, or one `shares-failed: <path>: <why>` line per
    /// folder that could not be mounted (exit status 1). Each step is said on
    /// stderr ("monad-shares: …"), for the debug log, and on a failure what
    /// the shared folder device holds (a folder added while the VM runs must
    /// show up there).
    ///
    /// `rebind`: the running VM's shared folder device was just given a new
    /// folder list. Folders bound before it then point at nothing (stale
    /// file handles), so every folder is bound again, unchanged ones too
    /// (a shell inside one needs to `cd` into it again).
    ///
    /// A folder the script made to mount on (recorded in `made`) is removed
    /// once its share is gone, if empty; one that was there before stays.
    static func script(for shares: [SharedFolder], root: String = root, list: String = list, made: String = made,
                       rebind: Bool = false) -> String {
        let wanted = entries(shares).map { $0 + "\n" }.joined()
        return """
            set -u
            root=\(quoted(root))
            list=\(quoted(list))
            made=\(quoted(made))
            want="$list.want"
            new="$list.new"
            tab=$(printf '\\t')
            rebind=\(rebind ? 1 : 0)
            failed=0
            say() { echo "monad-shares: $*" >&2; }
            oneline() { printf '%s' "$1" | paste -sd ' ' -; }
            mkdir -p "$root" "$(dirname "$made")"
            if ! mountpoint -q "$root"; then
                say "mounting the shared folder device at $root"
                err=$(mount -t virtiofs \(tag) "$root" 2>&1) || { echo "shares-failed: the shared folder device: $(oneline "$err")"; exit 1; }
            fi
            [ "$rebind" = 0 ] || say "the shared folder device changed, binding every folder again"
            cat > "$want" <<'MONAD_SHARES'
            \(wanted)MONAD_SHARES
            touch "$list" "$made"
            while IFS= read -r line; do
                grep -qxF -- "$line" "$want" && continue
                p=${line#*"$tab"}; p=${p#*"$tab"}
                umount "$p" 2>/dev/null || umount -l "$p" 2>/dev/null || true
                say "unmounted $p"
            done < "$list"
            : > "$new"
            while IFS= read -r line; do
                name=${line%%"$tab"*}; rest=${line#*"$tab"}; mode=${rest%%"$tab"*}; p=${rest#*"$tab"}
                if grep -qxF -- "$line" "$list"; then
                    if [ "$rebind" = 0 ] && mountpoint -q "$p"; then
                        echo "$line" >> "$new"
                        say "kept $name at $p ($mode)"
                        continue
                    fi
                    # Bound before but stale or gone: let go of it first.
                    umount "$p" 2>/dev/null || umount -l "$p" 2>/dev/null || true
                fi
                fresh=0
                [ -e "$p" ] || fresh=1
                if err=$(mkdir -p "$p" 2>&1 && mount --bind "$root/$name" "$p" 2>&1); then
                    if err=$(mount -o "remount,bind,$mode" "$p" 2>&1); then
                        echo "$line" >> "$new"
                        [ "$fresh" = 0 ] || grep -qxF -- "$p" "$made" || echo "$p" >> "$made"
                        say "mounted $name at $p ($mode)"
                        continue
                    fi
                    umount "$p" 2>/dev/null || umount -l "$p" 2>/dev/null
                fi
                [ "$fresh" = 0 ] || rmdir "$p" 2>/dev/null
                echo "shares-failed: $p: $(oneline "$err")"
                failed=1
            done < "$want"
            # Folders made for shares that are gone (now or while the VM was
            # off) go too, if empty; the list forgets them either way.
            : > "$made.new"
            while IFS= read -r p; do
                [ -n "$p" ] || continue
                if cut -f3 "$want" | grep -qxF -- "$p" || mountpoint -q "$p"; then
                    echo "$p" >> "$made.new"
                elif rmdir "$p" 2>/dev/null; then
                    say "removed the empty folder $p"
                fi
            done < "$made"
            mv "$made.new" "$made"
            mv "$new" "$list"
            rm -f "$want"
            if [ "$failed" != 0 ]; then
                say "the shared folder device holds: $(ls -A "$root" 2>&1 | paste -sd ' ' -)"
                exit 1
            fi
            echo shares-ok

            """
    }

    // MARK: macOS guests

    /// A macOS guest's mount of the device, and the links the script made
    /// (kept across reboots: a share removed while the VM was off loses its
    /// link too).
    static let macRoot = "/var/run/monad/virtiofs"
    static let macMade = "/var/db/monad/shares-made"

    /// The same for a macOS guest, which has no bind mounts: the device is
    /// mounted once with Apple's mount_virtiofs and each folder is a
    /// symbolic link at its path (read-only is the device's, per folder).
    /// Links already right stay; links Monad made for folders no longer
    /// shared go; an empty folder where a share goes is replaced, anything
    /// else there is never touched and is reported. `rebind`: the device
    /// was given a new folder list, so it is mounted again. Same answers as
    /// `script`.
    static func macScript(for shares: [SharedFolder], root: String = macRoot, made: String = macMade,
                          rebind: Bool = false) -> String {
        let wanted = entries(shares).map { $0 + "\n" }.joined()
        return """
            set -u
            root=\(quoted(root))
            made=\(quoted(made))
            want="$made.want"
            tab=$(printf '\\t')
            rebind=\(rebind ? 1 : 0)
            failed=0
            owner=${SUDO_UID:-}
            group=${SUDO_GID:-}
            say() { echo "monad-shares: $*" >&2; }
            oneline() { printf '%s' "$1" | paste -sd ' ' -; }
            mkdir -p "$root" "$(dirname "$made")"
            # mount lists the path resolved (/var is /private/var).
            real=$(cd "$root" && pwd -P)
            mounted() { mount | grep -qF " on $real ("; }
            if [ "$rebind" = 1 ] && mounted; then
                say "the shared folder device changed, mounting it again"
                umount -f "$root" 2>/dev/null || umount "$root" 2>/dev/null
            fi
            if ! mounted; then
                say "mounting the shared folder device at $root"
                err=$(mount_virtiofs \(tag) "$root" 2>&1) || { echo "shares-failed: the shared folder device: $(oneline "$err")"; exit 1; }
            fi
            cat > "$want" <<'MONAD_SHARES'
            \(wanted)MONAD_SHARES
            touch "$made"
            : > "$made.new"
            while IFS= read -r p; do
                [ -n "$p" ] || continue
                if cut -f3 "$want" | grep -qxF -- "$p"; then
                    echo "$p" >> "$made.new"
                elif [ -L "$p" ] && rm -f "$p"; then
                    say "removed the link $p"
                fi
            done < "$made"
            while IFS= read -r line; do
                name=${line%%"$tab"*}; rest=${line#*"$tab"}; mode=${rest%%"$tab"*}; p=${rest#*"$tab"}
                target="$root/$name"
                if [ -L "$p" ]; then
                    if [ "$(readlink "$p")" = "$target" ]; then
                        grep -qxF -- "$p" "$made.new" || echo "$p" >> "$made.new"
                        say "kept $name at $p ($mode)"
                        continue
                    fi
                    rm -f "$p"
                elif [ -d "$p" ] && [ -z "$(ls -A "$p" 2>/dev/null)" ]; then
                    rmdir "$p"
                elif [ -e "$p" ]; then
                    echo "shares-failed: $p: something is already there"
                    failed=1
                    continue
                fi
                parent=$(dirname "$p")
                if [ ! -d "$parent" ]; then
                    mkdir -p "$parent"
                    [ -z "$owner" ] || chown "$owner:$group" "$parent" 2>/dev/null
                fi
                if err=$(ln -s "$target" "$p" 2>&1); then
                    [ -z "$owner" ] || chown -h "$owner:$group" "$p" 2>/dev/null
                    grep -qxF -- "$p" "$made.new" || echo "$p" >> "$made.new"
                    say "linked $name at $p ($mode)"
                else
                    echo "shares-failed: $p: $(oneline "$err")"
                    failed=1
                fi
            done < "$want"
            mv "$made.new" "$made"
            rm -f "$want"
            if [ "$failed" != 0 ]; then
                say "the shared folder device holds: $(ls -A "$root" 2>&1 | paste -sd ' ' -)"
                exit 1
            fi
            echo shares-ok

            """
    }

    /// The error to show for a script run, nil when every folder is mounted.
    /// The guest writes it (root in it can say anything), so it is shown
    /// plain and bounded: a few folders, each cut.
    static func problem(_ r: ProcessRunner.Result) -> String? {
        if r.status == 0, r.stdoutString.contains("shares-ok") { return nil }
        let failed = r.stdoutString.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.hasPrefix("shares-failed: ") else { return nil }
            let what = line.dropFirst(15)
            guard let split = what.range(of: ": ") else { return String(what).plain(limit: 200) }
            return "\(String(what[..<split.lowerBound]).plain(limit: 120)) (\(String(what[split.upperBound...]).plain(limit: 160)))"
        }
        if !failed.isEmpty {
            let more = failed.count > 8 ? ", and \(failed.count - 8) more" : ""
            return "Could not mount in the guest: \(failed.prefix(8).joined(separator: ", "))\(more)."
        }
        let detail = r.stderrString.split(whereSeparator: \.isNewline).last { !$0.hasPrefix("monad-shares: ") }
            .map { String($0).plain(limit: 200) } ?? "status \(r.status)"
        return "Could not mount shared folders in the guest (\(detail))."
    }

    private static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
