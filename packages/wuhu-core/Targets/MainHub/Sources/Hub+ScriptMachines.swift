import MachineChannel
import struct MachineContract.ExecID
import struct MachineContract.ExecStart
import struct MachineContract.MachineID
import enum MachineContract.VFSOp
import enum MachineContract.VFSResult
import SessionDomain
import SpaceTools
import Synchronization
import TaskLifetime

extension Hub {
  nonisolated public func scriptMachines(session: SessionID) async throws -> [ScriptMachineSnapshot] {
    let access = try machineAccess()
    let attached = await access.files.attached()
    return try await usableMachines(session: session).map {
      ScriptMachineSnapshot(id: $0.id, name: $0.name, attached: attached.contains($0.id))
    }
  }

  nonisolated public func scriptMachineFile(session: SessionID, machine: MachineID, operation: VFSOp) async throws -> VFSResult {
    let access = try await attachedScriptMachine(machine, session: session)
    return try await access.files.attributed(to: session).vfs(machine, operation)
  }

  nonisolated public func startScriptExec(session: SessionID, script: ScriptRunID, request: ScriptExecRequest) async throws -> ScriptExecStream {
    let access = try await attachedScriptMachine(request.machine, session: session)
    let record = try await access.exec.mintScript(request.machine, session, script.rawValue)
    let endpoint = ChannelEndpoint()
    let outgoing = await endpoint.startExec(ExecStart(
      id: record.id, cwd: request.cwd, command: ["sh", "-c", request.command],
      env: request.environment.env, secrets: request.environment.secrets, window: request.window,
      maxOutput: request.maxOutput, timeout: request.timeout,
    ), autoAcknowledge: request.autoAcknowledge)
    if !request.acceptsStdin { await outgoing.closeStdin() }
    return scriptExecConnections.start(session: session, script: script, outgoing: outgoing, endpoint: endpoint, backend: access.exec)
  }

  nonisolated public func scriptExecInput(session: SessionID, script: ScriptRunID, exec: ExecID, input: ScriptExecInput) async throws {
    if case .kill(.recorded) = input {
      _ = try await ownExecStatus(exec.rawValue, session: session)
      try await machineAccess().exec.kill(exec)
      return
    }
    try await scriptExecConnections.input(session: session, script: script, exec: exec, input: input)
  }

  nonisolated private func machineAccess() throws -> ScriptMachineAccess {
    guard let scriptMachines else { throw ScriptError("this server gives scripts no machine access") }
    return scriptMachines
  }

  nonisolated private func attachedScriptMachine(_ machine: MachineID, session: SessionID) async throws -> ScriptMachineAccess {
    let access = try machineAccess()
    guard try await usableMachines(session: session).contains(where: { $0.id == machine }) else {
      throw ScriptError("no machine named \(machine.rawValue)")
    }
    guard await access.files.attached().contains(machine) else { throw ScriptError("machine \(machine.rawValue) is not attached") }
    return access
  }
}

final class ScriptExecConnections: Sendable {
  private struct Connection: Sendable {
    let session: SessionID
    let script: ScriptRunID
    let outgoing: OutgoingExec
    let scope: TaskScope
  }

  private let connections = Mutex<[ExecID: Connection]>([:])

  deinit {
    connections.withLock { Array($0.values) }.forEach { $0.scope.cancel() }
  }

  func start(session: SessionID, script: ScriptRunID, outgoing: OutgoingExec, endpoint: ChannelEndpoint, backend: ExecBackend) -> ScriptExecStream {
    let (events, sink) = AsyncThrowingStream<ScriptExecEvent, any Error>.makeStream()
    let scope = TaskScope()
    connections.withLock { $0[outgoing.id] = Connection(session: session, script: script, outgoing: outgoing, scope: scope) }
    sink.onTermination = { _ in scope.cancel() }
    try! scope.run("script-exec") {
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          do {
            if let reason = try await holdExecLeg(outgoing.id, endpoint: endpoint, backend: backend) { sink.yield(.lost(reason)) }
          } catch { sink.finish(throwing: error) }
        }
        group.addTask {
          do {
            for try await event in outgoing.events {
              sink.yield(.event(event))
              if case .exit = event { return }
              if case .failed = event { return }
            }
          } catch { sink.finish(throwing: error) }
        }
        _ = await group.next()
        group.cancelAll()
      }
      sink.finish()
    }
    return ScriptExecStream(id: outgoing.id, events: events)
  }

  func input(session: SessionID, script: ScriptRunID, exec: ExecID, input: ScriptExecInput) async throws {
    let connection = try connections.withLock { connections -> Connection? in
      guard let connection = connections[exec] else {
        if case .release = input { return nil }
        throw ScriptError("no process \(exec.rawValue) in this script")
      }
      guard connection.session == session, connection.script == script else { throw ScriptError("no process \(exec.rawValue) in this script") }
      return connection
    }
    guard let connection else { return }
    switch input {
    case let .write(bytes): try await connection.outgoing.sendStdin(bytes)
    case .closeStdin: await connection.outgoing.closeStdin()
    case let .acknowledge(through): await connection.outgoing.acknowledge(through: through)
    case .release:
      await connection.scope.close()
      connections.withLock { $0[exec] = nil }
    case .kill(.caller): await connection.outgoing.kill()
    case .kill(.recorded): preconditionFailure("persistent kill is authorized by the hub")
    }
  }
}
