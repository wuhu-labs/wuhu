#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SessionDomain.SessionID
import struct SpaceCore.CompactRequestClaim
import protocol SpaceCore.SessionExecutionOwnerClient
import struct SpaceCore.StaleCompactClaim
import struct WorkerProtocol.WorkerProtocolError

actor CompactClaims {
  struct Entry: Sendable {
    let session: SessionID
    let generation: Int
    let claim: CompactRequestClaim
  }

  private var entries: [String: Entry] = [:]

  func issue(session: SessionID, generation: Int, owner: any SessionExecutionOwnerClient) async throws -> CompactClaimSnapshot? {
    guard let claim = try await owner.claimCompactRequest(session, generation: generation) else { return nil }
    entries = entries.filter { $0.value.session != session || $0.value.claim.identifiesSameRequest(as: claim) }
    if let existing = entries.first(where: { $0.value.session == session && $0.value.claim.identifiesSameRequest(as: claim) }) {
      return CompactClaimSnapshot(handle: existing.key, transcript: .init(claim.transcript))
    }
    guard entries.count < 4096 else { throw WorkerProtocolError(.capacityExceeded, message: "Too many outstanding compact claims") }
    let handle = UUID().uuidString
    entries[handle] = Entry(session: session, generation: generation, claim: claim)
    return CompactClaimSnapshot(handle: handle, transcript: .init(claim.transcript))
  }

  func complete(_ handle: String?) { if let handle { entries[handle] = nil } }

  func resolve(_ handle: String?, session: SessionID) throws -> CompactRequestClaim? {
    guard let handle else { return nil }
    guard let entry = entries[handle], entry.session == session else {
      throw WorkerProtocolError(.invalidMessage, message: "Unknown compact claim handle")
    }
    return entry.claim.requiringCurrentCompletion()
  }
}
