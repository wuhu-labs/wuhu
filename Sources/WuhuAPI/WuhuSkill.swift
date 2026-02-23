import Foundation
import PiAI

public struct WuhuSkill: Sendable, Hashable, Codable, Identifiable {
  public var name: String
  public var description: String
  public var filePath: String
  public var baseDir: String
  public var source: String
  public var disableModelInvocation: Bool

  public var id: String {
    name
  }

  public init(
    name: String,
    description: String,
    filePath: String,
    baseDir: String,
    source: String,
    disableModelInvocation: Bool = false,
  ) {
    self.name = name
    self.description = description
    self.filePath = filePath
    self.baseDir = baseDir
    self.source = source
    self.disableModelInvocation = disableModelInvocation
  }
}

public enum WuhuSkills {
  public static let headerMetadataKey = "skills"

  public static func extract(from entries: [WuhuSessionEntry]) -> [WuhuSkill] {
    for entry in entries {
      if case let .header(header) = entry.payload {
        return decodeFromHeaderMetadata(header.metadata)
      }
    }
    return []
  }

  public static func decodeFromHeaderMetadata(_ metadata: JSONValue) -> [WuhuSkill] {
    guard case let .object(obj) = metadata else { return [] }
    guard let raw = obj[headerMetadataKey], case let .array(arr) = raw else { return [] }

    var skills: [WuhuSkill] = []

    for item in arr {
      guard case let .object(o) = item else { continue }
      guard let name = o["name"]?.stringValue,
            let description = o["description"]?.stringValue,
            let filePath = o["filePath"]?.stringValue,
            let baseDir = o["baseDir"]?.stringValue,
            let source = o["source"]?.stringValue
      else { continue }

      let disableModelInvocation = o["disableModelInvocation"]?.boolValue ?? false
      skills.append(.init(
        name: name,
        description: description,
        filePath: filePath,
        baseDir: baseDir,
        source: source,
        disableModelInvocation: disableModelInvocation,
      ))
    }
    return skills
  }

  public static func encodeForHeaderMetadata(_ skills: [WuhuSkill]) -> JSONValue {
    .array(skills.map { skill in
      .object([
        "name": .string(skill.name),
        "description": .string(skill.description),
        "filePath": .string(skill.filePath),
        "baseDir": .string(skill.baseDir),
        "source": .string(skill.source),
        "disableModelInvocation": .bool(skill.disableModelInvocation),
      ])
    })
  }

  public static func promptSection(skills: [WuhuSkill]) -> String {
    let visibleSkills = skills.filter { !$0.disableModelInvocation }
    guard !visibleSkills.isEmpty else { return "" }

    var lines: [String] = []

    lines.append("")
    lines.append("")
    lines.append("The following skills provide specialized instructions for specific tasks.")
    lines.append("Use the read tool to load a skill's file when the task matches its description.")
    lines.append("When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.")
    lines.append("")
    lines.append("<available_skills>")

    for skill in visibleSkills {
      lines.append("  <skill>")
      lines.append("    <name>\(skill.name)</name>")
      lines.append("    <description>\(skill.description)</description>")
      lines.append("    <location>\(skill.filePath)</location>")
      lines.append("  </skill>")
    }

    lines.append("</available_skills>")
    return lines.joined(separator: "\n")
  }
}
