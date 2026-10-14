#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import enum JSONValue.JSONValue
import class JSONValue.JSONValueEncoder
import OperationClient
import struct OperationProtocol.ChannelPayload
import struct OperationProtocol.OperationError
import QuickJSKit
import struct SpaceContract.GroupID
import SpaceCore
import Synchronization

public struct ScriptMachineV2Access: Sendable {
  public let client: @Sendable (GroupID) async throws -> OperationClient
  public init(client: @escaping @Sendable (GroupID) async throws -> OperationClient) { self.client = client }
}

final class ScriptV2Operations: Sendable {
  struct Handle: Sendable { let client: OperationClient; let machine: String }
  private struct State { var keys: [String: UUID] = [:]; var handles: [UUID: Handle] = [:]; var starting = 0; var closed = false; var finished: Set<UUID> = []; var terminal: Set<UUID> = [] }
  private let state = Mutex(State())
  private let ending: AsyncStream<Void>
  private let end: AsyncStream<Void>.Continuation
  init() { (ending, end) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(1)) }
  func existing(_ key: String) -> UUID? { state.withLock { $0.keys[key] } }
  func reserve() throws { try state.withLock { state in guard !state.closed else { throw OperationError(.operationEnded) }; guard state.handles.count < 4096 && state.handles.count - state.terminal.count + state.starting < 8 else { throw OperationError(.capacityExceeded) }; state.starting += 1 } }
  func adopt(_ id: UUID, handle: Handle, key: String) { state.withLock { $0.handles[id] = handle; $0.keys[key] = id } }
  func settle(_ id: UUID?, handle: Handle?, key: String? = nil) async throws {
    let closed = state.withLock { state in
      state.starting -= 1
      if let id, let handle { state.handles[id] = handle; if let key { state.keys[key] = id } }
      return state.closed
    }
    if closed, let id, let handle { _ = try await handle.client.stop(id, reason: "scriptEnded"); throw OperationError(.operationEnded) }
  }

  func handle(_ id: UUID) throws -> Handle { try state.withLock { state in guard let handle = state.handles[id] else { throw OperationError(.unknownOperation, operation: id) }; return handle } }
  func observed(_ id: UUID, terminal: Bool, consumed: Bool) { state.withLock { if terminal { $0.terminal.insert(id) }; if terminal && consumed { $0.finished.insert(id) } } }
  func run() async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await self.maintain() }
      for await _ in ending {}
      group.cancelAll()
    }
  }

  private func maintain() async {
    @Dependency(\.continuousClock) var clock
    while !Task.isCancelled {
      do { try await clock.sleep(for: .seconds(20)) } catch { return }
      await maintenancePass()
    }
  }

  func maintenancePass() async {
    let handles = state.withLock { state in state.handles.filter { !state.finished.contains($0.key) } }
    await withTaskGroup(of: Void.self) { group in
      for (id, handle) in handles { group.addTask {
        do { let snapshot = try await handle.client.reconcile(id)
          self.observed(id, terminal: snapshot.verdict != nil, consumed: snapshot.outputConsumed)
        } catch let error as OperationError { if error.code == .unknownOperation { self.observed(id, terminal: true, consumed: true) } }
        catch {}
      } }
    }
  }

  func shutdown() async {
    end.finish()
    let handles = state.withLock { state in state.closed = true; return state.handles }
    await withTaskGroup(of: Void.self) { group in for (id, handle) in handles { group.addTask { _ = try? await handle.client.stop(id, reason: "scriptEnded") } } }
  }
}

final class ScriptMachineV2Bindings: Sendable {
  let execution: ScriptExecution; let space: Space; let access: ScriptMachineV2Access?
  init(execution: ScriptExecution, space: Space, access: ScriptMachineV2Access?) { self.execution = execution; self.space = space; self.access = access }
  func install(in engine: JSEngine) {
    engine.define("__wuhu_machine_v2", promising: { [self] arguments in
      do { return .object(["ok": try await call(arguments)]) }
      catch let error as OperationError { return .object(["error": try JSONValueEncoder().encode(error)]) }
      catch { return .object(["error": try JSONValueEncoder().encode(OperationError(.storeUnavailable))]) }
    })
  }

