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

public enum SessionError: Error, Equatable, Sendable, CustomStringConvertible {
  case unreadableData(SessionID)
  case archiveGraceExpired
  case archiveInProgress
  case archiveReservationLost

  public var description: String {
    switch self {
    case let .unreadableData(id): "session \(id.rawValue) cannot load its stored data; use Start over instead of Resume"
    case .archiveGraceExpired: "the archive grace has expired"
    case .archiveInProgress: "session is being archived; retry after the archive finishes"
    case .archiveReservationLost: "session changed during archive; archive stopped, retry it"
    }
  }
}
