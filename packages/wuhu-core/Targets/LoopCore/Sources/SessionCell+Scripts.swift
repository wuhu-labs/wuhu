#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import SessionTools
import struct SpaceCore.SessionPut
import StructuredQueries
import struct WuhuAI.ToolCall
import Wuwei
import WuweiQueries

extension SessionCell {
  mutating func startScript(_ slot: ToolCallJob.ID, _ call: ToolCall, _ plan: ScriptPlan) throws {
    var handle: String
    repeat { handle = "script." + String(client.uuid().uuidString.lowercased().suffix(8)) }
    while ctx.exists(scriptID(handle))
    let membership = SessionScript(handle: handle, slot: slot.key)
    try db.execute(SessionScript.insert { membership })
    ctx.create(scriptID(handle), params: .init(session: id.session, handle: handle, slot: slot, call: call, plan: plan, yieldBy: try yieldDeadline(id.session)))
  }

  func scriptAt(_ slot: String) -> ScriptJob.ID? {
    db.rows(SessionScript.where { $0.slot.eq(slot) }).first.map { scriptID($0.handle) }
  }

  func scriptRuns() -> [ScriptJob.ID] {
    db.rows(SessionScript.all).map { scriptID($0.handle) }
  }

  func runningScripts() -> [String] {
    db.rows(SessionScript.all).map(\.handle).sorted()
  }

  private func scriptID(_ handle: String) -> ScriptJob.ID { .init("\(id.key):\(handle)") }
}

@Table("session_scripts")
struct SessionScript: Owned {
  let handle: String
  let slot: String
}
