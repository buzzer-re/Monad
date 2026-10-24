//
//  ParserFuzzTests.swift — the Swift parsers that read unverified or guest
//  data, fed mutated copies of valid input and random bytes (F-19). Each
//  checks a property, not only that nothing crashes: what a parser lets
//  through is always of the form the rest of Monad relies on.
//

import CryptoKit
import XCTest
@testable import Monad

/// Deterministic, so a failure can be replayed (SplitMix64).
struct FuzzRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }

    /// A mutated copy of one of `seeds`, or random bytes now and then.
    mutating func mutate(_ seeds: [[UInt8]]) -> [UInt8] {
        if seeds.isEmpty || below(12) == 0 { return (0..<below(300)).map { _ in UInt8(truncatingIfNeeded: next()) } }
        var b = seeds[below(seeds.count)]
        let interesting: [UInt8] = Array(" \t\r\n:;,./*-_=@\\\"'<>%".utf8) + [0, 0x1B, 0x7F, 0xC2, 0x80, 0xE2, 0xFF]
        for _ in 0..<(1 + below(6)) {
            guard !b.isEmpty else { break }
            let at = below(b.count)
            switch below(6) {
            case 0: b[at] ^= UInt8(1 << below(8))
            case 1: b[at] = interesting[below(interesting.count)]
            case 2: b.insert(interesting[below(interesting.count)], at: at)
            case 3: b.remove(at: at)
            case 4: b.removeSubrange(at..<min(b.count, at + below(16)))
            default: b.insert(contentsOf: b[at..<min(b.count, at + below(32))], at: below(b.count))
            }
        }
        return b
    }

    mutating func mutateText(_ seeds: [String]) -> String {
        String(decoding: mutate(seeds.map { Array($0.utf8) }), as: UTF8.self)
    }
}

final class ParserFuzzTests: XCTestCase {
    private let rounds = 3000

    func testChecksumFilesOnlyYieldSafeNamesAndDigests() {
        var r = FuzzRandom(seed: 1)
        let sha = String(repeating: "ab", count: 32)
        let seeds = ["\(sha)  disk.qcow2\n\(sha) *other.img\n", "SHA256 (b-2-5.aarch64.raw) = \(sha)\n",
                     "\(sha)  ../../etc/passwd\n", "# comment\n\(sha)\r\n"]
        var accepted = 0
        for _ in 0..<rounds {
            let text = r.mutateText(seeds)
            for format in [ChecksumFile.Format.gnu, .bsd] {
                guard let file = try? ChecksumFile(text: text, format: format, algorithm: .sha256) else { continue }
                accepted += 1
                for e in file.entries {
                    XCTAssertTrue(ChecksumFile.isSafeFileName(e.file), e.file)
                    XCTAssertEqual(e.digest.count, 64)
                    XCTAssertTrue(e.digest.allSatisfy { "0123456789abcdef".contains($0) }, e.digest)
                }
            }
        }
        XCTAssertGreaterThan(accepted, rounds / 20, "the mutations reach the parser's accepting paths")
    }

