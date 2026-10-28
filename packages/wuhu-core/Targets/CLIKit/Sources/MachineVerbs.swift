#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import JSONValue
import MachineContract
import struct SpaceClient.SpaceClient

extension Executor {
  mutating func machineAdd(name: String?, group: String?) async throws {
    let space = try self.wallet.pinnedSpace()
    let server = await self.advertisedServer(space: space)
    var body: JSONValue = .object([:])
    body.set("name", name.map(JSONValue.string))
    body.set("group", group.map(JSONValue.string))
    let output: MachineAddOutput = try await self.api(.post, "/v1/machine-v2", space: space, body: body)
    await self.runner.stdout("machine \(output.id.rawValue)\n" + tokenLines(output.token, fingerprint: output.fingerprint))
    if let group, output.group != group {
      let reason = output.group.map { "server placed the machine in group \($0), not \(group)" }
        ?? "server too old to place machines in a group"
      throw CLIError(message: "\(reason); upgrade or use machine move \(output.id.rawValue) --group \(group). The machine was created; keep its join token.")
    }
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

  mutating func machineID(_ reference: String, verb: String) async throws -> MachineID {
    if MachineID.isValid(reference) { return MachineID(rawValue: reference) }
    let space = try self.wallet.pinnedSpace()
    let encoded = reference.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!.replacingOccurrences(of: "/", with: "%2F")
    let missing = CLIError(message: "\(verb): no machine named \(reference) in this space; list them with: wuhu machine list")
    do {
      let status: MachineStatus = try await self.api(.get, "/v1/machine/\(encoded)/status", space: space)
      return status.id
    } catch let error as SpaceClient.ToolFailure where error.error.code == .notFound { throw missing }
    catch let error as SpaceClient.TransportFailure where error.status == 404 { throw missing }
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

  mutating func machineDelete(id: String) async throws {
    let space = try self.wallet.pinnedSpace()
    let reference = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "_-")))!
    let _: EmptyOutput = try await self.api(.delete, "/v1/machine/\(reference)", space: space)
    await self.runner.stdout("deleted \(id)\n")
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

  mutating func machineScope(machine: String, scope: String) async throws {
    let space = try self.wallet.pinnedSpace()
    let body: JSONValue = .object(["scope": .string(scope)])
    let status: MachineStatus = try await self.api(.put, "/v1/machine/\(machine)/scope", space: space, body: body)
    await self.runner.stdout("\(status.name ?? status.id.rawValue) \(status.scope ?? scope)\n")
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
  ["wuhu machine-v2 join", server, fingerprint]
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

struct EmptyOutput: Decodable {}
