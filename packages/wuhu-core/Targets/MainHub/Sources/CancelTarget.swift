import struct MachineContract.ExecID

// cancel(id): the id's prefix says what it names. Subscriptions are cancelled
// by the owner, which holds their slots, and so are exec jobs; a script where
// it runs.
public enum CancelTarget: Equatable {
  case subscription
  case script(String)
  case exec(ExecID)

  private static let subscriptionPrefixes = ["obs.", "timer.", "stall.", "deadline."]

  public init(_ id: String) throws(ToolProblem) {
    if id.hasPrefix("script.") {
      let script = String(id.dropFirst("script.".count))
      guard !script.isEmpty else { throw ToolProblem("cancel: \(id) names no script", code: "invalidArgument") }
      self = .script(script)
      return
    }
    if id.hasPrefix("exec.") {
      let exec = String(id.dropFirst("exec.".count))
      guard !exec.isEmpty else { throw ToolProblem("cancel: \(id) names no exec", code: "invalidArgument") }
      self = .exec(ExecID(rawValue: exec))
      return
    }
    if Self.subscriptionPrefixes.contains(where: id.hasPrefix) {
      self = .subscription
      return
    }
    if id.count == 8, id.allSatisfy(\.isHexDigit) {
      throw ToolProblem("cancel: a script id is written script.\(id)", code: "invalidArgument")
    }
    throw ToolProblem("cancel: \(id) is not an id cancel takes; ids start with obs., timer., script. or exec.", code: "invalidArgument")
  }
}
