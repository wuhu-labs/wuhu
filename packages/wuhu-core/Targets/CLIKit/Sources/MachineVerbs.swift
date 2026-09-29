#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

import Crypto
import Fetch
import JSONValue
import MachineAgent
import MachineContract
import struct SpaceClient.SpaceClient
import struct SpaceContract.EnrollConsumeOutput

extension Executor {
  mutating func machineAdd(name: String?) async throws {
    let space = try self.wallet.pinnedSpace()
    let server = await self.advertisedServer(space: space)
    var body: JSONValue = .object([:])
    body.set("name", name.map(JSONValue.string))
    let output: MachineAddOutput = try await self.api(.post, "/v1/machine", space: space, body: body)
    await self.runner.stdout("machine \(output.id.rawValue)\n" + tokenLines(output.token, fingerprint: output.fingerprint))
    await self.runner.stderr("""
    the join token is shown once. join from the box, feeding the token on stdin:
      \(joinCommand(server: server, fingerprint: output.fingerprint))

    """)
  }

  mutating func machineList() async throws {
    let space = try self.wallet.pinnedSpace()
    let statuses: [MachineStatus] = try await self.api(.get, "/v1/machine", space: space)
    let text = statuses.map { status in
      "\(status.name ?? "-") \(status.id.rawValue) \(status.attached ? "attached" : "detached")\n"
    }.joined()
    await self.runner.stdout(text)
  }

  // The wire takes an id; a name is a client-side lookup against the roster
  // the space already publishes.
  mutating func machineID(_ reference: String, verb: String) async throws -> MachineID {
    if MachineID.isValid(reference) { return MachineID(rawValue: reference) }
    let space = try self.wallet.pinnedSpace()
    let statuses: [MachineStatus] = try await self.api(.get, "/v1/machine", space: space)
    guard let match = statuses.first(where: { $0.name?.lowercased() == reference.lowercased() }) else {
      throw CLIError(message: "\(verb): no machine named \(reference) in this space; list them with: wuhu machine list")
    }
    return match.id
  }

  mutating func machineName(machine: String, name: String) async throws {
    let space = try self.wallet.pinnedSpace()
    let body: JSONValue = .object(["name": .string(name)])
    let status: MachineStatus = try await self.api(.put, "/v1/machine/\(machine)/name", space: space, body: body)
    await self.runner.stdout("\(status.name ?? "-") \(status.id.rawValue)\n")
  }

  mutating func machineRotate(id: String) async throws {
    let space = try self.wallet.pinnedSpace()
    let server = await self.advertisedServer(space: space)
    let output: MachineRotateOutput = try await self.api(.post, "/v1/machine/\(id)/rotate", space: space)
    await self.runner.stdout(tokenLines(output.token, fingerprint: output.fingerprint))
    await self.runner.stderr("""
    the previous key is now refused and any live connection is dropped. rejoin the box, feeding the token on stdin:
      \(joinCommand(server: server, fingerprint: output.fingerprint))

    """)
  }

  mutating func machineRevoke(id: String) async throws {
    let space = try self.wallet.pinnedSpace()
    let _: EmptyOutput = try await self.api(.post, "/v1/machine/\(id)/revoke", space: space)
    await self.runner.stdout("revoked \(id)\n")
  }

  mutating func machineMove(machine: String, group: String) async throws {
    let space = try self.wallet.pinnedSpace()
    let body: JSONValue = .object(["group": .string(group)])
    let status: MachineStatus = try await self.api(.put, "/v1/machine/\(machine)/group", space: space, body: body)
    await self.runner.stdout("moved \(status.name ?? status.id.rawValue) to group \(group)\n")
  }

