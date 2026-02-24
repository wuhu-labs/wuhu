import Foundation

public enum WuhuSessionType: String, Sendable, Hashable, Codable {
  case coding
  case channel
  /// A forked coding session that preserves the parent channel's tool schema in the prompt
  /// so cached KV entries carry over, while having coding-level execution permissions.
  case forkedChannel = "forked-channel"
}

public struct WuhuSession: Sendable, Hashable, Codable, Identifiable {
  public var id: String
  public var type: WuhuSessionType
  public var provider: WuhuProvider
  public var model: String
  /// UUID of the canonical environment definition used to create this session, if known.
  public var environmentID: String?
  public var environment: WuhuEnvironment
  public var cwd: String
  public var runnerName: String?
  public var parentSessionID: String?
  /// If set, clients should hide transcript entries whose `id` is less than this value.
  /// Used for forked sessions to keep inherited history out of the visible UI while still
  /// providing full context to the LLM.
  public var displayStartEntryID: Int64?
  public var createdAt: Date
  public var updatedAt: Date
  public var headEntryID: Int64
  public var tailEntryID: Int64

  public init(
    id: String,
    type: WuhuSessionType = .coding,
    provider: WuhuProvider,
    model: String,
    environmentID: String? = nil,
    environment: WuhuEnvironment,
    cwd: String,
    runnerName: String? = nil,
    parentSessionID: String?,
    displayStartEntryID: Int64? = nil,
    createdAt: Date,
    updatedAt: Date,
    headEntryID: Int64,
    tailEntryID: Int64,
  ) {
    self.id = id
    self.type = type
    self.provider = provider
    self.model = model
    self.environmentID = environmentID
    self.environment = environment
    self.cwd = cwd
    self.runnerName = runnerName
    self.parentSessionID = parentSessionID
    self.displayStartEntryID = displayStartEntryID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.headEntryID = headEntryID
    self.tailEntryID = tailEntryID
  }

  enum CodingKeys: String, CodingKey {
    case id
    case type
    case provider
    case model
    case environmentID
    case environment
    case cwd
    case runnerName
    case parentSessionID
    case displayStartEntryID
    case createdAt
    case updatedAt
    case headEntryID
    case tailEntryID
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    type = try c.decodeIfPresent(WuhuSessionType.self, forKey: .type) ?? .coding
    provider = try c.decode(WuhuProvider.self, forKey: .provider)
    model = try c.decode(String.self, forKey: .model)
    environmentID = try c.decodeIfPresent(String.self, forKey: .environmentID)
    environment = try c.decode(WuhuEnvironment.self, forKey: .environment)
    cwd = try c.decode(String.self, forKey: .cwd)
    runnerName = try c.decodeIfPresent(String.self, forKey: .runnerName)
    parentSessionID = try c.decodeIfPresent(String.self, forKey: .parentSessionID)
    displayStartEntryID = try c.decodeIfPresent(Int64.self, forKey: .displayStartEntryID)
    createdAt = try c.decode(Date.self, forKey: .createdAt)
    updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    headEntryID = try c.decode(Int64.self, forKey: .headEntryID)
    tailEntryID = try c.decode(Int64.self, forKey: .tailEntryID)
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(type, forKey: .type)
    try c.encode(provider, forKey: .provider)
    try c.encode(model, forKey: .model)
    try c.encodeIfPresent(environmentID, forKey: .environmentID)
    try c.encode(environment, forKey: .environment)
    try c.encode(cwd, forKey: .cwd)
    try c.encodeIfPresent(runnerName, forKey: .runnerName)
    try c.encodeIfPresent(parentSessionID, forKey: .parentSessionID)
    try c.encodeIfPresent(displayStartEntryID, forKey: .displayStartEntryID)
    try c.encode(createdAt, forKey: .createdAt)
    try c.encode(updatedAt, forKey: .updatedAt)
    try c.encode(headEntryID, forKey: .headEntryID)
    try c.encode(tailEntryID, forKey: .tailEntryID)
  }
}
