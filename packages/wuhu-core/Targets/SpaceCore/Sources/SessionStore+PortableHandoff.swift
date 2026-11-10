#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import StructuredQueries
import StructuredQueriesSQLite

public enum PortableHandoffConflict: Error, Equatable, Sendable {
  case routeChanged
}

extension SessionStore {
  public func writePortableHandoff(_ id: SessionID, transcript: Transcript) async throws -> Transcript {
    try await rows { try $0.writePortableHandoff(id, transcript: transcript) }
  }
}
