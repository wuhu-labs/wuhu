#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import Logging
import struct SessionDomain.SessionID
import protocol SessionTools.ScriptOwnerClient

func lostWorkerScript(owner: any ScriptOwnerClient) -> @Sendable (SessionID, String) async -> Void {
  { session, script in
    do { try await owner.releaseScriptExecs(script: script) }
    catch { Logger(label: "wuhu.execution-worker").error("Could not release lost script processes") }
    guard !script.hasPrefix("handler-") else { return }
    @Dependency(\.uuid) var uuid
    @Dependency(\.date) var date
    do {
      try await owner.notify(session: session, notification: .init(id: uuid(), timestamp: date.now, kind: .script, subscriptionID: .script(script), content: .init(text: "script \(script) was killed by an execution worker restart; its effects are unknown and it will not be retried automatically")))
    } catch { Logger(label: "wuhu.execution-worker").error("Could not notify lost script owner") }
  }
}