  mutating func machineJoin(server: String, fingerprint: String?, name: String?) async throws {
    if self.runner.stdinIsTerminal {
      await self.runner.stderr("join token (stdin, end with ctrl-d): ")
    }
    let token = try await self.runner.stdin().strippingOneTrailingLineEnding()
    guard !token.isEmpty else {
      throw UsageError(message: "machine join: expected the join token on stdin (wuhu machine join <server-url> [fingerprint] < token)")
    }
    // Trust settles before the join call makes the first dial: a fingerprint
    // delivered with the token is recorded up front, so there is no TOFU window.
    try await self.establishDeliveredTrust(
      server: server,
      fingerprint: fingerprint,
      verb: "machine join",
      refingerprintHint: """
      to pin the fingerprint printed by wuhu machine add, run:
        wuhu machine join <server-url> <fingerprint> < token
      """,
    )
    // A fresh key per join; the working key on disk is replaced only after
    // the server has enrolled its successor.
    let key = Curve25519.Signing.PrivateKey()
    var body: JSONValue = .object(["token": .string(token), "pubkey": .string(key.pubkeyLabel)])
    body.set("name", (name ?? boxHostname()).map(JSONValue.string))
    let output: EnrollConsumeOutput = try await self.api(.post, "/v1/enroll/consume", space: server, body: body)
    guard let machine = output.machine, MachineID.isValid(machine) else {
      throw CLIError(message: "this join token does not name a machine; mint one with: wuhu machine add")
    }
    let home = try MachineHome.locate(environment: self.runner.environment)
    let config = MachineAgentConfig(
      server: self.client(server).base,
      machine: MachineID(rawValue: machine),
      name: output.machineName,
    )
    try home.save(config)
    try home.saveKey(key)
    await self.runner.stdout("joined \(machine)\(output.machineName.map { " (\($0))" } ?? "")\n")
    // A join names an unnamed box only, so a box that asked for one and kept
    // another must be told the ask did not land.
    if let name, let kept = output.machineName, kept != name.lowercased() {
      await self.runner.stderr("this machine is already named \(kept); rename it with: wuhu machine name \(kept) \(name)\n")
    }
    if let fingerprint {
      await self.runner.stderr("pinned server certificate \(fingerprint)\n")
    }
    await self.runner.stderr("machine key written to \(home.keyFile.path)\nstart the agent: wuhu machine run\n")
  }

  func machineRun() async throws {
    let home = try MachineHome.locate(environment: self.runner.environment)
    guard let config = try home.load() else {
      throw CLIError(message: "this box has not joined a machine; run: wuhu machine join <server-url> <fingerprint> < token")
    }
    guard let key = try home.loadKey() else {
      throw CLIError(message: "this box holds no machine key; rejoin: wuhu machine join <server-url> <fingerprint> < token")
    }
    guard let url = URL(string: config.server + "/v1/machine/connect") else {
      throw CLIError(message: "malformed server url in \(home.configFile.path): \(config.server)")
    }
    guard let dial = self.runner.dial else {
      throw CLIError(message: "no websocket transport is available in this client")
    }
    try FileManager.default.createDirectory(
      at: home.stateDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700],
    )
    await self.runner.stderr("machine \(config.machine.rawValue) dialing \(config.server)\n")
    let agent = MachineAgent(stateDirectory: home.stateDirectory.path)
    let client = self.client(config.server)
    await agent.run(dial: {
      // Every dial proves possession afresh: a one-shot server challenge,
      // signed with the machine key, verified against the live key row.
      let output: MachineChallengeOutput = try await client.api(.get, "/v1/machine/challenge")
      let signature = try key.signature(for: MachineConnect.signingPayload(challenge: output.challenge))
      return try await dial(url, [
        (MachineConnect.pubkeyHeader, key.pubkeyLabel),
        (MachineConnect.challengeHeader, output.challenge),
        (MachineConnect.signatureHeader, signature.base64EncodedString()),
        (MachineConnect.capabilitiesHeader, MachineConnect.groupSecrets),
      ])
    })
  }

  mutating func ps() async throws {
    let space = try self.wallet.pinnedSpace()
    let execs: [ExecStatus] = try await self.api(.get, "/v1/exec", space: space)
    let text = execs.map { exec in
      "\(exec.id.rawValue) \(exec.machine.rawValue) \(formatTimestamp(exec.startedAt)) \(exec.command)\n"
    }.joined()
    await self.runner.stdout(text)
  }

  mutating func kill(id: String) async throws {
    let space = try self.wallet.pinnedSpace()
    guard ExecID.isValid(id) else {
      throw UsageError(message: "kill: invalid exec id \(id)")
    }
    let _: EmptyOutput = try await self.api(.post, "/v1/exec/\(id)/kill", space: space)
  }

  mutating func api<Output: Decodable>(
    _ method: Fetch.Method,
    _ path: String,
    space: String,
    body: JSONValue? = nil,
  ) async throws -> Output {
    try await self.authenticated(space).api(method, path, body: body)
  }
}

