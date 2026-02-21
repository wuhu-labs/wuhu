import Foundation
import PiAI

public struct WuhuSkill: Sendable, Hashable, Codable, Identifiable {
  public var name: String
  public var description: String
  public var filePath: String
  public var baseDir: String
  public var source: String
  public var disableModelInvocation: Bool

  public var id: String { name }

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
        let fromMetadata = decodeFromHeaderMetadata(header.metadata)
        if !fromMetadata.isEmpty { return fromMetadata }
        return parseFromSystemPrompt(header.systemPrompt)
      }
    }
    return []
  }

  public static func decodeFromHeaderMetadata(_ metadata: JSONValue) -> [WuhuSkill] {
    guard case let .object(obj) = metadata else { return [] }
    guard let raw = obj[headerMetadataKey], case let .array(arr) = raw else { return [] }

    var skills: [WuhuSkill] = []
    skills.reserveCapacity(arr.count)

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
    lines.reserveCapacity(12 + visibleSkills.count * 8)

    lines.append("")
    lines.append("")
    lines.append("The following skills provide specialized instructions for specific tasks.")
    lines.append("Use the read tool to load a skill's file when the task matches its description.")
    lines.append("When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.")
    lines.append("")
    lines.append("<available_skills>")

    for skill in visibleSkills {
      lines.append("  <skill>")
      lines.append("    <name>\(escapeXml(skill.name))</name>")
      lines.append("    <description>\(escapeXml(skill.description))</description>")
      lines.append("    <location>\(escapeXml(skill.filePath))</location>")
      lines.append("  </skill>")
    }

    lines.append("</available_skills>")
    return lines.joined(separator: "\n")
  }

  private static func parseFromSystemPrompt(_ prompt: String) -> [WuhuSkill] {
    // Best-effort fallback for older sessions; prefers metadata.
    guard let open = prompt.range(of: "<available_skills>"),
          let close = prompt.range(of: "</available_skills>")
    else { return [] }

    let xml = String(prompt[open.upperBound ..< close.lowerBound])
    var skills: [WuhuSkill] = []

    let blocks = xml.components(separatedBy: "<skill>").dropFirst()
    for blockWithRest in blocks {
      guard let endRange = blockWithRest.range(of: "</skill>") else { continue }
      let block = String(blockWithRest[..<endRange.lowerBound])
      guard let name = extractXmlTag(block, tag: "name"),
            let description = extractXmlTag(block, tag: "description"),
            let location = extractXmlTag(block, tag: "location")
      else { continue }

      skills.append(.init(
        name: name,
        description: description,
        filePath: location,
        baseDir: (location as NSString).deletingLastPathComponent,
        source: "unknown",
        disableModelInvocation: false,
      ))
    }

    return skills
  }

  private static func extractXmlTag(_ block: String, tag: String) -> String? {
    guard let open = block.range(of: "<\(tag)>"),
          let close = block.range(of: "</\(tag)>")
    else { return nil }
    let raw = String(block[open.upperBound ..< close.lowerBound])
    return unescapeXml(raw).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func escapeXml(_ str: String) -> String {
    str
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }

  private static func unescapeXml(_ str: String) -> String {
    str
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&apos;", with: "'")
      .replacingOccurrences(of: "&amp;", with: "&")
  }
}

