import Foundation

public struct WuhuSession: Sendable, Hashable, Codable, Identifiable {
  public var id: String
  public var provider: WuhuProvider
  public var model: String
  public var cwd: String
  public var parentSessionID: String?
  public var createdAt: Date
  public var updatedAt: Date
  public var headEntryID: Int64
  public var tailEntryID: Int64

  public init(
    id: String,
    provider: WuhuProvider,
    model: String,
    cwd: String,
    parentSessionID: String?,
    createdAt: Date,
    updatedAt: Date,
    headEntryID: Int64,
    tailEntryID: Int64,
  ) {
    self.id = id
    self.provider = provider
    self.model = model
    self.cwd = cwd
    self.parentSessionID = parentSessionID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.headEntryID = headEntryID
    self.tailEntryID = tailEntryID
  }
}
