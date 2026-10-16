#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import CProcessIdentity

public struct ImageReference: Codable, Equatable, Sendable {
  public let id: UUID
  public let digest: String
  public let owner: String
  public let processID: Int32?
  public let birth: String?

  init(id: UUID, digest: String, owner: String, processID: Int32? = nil, birth: String? = nil) {
    self.id = id; self.digest = digest; self.owner = owner; self.processID = processID; self.birth = birth
  }

  func validate() throws {
    guard digest.count == 64, digest.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }),
          !owner.isEmpty, owner.utf8.count <= 512, (processID == nil) == (birth == nil),
          processID.map({ $0 > 0 }) ?? true, birth.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true
    else { throw ImageRetentionError.invalidEvidence }
  }
}

public enum ImageRetentionError: Error, Equatable {
  case unsafeStorage
  case invalidEvidence
  case imageChanged
  case processStillLive
}

func imageProcessBirth(_ processID: Int32) throws -> String {
  var bytes = [CChar](repeating: 0, count: 256)
  guard process_birth_identity(processID, &bytes, bytes.count) == 0 else { throw ImageRetentionError.invalidEvidence }
  return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
