import struct MainHub.TerminalRun
import SessionDomain
import struct SpaceCore.Observer

/// Whom a script acts as on main's API: a session, a group's observer in one
/// firing, or a person from a terminal, the last two with the token main
/// minted for that run.
public enum ScriptActor: Sendable {
  case session(SessionID)
  case observer(Observer, token: String)
  case person(TerminalRun, token: String)

  var session: SessionID? {
    if case let .session(session) = self { session } else { nil }
  }
}

extension ToolExecutor {
  func bearer(_ actor: ScriptActor) async throws -> String {
    switch actor {
    case let .session(session): try await credential(session)
    case let .observer(_, token): token
    case let .person(_, token): token
    }
  }
}
