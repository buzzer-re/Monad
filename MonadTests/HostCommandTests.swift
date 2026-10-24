//
//  HostCommandTests.swift — a host command (agents phase):
//  a Mac program the user chose, the arguments the VM may vary and the
//  patterns each must match. The VM's request is parsed by Monad (quotes,
//  no shell) and checked before anything runs.
//

import XCTest
@testable import Monad

/// A build command, in a shared folder `share`.
func buildCommand(in share: String = "/Users/someone/src/app") -> HostCommand {
    HostCommand(name: "app-make", summary: "Build and benchmark the app on the Mac.", program: "/usr/bin/make",
                arguments: [
                    .init(name: "target", pattern: "^(build|test|benchmark)$", required: true,
                          summary: "The make target."),
                    .init(name: "model", pattern: "^MODEL=[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$", required: false,
                          summary: "MODEL=<repo>:<quant>"),
                    .init(name: "args", pattern: "^BENCH_ARGS=[A-Za-z0-9 ,._=+/-]{0,200}$", required: false,
                          summary: "Arguments for the profile."),
                ],
                workingDirectory: share, timeoutSeconds: 3600, results: true,
                environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"], guestSocket: "/run/monad/app-make.sock")
}

final class HostCommandTests: XCTestCase {
    /// The request line: `run` and the values quoted as a shell would, by
    /// Monad's own rules (single quotes, double quotes with backslash, no
    /// expansion of any kind), or `describe`.
    func testRequestsAreParsedWithoutAShell() throws {
        let table: [(String, HostCommand.Request)] = [
            ("describe", .describe),
            ("describe\n", .describe),
            ("run", .run([])),
            ("run build", .run(["build"])),
            ("run  build   MODEL=a/b:Q4\n", .run(["build", "MODEL=a/b:Q4"])),
            ("run 'BENCH_ARGS=--prompt-tokens 2048 --cycles 9'", .run(["BENCH_ARGS=--prompt-tokens 2048 --cycles 9"])),
            (#"run "a \"quoted\" \\ value""#, .run([#"a "quoted" \ value"#])),
            (#"run "it's""#, .run(["it's"])),
            (#"run 'say "hi"'"#, .run([#"say "hi""#])),
            (#"run a\b"#, .run([#"a\b"#])),
            ("run '' x", .run(["", "x"])),
            ("run a'b c'd", .run(["ab cd"])),
            ("run $(rm -rf ~) `id` ;", .run(["$(rm", "-rf", "~)", "`id`", ";"])),
        ]
        for (line, expected) in table {
            XCTAssertEqual(try HostCommand.parseRequest(line), expected, line)
        }
        let refused: [(String, String)] = [
            ("", "Say run or describe."),
            ("rm -rf /", "Say run or describe."),
            ("run 'open", "A quote is not closed."),
            (#"run "open"#, "A quote is not closed."),
            ("run a\u{7}b", "Control characters are not allowed."),
            ("run a\u{1B}[2J", "Control characters are not allowed."),
            ("run caf\u{E9}", "Only printable ASCII is allowed."),
            ("run " + String(repeating: "a", count: HostCommand.maxRequestBytes), "The request is too long."),
        ]
        for (line, why) in refused {
            XCTAssertThrowsError(try HostCommand.parseRequest(line), line) {
                XCTAssertEqual($0.localizedDescription, why, line)
            }
        }
    }

    /// Values meet the patterns before anything runs; a miss names the
    /// argument and its pattern. The program gets the fixed arguments, then
    /// the values given.
    func testValuesAreCheckedAgainstThePatterns() throws {
        var c = buildCommand()
        c.fixedArguments = ["-s"]
        XCTAssertEqual(try c.arguments(for: ["build"]), ["-s", "build"])
        XCTAssertEqual(try c.arguments(for: ["benchmark", "MODEL=org/model:Q4_K_M",
                                             "BENCH_ARGS=--prompt-tokens 2048 --cycles 9"]),
                       ["-s", "benchmark", "MODEL=org/model:Q4_K_M",
                        "BENCH_ARGS=--prompt-tokens 2048 --cycles 9"])
        let refused: [([String], String)] = [
            (["clean"], "target “clean” does not match ^(build|test|benchmark)$."),
            ([], "target is required."),
            (["build", "MODEL=x; rm -rf ~"], "model “MODEL=x; rm -rf ~” does not match ^MODEL=[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$."),
            (["build", "MODEL=a", "BENCH_ARGS=x", "more"], "app-make takes at most 3 values."),
            (["buildx"], "target “buildx” does not match ^(build|test|benchmark)$."),
            (["build\nclean"], "target “build\nclean” does not match ^(build|test|benchmark)$."),
        ]
        for (values, why) in refused {
            XCTAssertThrowsError(try c.arguments(for: values), "\(values)") {
                XCTAssertEqual($0.localizedDescription, why)
            }
        }
    }

    /// A pattern that backtracks without end (a nested quantifier) cannot
    /// hold MonadHost: the match gives up after a moment and the value is
    /// refused. A value is at most 1 KB. Such a pattern is pointed out.
    func testAPatternThatBacktracksCannotHangTheMac() throws {
        let c = HostCommand(name: "slow", summary: "", program: "/bin/echo",
                            arguments: [.init(name: "word", pattern: "^(a+)+$")], workingDirectory: "/tmp")
        let start = Date()
        XCTAssertThrowsError(try c.arguments(for: [String(repeating: "a", count: 64) + "!"])) {
            XCTAssertTrue($0.localizedDescription.contains("too long"), $0.localizedDescription)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "given up, not run to the end")
        XCTAssertEqual(try c.arguments(for: ["aaaa"]), ["aaaa"], "a value that matches still does")
        XCTAssertThrowsError(try c.arguments(for: [String(repeating: "a", count: 1025)]), "at most 1 KB")
        XCTAssertTrue(c.warnings.contains { $0.contains("word") && $0.contains("nested") }, "\(c.warnings)")
        var alternation = c
        alternation.arguments = [.init(name: "word", pattern: "^(a|aa)+$")]
        XCTAssertTrue(alternation.warnings.contains { $0.contains("nested") }, "a repeated alternation backtracks too")
        XCTAssertFalse(buildCommand().warnings.contains { $0.contains("nested") }, "\(buildCommand().warnings)")
    }

    /// `describe`: what an agent needs to call it, one JSON line.
    func testDescribeIsOneJSONLine() throws {
        let line = buildCommand().describe
        XCTAssertFalse(line.contains("\n"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "app-make")
        XCTAssertEqual(json["summary"] as? String, "Build and benchmark the app on the Mac.")
        let args = try XCTUnwrap(json["arguments"] as? [[String: Any]])
        XCTAssertEqual(args.map { $0["name"] as? String }, ["target", "model", "args"])
        XCTAssertEqual(args[0]["required"] as? Bool, true)
        XCTAssertEqual(args[1]["pattern"] as? String, "^MODEL=[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$")
        XCTAssertNil(json["program"], "the VM is not told which program runs")
        XCTAssertNil(json["environment"])
    }

    /// Each rule in the user's words; the VM's config refuses a bad one on
    /// create, update and load.
    func testABadHostCommandIsRefusedWithItsReason() {
        let share = SharedFolder(hostPath: "/Users/someone/src", guestPath: "/home/dev/src", readOnly: false)
        func problem(_ change: (inout HostCommand) -> Void) -> String? {
            var c = buildCommand(in: "/Users/someone/src/app")
            change(&c)
            return c.problem(shares: [share])
        }
        XCTAssertNil(problem { _ in })
        XCTAssertEqual(problem { $0.name = "App Make" }, "“App Make” cannot be a tool name: lowercase letters, digits and dashes.")
        XCTAssertEqual(problem { $0.program = "make" }, "The program needs its full path, like /usr/bin/make.")
        XCTAssertEqual(problem { $0.program = "/usr/bin/../bin/make" }, "The program needs its full path, like /usr/bin/make.")
        XCTAssertEqual(problem { $0.arguments[0].pattern = "build|test" },
                       "target: a pattern starts with ^ and ends with $, so it covers the whole value.")
        XCTAssertEqual(problem { $0.arguments[0].pattern = "^(build$" }, "target: the pattern does not compile.")
        XCTAssertEqual(problem { $0.arguments[0].pattern = "^" + String(repeating: "a", count: 300) + "$" },
                       "target: a pattern is at most 256 characters.")
        XCTAssertEqual(problem { $0.arguments[0].pattern = "^caf\u{E9}$" }, "target: a pattern is printable ASCII.")
        XCTAssertEqual(problem { $0.arguments[1].name = "target" }, "Two arguments are called target.")
        XCTAssertEqual(problem { $0.arguments = Array(repeating: $0.arguments[1], count: 17) },
                       "A host command takes at most 16 arguments.")
        XCTAssertEqual(problem { $0.workingDirectory = "/Users/someone" },
                       "The working folder must be inside a folder this VM shares.")
        XCTAssertEqual(problem { $0.workingDirectory = "relative" },
                       "The working folder must be inside a folder this VM shares.")
        XCTAssertEqual(problem { $0.environment["DYLD_INSERT_LIBRARIES"] = "/x.dylib" }, "DYLD_INSERT_LIBRARIES cannot be set.")
        XCTAssertEqual(problem { $0.environment["HOME"] = "/tmp" }, "HOME cannot be set.")
        XCTAssertEqual(problem { $0.environment["lower"] = "x" }, "“lower” is not a variable name (A-Z, 0-9, _).")
        XCTAssertEqual(problem { $0.environment["X"] = "a\u{0}b" }, "X: a value is printable ASCII.")
        XCTAssertEqual(problem { $0.timeoutSeconds = 0 }, "The time limit is 1 second to 24 hours.")
        XCTAssertEqual(problem { $0.timeoutSeconds = 86_401 }, "The time limit is 1 second to 24 hours.")
        XCTAssertEqual(problem { $0.fixedArguments = ["a\nb"] }, "A fixed argument has a control character.")
        XCTAssertEqual(problem { $0.guestSocket = nil; $0.guestPort = 80 },
                       "In the VM: a port from 1024 to 65535, or a socket's full path.")
        XCTAssertEqual(problem { $0.summary = String(repeating: "s", count: 301) }, "The summary is at most 300 characters.")
        XCTAssertTrue(buildCommand().warnings.isEmpty)
        var loose = buildCommand()
        loose.arguments[2].pattern = "^.*$"
        XCTAssertEqual(loose.warnings, ["args takes anything (.*): the program gets whatever the VM sends."])
    }

    /// In the VM's settings: round trip, written only when there are some,
    /// counted with the bridges, every endpoint in the VM its own.
    func testHostCommandsInTheVMsSettings() throws {
        var config = InstanceConfig.defaults(name: "work")
        config.sharing.runtimeEnabled = true
        config.sharing.shares = [SharedFolder(hostPath: "/Users/someone/src", guestPath: "/home/dev/src", readOnly: false)]
        let plain = try JSONEncoder().encode(config)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("hostCommands"))
        config.hostCommands = [buildCommand(in: "/Users/someone/src/app")]
        XCTAssertNoThrow(try config.validate(maxCPUs: 8, maxMemoryGiB: 16))
        let decoded = try JSONDecoder().decode(InstanceConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.hostCommands, config.hostCommands)

        var bad = config
        bad.hostCommands[0].program = "make"
        XCTAssertThrowsError(try bad.validate(maxCPUs: 8, maxMemoryGiB: 16)) {
            XCTAssertEqual($0.localizedDescription, "app-make: The program needs its full path, like /usr/bin/make.")
        }
        var crowded = config
        crowded.bridges = (0..<8).map { CommandBridge(name: "b\($0)", command: ["/bin/cat"], guestPort: 9000 + $0) }
        XCTAssertThrowsError(try crowded.validate(maxCPUs: 8, maxMemoryGiB: 16), "8 bridges and host commands at most")
        var twice = config
        twice.hostCommands.append(buildCommand(in: "/Users/someone/src/app"))
        XCTAssertThrowsError(try twice.validate(maxCPUs: 8, maxMemoryGiB: 16), "names and endpoints are each one's own")
        var clash = config
        clash.bridges = [CommandBridge(name: "b", command: ["/bin/cat"], guestSocket: "/run/monad/app-make.sock")]
        XCTAssertThrowsError(try clash.validate(maxCPUs: 8, maxMemoryGiB: 16), "a bridge on the same socket")
        var unshared = config
        unshared.sharing.shares = []
        XCTAssertThrowsError(try unshared.validate(maxCPUs: 8, maxMemoryGiB: 16), "its folder is no longer shared")

        XCTAssertEqual(ConfigChange.restartOnly(from: config, to: bad), [], "host commands change live")
        XCTAssertEqual(ConfigChange.all(from: config, to: bad), ["host commands"])
    }

    /// The Mac side: a private socket and log in the VM's folder, short
    /// enough for a unix socket path; the VM reaches it by a remote forward.
    func testItsPlaceOnTheMacAndInTheVM() {
        let c = buildCommand()
        let paths = InstancePaths(name: "work", root: URL(fileURLWithPath: "/Users/someone/.monad/instances"))
        XCTAssertTrue(c.socket(in: paths).lastPathComponent.hasPrefix("cmd-"))
        XCTAssertEqual(c.socket(in: paths).deletingLastPathComponent().path, paths.dir.path)
        XCTAssertEqual(c.spec(in: paths), SSHMux.Spec(flag: "-R", value: "/run/monad/app-make.sock:\(c.socket(in: paths).path)"))
        var onPort = c
        onPort.guestSocket = nil
        onPort.guestPort = 9100
        XCTAssertEqual(onPort.guestEndpoint, "127.0.0.1:9100")
    }
}
