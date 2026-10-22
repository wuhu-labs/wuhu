import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@testable import CLIKit
import Dependencies
import Fetch
import JSONValue
import SpaceCore
import Testing

@Suite(.deterministicDependencies, .serialized) struct LiveUserVerbTests {
  @Test func addEnrollInviteAndPromoteWithoutStoppingTheServer() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      _ = try await signIn(rig, server: server, admin: true)
      let added = CLIIO()
      #expect(await rig.run(["user", "add", "--name", "bob"], io: added) == 0)
      let lines = await added.stdoutText().split(separator: "\n").map(String.init)
      #expect(lines.count == 2)
      let bob = try #require(try await rig.space.accounts().first { $0.name == "bob" })
      #expect(lines.first == "account \(bob.id.rawValue) (bob)")
      #expect(!bob.isAdmin)
      let personal = try #require(try await rig.space.personalGroup(of: bob.id))
      #expect(try await rig.space.memberGroups(of: bob.id) == [personal])
      #expect(try await rig.space.reads(personal) == [personal, .settings])
      #expect(try await rig.space.isHumanAdmin(bob.id, of: personal))
      #expect(try await rig.space.ensurePersonalGroup(account: bob.id) == personal)
      #expect(await added.stderrText() == "one-time link; it dies at first use or in 3600 seconds\n")
      let envelope = try #require(EnrollmentEnvelope.parse(lines[1]))
      #expect(envelope.space == server.space)
      #expect(envelope.fingerprint == server.fingerprint)
      #expect(envelope.server == "https://127.0.0.1:\(server.port)")

      let secondDevice = try EnrollRig(sharing: rig)
      let login = CLIIO(stdin: lines[1])
      #expect(await secondDevice.run(["login"], io: login) == 0)
      #expect(await login.stdoutText() == "enrolled \(bob.id.rawValue) (device)\n")
      #expect(await secondDevice.run(["login"], io: CLIIO(stdin: lines[1])) == 1)
      try secondDevice.pinWallet(to: "127.0.0.1:\(server.port)")

      let invited = CLIIO()
      #expect(await secondDevice.run(["user", "invite", bob.id.rawValue, "--ttl", "60"], io: invited) == 0)
      let fresh = try #require(EnrollmentEnvelope.parse(await invited.stdoutText()))
      #expect(fresh.token != envelope.token)
      #expect(await invited.stderrText() == "one-time link; it dies at first use or in 60 seconds\n")
      rig.clock.advance(by: 61)
      #expect(await secondDevice.run(["login"], io: CLIIO(stdin: fresh.url)) == 1)

