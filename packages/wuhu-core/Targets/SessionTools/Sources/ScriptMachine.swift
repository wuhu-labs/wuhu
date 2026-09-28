#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import MachineChannel
import struct MachineContract.Base64Data
import struct MachineContract.ExecID
import enum MachineContract.ExecOutputStream
import struct MachineContract.ExecStart
import enum MachineContract.ExitStatus
import struct MachineContract.MachineError
import struct MachineContract.MachineID
import enum MachineContract.VaultOutcome
import enum MachineContract.VFSOp
import enum MachineContract.VFSResult
import QuickJSKit
import SpaceCore
import SpaceTools

// What wuhu:machine reaches: the machines' files, and execs minted for the
// script that runs them. wuhu:secret reaches a machine's vault through it too.
public struct ScriptMachineAccess: Sendable {
  let files: MachineSeam
  let exec: ExecBackend
  let vault: MachineVaultSeam

  public init(files: MachineSeam, exec: ExecBackend, vault: MachineVaultSeam) {
    self.files = files
    self.exec = exec
    self.vault = vault
  }
}

/// A machine's vault as a script reaches it: setting an entry and listing the
/// names. Removal can't be undone, so it is a person's and has no seam.
public struct MachineVaultSeam: Sendable {
  let set: @Sendable (MachineID, String, String) async throws -> VaultOutcome
  let list: @Sendable (MachineID) async throws -> VaultOutcome

  public init(
    set: @escaping @Sendable (MachineID, String, String) async throws -> VaultOutcome,
    list: @escaping @Sendable (MachineID) async throws -> VaultOutcome,
  ) {
    self.set = set
    self.list = list
  }
}

let scriptExecOutputBytes = 1 << 20
let scriptExecOutputLimit = 4 << 20
// A write crosses the wire as one base64 frame under the hub's 16 MiB ceiling.
let scriptWriteBytes = (12 << 20) - (64 << 10)

final class ScriptMachineBindings: Sendable {
  private let execution: ScriptExecution
  private let space: Space
  private let access: ScriptMachineAccess?

  init(execution: ScriptExecution, space: Space, access: ScriptMachineAccess?) {
    self.execution = execution
    self.space = space
    self.access = access
  }

  func install(in engine: JSEngine) {
    engine.define("__wuhu_machine_list", promising: { [self] _ in try await machines() })
    engine.define("__wuhu_machine_fs", promising: { [self] in try await files($0) })
    engine.define("__wuhu_machine_exec", promising: { [self] in try await exec($0) })
    engine.define("__wuhu_machine_spawn", promising: { [self] in try await spawn($0) })
    engine.define("__wuhu_machine_next", promising: { [self] in try await next($0) })
    engine.define("__wuhu_machine_wait", promising: { [self] arguments in
      status(try await execution.processes.process(string(arguments, 0)).wait())
    })
    engine.define("__wuhu_machine_write", promising: { [self] arguments in
      let bytes = try payload(arguments[safe: 1])
      try refusePlaceholders(bytes, in: "stdin")
      try await execution.processes.process(string(arguments, 0)).write(bytes)
      return .null
    })
    engine.define("__wuhu_machine_end", promising: { [self] arguments in
      try await execution.processes.process(string(arguments, 0)).end()
      return .null
    })
    engine.define("__wuhu_machine_kill", promising: { [self] arguments in
      try await execution.processes.process(string(arguments, 0)).kill()
      return .null
    })
    engine.define("__wuhu_machine_discard", promising: { [self] arguments in
      try await execution.processes.process(string(arguments, 0)).discard()
      return .null
    })
    engine.define("__wuhu_vault_set", promising: { [self] in try await vaultSet($0) })
    engine.define("__wuhu_vault_list", promising: { [self] in try await vaultList($0) })
    engine.define("__wuhu_vault_remove", promising: { [self] in try await vaultRemove($0) })
  }

  // MARK: A machine's vault

