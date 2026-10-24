//
//  ProfileScriptTests.swift — a profile as the shell script that sets it up:
//  the lines it writes per package manager, its progress markers, and the
//  script itself run under /bin/sh with stand-ins for the package managers,
//  npm, curl (a fake nodejs.org), uname and sha256sum, in a temporary root.
//

import XCTest
@testable import Monad

final class ProfileScriptTests: XCTestCase {
    private typealias Step = ProfileConfig.Step

    // MARK: What it writes

    func testPackagesPerPackageManager() throws {
        let catalog = try ProfileCatalog.bundled()
        let agentic = try XCTUnwrap(catalog.profile("agentic"))
        let apt = try ProfileScript.render(agentic, packageManager: "apt", user: "dev")
        XCTAssertTrue(apt.contains("apt-get install -y -q --no-install-recommends $pick"), apt)
        XCTAssertTrue(apt.contains("dpkg-query -W -f='${Status}'"))
        XCTAssertTrue(apt.contains("'build-essential'"))
        XCTAssertTrue(apt.contains("npm install -g --prefix \"$MONAD_ROOT/usr/local\" $missing"))
        XCTAssertTrue(apt.contains("MONAD_USER='dev'"))
        // From / (root's), not the login user's home: npm runs install scripts as the owner of where it is.
        XCTAssertTrue(apt.contains("\ncd / || exit 1\n"))
        // Run as its own session (setsid): Stop ends the whole process group by this id.
        XCTAssertTrue(apt.contains("echo \"@@monad pid $$\""))
        // Node.js from nodejs.org, checked against its checksum file, in the VM.
        XCTAssertTrue(apt.contains("https://nodejs.org/dist/index.tab"))
        XCTAssertTrue(apt.contains("sha256sum -c"))
        // The index is saved, then read: piped into awk, which stops at the first match, curl
        // fails with "(23) Failure writing output".
        XCTAssertFalse(apt.contains("index.tab' |"))
        XCTAssertTrue(apt.contains("-o \"$tmp/index.tab\""))
        let dnf = try ProfileScript.render(agentic, packageManager: "dnf", user: "dev")
        XCTAssertTrue(dnf.contains("dnf install -y $pick"))
        XCTAssertTrue(dnf.contains("rpm -q --quiet"))
        XCTAssertFalse(dnf.contains("apt-get"))
        let zypper = try ProfileScript.render(agentic, packageManager: "zypper", user: "dev")
        XCTAssertTrue(zypper.contains("zypper --non-interactive install --no-recommends $pick"))
        // Every step announces itself.
        for id in ["base", "node", "agents"] {
            XCTAssertTrue(apt.contains("@@monad step \(id) start"), id)
            XCTAssertTrue(apt.contains("@@monad step \(id) done"), id)
        }
        // All of it one function, run with no stdin: the script is the shell's stdin.
        XCTAssertTrue(apt.contains("\nmonad_main() {\n"))
        XCTAssertTrue(apt.hasSuffix("echo '@@monad finished'\n}\nmonad_main </dev/null\n"))
    }

    func testWhatCannotBeRenderedIsRefused() throws {
        let p = ProfileConfig(id: "x", name: "X", summary: "", steps: [Step(id: "p", title: "P", packages: ["apt": ["git"]])])
        XCTAssertThrowsError(try ProfileScript.render(p, packageManager: "zypper", user: "dev"))
        let r = ProfileConfig(id: "x", name: "X", summary: "", steps: [Step(id: "n", title: "Rust", runtime: "rust")])
        XCTAssertThrowsError(try ProfileScript.render(r, packageManager: "apt", user: "dev"), "unknown runtime")
        let q = ProfileConfig(id: "x", name: "X", summary: "", steps: [Step(id: "p", title: "P", npm: ["x"])])
        XCTAssertThrowsError(try ProfileScript.render(q, packageManager: "apt", user: "dev; rm -rf /"))
    }