      let promoted = CLIIO()
      #expect(await rig.run(["user", "admin", bob.id.rawValue], io: promoted) == 0)
      #expect(await promoted.stdoutText() == "account \(bob.id.rawValue) admin\n")
      #expect(try await rig.space.isHumanAdmin(bob.id, of: .shared))
      let adminAdd = CLIIO()
      #expect(await secondDevice.run(["user", "add", "--name", "carol", "--admin", "--ttl", "90"], io: adminAdd) == 0)
      let carol = try #require(try await rig.space.accounts().first { $0.name == "carol" })
      #expect(carol.isAdmin)
      #expect(await adminAdd.stdoutText().hasPrefix("account \(carol.id.rawValue) (carol) admin\n"))
      #expect(await adminAdd.stderrText() == "one-time link; it dies at first use or in 90 seconds\n")
    }
  }

  @Test func personalGroupAdminCannotAddPromoteOrInviteSomeoneElse() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving(origin: "https://public.test") { server in
      let alice = try await signIn(rig, server: server, admin: false)
      let personal = try #require(try await rig.space.personalGroup(of: alice.id))
      #expect(try await rig.space.isHumanAdmin(alice.id, of: personal))
      #expect(try await !rig.space.isHumanAdmin(alice.id, of: .shared))
      let bob = try await rig.space.addAccount(kind: .human, name: "bob")
      for args in [
        ["user", "add", "--name", "carol", "--admin"],
        ["user", "admin", bob.id.rawValue],
        ["user", "invite", bob.id.rawValue],
      ] {
        let io = CLIIO()
        #expect(await rig.run(args, io: io) == 1)
        #expect(await io.stdoutText() == "")
        #expect(await io.stderrText().contains("requires an admin of shared"))
      }
      #expect(try await rig.space.accounts().count == 2)
      #expect(try await rig.space.account(bob.id)?.isAdmin == false)
      let own = CLIIO()
      #expect(await rig.run(["user", "invite", alice.id.rawValue], io: own) == 0)
      let envelope = try #require(EnrollmentEnvelope.parse(await own.stdoutText()))
      #expect(envelope.server == "https://public.test")
      #expect(envelope.fingerprint == server.fingerprint)
    }
  }

  @Test func unenrolledDeviceDoesNotUseTheDevOwner() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving(dev: true) { server in
      try rig.pinWallet(to: "127.0.0.1:\(server.port)")
      let log = RequestLog()
      for args in [["user", "add", "--name", "bob"], ["user", "admin", "ac_missing0"], ["user", "invite", "ac_missing0"]] {
        let io = CLIIO()
        #expect(await rig.run(args, io: io, log: log) == 1)
        #expect(await io.stderrText().contains("no signed-in identity"))
      }
      #expect(log.recorded.isEmpty)
      #expect(try await rig.space.accounts().isEmpty)
    }
  }

  @Test func losingTheRecordedIdentityNeverUsesTheDevOwner() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving(dev: true) { server in
      _ = try await signIn(rig, server: server, admin: false)
      let target = try await rig.space.addAccount(kind: .human, name: "target")
      let transport = SpaceTransport.fetchClient(trust: rig.trust, timeout: .seconds(10), plain: FetchClient { _ in
        throw FetchError.unimplemented
      })
      for args in [
        ["user", "add", "--name", "bob", "--admin"],
        ["user", "invite", target.id.rawValue],
        ["user", "admin", target.id.rawValue],
      ] {
        try SpaceIdentityStore(directory: rig.configDirectory).record(server.space, forHost: "127.0.0.1:\(server.port)")
        let io = CLIIO()
        let requests = RequestLog()
        let fetch = FetchClient { request in
          #expect(request.headers.sensitiveValues["authorization"]?.hasPrefix("Bearer ") == true)
          requests.record(request.url.path)
          let file = rig.configDirectory.appendingPathComponent("spaces.json")
          if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
          }
          return try await transport(request)
        }
        #expect(await run(rig, args: args, io: io, fetch: fetch) == 1)
        #expect(await io.stderrText().contains("requires an admin of shared"))
        #expect(await io.stdoutText() == "")
        #expect(!requests.recorded.isEmpty)
      }
      #expect(try await rig.space.accounts().count == 2)
      #expect(try await rig.space.account(target.id)?.isAdmin == false)
    }
  }

  @Test func revokedIdentityBeforeInviteMintingRefusesInsteadOfGoingAnonymous() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving(dev: true) { server in
      let admin = try await signIn(rig, server: server, admin: true)
      let pubkey = try #require(try await rig.space.keys(account: admin.id).first?.pubkey)
      let transport = SpaceTransport.fetchClient(trust: rig.trust, timeout: .seconds(10), plain: FetchClient { _ in
        throw FetchError.unimplemented
      })
      let io = CLIIO()
      let requests = RequestLog()
      let fetch = FetchClient { request in
        #expect(request.headers.sensitiveValues["authorization"]?.hasPrefix("Bearer ") == true)
        requests.record(request.url.path)
        let response = try await transport(request)
        if request.url.path == "/v1/accounts" {
          try FileManager.default.removeItem(at: rig.configDirectory.appendingPathComponent("spaces.json"))
          try await rig.space.removeKey(pubkey: pubkey)
        }
        return response
      }
      #expect(await run(rig, args: ["user", "add", "--name", "bob"], io: io, fetch: fetch) == 1)
      #expect(requests.recorded == ["/v1/server", "/v1/accounts", "/v1/enroll"])
      #expect(await io.stderrText().contains("unauthorized"))
      let bob = try #require(try await rig.space.accounts().first { $0.name == "bob" })
      #expect(await io.stdoutText() == "account \(bob.id.rawValue) (bob)\n")
      #expect(try await rig.space.keys(account: bob.id).isEmpty)
    }
  }

  @Test func discoveryAndMintErrorsDoNotTakeAnotherPath() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      _ = try await signIn(rig, server: server, admin: true)
      for failDiscovery in [true, false] {
        let io = CLIIO()
        let log = RequestLog()
        let runner = CommandRunner(
          fetch: FetchClient { request in
            #expect(request.headers.sensitiveValues["authorization"]?.hasPrefix("Bearer ") == true)
            log.record(request.url.path)
            switch request.url.path {
            case "/v1/server" where !failDiscovery:
              return try Response.json(JSONValue.object([
                "space": .string(server.space), "groups": .bool(true), "origin": .string("https://public.test"),
              ]))
            case "/v1/accounts":
              #expect(request.method == .post)
              #expect(try await request.json(JSONValue.self) == .object(["name": .string("bob"), "admin": .bool(false)]))
              return try Response.json(JSONValue.object([
                "id": .string("ac_test0000"), "kind": .string("human"), "name": .string("bob"),
                "admin": .bool(false), "createdAt": .integer(0),
              ]))
            default:
              return try Response.json(JSONValue.object([
                "code": .string("unavailable"), "message": .string("deliberate failure"),
              ]), status: .serviceUnavailable)
            }
          },
          stdin: { "" },
          stdout: { await io.appendOut(Array($0.utf8)) },
          stderr: { await io.appendErr(Array($0.utf8)) },
          environment: ["WUHU_CONFIG_DIR": rig.configDirectory.path],
          currentDirectory: rig.root.appendingPathComponent("work").path,
        )
        let code = await withDependencies { $0.date = rig.clock.generator } operation: {
          await runner.run(arguments: ["user", "add", "--name", "bob"])
        }
        #expect(code == 1)
        #expect(await io.stderrText().contains("deliberate failure"))
        #expect(log.recorded == (failDiscovery ? ["/v1/server"] : ["/v1/server", "/v1/accounts", "/v1/enroll"]))
        #expect(await io.stdoutText() == (failDiscovery ? "" : "account ac_test0000 (bob)\n"))
      }
    }
  }

  @Test func parserKeepsOfflineCommandsAndRefusesLiveSessionIdentity() throws {
    #expect(try Command.parse(["user", "add", "--space", "/space"]) == .user(.add(folder: "/space", name: nil, admin: false)))
    #expect(try Command.parse(["user", "invite", "--space", "/space", "ac_test"]) == .user(.invite(folder: "/space", account: "ac_test", server: nil, ttl: nil)))
    for args in [["user", "add", "--name", "bob"], ["user", "admin", "ac_test"], ["user", "invite", "ac_test"]] {
      #expect(try Command.parse(args).isRefusedToSessions)
      #expect(try !Command.parse(args).runsWithoutWallet)
    }
    for args in [
      ["user", "add", "--name", "bob", "--ttl", "0"],
      ["user", "add", "--space", "/space", "--ttl", "60"],
      ["user", "invite", "ac_test", "--server", "https://other.test"],
      ["user", "admin", "ac_test", "--space", "/space"],
    ] {
      #expect(throws: UsageError.self) { try Command.parse(args) }
    }
  }

  private func run(_ rig: EnrollRig, args: [String], io: CLIIO, fetch: FetchClient) async -> Int32 {
    let runner = CommandRunner(
      fetch: fetch,
      stdin: { "" },
      stdout: { await io.appendOut(Array($0.utf8)) },
      stderr: { await io.appendErr(Array($0.utf8)) },
      environment: ["WUHU_CONFIG_DIR": rig.configDirectory.path],
      currentDirectory: rig.root.appendingPathComponent("work").path,
    )
    return await withDependencies { $0.date = rig.clock.generator } operation: {
      await runner.run(arguments: args)
    }
  }

  private func signIn(_ rig: EnrollRig, server: BoundServer, admin: Bool) async throws -> AccountRecord {
    let account = try await rig.space.addAccount(kind: .human, name: "alice", admin: admin)
    let minted = try await rig.space.mintJoinToken(account: account.id, capabilities: [.device], createdBy: nil, lifetime: 600)
    let envelope = EnrollmentEnvelope(server: "https://127.0.0.1:\(server.port)", token: minted.token.rawValue, space: server.space, fingerprint: server.fingerprint)
    #expect(await rig.run(["login"], io: CLIIO(stdin: envelope.url)) == 0)
    try rig.pinWallet(to: "127.0.0.1:\(server.port)")
    return account
  }
}