  // Setting an entry takes an admin of the machine's group, as `wuhu machine
  // vault set` does; listing takes any session that can use the machine.
  private func vaultSet(_ arguments: [JSONValue]) async throws -> JSONValue {
    let access = try available()
    let reference = string(arguments, 0)
    let record = try await usableMachine(reference)
    guard try await space.isAdmin(.session(execution.session), of: record.group) else {
      throw ScriptError(
        "setting a vault entry on \(reference) needs an admin of group \(record.group.rawValue)"
          + (await notAdmin(execution.session, of: record.group, space: space)),
      )
    }
    let id = try await attached(record, reference, access)
    _ = try await vault(reference) { try await access.vault.set(id, string(arguments, 1), string(arguments, 2)) }
    return .null
  }

  private func vaultList(_ arguments: [JSONValue]) async throws -> JSONValue {
    let access = try available()
    let reference = string(arguments, 0)
    let id = try await attached(usableMachine(reference), reference, access)
    return .array(try await vault(reference) { try await access.vault.list(id) }.map(JSONValue.string))
  }

  private func vaultRemove(_ arguments: [JSONValue]) async throws -> JSONValue {
    let record = try await usableMachine(string(arguments, 0))
    throw ScriptError(
      "removing vault entry \(string(arguments, 1)) can't be undone and needs a human admin of group \(record.group.rawValue)",
    )
  }

  private func vault(_ reference: String, _ operation: () async throws -> VaultOutcome) async throws -> [String] {
    let outcome: VaultOutcome
    do {
      outcome = try await operation()
    } catch let error as ScriptError {
      throw error
    } catch {
      throw ScriptError(renderedFailure(Wire.failure(error)))
    }
    switch outcome {
    case .ok: return []
    case let .names(_, names): return names
    case let .error(_, error): throw failure(error)
    }
  }

  // MARK: Machines and files

  private func machines() async throws -> JSONValue {
    let access = try available()
    let attached = await access.files.attached()
    let group = try await space.principal(of: execution.session).group
    return .array(try await space.machines(usableFrom: group).map { record in
      .object([
        "id": .string(record.id.rawValue),
        "name": record.name.map(JSONValue.string) ?? .null,
        "attached": .bool(attached.contains(record.id)),
      ])
    })
  }

  private func files(_ arguments: [JSONValue]) async throws -> JSONValue {
    let access = try available()
    let machine = try await attachedMachine(string(arguments, 0), access)
    let operation = string(arguments, 1)
    guard case let .object(fields)? = arguments[safe: 2] else { throw ScriptError("malformed \(operation) call") }
    func path(_ key: String = "path") throws -> String {
      guard case let .string(path)? = fields[key], path.hasPrefix("/") else {
        throw ScriptError("\(operation) takes an absolute path on the machine")
      }
      return path
    }
    func vfs(_ op: VFSOp) async throws -> VFSResult {
      do {
        return try await access.files.vfs(machine, op)
      } catch let error as ScriptError {
        throw error
      } catch {
        throw ScriptError(renderedFailure(Wire.failure(error)))
      }
    }
    func unexpected(_ result: VFSResult) -> ScriptError {
      if case let .error(error) = result { return failure(error) }
      return ScriptError("machine returned an unexpected result for \(operation)")
    }

    switch operation {
    case "stat":
      switch try await vfs(.stat(path: path())) {
      case let .entry(entry):
        return .object(["kind": .string(entry.kind.rawValue), "size": .integer(entry.size), "mtime": .number(entry.mtime), "token": .string(entry.token)])
      case let .error(error) where error.code == .notFound:
        return .null
      case let other:
        throw unexpected(other)
      }
    case "list":
      let result = try await vfs(.ls(path: path()))
      guard case let .entries(entries) = result else { throw unexpected(result) }
      return .array(entries.map { entry in
        .object(["name": .string(entry.name), "kind": .string(entry.kind.rawValue), "size": .integer(entry.size), "mtime": .number(entry.mtime)])
      })
    case "read", "readText":
      let target = try path()
      let result = try await vfs(.read(path: target))
      guard case let .file(_, data) = result else { throw unexpected(result) }
      guard operation == "readText" else { return .string(Data(data.bytes).base64EncodedString()) }
      guard let text = String(bytes: data.bytes, encoding: .utf8) else {
        throw ScriptError("\(target) is not UTF-8 text; read it with read()")
      }
      return .string(text)
    case "write":
      let target = try path()
      let bytes = try payload(fields["data"])
      guard bytes.count <= scriptWriteBytes else {
        throw ScriptError("a write carries at most \(scriptWriteBytes) bytes; \(target) got \(bytes.count)")
      }
      let ifMatch: String? = if case let .string(token)? = fields["ifMatch"] { token } else { nil }
      if let slash = target.lastIndex(of: "/"), slash != target.startIndex {
        let result = try await vfs(.mkdir(path: String(target[..<slash])))
        guard case .ok = result else { throw unexpected(result) }
      }
      let result = try await vfs(.write(path: target, data: Base64Data(bytes), ifMatch: ifMatch))
      guard case let .written(token) = result else { throw unexpected(result) }
      return .string(token)
    case "remove":
      let result = try await vfs(.rm(path: path(), ifMatch: nil))
      guard case .ok = result else { throw unexpected(result) }
      return .null
    case "mkdir":
      let result = try await vfs(.mkdir(path: path()))
      guard case .ok = result else { throw unexpected(result) }
      return .null
    case "move":
      let result = try await vfs(.mv(from: path("from"), to: path("to")))
      guard case .ok = result else { throw unexpected(result) }
      return .null
    default:
      throw ScriptError("unknown machine operation \(operation)")
    }
  }