    func testAScriptCannotEndItsHeredocEarly() throws {
        let tricky = "echo one\nMONAD_SCRIPT\necho two\n"
        let p = ProfileConfig(id: "x", name: "X", summary: "", steps: [Step(id: "s", title: "S", script: tricky)])
        let out = try ProfileScript.render(p, packageManager: "apt", user: "dev")
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let open = try XCTUnwrap(lines.first { $0.contains("<<'MONAD_") })
        let name = String(open[open.range(of: "<<'")!.upperBound...].dropLast())
        XCTAssertTrue(name.hasPrefix("MONAD_SCRIPT_"))
        XCTAssertFalse(tricky.contains(name), "the delimiter never occurs in the script")
        XCTAssertEqual(lines.filter { $0 == name }.count, 1, "and ends it exactly once")
    }

    // MARK: Progress

    func testProgressMarkers() {
        XCTAssertEqual(ProfileProgress.parse("@@monad step base start"), .started("base"))
        XCTAssertEqual(ProfileProgress.parse("@@monad step base done"), .finished("base"))
        XCTAssertEqual(ProfileProgress.parse("@@monad step node failed the archive does not match"),
                       .failed("node", "the archive does not match"))
        XCTAssertEqual(ProfileProgress.parse("@@monad finished"), .allDone)
        XCTAssertEqual(ProfileProgress.parse("@@monad pid 4242"), .pid(4242))
        XCTAssertNil(ProfileProgress.parse("@@monad pid -1"))
        XCTAssertNil(ProfileProgress.parse("@@monad pid x"))
        XCTAssertNil(ProfileProgress.parse("Reading package lists..."))
        XCTAssertNil(ProfileProgress.parse("@@monad step Bad Id start"))
        XCTAssertNil(ProfileProgress.parse("x @@monad step base start"))
    }

    // MARK: Running it

    private var root: URL!
    private var bin: URL!
    private var log: URL!
    /// The fake nodejs.org/dist.
    private var server: URL!
    private var cpu = "aarch64"

