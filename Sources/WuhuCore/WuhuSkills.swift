import Foundation
import WuhuAPI
import Yams

public enum WuhuSkillLoader {
  public static func loadSkills(
    environmentRoot: String,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
  ) -> [WuhuSkill] {
    let userDir = homeDirectory
      .appendingPathComponent(".wuhu", isDirectory: true)
      .appendingPathComponent("skills", isDirectory: true)
    let projectDir = URL(fileURLWithPath: environmentRoot, isDirectory: true)
      .appendingPathComponent(".wuhu", isDirectory: true)
      .appendingPathComponent("skills", isDirectory: true)

    let userSkills = loadSkills(from: userDir, source: .user)
    let projectSkills = loadSkills(from: projectDir, source: .project)

    var byName: [String: WuhuSkill] = [:]
    byName.reserveCapacity(userSkills.count + projectSkills.count)

    // Default precedence: project overrides user on name collision.
    for skill in userSkills {
      byName[skill.name] = skill
    }
    for skill in projectSkills {
      byName[skill.name] = skill
    }

    return byName.values.sorted { $0.name < $1.name }
  }

  private static func loadSkills(from rootDir: URL, source: WuhuSkill.Source) -> [WuhuSkill] {
    guard FileManager.default.fileExists(atPath: rootDir.path) else { return [] }

    var files: [URL] = []
    files.append(contentsOf: directMarkdownChildren(in: rootDir))
    files.append(contentsOf: recursiveSkillMarkdowns(in: rootDir))

    var skills: [WuhuSkill] = []
    skills.reserveCapacity(files.count)
    for file in files {
      if let skill = parseSkillFile(file, source: source) {
        skills.append(skill)
      }
    }

    return skills
  }

  private static func directMarkdownChildren(in dir: URL) -> [URL] {
    guard let children = try? FileManager.default.contentsOfDirectory(
      at: dir,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles],
    ) else { return [] }

    return children.compactMap { url in
      guard url.pathExtension.lowercased() == "md" else { return nil }
      guard url.lastPathComponent != "SKILL.md" else { return nil }
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
      return url
    }
  }

  private static func recursiveSkillMarkdowns(in dir: URL) -> [URL] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
      at: dir,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
      options: [.skipsHiddenFiles],
    ) else { return [] }

    var result: [URL] = []
    for case let url as URL in enumerator {
      if url.lastPathComponent == "node_modules" {
        enumerator.skipDescendants()
        continue
      }

      if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        continue
      }

      guard url.lastPathComponent == "SKILL.md" else { continue }
      result.append(url)
    }
    return result
  }

  private static func parseSkillFile(_ file: URL, source: WuhuSkill.Source) -> WuhuSkill? {
    guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }

    let frontmatter = parseYAMLFrontmatter(raw) ?? [:]

    let description: String? = {
      let v = frontmatter["description"]
      if let s = v as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
      return nil
    }()
    guard let description, !description.isEmpty else { return nil }

    let name: String = {
      if let s = frontmatter["name"] as? String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
      }

      if file.lastPathComponent == "SKILL.md" {
        return file.deletingLastPathComponent().lastPathComponent
      }

      return file.deletingPathExtension().lastPathComponent
    }()

    let disableModelInvocation: Bool = {
      if let b = frontmatter["disable-model-invocation"] as? Bool { return b }
      if let b = frontmatter["disableModelInvocation"] as? Bool { return b }
      return false
    }()

    return .init(
      name: name,
      description: description,
      filePath: file.path,
      source: source,
      disableModelInvocation: disableModelInvocation,
    )
  }

  private static func parseYAMLFrontmatter(_ markdown: String) -> [String: Any]? {
    let normalized = markdown
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")

    var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
    guard let firstLine = lines.first,
          String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines) == "---"
    else {
      return nil
    }

    lines.removeFirst()
    guard let endIndex = lines.firstIndex(where: { String($0).trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) else {
      return nil
    }

    let yaml = lines[..<endIndex].joined(separator: "\n")
    if yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return [:]
    }

    do {
      let loaded = try Yams.load(yaml: yaml)
      if let dict = loaded as? [String: Any] { return dict }
      if let dict = loaded as? [AnyHashable: Any] {
        var out: [String: Any] = [:]
        out.reserveCapacity(dict.count)
        for (k, v) in dict {
          if let key = k as? String {
            out[key] = v
          }
        }
        return out
      }
      return nil
    } catch {
      return nil
    }
  }
}

public enum WuhuSkillsPromptFormatter {
  public static func formatForSystemPrompt(_ skills: [WuhuSkill]) -> String {
    let visible = skills.filter { !$0.disableModelInvocation }
    guard !visible.isEmpty else { return "" }

    var lines: [String] = []
    lines.append("")
    lines.append("")
    lines.append("The following skills provide specialized instructions for specific tasks.")
    lines.append("Use the read tool to load a skill's file when the task matches its description.")
    lines.append("When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.")
    lines.append("")
    lines.append("<available_skills>")
    for skill in visible {
      lines.append("  <skill>")
      lines.append("    <name>\(escapeXML(skill.name))</name>")
      lines.append("    <description>\(escapeXML(skill.description))</description>")
      lines.append("    <location>\(escapeXML(skill.filePath))</location>")
      lines.append("  </skill>")
    }
    lines.append("</available_skills>")
    return lines.joined(separator: "\n")
  }

  private static func escapeXML(_ s: String) -> String {
    s
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }
}
