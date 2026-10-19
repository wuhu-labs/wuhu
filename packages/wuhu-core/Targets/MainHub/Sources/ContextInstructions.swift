import Crypto
import SpaceCore

struct ContextInstructions {
  enum SkillStyle {
    case machineNotes, repository
  }

  var read: @Sendable (Address) async -> String?
  var names: @Sendable (Address) async -> [String]?

  func load(_ folder: Address, style: SkillStyle, delivery: inout ContextDelivery) async -> [String] {
    var sections: [String] = []
    let agents = folder.appending("AGENTS.md")
    if let text = await read(agents) {
      if let first = delivery.firstSource(of: text, kind: .fullText, from: agents.rendered) {
        sections.append("\(agents.rendered) is identical to \(first) (loaded earlier)")
      } else {
        sections.append(agentsSection(from: agents.rendered, text))
      }
    }
    if let skills = await skillsIndex(in: folder, style: style, delivery: &delivery) {
      sections.append(skills)
    }
    return sections
  }

  private func skillsIndex(in folder: Address, style: SkillStyle, delivery: inout ContextDelivery) async -> String? {
    guard let names = await names(folder.appending(skillsDirectory)) else { return nil }
    var skills: [String] = []
    for name in names.sorted() {
      let skill = folder.appending("\(skillsDirectory)/\(name)/SKILL.md")
      guard let markdown = await read(skill) else { continue }
      let descriptor: (name: String, description: String)
      switch style {
      case .machineNotes:
        descriptor = (name, InstructionScope.skillDescription(markdown))
      case .repository:
        let front = frontmatter(of: markdown)
        descriptor = (front["name"] ?? name, front["description"] ?? "")
      }
      if let first = delivery.firstSource(of: markdown, kind: .skillListing, from: skill.rendered) {
        skills.append(skillLine(descriptor.name, "identical to \(first) (loaded earlier)", skill.rendered))
      } else {
        skills.append(skillLine(descriptor.name, descriptor.description, skill.rendered))
      }
    }
    return skillsListing(skills)
  }

  private func agentsSection(from path: String, _ text: String) -> String {
    "<AGENTS.md from=\"\(path)\">\n\(capped(text))\n</AGENTS.md>"
  }

  private func skillLine(_ name: String, _ description: String, _ path: String) -> String {
    "- \(name)\(description.isEmpty ? "" : " — " + description) (\(path))"
  }

  private func skillsListing(_ lines: [String]) -> String? {
    guard !lines.isEmpty else { return nil }
    return "skills (read the path before using one):\n" + lines.joined(separator: "\n")
  }

  private func capped(_ content: String) -> String {
    guard content.utf8.count > instructionsByteCap else { return content }
    var prefix = String(decoding: content.utf8.prefix(instructionsByteCap), as: UTF8.self)
    if prefix.utf8.count > instructionsByteCap {
      prefix = String(prefix.dropLast())
    }
    return prefix + "\n(AGENTS.md truncated at 32KiB)"
  }
}

private func frontmatter(of markdown: String) -> [String: String] {
  var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)[...]
  guard lines.first == "---" else { return [:] }
  lines = lines.dropFirst()
  var fields: [String: String] = [:]
  while let line = lines.first, line != "---" {
    lines = lines.dropFirst()
    guard let colon = line.firstIndex(of: ":") else { continue }
    let key = line[..<colon].trimmingCharacters(in: .whitespaces)
    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty, !value.isEmpty else { continue }
    fields[key] = value
  }
  return fields
}

private let skillsDirectory = ".agents/skills"
private let instructionsByteCap = 32 * 1024

struct ContextDelivery {
  enum Kind: String {
    case fullText, skillListing
  }

  var alreadyLoaded: [String: String]
  var delivered: [String: String] = [:]

  mutating func firstSource(of text: String, kind: Kind, from path: String) -> String? {
    let digest = SHA256.hash(data: Array(text.utf8)).map { String(format: "%02x", $0) }.joined()
    let hash = kind.rawValue + ":" + digest
    if let first = alreadyLoaded[hash] {
      return first
    }
    alreadyLoaded[hash] = path
    delivered[hash] = path
    return nil
  }
}
