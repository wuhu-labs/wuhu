#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@testable import CLIKit
import Dependencies
import Fetch
import Scratch
import ServeNIO
import ServeTLS
import SpaceCore
import SpaceServer
import Testing

@Suite(.serialized) struct MachineTrustTests {
  @Test func joinWithFingerprintPinsBeforeTheFirstDialAndTheAgentHonorsIt() async throws {
    let rig = try TrustRig()
    defer { rig.cleanUp() }
    let identity = try TLSIdentity.selfSigned(hosts: ["localhost", "127.0.0.1"])
    let fingerprint = try identity.fingerprint()
    let handler = SpaceServer.handler(
      space: rig.space, hub: rig.hub, fingerprint: fingerprint, dev: true, webApp: nil,
    )
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, tls: identity, upgrading: handler)
    let port = try #require(server.boundAddress.port)
    let machine = try await rig.space.addMachine(name: "box")
    let minted = try await rig.space.mintJoinToken(
      account: machine.account, capabilities: [.execMachine], createdBy: nil, lifetime: 600,
    )

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await rig.hub.run() }
      group.addTask {
        let base = "https://127.0.0.1:\(port)"
        let key = "127.0.0.1:\(port)"
        #expect((try? rig.trust.pin(forHost: key)) == nil)

        let joinIO = CLIIO(stdin: minted.token.rawValue + "\n")
        let joinCode = await rig.run(
          ["machine", "join", base, fingerprint], io: joinIO,
        )
        #expect(joinCode == 0)
        #expect(await joinIO.stdoutText().hasPrefix("joined \(machine.id.rawValue)"))
        #expect(await joinIO.stderrText().contains("pinned server certificate \(fingerprint)"))
        #expect((try? rig.trust.pin(forHost: key)) == fingerprint)

        await withTaskGroup(of: Void.self) { runGroup in
          runGroup.addTask { _ = await rig.run(["machine", "run"]) }
          let attached = (try? await pollUntil { await rig.hub.attachedMachines().contains(machine.id) }) ?? false
          #expect(attached)
          runGroup.cancelAll()
        }
      }
      _ = try await group.next()
      group.cancelAll()
    }
    await server.shutdown()
  }

  @Test func joinWithoutFingerprintRejectsAnUntrustedCertificateWithAPinHint() async throws {
    let rig = try TrustRig()
    defer { rig.cleanUp() }
    let token = "jt_" + String(repeating: "z", count: 32)
    let io = CLIIO(stdin: token + "\n")
    let code = await withDependencies {
      $0[ServerTrustProbe.self] = ServerTrustProbe(
        validateSystem: { _, _ in throw CLIError(message: "certificate not trusted") },
        observeLeaf: { _, _ in throw UnimplementedProbe(endpoint: "observeLeaf") },
      )
    } operation: {
      await rig.run(["machine", "join", "https://127.0.0.1:5599"], io: io)
    }
    #expect(code == 1)
    let error = await io.stderrText()
    #expect(error.contains("127.0.0.1:5599 presented a certificate this system does not trust"))
    #expect(error.contains("wuhu machine join <server-url> <fingerprint> < token"))
    #expect(try rig.trust.pin(forHost: "127.0.0.1:5599") == nil)
  }

  @Test func preMigrationConfigWithAFrozenCertificateIsRejectedLoudly() async throws {
    let rig = try TrustRig()
    defer { rig.cleanUp() }
    let machineDir = rig.trust.directory.appendingPathComponent("machine", isDirectory: true)
    try FileManager.default.createDirectory(at: machineDir, withIntermediateDirectories: true)
    let legacy = """
    {"server":"https://127.0.0.1:5599","machine":"mc_a1b2c3d4","token":"ct_\(String(repeating: "z", count: 32))","certificate":"sha256:\(String(repeating: "a", count: 64))"}
    """
    try Data(legacy.utf8).write(to: machineDir.appendingPathComponent("agent.json"))
    let io = CLIIO()
    #expect(await rig.run(["machine", "run"], io: io) == 1)
    let error = await io.stderrText()
    #expect(error.contains("joined before the trust-store migration"))
    #expect(error.contains("re-join: wuhu machine join <server-url> <fingerprint> < token"))
  }

  @Test func joinRejectsAMalformedFingerprint() async throws {
    let rig = try TrustRig()
    defer { rig.cleanUp() }
    let token = "jt_" + String(repeating: "z", count: 32)
    let io = CLIIO(stdin: token + "\n")
    let code = await rig.run(["machine", "join", "https://127.0.0.1:5599", "Y2VydC1h"], io: io)
    #expect(code == 64)
    #expect(await io.stderrText().contains("sha256:<64 lowercase hex>"))
    #expect(try rig.trust.pin(forHost: "127.0.0.1:5599") == nil)
  }
}

private struct TrustRig {
  let scratch: ScratchFolder
  let root: URL
  let space: Space
  let hub: MachineHub
  let trust: ServerTrust

  init() throws {
    scratch = try ScratchFolder("machine-trust")
    root = scratch.url
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("work", isDirectory: true), withIntermediateDirectories: true,
    )
    let space = try withDependencies {
      $0.date = DateGenerator { Date() }
      $0.continuousClock = ContinuousClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(SeededRNG(seed: 23))
    } operation: {
      try Space.inMemory()
    }
    self.space = space
    hub = withDependencies {
      $0.continuousClock = ContinuousClock()
    } operation: {
      MachineHub(space: space)
    }
    trust = ServerTrust(directory: root.appendingPathComponent("user-config", isDirectory: true))
  }

  func run(_ arguments: [String], io: CLIIO = CLIIO()) async -> Int32 {
    let plain = FetchClient { request in
      Issue.record("machine traffic must not reach the plain client: \(request.url)")
      throw FetchError.unimplemented
    }
    let runner = CommandRunner(
      fetch: SpaceTransport.fetchClient(trust: trust, timeout: .seconds(10), plain: plain),
      stdin: { io.stdinText },
      stdout: { text in await io.appendOut(Array(text.utf8)) },
      stderr: { text in await io.appendErr(Array(text.utf8)) },
      dial: SpaceTransport.webSocketTransport(trust: trust, maxFrameBytes: 1 << 20),
      environment: [
        "HOME": root.appendingPathComponent("home").path,
        "WUHU_CONFIG_DIR": trust.directory.path,
      ],
      currentDirectory: root.appendingPathComponent("work").path,
    )
    return await withDependencies {
      $0.continuousClock = ContinuousClock()
    } operation: {
      await runner.run(arguments: arguments)
    }
  }

  func cleanUp() {
    try? FileManager.default.removeItem(at: root)
  }
}
