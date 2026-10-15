#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import struct Assertion.AssertionClaims
import struct Assertion.SignedAssertion
@testable import CLIKit
import Crypto
import Dispatch
#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif
import Scratch
import Synchronization
import Testing

struct AssertionCacheTests {
  @Test(arguments: ["space.example", "space.example:443", "https://space.example", "https://SPACE.EXAMPLE:443/"])
  func secureDefaultPortAliasesShareOneKey(_ spelling: String) {
    #expect(Wallet.assertionKey(spelling) == "space.example:443")
  }

  @Test func portsSchemesAndIPv6RemainUnambiguous() {
    #expect(Wallet.assertionKey("https://space.example:5530/") == "space.example:5530")
    #expect(Wallet.assertionKey("http://space.example") == "http://space.example:80")
    #expect(Wallet.assertionKey("http://space.example:443") == "http://space.example:443")
    #expect(Wallet.assertionKey("https://[::1]") == "[::1]:443")
    #expect(Wallet.assertionKey("[::1]:443") == "[::1]:443")
  }

  @Test func aliasesMergeTheFreshestValidAssertionForTheAuthoritativeAudience() throws {
    let scratch = try ScratchFolder("assertion-aliases")
    defer { scratch.remove() }
    let key = Curve25519.Signing.PrivateKey()
    let identity = "spc_" + String(repeating: "a", count: 32)
    func assertion(_ expiry: TimeInterval, space: String? = nil) throws -> SignedAssertion {
      try AssertionClaims(
        key: "ed25519:" + key.publicKey.rawRepresentation.base64EncodedString(),
        space: space ?? identity,
        expiresAt: Date(timeIntervalSince1970: expiry),
      ).signed(by: key)
    }
    let expired = try assertion(1)
    let fresh = try assertion(3600)
    let staleAudience = try assertion(7200, space: "spc_" + String(repeating: "b", count: 32))
    let forged = try assertion(10800).rawValue.split(separator: ".").prefix(2).joined(separator: ".") + ".AA"
    let unrelated = ["space.example:5530": expired.rawValue, "http://space.example:443": expired.rawValue, "other.example:443": expired.rawValue]
    var entries = unrelated
    entries["space.example:443"] = staleAudience.rawValue
    entries["https://space.example"] = expired.rawValue
    entries["https://SPACE.EXAMPLE:443/"] = fresh.rawValue
    entries["space.example"] = forged
    entries["https://space.example/"] = "malformed"
    let file = scratch.url.appendingPathComponent("assertions.json")
    #expect(FileManager.default.createFile(atPath: file.path, contents: try JSONEncoder().encode(entries), attributes: [.posixPermissions: 0o600]))
    var wallet = Wallet(directory: scratch.url)
    #expect(wallet.assertion(space: "https://space.example", identity: identity) == fresh)
    let merged = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
    #expect(merged == unrelated.merging(["space.example:443": fresh.rawValue]) { $1 })
    #expect(posixMode(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]) == 0o600)
    #expect(wallet.drainWarnings().isEmpty)
    #expect(wallet.assertion(space: "space.example", identity: identity) == fresh)
  }

  @Test func newCredentialsReplaceAllAliasesWithoutTouchingOtherServers() throws {
    let scratch = try ScratchFolder("assertion-record")
    defer { scratch.remove() }
    let file = scratch.url.appendingPathComponent("assertions.json")
    let entries = ["https://space.example": "expired", "space.example:443": "expired", "other.example:443": "unrelated"]
    #expect(FileManager.default.createFile(atPath: file.path, contents: try JSONEncoder().encode(entries), attributes: [.posixPermissions: 0o600]))
    var wallet = Wallet(directory: scratch.url)
    wallet.recordAssertion("fresh", space: "https://SPACE.EXAMPLE:443/")
    let recorded = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
    #expect(recorded == ["space.example:443": "fresh", "other.example:443": "unrelated"])
  }

