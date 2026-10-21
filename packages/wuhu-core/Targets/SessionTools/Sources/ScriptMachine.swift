import enum MainHub.Address
import struct MainHub.ExecEnvironment
import func MainHub.execEnvironment
import func MainHub.execHandle
import func MainHub.renderedFailure
import struct MainHub.ScriptError
import struct MainHub.ToolProblem
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import struct MachineContract.ExecID
import struct MachineContract.ExecMintOutput
import enum MachineContract.ExecOutputStream
import struct MachineContract.ExecStart
import struct MachineContract.ExecStatus
import enum MachineContract.ExitStatus
import struct MachineContract.MachineError
import struct MachineContract.MachineID
import QuickJSKit
import SpaceClient
import struct SpaceContract.Entry
import struct SpaceContract.ListOutput
import struct SpaceContract.WriteOutput
import SpaceCore
import SpaceTools
import Synchronization

// What wuhu:machine reaches: the machines' files, and execs minted for the
// script that runs them.
let scriptExecOutputBytes = 1 << 20
let scriptExecOutputLimit = 4 << 20
// A write crosses the wire as one base64 frame under the hub's 16 MiB ceiling.
let scriptWriteBytes = (12 << 20) - (64 << 10)

final class ScriptMachineBindings: Sendable {
  private let execution: ScriptExecution
  private let tools: ToolExecutor

  init(execution: ScriptExecution, tools: ToolExecutor) {
    self.execution = execution
    self.tools = tools
  }

  func install(in engine: JSEngine) {
    engine.define("__wuhu_machine_own_exec", promising: { [self] arguments in
      await spaceAnswer {
        let client = execution.client
        switch string(arguments, 0) {
        case "list": return try JSONValueEncoder().encode(try await client.api(.get, "/v1/exec") as [ExecStatus])
        case "status": return try JSONValueEncoder().encode(try await client.api(.get, "/v1/exec/\(pathSegment(string(arguments, 1)))") as ExecStatus)
        case "kill":
          let _: JSONValue = try await client.api(.post, "/v1/exec/\(pathSegment(string(arguments, 1)))/kill")
          return .null
        default: throw ToolRunError.failed(code: .invalidArgument, message: "unknown exec operation", hint: nil)
        }
      }
    })
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
  }

  // MARK: Machines and files

  private func machines() async throws -> JSONValue {
    .array(try await tools.machines(as: execution.session).map { machine in
      .object([
        "id": .string(machine.id.rawValue),
        "name": machine.name.map(JSONValue.string) ?? .null,
        "attached": .bool(machine.attached),
      ])
    })
  }