  // MARK: Processes

  private struct Options {
    var cwd = "/"
    var env: [String: String] = [:]
    var secrets: [String: String] = [:]
    var stdin = false
    var timeout: Double?
    var maxOutput = scriptExecOutputBytes

    // Numbers arrive as Doubles and are clamped before any conversion: a
    // huge one must not trap the server (`Int`) or the agent (`Duration`).
    init(_ value: JSONValue?, lifetime: Duration) throws {
      guard let value, value != .null else { return }
      guard case let .object(fields) = value else { throw ScriptError("options must be an object") }
      if case let .string(cwd)? = fields["cwd"] {
        guard cwd.hasPrefix("/") else { throw ScriptError("cwd must be an absolute path on the machine") }
        self.cwd = cwd
      }
      env = try strings(fields["env"], "env")
      secrets = try strings(fields["secrets"], "secrets")
      if case let .bool(stdin)? = fields["stdin"] { self.stdin = stdin }
      if let milliseconds = number(fields["timeout"]) {
        guard milliseconds > 0 else { throw ScriptError("timeout must be a positive number of milliseconds") }
        // A process dies with its script, so a longer timeout means nothing.
        timeout = min(milliseconds / 1000, lifetime / .seconds(1))
      }
      if let maxOutput = number(fields["maxOutput"]) {
        guard maxOutput > 0 else { throw ScriptError("maxOutput must be a positive number of bytes") }
        self.maxOutput = max(1, Int(min(maxOutput, Double(scriptExecOutputLimit))))
      }
    }
  }

  private func start(
    _ arguments: [JSONValue],
    _ access: ScriptMachineAccess,
  ) async throws -> (MachineID, String, Options, ExecEnvironment) {
    let machine = try await attachedMachine(string(arguments, 0), access)
    guard case let .string(command)? = arguments[safe: 1], !command.isEmpty else {
      throw ScriptError("the command must be a non-empty string")
    }
    let options = try Options(arguments[safe: 2], lifetime: execution.lifetime)
    let environment: ExecEnvironment
    do {
      environment = try execEnvironment(env: options.env, secrets: options.secrets)
    } catch let problem as ToolProblem {
      throw ScriptError(problem.message)
    }
    try refusePlaceholders(Array(command.utf8), in: "the command")
    for (name, value) in options.env.sorted(by: { $0.key < $1.key }) {
      try refusePlaceholders(Array(value.utf8), in: "env \(name)")
    }
    return (machine, command, options, environment)
  }