  @Test func migrationAndMintingSerializeTheirFreshReadsAndPreserveBothServers() throws {
    let scratch = try ScratchFolder("assertion-writers")
    defer { scratch.remove() }
    let key = Curve25519.Signing.PrivateKey()
    let identity = "spc_" + String(repeating: "a", count: 32)
    let first = try AssertionClaims(
      key: "ed25519:" + key.publicKey.rawRepresentation.base64EncodedString(),
      space: identity, expiresAt: Date(timeIntervalSince1970: 3600),
    ).signed(by: key)
    let file = scratch.url.appendingPathComponent("assertions.json")
    #expect(FileManager.default.createFile(atPath: file.path, contents: try JSONEncoder().encode(["https://first.example": first.rawValue]), attributes: [.posixPermissions: 0o600]))
    let lockURL = scratch.url.appendingPathComponent(".assertions.lock")
    let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { Issue.record("could not open fixture lock"); return }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else { Issue.record("could not hold fixture lock"); return }
    let started = DispatchSemaphore(value: 0)
    let migrated = DispatchSemaphore(value: 0)
    let minted = DispatchSemaphore(value: 0)
    let group = DispatchGroup()
    let warnings = Mutex<[String]>([])
    let directory = scratch.url
    DispatchQueue.global().async(group: group) {
      var wallet = Wallet(directory: directory)
      started.signal()
      _ = wallet.assertion(space: "first.example:443", identity: identity)
      warnings.withLock { $0 += wallet.drainWarnings() }
      migrated.signal()
    }
    DispatchQueue.global().async(group: group) {
      var wallet = Wallet(directory: directory)
      started.signal()
      wallet.recordAssertion("second-credential", space: "https://second.example")
      warnings.withLock { $0 += wallet.drainWarnings() }
      minted.signal()
    }
    #expect(started.wait(timeout: .now() + 5) == .success)
    #expect(started.wait(timeout: .now() + 5) == .success)
    #expect(migrated.wait(timeout: .now() + 0.1) == .timedOut)
    #expect(minted.wait(timeout: .now() + 0.1) == .timedOut)
    // The holder publishes a new entry after contenders started: neither may
    // use a snapshot read before acquiring the lock.
    let staged = scratch.url.appendingPathComponent("intervening.json")
    #expect(FileManager.default.createFile(atPath: staged.path, contents: try JSONEncoder().encode(["https://first.example": first.rawValue, "intervening.example:443": "intervening-credential"]), attributes: [.posixPermissions: 0o600]))
    #expect(rename(staged.path, file.path) == 0)
    #expect(flock(fd, LOCK_UN) == 0)
    // Join even on timeout so a failing test cannot remove live writers' files.
    let completion = group.wait(timeout: .now() + 5)
    group.wait()
    #expect(completion == .success)
    #expect(warnings.withLock { $0.isEmpty })
    let merged = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
    #expect(merged == ["first.example:443": first.rawValue, "second.example:443": "second-credential", "intervening.example:443": "intervening-credential"])
    #expect(posixMode(try FileManager.default.attributesOfItem(atPath: lockURL.path)[.posixPermissions]) == 0o600)
  }

  @Test(arguments: [false, true])
  func unsafeLockFilesRefuseCacheWritesWithoutChangingTheTarget(_ symlink: Bool) throws {
    let scratch = try ScratchFolder("assertion-unsafe-lock")
    defer { scratch.remove() }
    let lock = scratch.url.appendingPathComponent(".assertions.lock")
    let target = scratch.url.appendingPathComponent("decoy")
    #expect(FileManager.default.createFile(atPath: target.path, contents: Data("unchanged".utf8), attributes: [.posixPermissions: 0o600]))
    if symlink {
      try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)
    } else {
      #expect(FileManager.default.createFile(atPath: lock.path, contents: Data(), attributes: [.posixPermissions: 0o644]))
    }
    var wallet = Wallet(directory: scratch.url)
    wallet.recordAssertion("credential", space: "space.example")
    #expect(!FileManager.default.fileExists(atPath: scratch.url.appendingPathComponent("assertions.json").path))
    #expect(wallet.drainWarnings().joined().contains("could not cache"))
    #expect(try Data(contentsOf: target) == Data("unchanged".utf8))
  }
}