    func testDirectoryListingsOnlyYieldSafeNames() {
        var r = FuzzRandom(seed: 2)
        let seeds = [#"<a href="B-2-5-CHECKSUM">x</a> <a href='./b-2-5.raw'>y</a>"#, #"<A HREF="../up">u</A>"#,
                     #"href="a/b" href="%2e%2e" href=".hidden" href="ok.img""#]
        var found = 0
        for _ in 0..<rounds {
            let html = r.mutateText(seeds)
            for name in DirectoryIndex.files(in: html) {
                found += 1
                XCTAssertTrue(ChecksumFile.isSafeFileName(name), name)
            }
            if let name = try? DirectoryIndex.file(in: html, matching: "*") {
                XCTAssertTrue(ChecksumFile.isSafeFileName(name), name)
            }
        }
        XCTAssertGreaterThan(found, rounds / 10)
    }

    func testTheAgentsLinesAreBoundedAndWhole() {
        var r = FuzzRandom(seed: 3)
        var reader = AgentLineReader(maxLineLength: 64)
        let seeds = ["port+ tcp 0.0.0.0 8000\n", "hello monad-agent 1\r\n", "port- tcp [::1] 22\n",
                     String(repeating: "x", count: 100) + "\n"]
        for _ in 0..<rounds {
            let bytes = r.mutate(seeds.map { Array($0.utf8) })
            for line in reader.feed(Data(bytes)) {
                XCTAssertLessThanOrEqual(line.utf8.count, 64)
                XCTAssertFalse(line.contains("\n"))
                _ = AgentMessage.parse(line)
            }
            XCTAssertLessThanOrEqual(reader.bufferedBytes, 64, "memory stays bounded")
        }
    }

    func testProfileProgressOnlyNamesRealProfiles() {
        var r = FuzzRandom(seed: 4)
        let seeds = ["@@monad step node start", "@@monad step docker failed exit 3", "@@monad pid 4242",
                     "@@monad finished", "@@monad step ../x done"]
        for _ in 0..<rounds {
            switch ProfileProgress.parse(r.mutateText(seeds)) {
            case .started(let id), .finished(let id), .failed(let id, _): XCTAssertTrue(ProfileConfig.isID(id), id)
            case .pid(let n): XCTAssertGreaterThan(n, 1)
            case .allDone, nil: break
            }
        }
    }

    func testFirewallQuestionsOnlyCarryUsableNames() {
        var r = FuzzRandom(seed: 5)
        let seeds = ["event ask 3 tcp 93.184.216.34 443 www.example.com,example.com", "event ask 0 icmp 1.1.1.1 0",
                     "event lookup 4 api.example.com", "event ask 1 udp 9.9.9.9 53 a.b,*.c,d!e"]
        var accepted = 0
        for i in 0..<rounds {
            guard let event = FirewallAsk.parse(r.mutateText(seeds), id: UInt64(i)) else { continue }
            accepted += 1
            XCTAssertGreaterThanOrEqual(event.port, 0)
            for name in event.ask.names {
                XCTAssertFalse(name.hasPrefix("*"), name)
                XCTAssertTrue(NetworkDefinition.isHostPattern(name), name)
            }
            if event.ask.isLookup {
                XCTAssertEqual(event.ask.names.count, 1)
            } else {
                XCTAssertNotNil(NetworkDefinition.parseIPv4(event.ask.address), event.ask.address)
                XCTAssertTrue((0...65535).contains(event.ask.port))
            }
        }
        XCTAssertGreaterThan(accepted, rounds / 20)
    }

    func testShareProblemsNeverCrash() {
        var r = FuzzRandom(seed: 6)
        let seeds = ["shares-failed: /home/dev/src: mkdir: Permission denied\n", "shares-ok\n", "shares-failed: x\n"]
        for _ in 0..<rounds {
            let out = r.mutate(seeds.map { Array($0.utf8) })
            _ = GuestShares.problem(ProcessRunner.Result(status: Int32(r.below(3)), stdout: Data(out), stderr: Data()))
        }
    }

    /// A signature over a message never verifies a changed message, and a
    /// clearsigned file that verifies yields exactly the signed text.
    func testSignaturesNeverCoverChangedText() throws {
        var r = FuzzRandom(seed: 7)
        let signer = TestSigner()
        let keys = try OpenPGP.keys(from: Data(signer.armoredKey.utf8))
        let now = Date(timeIntervalSince1970: TimeInterval(signer.created) + 100)
        let message = "\(String(repeating: "ab", count: 32))  disk.qcow2\n- dashed line\nlast\n"
        let detached = signer.detachedSignature(over: Data(message.utf8))
        let clear = signer.clearsign(message)
        for _ in 0..<500 {
            let changed = r.mutate([Array(message.utf8)])
            if changed != Array(message.utf8) {
                XCTAssertThrowsError(try OpenPGP.verifyDetached(Data(changed), signature: detached, keys: keys, now: now))
            }
            let file = Data(r.mutate([Array(clear)]))
            if let verified = try? OpenPGP.verifyClearsigned(file, keys: keys, now: now) {
                XCTAssertEqual(verified.text, message, "a verified clearsigned file says only what was signed")
            }
            _ = try? OpenPGP.keys(from: Data(r.mutate([Array(signer.armoredKey.utf8)])))
        }
    }
}
