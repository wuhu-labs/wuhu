public enum SessionError: Error, Equatable, Sendable {
  case archiveGraceExpired
  case busyForArchive
}
