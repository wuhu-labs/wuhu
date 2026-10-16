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
  case generationChanged
  case transcriptChanged
  case routeChanged
}

extension SessionStore {
  public func writePortableHandoff(_ id: SessionID, expectedGeneration: Int, source: Transcript, transcript: Transcript, transition: ModelRouteTransition? = nil) async throws -> Transcript {
    precondition(transcript.pendingToolCallIDs.isEmpty)
    precondition(transition == nil || transition?.transcript == transcript)
    guard case let .generationHead(head)? = transcript.items.first, head.replayBinding != nil else {
      preconditionFailure("portable handoff requires a bound generation head")
    }
    let key = id.rawValue
    let now = SQLiteDateFormat.string(from: dateGen.now)
    return try await writer.write { db in
      let runtime = try Sessions.runtime(key, in: db)
      guard runtime.generation == expectedGeneration else { throw PortableHandoffConflict.generationChanged }
      let old = try Sessions.transcript(key, in: db)
      let hydrated = try Sessions.kernelTranscript(key, in: db)
      guard old.items == source.items || hydrated.items == source.items else { throw PortableHandoffConflict.transcriptChanged }
      let existing = Dictionary(uniqueKeysWithValues: old.items.map { ($0.id, $0) })
      guard old.pendingToolCallIDs.isEmpty else { throw PortableHandoffError.outstandingToolCalls }
      for item in transcript.items.dropFirst() {
        if let original = existing[item.id] {
          precondition(original == item, "rewritten handoff items require new content IDs")
        } else {
          let row = SessionContentRow(sessionID: key, id: item.id.uuidString.lowercased(), payload: try Sessions.encode(item))
          try SessionContentRow.insert { row }.execute(db)
        }
      }
      if let transition { try Sessions.commitRouteTransition(key, transition: transition, in: db) }
      try Sessions.writeGeneration(key, generation: runtime.generation + 1, transcript: transcript, in: db)
      try Sessions.refreshWork(key, transcript: transcript, now: now, in: db)
      try PromptRevisions.advance(key, in: db)
      return transcript
    }
  }
}
