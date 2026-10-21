import Dependencies
import Logging
import MachineContract
import SessionDomain
import SpaceCore
import SpaceTools

extension Hub {
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
