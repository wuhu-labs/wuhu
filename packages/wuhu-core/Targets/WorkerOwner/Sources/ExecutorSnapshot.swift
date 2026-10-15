import struct SessionDomain.ModelSpecifier
import enum SessionDomain.SessionExecutor
import struct WorkerProtocol.WorkerProtocolError

struct ExecutorSnapshot: Codable, Sendable {
  let kind: String
  let specifier: ModelSpecifier?
  let group: String?
  let effort: String?
  let contractor: String?

  init(_ executor: SessionExecutor) {
    specifier = switch executor { case let .kernel(value), let .claudeCode(value): value; default: nil }
    group = switch executor { case let .modelGroup(id, _): id; default: nil }
    effort = switch executor { case let .modelGroup(_, effort): effort; default: nil }
    contractor = switch executor { case let .contractor(name): name; default: nil }
    kind = switch executor { case .kernel: "kernel"; case .modelGroup: "model-group"; case .claudeCode: "claude-code"; case .contractor: "contractor" }
  }

  func executor() throws -> SessionExecutor {
    switch (kind, specifier, group, effort, contractor) {
    case ("kernel", let specifier?, nil, nil, nil): .kernel(specifier)
    case ("claude-code", let specifier?, nil, nil, nil): .claudeCode(specifier)
    case ("model-group", nil, let group?, let effort?, nil): .modelGroup(id: group, effort: effort)
    case ("contractor", nil, nil, nil, let name?): .contractor(name: name)
    default: throw WorkerProtocolError(.invalidMessage, message: "Invalid executor snapshot")
    }
  }
}
