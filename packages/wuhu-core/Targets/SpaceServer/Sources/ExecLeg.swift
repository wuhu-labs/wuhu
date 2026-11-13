import MachineContract
import OperationProtocol
import SessionDomain
import SpaceCore

extension Space {
  /// `StartRequest.caller` for a start `session` caused: its id, title and group, read at start time.
  /// Display-only attribution, so a session that can't be read (gone, or no session at all) leaves it out rather than failing the start.
  func startCaller(_ session: SessionID?) async -> StartRequest.Caller? {
    guard let session, let record = try? await sessions.record(session) else { return nil }
    return .init(session: session.rawValue, title: record.title, group: record.group.rawValue)
  }
}

public enum ExecLeg: Hashable, Sendable {
  case session(SessionID)
  case person(AccountID)
  case observer(String)

  /// Nil for a page, which attaches to no exec.
  public init?(_ actor: SpaceCore.Actor) {
    switch actor {
    case let .session(id): self = .session(id)
    case let .person(_, account): self = .person(account)
    case let .observer(observer): self = .observer(observer.member)
    case .page, .publicReader: return nil
    }
  }

  var session: SessionID? { if case let .session(id) = self { id } else { nil } }
}