  private func exec(_ arguments: [JSONValue]) async throws -> JSONValue {
    let access = try available()
    let (machine, command, options, environment) = try await start(arguments, access)
    try execution.buffers.withLock { try $0.claim(options.maxOutput, for: .execOutput) }
    defer { execution.buffers.withLock { $0.unclaim(options.maxOutput) } }
    let record = try await mint(machine, access)
    let endpoint = ChannelEndpoint()
    let outgoing = await endpoint.startExec(ExecStart(
      id: record.id,
      cwd: options.cwd,
      command: ["sh", "-c", command],
      env: environment.env,
      secrets: environment.secrets,
      window: scriptProcessWindow,
      maxOutput: options.maxOutput,
      timeout: options.timeout,
    ))
    await outgoing.closeStdin()
    let outcome = try await withThrowingTaskGroup(of: ExecOutcome?.self, returning: ExecOutcome.self) { group in
      group.addTask {
        try await holdExecLeg(record.id, endpoint: endpoint, backend: access.exec, abandoningLost: true).map(ExecOutcome.lost)
      }
      group.addTask {
        var output: [ExecOutputStream: [UInt8]] = [:]
        for try await event in outgoing.events {
          switch event {
          case let .output(stream, _, data): output[stream, default: []] += data.bytes
          case let .exit(status): return .exited(status, stdout: output[.stdout] ?? [], stderr: output[.stderr] ?? [])
          case .truncated: continue
          case let .failed(error): return .lost(error.message)
          }
        }
        return nil
      }
      defer { group.cancelAll() }
      while let outcome = try await group.next() {
        if let outcome { return outcome }
      }
      throw CancellationError()
    }
    switch outcome {
    case let .exited(status, stdout, stderr):
      guard case var .object(fields) = self.status(status) else { preconditionFailure("status is an object") }
      fields["stdout"] = .string(text(stdout))
      fields["stderr"] = .string(text(stderr))
      fields["truncated"] = .bool(stdout.count + stderr.count >= options.maxOutput)
      return .object(fields)
    case let .lost(reason):
      throw ScriptError("\(reason) while exec \(record.id.rawValue) ran; it gets killed if the machine comes back")
    }
  }

  private enum ExecOutcome: Sendable {
    case exited(ExitStatus, stdout: [UInt8], stderr: [UInt8])
    case lost(String)
  }

  private func spawn(_ arguments: [JSONValue]) async throws -> JSONValue {
    let access = try available()
    let (machine, command, options, environment) = try await start(arguments, access)
    try execution.processes.admit()
    var process: ScriptProcess?
    defer { execution.processes.settle(process) }
    try execution.buffers.withLock { try $0.claim(scriptProcessWindow, for: .processOutput) }
    do {
      let record = try await mint(machine, access)
      let endpoint = ChannelEndpoint()
      let outgoing = await endpoint.startExec(
        ExecStart(
          id: record.id,
          cwd: options.cwd,
          command: ["sh", "-c", command],
          env: environment.env,
          secrets: environment.secrets,
          window: scriptProcessWindow,
          maxOutput: nil,
          timeout: nil,
        ),
        autoAcknowledge: false,
      )
      if !options.stdin { await outgoing.closeStdin() }
      process = ScriptProcess(
        id: record.id,
        machine: machine,
        acceptsStdin: options.stdin,
        outgoing: outgoing,
        endpoint: endpoint,
        backend: access.exec,
        giveBack: { [execution] bytes in execution.buffers.withLock { $0.unclaim(bytes) } },
      )
      return .object(["id": .string(record.id.rawValue)])
    } catch {
      execution.buffers.withLock { $0.unclaim(scriptProcessWindow) }
      throw error
    }
  }

