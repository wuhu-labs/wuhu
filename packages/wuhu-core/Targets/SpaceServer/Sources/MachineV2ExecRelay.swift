#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct Credentials.SpaceSecretStores
import Dependencies
import enum JSONValue.JSONValue
import MachineChannel
import MachineContract
import class OperationClient.OperationClient
import struct OperationClient.OperationOwner
import struct OperationProtocol.ChannelPayload
import struct OperationProtocol.OperationError
import struct OperationProtocol.Verdict
import struct OperationProtocol.WriteReceipt
import Serve
import struct SessionDomain.SessionID
import SpaceCore
import Synchronization

struct MachineV2ExecRelay: Sendable {
  let record: ExecRecord
  let endpoint: ChannelEndpoint
  let space: Space
  let tokens: ExecTokens?
  let secrets: SpaceSecretStores?
}

extension MachineV2Service {
  func noteMinted(_ record: ExecRecord, space: Space) {
    relays.continuation.yield(.minted(record, space))
  }

  func expireUnconnected(_ record: ExecRecord, space: Space) async {
    @Dependency(\.continuousClock) var clock
    do { try await clock.sleep(for: .seconds(60)) } catch { return }
    if execEndpoints[record.id.rawValue] == nil { try? await space.finishExec(record.id, .reaped) }
  }

  func runCaller(_ record: ExecRecord, socket: WebSocket, space: Space, tokens: ExecTokens?, secrets: SpaceSecretStores?) async {
    @Dependency(\.date) var date
    let key = record.id.rawValue
    for (key, entry) in execEndpoints where entry.completed.map({ date.now.timeIntervalSince($0) >= 600 }) == true {
      execEndpoints[key] = nil
      killedExecs.remove(key)
    }
    let caller = UUID()
    if execEndpoints[key] == nil {
      guard execEndpoints.count < 4096 else { socket.close(); return }
      let endpoint = ChannelEndpoint()
      execEndpoints[key] = ExecEndpoint(endpoint: endpoint)
      relays.continuation.yield(.caller(.init(record: record, endpoint: endpoint, space: space, tokens: tokens, secrets: secrets)))
    }
    let endpoint = execEndpoints[key]!.endpoint
    execEndpoints[key]!.callers.insert(caller)
    execEndpoints[key]!.disconnected = nil
    await endpoint.run(WebSocketTransport(socket))
    execEndpoints[key]?.callers.remove(caller)
    if execEndpoints[key]?.callers.isEmpty == true { execEndpoints[key]?.disconnected = date.now }
  }

  private func callerExpired(_ key: String) -> Bool {
    @Dependency(\.date) var date
    guard let entry = execEndpoints[key], entry.callers.isEmpty, let disconnected = entry.disconnected else { return false }
    return date.now.timeIntervalSince(disconnected) >= 60
  }

  func killExec(_ record: ExecRecord) async throws {
    killedExecs.insert(record.id.rawValue)
    if let id = execOperations[record.id.rawValue] {
      _ = try await client(group: record.group).stop(id, reason: "callerCancelled")
    }
  }