    /// Stand-ins that record what they are asked to do and remember what they
    /// installed; curl serves files from `server`.
    private func makeStubs() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("profile-run-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        root = tmp.appendingPathComponent("root")
        bin = tmp.appendingPathComponent("bin")
        log = tmp.appendingPathComponent("log")
        server = tmp.appendingPathComponent("server")
        let state = tmp.appendingPathComponent("state")
        for d in [root!, bin!, state, server!] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        func stub(_ name: String, _ body: String) throws {
            let url = bin.appendingPathComponent(name)
            let head = "#!/bin/sh\nLOG='\(log.path)'\nSTATE='\(state.path)'\nBIN='\(bin.path)'\nSERVER='\(server.path)'\n"
            try (head + body).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try stub("apt-cache", #"[ "$1" = show ] || exit 1; for k in $KNOWN; do [ "$k" = "$2" ] && exit 0; done; exit 100"#)
        try stub("dpkg-query", #"for p; do last="$p"; done; [ -f "$STATE/pkg-$last" ] && echo 'install ok installed' && exit 0; exit 1"#)
        try stub("apt-get", #"echo "apt-get $*" >> "$LOG"; [ "$1" = install ] || exit 0; for p; do case "$p" in -*|install) ;; *) touch "$STATE/pkg-$p"; printf '#!/bin/sh\n' > "$BIN/$p"; chmod +x "$BIN/$p";; esac; done"#)
        try stub("npm", #"echo "npm $*" >> "$LOG"; case "$1" in ls) for p; do last="$p"; done; s=$(echo "$last" | tr '/@' '__'); [ -f "$STATE/npm-$s" ]; exit $?;; install) shift; for p; do case "$p" in -*|*/usr/local) ;; *) s=$(echo "$p" | tr '/@' '__'); touch "$STATE/npm-$s";; esac; done; printf '#!/bin/sh\n' > "$BIN/tool"; chmod +x "$BIN/tool";; esac"#)
        try stub("sha256sum", #"[ "$1" = -c ] || exit 2; while read sum file; do [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sum" ] || exit 1; done"#)
        // nodejs.org/dist/X and github.com/containerd/nerdctl/releases/download/X are $SERVER/X;
        // -w '%{url_effective}' answers $LATEST (the redirect of releases/latest).
        // herdr.dev/X is $SERVER/X too.
        try stub("curl", #"out=''; url=''; eff=''; while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift;; -w) eff=1; shift;; https://*) url="$1";; esac; shift; done; echo "curl $url" >> "$LOG"; if [ -n "$eff" ]; then printf '%s' "$LATEST"; exit 0; fi; p="${url#https://nodejs.org/dist/}"; p="${p#https://github.com/containerd/nerdctl/releases/download/}"; p="${p#https://herdr.dev/}"; f="$SERVER/$p"; [ -f "$f" ] || exit 22; if [ -n "$out" ] && [ "$out" != /dev/null ]; then cp "$f" "$out"; else cat "$f"; fi"#)
        try stub("uname", "[ \"$1\" = -m ] && echo '\(cpu)'")
    }

    /// nodejs.org/dist with these releases (newest first; lts "-" for Current),
    /// each with a linux-arm64 archive and its checksum file.
    private func publish(_ releases: [(version: String, lts: String)], tamper: Bool = false) throws {
        var tab = "version\tdate\tfiles\tnpm\tv8\tuv\tzlib\topenssl\tmodules\tlts\tsecurity\n"
        for r in releases {
            tab += "\(r.version)\t2026-09-01\tlinux-arm64,linux-x64,osx-arm64-tar\t10.0.0\t13.0\t1.50\t1.3\t3.5\t137\t\(r.lts)\tfalse\n"
            let name = "node-\(r.version)-linux-arm64"
            let dir = server.appendingPathComponent(r.version)
            let staging = server.deletingLastPathComponent().appendingPathComponent("staging-\(r.version)/\(name)")
            try FileManager.default.createDirectory(at: staging.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for b in ["node", "npm", "npx"] {
                let url = staging.appendingPathComponent("bin/\(b)")
                // Linked first on PATH, as in a VM: its npm hands over to the stand-in.
                let body = b == "npm" ? "exec '\(bin.appendingPathComponent("npm").path)' \"$@\"" : "echo \(b) \(r.version)"
                try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            let archive = dir.appendingPathComponent("\(name).tar.xz")
            let tar = try ProcessRunner.runSync("/usr/bin/tar", ["-cJf", archive.path, "-C", staging.deletingLastPathComponent().path, name])
            XCTAssertEqual(tar.status, 0)
            let sum = try ProcessRunner.runSync("/usr/bin/shasum", ["-a", "256", archive.path])
            var digest = String(String(decoding: sum.stdout, as: UTF8.self).prefix(64))
            if tamper { digest = String(repeating: "0", count: 64) }
            try "\(digest)  \(name).tar.xz\n\(String(repeating: "1", count: 64))  node-\(r.version)-linux-x64.tar.xz\n"
                .write(to: dir.appendingPathComponent("SHASUMS256.txt"), atomically: true, encoding: .utf8)
        }
        try tab.write(to: server.appendingPathComponent("index.tab"), atomically: true, encoding: .utf8)
    }

    private func runScript(_ script: String) throws -> (status: Int32, output: String) {
        let env = "PATH='\(bin.path):/usr/bin:/bin'\nexport PATH\n"
        let r = try ProcessRunner.runSync("/bin/sh", ["-s"], stdin: Data((env + script).utf8), timeout: 60)
        return (r.status, String(decoding: r.stdout + r.stderr, as: UTF8.self))
    }

    private func logLines() -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func render(_ p: ProfileConfig) throws -> String {
        try ProfileScript.render(p, packageManager: "apt", user: "dev", root: root.path)
    }

    private let nodeStep = Step(id: "node", title: "Node.js", runtime: "nodejs", commands: ["node"])

    func testRunningTwiceChangesNothingTheSecondTime() throws {
        try makeStubs()
        try publish([("v26.1.0", "-"), ("v24.2.0", "Krypton"), ("v24.1.0", "Krypton")])
        let p = ProfileConfig(id: "mine", name: "Mine", summary: "", steps: [
            // Not curl: the stand-in apt-get would replace the fake nodejs.org.
            Step(id: "base", title: "Base", packages: ["apt": ["git", "less"]], commands: ["git"]),
            nodeStep,
            Step(id: "agents", title: "Agents", npm: ["@scope/tool", "other"], commands: ["tool"]),
            Step(id: "mark", title: "Mark", script: "touch \"$MONAD_ROOT/marker-$MONAD_USER\"\n"),
        ])
        let script = try render(p)
        let first = try runScript(script)
        XCTAssertEqual(first.status, 0, first.output)
        XCTAssertTrue(first.output.contains("@@monad finished"), first.output)
        XCTAssertTrue(logLines().contains { $0.hasPrefix("apt-get install") && $0.contains("git") && $0.contains("less") })
        XCTAssertTrue(logLines().contains { $0.hasPrefix("npm install -g --prefix") && $0.contains("@scope/tool") })
        XCTAssertTrue(logLines().contains("curl https://nodejs.org/dist/v24.2.0/node-v24.2.0-linux-arm64.tar.xz"),
                      "the newest LTS, not the newer Current: \(logLines())")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("opt/monad/node-v24.2.0/bin/node").path))
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("usr/local/bin/node").path)
        XCTAssertTrue(link.hasSuffix("/opt/monad/node-v24.2.0/bin/node"), link)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("marker-dev").path))

        try? FileManager.default.removeItem(at: log)
        let second = try runScript(script)
        XCTAssertEqual(second.status, 0, second.output)
        XCTAssertFalse(logLines().contains { $0.hasPrefix("apt-get") }, "\(logLines())")
        XCTAssertFalse(logLines().contains { $0.hasPrefix("npm install") }, "\(logLines())")
        XCTAssertEqual(logLines().filter { $0.hasPrefix("curl") }, ["curl https://nodejs.org/dist/index.tab"],
                       "only the index is read again")
    }

    /// Commands get no stdin: the script itself comes on it, and one that
    /// reads (a prompt, a cat) would swallow the steps after it.
    func testCommandsCannotReadTheScript() throws {
        try makeStubs()
        let p = ProfileConfig(id: "mine", name: "Mine", summary: "", steps: [
            Step(id: "greedy", title: "Greedy", script: "cat > \"$MONAD_ROOT/stdin\"\n"),
            Step(id: "after", title: "After", script: "touch \"$MONAD_ROOT/after\"\n"),
        ])
        let r = try runScript(try render(p))
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertTrue(r.output.contains("@@monad finished"), r.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("after").path), r.output)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("stdin"), encoding: .utf8), "")
    }

    /// Each step says what it does, so there is more to see than a spinner
    /// while a quiet command runs.
    func testEachActionIsSaid() throws {
        try makeStubs()
        try publish([("v24.2.0", "Krypton")])
        let p = ProfileConfig(id: "mine", name: "Mine", summary: "", steps: [
            Step(id: "base", title: "Base", packages: ["apt": ["git", "less"]]),
            nodeStep,
            Step(id: "agents", title: "Agents", npm: ["@scope/tool"]),
            Step(id: "mark", title: "Mark", script: "true\n"),
        ])
        let first = try runScript(try render(p))
        XCTAssertEqual(first.status, 0, first.output)
        for said in ["› Refreshing the package lists", "› Installing git less", "› Finding the latest Node.js LTS",
                     "› Downloading Node.js v24.2.0", "› Installing with npm: @scope/tool", "› Running the script"] {
            XCTAssertTrue(first.output.contains(said + "\n"), "\(said) in \(first.output)")
        }
        let second = try runScript(try render(p))
        for said in ["› Already installed: git less", "› Node.js v24.2.0 is installed", "› Already installed: @scope/tool"] {
            XCTAssertTrue(second.output.contains(said + "\n"), "\(said) in \(second.output)")
        }
    }

    /// "a|b": the first one the distro has (Ubuntu names Compose v2
    /// docker-compose-v2, Debian docker-compose).
    func testAlternativesInstallTheFirstAvailable() throws {
        try makeStubs()
        let p = ProfileConfig(id: "mine", name: "Mine", summary: "", steps: [
            Step(id: "base", title: "Base", packages: ["apt": ["git", "docker-compose-v2|docker-compose"]],
                 commands: ["docker-compose"]),
        ])
        let script = "KNOWN='git docker-compose'\nexport KNOWN\n" + (try render(p))
        let first = try runScript(script)
        XCTAssertEqual(first.status, 0, first.output)
        let install = try XCTUnwrap(logLines().first { $0.hasPrefix("apt-get install") })
        XCTAssertTrue(install.hasSuffix(" git docker-compose"), install)
        try? FileManager.default.removeItem(at: log)
        XCTAssertEqual(try runScript(script).status, 0)
        XCTAssertFalse(logLines().contains { $0.hasPrefix("apt-get install") }, "installed: nothing to do")
        // None of them: the step says so.
        let none = ProfileConfig(id: "mine", name: "Mine", summary: "", steps: [
            Step(id: "base", title: "Base", packages: ["apt": ["nope-v2|nope"]]),
        ])
        let r = try runScript("KNOWN=''\nexport KNOWN\n" + (try render(none)))
        XCTAssertTrue(r.output.contains("@@monad step base failed none of nope-v2|nope can be installed"), r.output)
    }

    /// herdr (Agentic) by its own installer, saved before it runs (a cut
    /// download runs nothing), into /usr/local/bin; kept once installed.
    func testHerdrByItsInstaller() throws {
        try makeStubs()
        try "#!/bin/sh\nmkdir -p \"$HERDR_INSTALL_DIR\" && printf '#!/bin/sh\\n' > \"$HERDR_INSTALL_DIR/herdr\" && chmod +x \"$HERDR_INSTALL_DIR/herdr\"\n"
            .write(to: server.appendingPathComponent("install.sh"), atomically: true, encoding: .utf8)
        let step = try XCTUnwrap(try ProfileCatalog.bundled().profile("agentic")?.steps.first { $0.id == "herdr" })
        let p = ProfileConfig(id: "mine", name: "Mine", summary: "", steps: [step])
        let r = try runScript(try render(p))
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("usr/local/bin/herdr").path), r.output)
        XCTAssertTrue(logLines().contains("curl https://herdr.dev/install.sh"), "\(logLines())")
        XCTAssertFalse(step.script?.contains("| sh") ?? true, "saved, then run")

