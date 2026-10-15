#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SessionDomain.SessionID
import struct SpaceContract.GroupID

struct EmptyRequest: Codable, Sendable {}
struct ProviderRequest: Codable, Sendable { let provider: String }
struct AudienceRequest: Codable, Sendable { let audience: URL }
struct TokenRequest: Codable, Sendable { let audience: URL; let session: SessionID }
struct TraceRequest: Codable, Sendable { let id: UUID }
struct TraceAppendRequest: Codable, Sendable { let id: UUID; let data: Data }
struct MediaRequest: Codable, Sendable { let reference: MediaSnapshot; let group: GroupID }