  func serveExec(_ relay: MachineV2ExecRelay) async {
    let record = relay.record
    defer {
      @Dependency(\.date) var date
      execEndpoints[record.id.rawValue]?.completed = date.now
      execOperations[record.id.rawValue] = nil
      killedExecs.remove(record.id.rawValue)
    }
    let exec = await withTaskGroup(of: IncomingExec?.self) { tasks in
      tasks.addTask {
        var incoming = relay.endpoint.incomingExecs.makeAsyncIterator()
        return await incoming.next()
      }
      tasks.addTask {
        @Dependency(\.continuousClock) var clock
        try? await clock.sleep(for: .seconds(60))
        return nil
      }
      defer { tasks.cancelAll() }
      return await tasks.next() ?? nil
    }
    guard let exec else { try? await relay.space.finishExec(record.id, .reaped); return }
    do {
      guard try await relay.space.execRecord(record.id)?.terminal == nil else { throw OperationError(.operationEnded, message: "Exec output is no longer retained") }
      let client = try await client(group: record.group)
      _ = try await client.describe(record.machine.rawValue)
      let owner = OperationOwner(scope: "exec/" + record.id.rawValue, key: record.id.rawValue)
      var input: [String: JSONValue] = ["argv": .array(exec.start.command.map(JSONValue.string)), "cwd": .string(exec.start.cwd), "stdin": true]
      input["env"] = exec.start.env.map { .object(.init(uniqueKeysWithValues: $0.entries.map { ($0.key, .string($0.value)) })) }
      let names = (exec.start.secrets?.entries ?? [:]).filter { !SessionExecEnvironment.reserved.contains($0.key) }
      if !names.isEmpty {
        guard let group = try await relay.space.machine(record.machine)?.group,
              let store = try relay.secrets?.group(group.rawValue) else { throw OperationError(.invalidInput, message: "Machine group secrets unavailable") }
        var values: [String: JSONValue] = [:]
        for (variable, name) in names.sorted(by: { $0.value < $1.value }) {
          do { values[variable] = .string(try await store.value(of: name)) }
          catch { throw OperationError(.invalidInput, message: "Secret \(name) unavailable in group \(group.rawValue)") }
        }
        input["secretValues"] = .object(.init(uniqueKeysWithValues: values.map { ($0.key, $0.value) }))
      }
      let claimed = Mutex<UUID?>(nil)
      var reserved = false
      if let caller = record.caller, let tokens = relay.tokens {
        input["sessionCredential"] = try await credential(tokens: tokens, session: SessionID(rawValue: caller), group: record.group, owner: owner, timeout: .seconds(exec.start.timeout ?? ExecTokens.longestLife))
        reserved = true
      }
      let id: UUID
      do {
        id = try await client.start(record.machine.rawValue, request: .init(kind: "exec.v1", input: .object(.init(uniqueKeysWithValues: input.map { ($0.key, $0.value) }))), owner: owner, onClaim: { id in claimed.withLock { $0 = id } })
      } catch {
        if let id = claimed.withLock({ $0 }) { _ = try? await client.stop(id, reason: "callerCancelled") }
        if reserved, let caller = record.caller { relay.tokens?.finishCredentialAttempt(session: SessionID(rawValue: caller), group: record.group, scope: owner.scope, key: owner.key, claimed: claimed.withLock { $0 != nil }) }
        throw error
      }
      if reserved, let caller = record.caller { relay.tokens?.finishCredentialAttempt(session: SessionID(rawValue: caller), group: record.group, scope: owner.scope, key: owner.key, claimed: true) }
      execOperations[record.id.rawValue] = id
      try await relay.space.recordExecCommand(record.id, command: exec.start.command.joined(separator: " "))
      if killedExecs.contains(record.id.rawValue) { _ = try await client.stop(id, reason: "callerCancelled") }
      let verdict = try await pump(exec, client: client, id: id, key: record.id.rawValue)
      if let error = verdict.error { throw error }
      if verdict.tag == .stopped { throw OperationError(.requestCancelled, message: "Machine exec stopped: \(verdict.reason ?? "stopped")", operation: id) }
      guard let termination = verdict.result?.object?["termination"]?.object else { throw OperationError(.invalidResponse, operation: id) }
      let status: ExitStatus
      if termination["tag"]?.stringValue == "signal", let signal = termination["signal"]?.intValue {
        status = .signaled(signal: signal)
        try await relay.space.finishExec(record.id, .signaled(signal: signal))
      } else if termination["tag"]?.stringValue == "exit", let code = termination["code"]?.intValue {
        status = .exited(code: code)
        try await relay.space.finishExec(record.id, .exited(code: code))
      } else { throw OperationError(.invalidResponse, operation: id) }
      await exec.exit(status)
    } catch is CancellationError {
      await stopRelay(record)
      try? await relay.space.finishExec(record.id, .machineLost)
    } catch {
      await stopRelay(record)
      let message: String
      if let error = error as? OperationError { message = "\(error.code.rawValue): \(error.message)" }
      else { message = "machine exec failed: \(error)" }
      try? await exec.send(.stderr, Array((message + "\n").utf8), waitForCapacity: false)
      try? await relay.space.finishExec(record.id, .exited(code: 1))
      await exec.exit(.exited(code: 1))
    }
  }

