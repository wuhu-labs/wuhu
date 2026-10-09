import JSONValue
import MachineContract
import SessionDomain
import SpaceCore

public extension SpaceToolContext {
  func ownExecs() async throws(ToolRunError) -> [ExecStatus] {
    do {
      let caller = try execCaller()
      return try await space.liveExecs().filter { $0.caller == caller }.map(Self.execStatus)
    } catch { throw Wire.failure(error) }
  }

  func ownExecStatus(_ id: String) async throws(ToolRunError) -> ExecStatus {
    Self.execStatus(try await ownExec(id))
  }

  func killOwnExec(_ id: String, kill: @Sendable (ExecID) async throws -> Void) async throws(ToolRunError) {
    let record = try await ownExec(id)
    do { try await kill(record.id) }
    catch { throw Wire.failure(error) }
  }

  private func ownExec(_ id: String) async throws(ToolRunError) -> ExecRecord {
    do {
      let caller = try execCaller()
      guard ExecID.isValid(id), let record = try await space.execRecord(ExecID(rawValue: id)), record.caller == caller else {
        throw ToolRunError.failed(code: .notFound, message: "unknown exec: \(id)", hint: nil)
      }
      return record
    } catch { throw Wire.failure(error) }
  }

  private func execCaller() throws(ToolRunError) -> String {
    guard case let .session(session) = principal.actor else {
      throw .failed(code: .unauthorized, message: "exec ownership requires a session", hint: nil)
    }
    return session.rawValue
  }

  private static func execStatus(_ record: ExecRecord) -> ExecStatus {
    let state: ExecState = switch record.terminal {
    case nil: .live
    case let .exited(code): .exited(code: code)
    case let .signaled(signal): .signaled(signal: signal)
    case .cancelled: .cancelled
    case .reaped: .reaped
    case .machineLost: .machineLost
    }
    return ExecStatus(id: record.id, machine: record.machine, command: record.command, startedAt: record.startedAt.timeIntervalSince1970, state: state)
  }
}