  private func call(_ args: [JSONValue]) async throws -> JSONValue {
    let verb = string(args, 0); let reference = string(args, 1)
    let fields: [String: JSONValue] = if case let .object(values)? = args[safe: 2] { Dictionary(uniqueKeysWithValues: values.map { ($0.key, $0.value) }) } else { [:] }
    if verb == "describe" || verb == "start" {
      let group = try await space.principal(of: execution.session).group
      guard let machine = try await space.resolveMachine(reference, usableFrom: group) else { throw OperationError(.unknownMachine) }
      guard let access, try await space.machineV2Members(group: machine.group).contains(machine.id.rawValue) else {
        throw OperationError(.machineUnavailable, message: "Machine is not attached over v2", details: ["state": "detached", "started": false])
      }
      let client = try await access.client(group)
      if verb == "describe" { return try JSONValueEncoder().encode(try await client.describe(machine.id.rawValue)) }
      guard case let .string(kind)? = fields["kind"], let input = fields["input"], case let .string(key)? = fields["key"], !key.isEmpty, key.utf8.count <= 1024 else { throw OperationError(.invalidInput) }
      guard !execution.secrets.carriesPlaceholder(Array(input.jsonString().utf8)) else { throw OperationError(.invalidInput, message: "Secret placeholders are only supported by fetch") }
      if case let .object(values) = input, values["secretValues"] != nil || values["sessionCredential"] != nil { throw OperationError(.invalidInput, message: "Exec credential fields are server-owned") }
      let timeout: Duration
      switch fields["timeoutMs"] {
      case let .integer(n)?: guard n > 0 && n <= Int(scriptSecondsCeiling * 1000) else { throw OperationError(.invalidInput) }; timeout = .milliseconds(n)
      case let .number(n)?: guard n.isFinite && n > 0 && n <= scriptSecondsCeiling * 1000 else { throw OperationError(.invalidInput) }; timeout = .milliseconds(Int(n))
      case nil: timeout = execution.lifetime
      default: throw OperationError(.invalidInput)
      }
      if execution.v2Operations.existing(key) != nil {
        let id = try await client.start(machine.id.rawValue, request: .init(kind: kind, input: input), owner: .init(scope: execution.id, key: key), timeout: min(timeout, execution.lifetime))
        return .string(id.uuidString)
      }
      try execution.v2Operations.reserve()
      var id: UUID?
      do {
        _ = try await client.describe(machine.id.rawValue)
        id = try await client.start(machine.id.rawValue, request: .init(kind: kind, input: input), owner: .init(scope: execution.id, key: key), timeout: min(timeout, execution.lifetime), onClaim: { id in
          self.execution.v2Operations.adopt(id, handle: .init(client: client, machine: machine.id.rawValue), key: key)
        })
      } catch {
        let claimed = execution.v2Operations.existing(key)
        try await execution.v2Operations.settle(nil, handle: nil)
        if let claimed {
          let code = (error as? OperationError)?.code
          let reason = code == .requestCancelled ? "callerCancelled" : "startFailed"
          await Task {
            do {
              let snapshot = try await client.stop(claimed, reason: reason)
              self.execution.v2Operations.observed(claimed, terminal: snapshot.verdict != nil, consumed: snapshot.outputConsumed)
            } catch let error as OperationError where error.code == .unknownOperation {
              self.execution.v2Operations.observed(claimed, terminal: true, consumed: true)
            } catch {}
          }.value
        }
        throw error
      }
      try await execution.v2Operations.settle(id, handle: .init(client: client, machine: machine.id.rawValue), key: key)
      return .string(id!.uuidString)
    }
    guard let id = UUID(uuidString: reference) else { throw OperationError(.invalidInput) }
    let handle = try execution.v2Operations.handle(id); let client = handle.client
    let channel = if case let .string(value)? = fields["channel"] { value } else { "" }
    switch verb {
    case "poll", "result":
      let snapshot = try await client.reconcile(id, holdMs: verb == "result" ? 20000 : 0)
      if verb == "result", snapshot.verdict == nil {
        @Dependency(\.continuousClock) var clock
        try await clock.sleep(for: .milliseconds(10))
      }
      if snapshot.verdict != nil { execution.v2Operations.observed(id, terminal: true, consumed: snapshot.outputConsumed) }
      if snapshot.verdict != nil && snapshot.finalOffsets.isEmpty { _ = try await client.poll(id, terminalAck: true) }
      return try JSONValueEncoder().encode(snapshot)
    case "next":
      let snapshot = try await client.poll(id, channel: channel, holdMs: 20000)
      if snapshot.verdict != nil { execution.v2Operations.observed(id, terminal: true, consumed: snapshot.outputConsumed) }
      let chunks = try await client.takeOutput(id, channel: channel)
      if snapshot.channelEnd { _ = try await client.poll(id, channel: channel, terminalAck: true) }
      return .object(["items": try JSONValueEncoder().encode(chunks), "done": .bool(snapshot.channelEnd)])
    case "write", "end":
      let bytes: Data
      if verb == "end" { bytes = Data() }
      else if case let .object(payload)? = fields["payload"], case let .string(text)? = payload["text"] { bytes = Data(text.utf8) }
      else if case let .object(payload)? = fields["payload"], case let .string(base64)? = payload["base64"], let data = Data(base64Encoded: base64) { bytes = data }
      else { throw OperationError(.invalidInput) }
      guard bytes.count <= 65536, !execution.secrets.carriesPlaceholder(Array(bytes)) else { throw OperationError(.inputTooLarge) }
      @Dependency(\.continuousClock) var clock
      while true {
        let receipt = try await client.write(id, channel: channel, payload: ChannelPayload(data: bytes), end: verb == "end")
        if !receipt.blocked { return try JSONValueEncoder().encode(receipt) }
        try await clock.sleep(for: .milliseconds(10))
      }
    case "stop":
      let reason = if case let .string(value)? = fields["reason"] { value } else { "callerCancelled" }
      let snapshot = try await client.stop(id, reason: reason)
      if snapshot.verdict != nil { execution.v2Operations.observed(id, terminal: true, consumed: snapshot.outputConsumed) }
      return try JSONValueEncoder().encode(snapshot)
    default: throw OperationError(.invalidInput)
    }
  }
}