  private func stopRelay(_ record: ExecRecord) async {
    guard let id = execOperations[record.id.rawValue], let client = try? await client(group: record.group) else { return }
    _ = try? await client.stop(id, reason: "callerCancelled")
  }

  private func pump(_ exec: IncomingExec, client: OperationClient, id: UUID, key: String) async throws -> Verdict {
    let budget = RelayOutputBudget()
    return try await withThrowingTaskGroup(of: Verdict?.self) { tasks in
      tasks.addTask {
        @Dependency(\.continuousClock) var clock
        var ticks = 0
        while true {
          try await clock.sleep(for: .seconds(1))
          if await self.callerExpired(key) {
            await exec.stopOutput()
            _ = try await client.stop(id, reason: "callerGone")
            return nil
          }
          ticks += 1
          if ticks == 20 { _ = try await client.reconcile(id); ticks = 0 }
        }
      }
      tasks.addTask {
        for try await bytes in exec.stdin { try await self.input(client, id: id, bytes: Data(bytes), end: false) }
        try await self.input(client, id: id, bytes: Data(), end: true)
        return nil
      }
      tasks.addTask {
        for await _ in exec.kills { await exec.stopOutput(); _ = try await client.stop(id, reason: "callerCancelled"); break }
        return nil
      }
      if let timeout = exec.start.timeout {
        tasks.addTask {
          @Dependency(\.continuousClock) var clock
          try await clock.sleep(for: .seconds(timeout))
          await exec.stopOutput()
          _ = try await client.stop(id, reason: "timeout")
          return nil
        }
      }
      for (channel, stream) in [("stdout", ExecOutputStream.stdout), ("stderr", .stderr)] {
        tasks.addTask {
          while true {
            let snapshot = try await client.poll(id, channel: channel, holdMs: 20000)
            for payload in try await client.takeOutput(id, channel: channel) {
              let bytes = payload.data ?? Data()
              let admitted = budget.bytes.withLock { used in
                let count = min(bytes.count, max(0, (exec.start.maxOutput ?? Int.max) - used)); used += count; return count
              }
              if admitted > 0 { try await exec.send(stream, Array(bytes.prefix(admitted))) }
              if admitted < bytes.count || budget.bytes.withLock({ $0 >= (exec.start.maxOutput ?? Int.max) }) {
                await exec.stopOutput()
                _ = try await client.stop(id, reason: "outputLimit")
              }
            }
            if snapshot.channelEnd, let verdict = snapshot.verdict {
              _ = try await client.poll(id, channel: channel, terminalAck: true)
              return verdict
            }
            if snapshot.channelEnd {
              @Dependency(\.continuousClock) var clock
              try await clock.sleep(for: .milliseconds(100))
            }
          }
        }
      }
      defer { tasks.cancelAll() }
      var outputs = 0; var terminal: Verdict?
      while let verdict = try await tasks.next() {
        if let verdict { outputs += 1; terminal = verdict }
        if outputs == 2, let terminal { return terminal }
      }
      throw OperationError(.invalidResponse, operation: id)
    }
  }

  private func input(_ client: OperationClient, id: UUID, bytes: Data, end: Bool) async throws {
    @Dependency(\.continuousClock) var clock
    while true {
      let receipt: WriteReceipt
      do { receipt = try await client.write(id, channel: "stdin", payload: ChannelPayload(data: bytes), end: end) }
      catch let error as OperationError where error.code == .operationEnded { return }
      if !receipt.blocked { return }
      try await clock.sleep(for: .milliseconds(10))
    }
  }
}

private final class RelayOutputBudget: Sendable {
  let bytes = Mutex(0)
}
