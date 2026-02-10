import Foundation

public enum WuhuStoreError: Error, Sendable, CustomStringConvertible {
  case sessionNotFound(String)
  case sessionCorrupt(String)
  case noHeaderEntry(String)

  public var description: String {
    switch self {
    case let .sessionNotFound(id):
      "Session not found: \(id)"
    case let .sessionCorrupt(reason):
      "Session is corrupt: \(reason)"
    case let .noHeaderEntry(id):
      "Session has no header entry: \(id)"
    }
  }
}

public protocol SessionStore: Sendable {
  func createSession(
    provider: WuhuProvider,
    model: String,
    systemPrompt: String,
    cwd: String,
    parentSessionID: String?,
  ) async throws -> WuhuSession

  func getSession(id: String) async throws -> WuhuSession
  func listSessions(limit: Int?) async throws -> [WuhuSession]

  @discardableResult
  func appendEntry(sessionID: String, payload: WuhuEntryPayload) async throws -> WuhuSessionEntry
  func getEntries(sessionID: String) async throws -> [WuhuSessionEntry]
}
