import Foundation
import PiAI

public struct WuhuSkill: Sendable, Hashable, Codable, Identifiable {
  public enum Source: String, Sendable, Hashable, Codable {
    case user
    case project
  }

  public var name: String
  public var description: String
  public var filePath: String
  public var source: Source
  public var disableModelInvocation: Bool

  public var id: String { name }

  public init(
    name: String,
    description: String,
    filePath: String,
    source: Source,
    disableModelInvocation: Bool = false,
  ) {
    self.name = name
    self.description = description
    self.filePath = filePath
    self.source = source
    self.disableModelInvocation = disableModelInvocation
  }
}

public extension WuhuSkill {
  func toJSONValue() -> JSONValue {
    .object([
      "name": .string(name),
      "description": .string(description),
      "filePath": .string(filePath),
      "source": .string(source.rawValue),
      "disableModelInvocation": .bool(disableModelInvocation),
    ])
  }

  static func fromJSONValue(_ value: JSONValue) -> WuhuSkill? {
    guard let obj = value.object else { return nil }
    guard let name = obj["name"]?.stringValue else { return nil }
    guard let description = obj["description"]?.stringValue else { return nil }
    guard let filePath = obj["filePath"]?.stringValue else { return nil }
    let sourceRaw = obj["source"]?.stringValue ?? Source.project.rawValue
    let source = Source(rawValue: sourceRaw) ?? .project
    let disable = obj["disableModelInvocation"]?.boolValue ?? false
    return .init(
      name: name,
      description: description,
      filePath: filePath,
      source: source,
      disableModelInvocation: disable,
    )
  }

  static func arrayFromJSONValue(_ value: JSONValue) -> [WuhuSkill] {
    guard let arr = value.array else { return [] }
    return arr.compactMap(WuhuSkill.fromJSONValue)
  }
}

