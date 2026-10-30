#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SessionDomain.ModelSpecifier

extension ModelsDocument {
  public struct Group: Hashable, Sendable, Codable {
    public var members: [Member]
    public var defaultEffort: String
    public var policy: Policy

    public init(members: [Member], defaultEffort: String, policy: Policy) {
      self.members = members
      self.defaultEffort = defaultEffort
      self.policy = policy
    }

    public init(from decoder: any Decoder) throws {
      let fields = try decoder.container(keyedBy: Field.self)
      try fields.requireOnly(["kind", "members", "defaultEffort", "policy"])
      guard try fields.decode(String.self, forKey: Field("kind")) == "group" else {
        throw GroupDeclarationError("kind must be group")
      }
      members = try fields.decode([Member].self, forKey: Field("members"))
      defaultEffort = try fields.decode(String.self, forKey: Field("defaultEffort"))
      policy = try fields.decodeIfPresent(Policy.self, forKey: Field("policy")) ?? .quotaAware
    }

    public func encode(to encoder: any Encoder) throws {
      var fields = encoder.container(keyedBy: Field.self)
      try fields.encode("group", forKey: Field("kind"))
      try fields.encode(members, forKey: Field("members"))
      try fields.encode(defaultEffort, forKey: Field("defaultEffort"))
      try fields.encode(policy, forKey: Field("policy"))
    }
  }

  public struct Member: Hashable, Sendable, Codable {
    public var id: String
    public var provider: String
    public var model: String

    public init(id: String, provider: String, model: String) {
      self.id = id
      self.provider = provider
      self.model = model
    }

    public init(from decoder: any Decoder) throws {
      let fields = try decoder.container(keyedBy: Field.self)
      try fields.requireOnly(["id", "provider", "model"])
      id = try fields.decode(String.self, forKey: Field("id"))
      provider = try fields.decode(String.self, forKey: Field("provider"))
      model = try fields.decode(String.self, forKey: Field("model"))
    }
  }

  public enum Policy: Hashable, Sendable, Codable {
    case quotaAware
    case select(member: String)

    public init(from decoder: any Decoder) throws {
      let fields = try decoder.container(keyedBy: Field.self)
      switch try fields.decode(String.self, forKey: Field("type")) {
      case "quotaAware":
        // holdDownSeconds is accepted and ignored so catalogs written before it lost its meaning still load.
        try fields.requireOnly(["type", "holdDownSeconds"])
        self = .quotaAware
      case "select":
        try fields.requireOnly(["type", "member"])
        self = .select(member: try fields.decode(String.self, forKey: Field("member")))
      default: throw GroupDeclarationError("unsupported group policy")
      }
    }

    public func encode(to encoder: any Encoder) throws {
      var fields = encoder.container(keyedBy: Field.self)
      switch self {
      case .quotaAware:
        try fields.encode("quotaAware", forKey: Field("type"))
      case let .select(member):
        try fields.encode("select", forKey: Field("type"))
        try fields.encode(member, forKey: Field("member"))
      }
    }
  }
}

private struct GroupDeclarationError: Error, CustomStringConvertible {
  var description: String
  init(_ description: String) { self.description = description }
}

private struct Field: CodingKey {
  var stringValue: String
  var intValue: Int? { nil }
  init(_ string: String) { stringValue = string }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}

private extension KeyedDecodingContainer where Key == Field {
  func requireOnly(_ allowed: Set<String>) throws {
    let unknown = Set(allKeys.map(\.stringValue)).subtracting(allowed)
    guard unknown.isEmpty else { throw GroupDeclarationError("unknown field(s): \(unknown.sorted().joined(separator: ", "))") }
  }
}
