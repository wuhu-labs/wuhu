import enum JSONValue.JSONValue
import struct MachineContract.ExecID
import SessionDomain

/// How an exec job is shown and cancelled: `exec.<exec id>`.
public func execHandle(_ id: ExecID) -> String { SubscriptionID.exec(id.rawValue).rawValue }

/// What exec and run_script return when their wait runs out first: one JSON
/// object, `status` first.
public func runningJSON(_ handle: String, tail: String, note: String) -> String {
  let fields = [("status", "running"), ("id", handle), ("tail", tail), ("note", note)]
  return "{" + fields.map { "\(jsonString($0.0)):\(jsonString($0.1))" }.joined(separator: ",") + "}"
}

private func jsonString(_ text: String) -> String { JSONValue.string(text).jsonString() }