  // The next batch of output: complete lines ("lines") or raw chunks.
  private func next(_ arguments: [JSONValue]) async throws -> JSONValue {
    let process = try execution.processes.process(string(arguments, 0))
    let lines = string(arguments, 1) == "lines"
    let take = try await lines ? process.lines() : process.chunks()
    let secrets = execution.secrets
    return .object([
      "items": .array(take.items.map { output in
        let masked = secrets.mask(output.bytes)
        let data: JSONValue = if lines {
          .string(String(decoding: masked.last == 0x0D ? masked.dropLast() : masked[...], as: UTF8.self))
        } else {
          .string(Data(masked).base64EncodedString())
        }
        return .object(["stream": .string(output.stream == .stdout ? "out" : "err"), lines ? "text" : "data": data])
      }),
      "done": .bool(take.done),
    ])
  }

  // MARK: Helpers

  private func mint(_ machine: MachineID, _ access: ScriptMachineAccess) async throws -> ExecRecord {
    let record = try await access.exec.mintScript(machine, execution.session, execution.id)
    guard execution.processes.minted(record.id) else {
      try? await access.exec.kill(record.id)
      throw CancellationError()
    }
    return record
  }

  private func available() throws -> ScriptMachineAccess {
    guard let access else { throw ScriptError("this server gives scripts no machine access") }
    return access
  }

  private func attachedMachine(_ reference: String, _ access: ScriptMachineAccess) async throws -> MachineID {
    try await attached(usableMachine(reference), reference, access)
  }

  private func usableMachine(_ reference: String) async throws -> MachineRecord {
    let group = try await space.principal(of: execution.session).group
    guard let record = try await space.resolveMachine(reference, usableFrom: group) else {
      throw ScriptError("no machine named \(reference)")
    }
    return record
  }

  private func attached(_ record: MachineRecord, _ reference: String, _ access: ScriptMachineAccess) async throws -> MachineID {
    guard await access.files.attached().contains(record.id) else {
      throw ScriptError("machine \(reference) is not attached")
    }
    return record.id
  }

  private func refusePlaceholders(_ bytes: [UInt8], in place: String) throws {
    guard execution.secrets.carriesPlaceholder(bytes) else { return }
    throw ScriptError("""
    \(place) holds a wuhu:secret placeholder, and space secrets never reach a machine; \
    put the value in the machine's vault and pass it by name in `secrets`
    """)
  }

  private func payload(_ value: JSONValue?) throws -> [UInt8] {
    switch value {
    case let .object(fields)?:
      if case let .string(text)? = fields["text"] { return Array(text.utf8) }
      if case let .string(base64)? = fields["base64"], let data = Data(base64Encoded: base64) { return Array(data) }
    default:
      break
    }
    throw ScriptError("data must be a string, an ArrayBuffer or a typed array")
  }

  private func status(_ status: ExitStatus) -> JSONValue {
    switch status {
    case let .exited(code): .object(["code": .integer(code), "signal": .null])
    case let .signaled(signal): .object(["code": .null, "signal": .integer(signal)])
    }
  }

  private func text(_ bytes: [UInt8]) -> String {
    String(decoding: execution.secrets.mask(bytes), as: UTF8.self)
  }

  private func failure(_ error: MachineError) -> ScriptError {
    ScriptError("\(error.code.rawValue): \(error.message)")
  }
}

private func strings(_ value: JSONValue?, _ name: String) throws -> [String: String] {
  switch value {
  case nil, .null?:
    return [:]
  case let .object(fields)?:
    var strings: [String: String] = [:]
    for (key, value) in fields {
      guard case let .string(text) = value else { throw ScriptError("\(name).\(key) must be a string") }
      strings[key] = text
    }
    return strings
  default:
    throw ScriptError("\(name) must be an object of strings")
  }
}

private func number(_ value: JSONValue?) -> Double? {
  switch value {
  case let .integer(value)?: Double(value)
  case let .number(value)?: value.isFinite ? value : nil
  default: nil
  }
}
