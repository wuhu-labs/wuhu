import Foundation

public struct WuhuSession: Sendable, Hashable, Codable, Identifiable {
  public var id: String
  public var provider: WuhuProvider
  public var model: String
  public var environment: WuhuEnvironment
  public var cwd: String
  public var runnerName: String?
  public var parentSessionID: String?
  public var createdAt: Date
  public var updatedAt: Date
  public var headEntryID: Int64
  public var tailEntryID: Int64

  public init(
    id: String,
    provider: WuhuProvider,
    model: String,
    environment: WuhuEnvironment,
    cwd: String,
    runnerName: String? = nil,
    parentSessionID: String?,
    createdAt: Date,
    updatedAt: Date,
    headEntryID: Int64,
    tailEntryID: Int64,
  ) {
    self.id = id
    self.provider = provider
    self.model = model
    self.environment = environment
    self.cwd = cwd
    self.runnerName = runnerName
    self.parentSessionID = parentSessionID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.headEntryID = headEntryID
    self.tailEntryID = tailEntryID
  }
}