private func tokenLines(_ token: String, fingerprint: String?) -> String {
  "token \(token)\n" + (fingerprint.map { "fingerprint \($0)\n" } ?? "")
}

private func joinCommand(server: String, fingerprint: String?) -> String {
  ["wuhu machine join", server, fingerprint]
    .compactMap { $0 }.joined(separator: " ")
}

struct MachineAddress: Equatable {
  var machine: String
  var path: String
}

func parseMachineAddress(_ raw: String) -> MachineAddress? {
  guard raw.hasPrefix("machines://") else { return nil }
  let rest = raw.dropFirst("machines://".count)
  let slash = rest.firstIndex(of: "/")
  let host = slash.map { String(rest[..<$0]) } ?? String(rest)
  guard !host.isEmpty else { return nil }
  let path = slash.map { String(rest[$0...]) } ?? "/"
  return MachineAddress(machine: host, path: path)
}

// The join default: the box names itself, and the server suffixes the name
// until it is free rather than refusing the join.
private func boxHostname() -> String? {
  var buffer = [CChar](repeating: 0, count: 256)
  return buffer.withUnsafeMutableBufferPointer { pointer -> String? in
    guard gethostname(pointer.baseAddress!, pointer.count - 1) == 0 else { return nil }
    let hostname = String(cString: pointer.baseAddress!)
    return hostname.isEmpty ? nil : hostname
  }
}

struct EmptyOutput: Decodable {}

struct MachineAgentConfig: Codable, Equatable {
  var server: String
  var machine: MachineID
  var name: String?
}

private struct LegacyPinnedConfig: Decodable {
  let certificate: String?
}

struct MachineHome {
  let directory: URL

  static func locate(environment: [String: String]) throws -> Self {
    Self(
      directory: try ServerTrust.userConfigDirectory(environment: environment)
        .appendingPathComponent("machine", isDirectory: true),
    )
  }

  var configFile: URL {
    self.directory.appendingPathComponent("agent.json")
  }

  // The machine's own credential, distinct from any device key under keys/:
  // a box that is both a user's device and a machine holds two keys in two
  // different homes.
  var keyFile: URL {
    self.directory.appendingPathComponent("machine.key")
  }

  var stateDirectory: URL {
    self.directory.appendingPathComponent("state", isDirectory: true)
  }

  func loadKey() throws -> Curve25519.Signing.PrivateKey? {
    try Ed25519KeyFile.read(self.keyFile, hint: "rejoin: wuhu machine join <server-url> <fingerprint> < token")
  }

  func saveKey(_ key: Curve25519.Signing.PrivateKey) throws {
    try Ed25519KeyFile.write(key, to: self.keyFile)
  }

  func load() throws -> MachineAgentConfig? {
    guard FileManager.default.fileExists(atPath: self.configFile.path) else { return nil }
    let config: MachineAgentConfig
    let legacyPin: String?
    do {
      let data = try Data(contentsOf: self.configFile)
      config = try JSONDecoder().decode(MachineAgentConfig.self, from: data)
      legacyPin = try JSONDecoder().decode(LegacyPinnedConfig.self, from: data).certificate
    } catch {
      throw CLIError(message: "malformed \(self.configFile.path); rejoin with: wuhu machine join <server-url> <fingerprint> < token")
    }
    // A pre-TA4 config froze its pin here; loading it minus the pin would
    // silently drop the box's trust decision.
    guard legacyPin == nil else {
      throw CLIError(message: """
      \(self.configFile.path) still carries a frozen certificate: this machine was joined before the trust-store migration
      re-join: wuhu machine join <server-url> <fingerprint> < token
      """)
    }
    return config
  }

  func save(_ config: MachineAgentConfig) throws {
    try FileManager.default.createDirectory(
      at: self.directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700],
    )
    let data = try JSONEncoder().encode(config)
    try data.write(to: self.configFile, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.configFile.path)
  }
}