        try? FileManager.default.removeItem(at: log)
        XCTAssertEqual(try runScript(try render(p)).status, 0)
        XCTAssertFalse(logLines().contains { $0.contains("herdr.dev") }, "kept once installed: \(logLines())")

        try FileManager.default.removeItem(at: root.appendingPathComponent("usr/local/bin/herdr"))
        try FileManager.default.removeItem(at: server.appendingPathComponent("install.sh"))
        let offline = try runScript(try render(p))
        XCTAssertNotEqual(offline.status, 0)
        XCTAssertTrue(offline.output.contains("herdr installer could not be downloaded"), offline.output)
    }

    private func serverStep(_ id: String) throws -> ProfileConfig {
        let step = try XCTUnwrap(try ProfileCatalog.bundled().profile("server")?.steps.first { $0.id == id })
        return ProfileConfig(id: "mine", name: "Mine", summary: "", steps: [step])
    }

    /// The nerdctl-full release for the CPU (nerdctl with containerd, BuildKit,
    /// RootlessKit and the CNI plugins), checked against its SHA256SUMS, in
    /// /opt/monad/nerdctl, kept once installed. Docker keeps its own containerd.
    func testNerdctlFullFromItsRelease() throws {
        try makeStubs()
        let tag = server.appendingPathComponent("v2.4.0")
        try FileManager.default.createDirectory(at: tag, withIntermediateDirectories: true)
        let staging = server.deletingLastPathComponent().appendingPathComponent("nerdctl-staging")
        for dir in ["bin", "libexec/cni"] {
            try FileManager.default.createDirectory(at: staging.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for file in ["bin/nerdctl", "bin/buildctl", "bin/containerd-rootless-setuptool.sh", "bin/rootlesskit", "bin/containerd",
                     "bin/runc", "libexec/cni/bridge"] {
            let url = staging.appendingPathComponent(file)
            try "#!/bin/sh\necho \(url.lastPathComponent)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let archive = tag.appendingPathComponent("nerdctl-full-2.4.0-linux-arm64.tar.gz")
        XCTAssertEqual(try ProcessRunner.runSync("/usr/bin/tar", ["-czf", archive.path, "-C", staging.path, "bin", "libexec"]).status, 0)
        let sum = String(String(decoding: try ProcessRunner.runSync("/usr/bin/shasum", ["-a", "256", archive.path]).stdout,
                                as: UTF8.self).prefix(64))
        try "\(sum)  nerdctl-full-2.4.0-linux-arm64.tar.gz\n".write(to: tag.appendingPathComponent("SHA256SUMS"), atomically: true,
                                                                       encoding: .utf8)
        // Ubuntu: unprivileged user namespaces only for programs AppArmor allows.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("proc/sys/kernel"), withIntermediateDirectories: true)
        try "1\n".write(to: root.appendingPathComponent("proc/sys/kernel/apparmor_restrict_unprivileged_userns"),
                        atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("etc/apparmor.d"), withIntermediateDirectories: true)
        let parser = bin.appendingPathComponent("apparmor_parser")
        try "#!/bin/sh\necho \"apparmor_parser $*\" >> '\(log.path)'\n".write(to: parser, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parser.path)
        // A plain nerdctl from an older Server profile is replaced.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("usr/local/bin"), withIntermediateDirectories: true)
        try "old".write(to: root.appendingPathComponent("usr/local/bin/nerdctl"), atomically: true, encoding: .utf8)

        let p = try serverStep("nerdctl")
        let env = "LATEST='https://github.com/containerd/nerdctl/releases/tag/v2.4.0'\nexport LATEST\n"
        let r = try runScript(env + (try render(p)))
        XCTAssertEqual(r.status, 0, r.output)
        let fm = FileManager.default
        XCTAssertTrue(fm.isExecutableFile(atPath: root.appendingPathComponent("opt/monad/nerdctl/bin/nerdctl").path))
        for tool in ["nerdctl", "buildctl", "containerd-rootless-setuptool.sh"] {
            let link = try fm.destinationOfSymbolicLink(atPath: root.appendingPathComponent("usr/local/bin/\(tool)").path)
            XCTAssertTrue(link.hasSuffix("/opt/monad/nerdctl/bin/\(tool)"), link)
        }
        for tool in ["containerd", "runc"] {
            XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("usr/local/bin/\(tool)").path), "Docker's \(tool) stays first")
        }
        let cni = try fm.destinationOfSymbolicLink(atPath: root.appendingPathComponent("opt/cni/bin").path)
        XCTAssertTrue(cni.hasSuffix("/opt/monad/nerdctl/libexec/cni"), cni)
        let profile = try String(contentsOf: root.appendingPathComponent("etc/apparmor.d/opt.monad.nerdctl.bin.rootlesskit"),
                                 encoding: .utf8)
        XCTAssertTrue(profile.contains("\"/opt/monad/nerdctl/bin/rootlesskit\" flags=(unconfined) {"), profile)
        XCTAssertTrue(profile.contains("  userns,"), profile)
        XCTAssertTrue(logLines().contains { $0.hasPrefix("apparmor_parser -r ") }, "\(logLines())")
        XCTAssertTrue(r.output.contains("› Downloading nerdctl-full v2.4.0"), r.output)

        // Kept once installed: nothing is downloaded again.
        try? fm.removeItem(at: log)
        XCTAssertEqual(try runScript(env + (try render(p))).status, 0)
        XCTAssertFalse(logLines().contains { $0.contains("nerdctl-full-2.4.0") }, "\(logLines())")

        // Tampered: refused, nothing installed.
        try fm.removeItem(at: root.appendingPathComponent("opt/monad"))
        try "\(String(repeating: "0", count: 64))  nerdctl-full-2.4.0-linux-arm64.tar.gz\n"
            .write(to: tag.appendingPathComponent("SHA256SUMS"), atomically: true, encoding: .utf8)
        let bad = try runScript(env + (try render(p)))
        XCTAssertNotEqual(bad.status, 0)
        XCTAssertTrue(bad.output.contains("the nerdctl download does not match its checksum"), bad.output)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("opt/monad/nerdctl").path))
    }

    /// nerdctl run by the login user is rootless: its own containerd and
    /// BuildKit, set up by nerdctl's tool as that user, kept running without
    /// a login (lingering), with subordinate IDs for the containers' users.
    func testRootlessContainerdForTheLoginUser() throws {
        try makeStubs()
        func stub(_ name: String, _ body: String) throws {
            let url = bin.appendingPathComponent(name)
            try ("#!/bin/sh\nLOG='\(log.path)'\nSTATE='\(root.path)/../state'\n" + body).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try stub("getent", #"[ "$1 $2" = "passwd dev" ] && echo 'dev:x:1000:1000:Monad user:/home/dev:/bin/bash'"#)
        try stub("loginctl", #"echo "loginctl $*" >> "$LOG"; mkdir -p "$MONAD_ROOT/run/user/1000"; : > "$MONAD_ROOT/run/user/1000/bus""#)
        try stub("usermod", #"echo "usermod $*" >> "$LOG"; case "$1" in --add-subuids) f=subuid;; --add-subgids) f=subgid;; *) exit 2;; esac; s=${2%-*}; e=${2#*-}; echo "$3:$s:$((e - s + 1))" >> "$MONAD_ROOT/etc/$f""#)
        // As the user: systemctl --user answers from STATE, the tool records what it set up.
        try stub("runuser", #"echo "runuser $*" >> "$LOG"; case "$*" in *"systemctl --user is-active --quiet "*) for a; do u="$a"; done; [ -f "$STATE/active-$u" ]; exit $?;; *"setuptool.sh install-buildkit"*) touch "$STATE/active-buildkit.service";; *"setuptool.sh install"*) touch "$STATE/active-containerd.service";; esac"#)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("etc"), withIntermediateDirectories: true)
        try "other:100000:65536\n".write(to: root.appendingPathComponent("etc/subuid"), atomically: true, encoding: .utf8)
        try "other:100000:65536\n".write(to: root.appendingPathComponent("etc/subgid"), atomically: true, encoding: .utf8)

        let p = try serverStep("rootless")
        let r = try runScript(try render(p))
        XCTAssertEqual(r.status, 0, r.output)
        let lines = logLines()
        XCTAssertTrue(lines.contains("usermod --add-subuids 165536-231071 dev"), "\(lines)")
        XCTAssertTrue(lines.contains("usermod --add-subgids 165536-231071 dev"), "\(lines)")
        XCTAssertTrue(lines.contains("loginctl enable-linger dev"), "\(lines)")
        let asUser = lines.filter { $0.hasPrefix("runuser -u dev -- env ") }
        XCTAssertEqual(asUser.count, lines.filter { $0.hasPrefix("runuser") }.count, "everything as the user")
        for line in asUser {
            XCTAssertTrue(line.contains("HOME=/home/dev XDG_RUNTIME_DIR=/run/user/1000 "), line)
            XCTAssertTrue(line.contains("PATH=/opt/monad/nerdctl/bin:"), "the bundle's containerd and runc for the user's: \(line)")
        }
        XCTAssertTrue(asUser.contains { $0.hasSuffix(" containerd-rootless-setuptool.sh install") }, "\(asUser)")
        XCTAssertTrue(asUser.contains { $0.hasSuffix(" containerd-rootless-setuptool.sh install-buildkit") }, "\(asUser)")

        // Set up already: nothing installed again, the IDs not added twice.
        try? FileManager.default.removeItem(at: log)
        XCTAssertEqual(try runScript(try render(p)).status, 0)
        XCTAssertFalse(logLines().contains { $0.contains("setuptool.sh install") || $0.hasPrefix("usermod") }, "\(logLines())")
    }

    func testANewLTSReplacesTheOldOne() throws {
        try makeStubs()
        try publish([("v24.1.0", "Krypton")])
        let p = ProfileConfig(id: "mine", name: "Mine", summary: "", steps: [nodeStep])
        XCTAssertEqual(try runScript(try render(p)).status, 0)
        try publish([("v24.2.0", "Krypton"), ("v24.1.0", "Krypton")])
        let r = try runScript(try render(p))
        XCTAssertEqual(r.status, 0, r.output)
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("usr/local/bin/node").path)
        XCTAssertTrue(link.hasSuffix("/opt/monad/node-v24.2.0/bin/node"), link)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("opt/monad/node-v24.1.0").path))
    }

    func testAFailedStepStopsTheRunAndSaysWhy() throws {
        try makeStubs()
        let p = ProfileConfig(id: "mine", name: "Mine", summary: "", steps: [
            Step(id: "base", title: "Base", packages: ["apt": ["git"]], commands: ["not-there"]),
            Step(id: "later", title: "Later", script: "touch \"$MONAD_ROOT/later\"\n"),
        ])
        let r = try runScript(try render(p))
        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(r.output.contains("@@monad step base failed not-there is not on PATH"), r.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("later").path))
    }

    func testADownloadThatDoesNotMatchItsChecksumIsRefused() throws {
        try makeStubs()
        try publish([("v24.2.0", "Krypton")], tamper: true)
        let r = try runScript(try render(ProfileConfig(id: "mine", name: "Mine", summary: "", steps: [nodeStep])))
        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(r.output.contains("@@monad step node failed the Node.js download does not match its checksum"), r.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("opt/monad/node-v24.2.0").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("usr/local/bin/node").path))
    }

    func testOddIndexesAndCPUsAreRefused() throws {
        cpu = "riscv64"
        try makeStubs()
        try publish([("v24.2.0", "Krypton")])
        let p = ProfileConfig(id: "mine", name: "Mine", summary: "", steps: [nodeStep])
        var r = try runScript(try render(p))
        XCTAssertTrue(r.output.contains("@@monad step node failed no Node.js build for riscv64"), r.output)
        // A version that is not one (it becomes part of a URL and a path).
        cpu = "aarch64"
        try makeStubs()
        try "version\tdate\tfiles\tnpm\tv8\tuv\tzlib\topenssl\tmodules\tlts\tsecurity\nv24.2.0/../x\td\tlinux-arm64\t-\t-\t-\t-\t-\t-\tKrypton\tfalse\n"
            .write(to: server.appendingPathComponent("index.tab"), atomically: true, encoding: .utf8)
        r = try runScript(try render(p))
        XCTAssertTrue(r.output.contains("@@monad step node failed no Node.js LTS release found"), r.output)
    }
}
