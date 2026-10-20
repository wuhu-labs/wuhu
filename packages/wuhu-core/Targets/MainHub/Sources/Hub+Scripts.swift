import Dependencies
import Logging
import MachineContract
import SessionDomain
import SpaceCore
import SpaceTools

extension Hub {
  nonisolated private func context(_ session: SessionID) async throws -> SpaceToolContext {
    try await SpaceToolContext(space: space, principal: space.principal(of: session))
  }

  nonisolated public func principal(of session: SessionID) async throws -> Principal { try await space.principal(of: session) }
  nonisolated public func usableMachines(session: SessionID) async throws -> [MachineRecord] { try await space.machines(usableFrom: principal(of: session).group) }
  nonisolated public func resolveMachine(_ reference: String, session: SessionID) async throws -> MachineRecord? { try await space.resolveMachine(reference, usableFrom: principal(of: session).group) }
  nonisolated public func ownExecs(session: SessionID) async throws -> [ExecStatus] { try await context(session).ownExecs() }
  nonisolated public func ownExecStatus(_ id: String, session: SessionID) async throws -> ExecStatus { try await context(session).ownExecStatus(id) }
  nonisolated public func releaseScriptExecs(script: String) async throws { try await space.releaseScriptExecs(script: script) }

  nonisolated public func announceScriptRestart() async {
    do {
      for owner in try await space.takeScriptExecOwners() {
        var text = "script.\(owner.script) was killed by a server restart"
        if !owner.live.isEmpty {
          let ids = owner.live.map(\.rawValue).joined(separator: ", ")
          text += "; the machine processes it left running (\(ids)) get killed about a minute after the restart, or when their machine reconnects if it is away then"
        }
        @Dependency(\.date) var date
        @Dependency(\.uuid) var uuid
        do {
          _ = try await append(SessionID(rawValue: owner.session), .inputEnqueued(.notification(.init(
            id: uuid(), timestamp: date.now, kind: .script, subscriptionID: .script(owner.script), content: .init(text: text),
          )))).value(Int.self)
        } catch {
          Logger(label: "wuhu.execution-boot").warning("Could not notify script owner: \(error)")
        }
      }
    } catch {
      Logger(label: "wuhu.execution-boot").error("Could not announce scripts stopped by restart: \(error)")
    }
  }
}
