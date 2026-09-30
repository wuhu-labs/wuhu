import SessionDomain

public struct ArchiveBusySession: Equatable, Sendable {
  public var id: SessionID
  public var title: String

  public init(id: SessionID, title: String) {
    self.id = id
    self.title = title
  }
}

public struct SubtreeArchiveBusy: Error, Equatable, Sendable {
  public var sessions: [ArchiveBusySession]

  public init(sessions: [ArchiveBusySession]) {
    self.sessions = sessions
  }

  public var message: String {
    "busy: " + sessions.map { "\($0.id.rawValue) (\($0.title))" }.joined(separator: ", ")
  }
}

public enum SessionError: Error, Equatable, Sendable {
  case archiveGraceExpired
  case archiveInProgress
  case archiveReservationLost
}