  // The machine's files over main's file tools and byte routes, addressed as
  // machines://<id>/<path>; the machine's refusal reads as its code and message.
  private func files(_ arguments: [JSONValue]) async throws -> JSONValue {
    let machine = try await attachedMachine(string(arguments, 0))
    let operation = string(arguments, 1)
    guard case let .object(fields)? = arguments[safe: 2] else { throw ScriptError("malformed \(operation) call") }
    func path(_ key: String = "path") throws -> String {
      guard case let .string(path)? = fields[key], path.hasPrefix("/") else {
        throw ScriptError("\(operation) takes an absolute path on the machine")
      }
      return path
    }
    func address(_ path: String) -> String { Address.machine(machine, path).rendered }
    let main = try await tools.client(execution.session)
    func machineCall<Output>(_ run: () async throws -> Output) async throws -> Output {
      do {
        return try await run()
      } catch let failure as SpaceClient.ToolFailure {
        throw ScriptError("\(failure.error.code.rawValue): \(failure.error.message)")
      } catch let error as ScriptError {
        throw error
      } catch {
        throw ScriptError(renderedFailure(Wire.failure(error)))
      }
    }

    switch operation {
    case "stat":
      let target = address(try path())
      let found: Entry? = try await machineCall {
        do { return try await main.tool("stat", .object(["path": .string(target)])) }
        catch let failure as SpaceClient.ToolFailure where failure.error.code == .notFound { return nil }
      }
      guard let found else { return .null }
      return .object(["kind": .string(found.kind.rawValue), "size": .integer(found.size), "mtime": .number(found.mtime), "token": .string(found.token)])
    case "list":
      let target = address(try path())
      let listed: ListOutput = try await machineCall { try await main.tool("ls", .object(["path": .string(target)])) }
      return .array(listed.entries.map { entry in
        .object(["name": .string(entry.name), "kind": .string(entry.kind.rawValue), "size": .integer(entry.size), "mtime": .number(entry.mtime)])
      })
    case "read", "readText":
      let target = try path()
      let bytes = try await machineCall { try await main.file(address(target)).data }
      guard operation == "readText" else { return .string(bytes.base64EncodedString()) }
      guard let text = String(bytes: bytes, encoding: .utf8) else {
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
      let written: WriteOutput = try await machineCall { try await main.putFileBytes(address(target), Data(bytes), ifMatch: ifMatch) }
      return .string(written.token)
    case "remove":
      let target = address(try path())
      let _: JSONValue = try await machineCall { try await main.tool("rm", .object(["path": .string(target)])) }
      return .null
    case "mkdir":
      let target = try path()
      let _: JSONValue = try await machineCall {
        try await main.api(.post, "/v1/machine/\(machine.rawValue)/mkdir", body: .object(["path": .string(target)]))
      }
      return .null
    case "move":
      let (from, to) = (address(try path("from")), address(try path("to")))
      let _: JSONValue = try await machineCall { try await main.tool("mv", .object(["from": .string(from), "to": .string(to)])) }
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
  ) async throws -> (MachineID, String, Options, ExecEnvironment) {
    let machine = try await attachedMachine(string(arguments, 0))
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
    let (machine, command, options, environment) = try await start(arguments)
    try execution.buffers.withLock { try $0.claim(options.maxOutput, for: .execOutput) }
    defer { execution.buffers.withLock { $0.unclaim(options.maxOutput) } }
    let (id, exec) = try await mint(machine, command: command, options: options, environment: environment, spawn: false)
    let output = Mutex<[ExecOutputStream: [UInt8]]>([:])
    let exit = Mutex<ExitStatus?>(nil)
    let termination = try await exec.run(
      autoAcknowledge: true, failOnRemoteError: true, input: .closed,
      output: { stream, bytes in output.withLock { $0[stream, default: []] += bytes } },
      onEvent: { event in if case let .exit(status) = event { exit.withLock { $0 = status } } },
    )
    guard let status = exit.withLock({ $0 }) else {
      guard let reason = lostReason(termination, id: id) else { throw CancellationError() }
      throw ScriptError("\(reason) while exec \(id.rawValue) ran; it gets killed if the machine comes back")
    }
    let (stdout, stderr) = output.withLock { ($0[.stdout] ?? [], $0[.stderr] ?? []) }
    guard case var .object(fields) = self.status(status) else { preconditionFailure("status is an object") }
    fields["stdout"] = .string(text(stdout))
    fields["stderr"] = .string(text(stderr))
    fields["truncated"] = .bool(stdout.count + stderr.count >= options.maxOutput)
    return .object(fields)
  }

  private func spawn(_ arguments: [JSONValue]) async throws -> JSONValue {
    let (machine, command, options, environment) = try await start(arguments)
    try execution.processes.admit()
    var process: ScriptProcess?
    defer { execution.processes.settle(process) }
    try execution.buffers.withLock { try $0.claim(scriptProcessWindow, for: .processOutput) }
    do {
      let (id, exec) = try await mint(machine, command: command, options: options, environment: environment, spawn: true)
      process = ScriptProcess(
        id: id,
        machine: machine,
        acceptsStdin: options.stdin,
        exec: exec,
        giveBack: { [execution] bytes in execution.buffers.withLock { $0.unclaim(bytes) } },
      )
      return .object(["id": .string(id.rawValue)])
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

  // An exec minted for this script on main, with its caller leg ready to dial.
  private func mint(_ machine: MachineID, command: String, options: Options, environment: ExecEnvironment, spawn: Bool) async throws -> (ExecID, ExecSession) {
    let client = execution.client
    let minted: ExecMintOutput
    do {
      minted = try await client.api(.post, "/v1/exec", body: .object(["machine": .string(machine.rawValue), "script": .string(execution.id)]))
    } catch { throw scriptFailure(error) }
    guard execution.processes.minted(minted.id) else {
      try? await killScriptExec(minted.id, via: client)
      throw CancellationError()
    }
    let start = ExecStart(
      id: minted.id, cwd: options.cwd, command: ["sh", "-c", command],
      env: environment.env, secrets: environment.secrets, window: scriptProcessWindow,
      maxOutput: spawn ? nil : options.maxOutput, timeout: spawn ? nil : options.timeout,
    )
    return (minted.id, ExecSession(client: client, start: start))
  }

  private func attachedMachine(_ reference: String) async throws -> MachineID {
    guard let machine = try await tools.machine(reference, as: execution.session) else {
      throw ScriptError("no machine named \(reference)")
    }
    guard machine.attached else { throw ScriptError("machine \(reference) is not attached") }
    return machine.id
  }

  private func refusePlaceholders(_ bytes: [UInt8], in place: String) throws {
    guard execution.secrets.carriesPlaceholder(bytes) else { return }
    throw ScriptError("""
    \(place) holds a wuhu:secret placeholder, which only fetch fills in; \
    pass a secret of the machine's group by name in `secrets` instead
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

// Why a script's exec ended without an exit; nil after an exit (its event was
// seen) or a cancelled run. A machine-lost verdict never proves process exit.
func lostReason(_ termination: ExecSession.Termination, id: ExecID) -> String? {
  switch termination {
  case .exited, .signaled, .interrupted: nil
  case let .machineLost(machine): "machine \(machine.rawValue) stopped responding; remote process outcome is unknown"
  case .tailLost: "\(execHandle(id)) is finished and its stream is no longer replayable"
  case .unreachable: "machine connection for \(execHandle(id)) failed; the run may still be tracked server-side"
  case .cancelled: "\(execHandle(id)) was cancelled"
  case let .streamFailed(message): message
  }
}

// Kills a script's exec on main; one that has already ended is no failure.
func killScriptExec(_ id: ExecID, via client: SpaceClient) async throws {
  do {
    let _: JSONValue = try await client.api(.post, "/v1/exec/\(id.rawValue)/kill")
  } catch let failure as SpaceClient.ToolFailure where failure.error.code.rawValue == "alreadyEnded" {
  } catch let failure as SpaceClient.TransportFailure where failure.code == "alreadyEnded" {}
}
