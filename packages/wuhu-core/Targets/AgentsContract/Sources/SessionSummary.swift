#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain

public struct SessionSummary: Sendable {
  public var id: SessionID
  public var group: String
  public var kind: SessionKind
  public var parent: SessionID?
  public var createdAt: Date
  public var lifecycle: SessionLifecycle
  public var createdBy: String

  public init(id: SessionID, group: String, kind: SessionKind, parent: SessionID?, createdAt: Date, lifecycle: SessionLifecycle, createdBy: String) {
    self.id = id
    self.group = group
    self.kind = kind
    self.parent = parent
    self.createdAt = createdAt
    self.lifecycle = lifecycle
    self.createdBy = createdBy
  }
}
