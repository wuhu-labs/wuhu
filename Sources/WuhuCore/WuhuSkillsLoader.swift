import Foundation
import WuhuAPI

enum WuhuSkillsLoader {
  static func load(environmentRoot: String) -> [WuhuSkill] {
    let fm = FileManager.default
    let homeSkillsDir = fm.homeDirectoryForCurrentUser
      .appendingPathComponent(".wuhu")
      .appendingPathComponent("skills")
      .path

    let projectSkillsDir = URL(fileURLWithPath: environmentRoot, isDirectory: true)
      .appendingPathComponent(".wuhu")
      .appendingPathComponent("skills")
      .path

    return load(userSkillsDir: homeSkillsDir, projectSkillsDir: projectSkillsDir)
  }

  static func load(userSkillsDir: String, projectSkillsDir: String) -> [WuhuSkill] {
    var byName: [String: WuhuSkill] = [:]

    for skill in loadFromDir(userSkillsDir, source: "user") {
      byName[skill.name] = skill
    }
    for skill in loadFromDir(projectSkillsDir, source: "project") {
      byName[skill.name] = skill
    }

    return byName.values.sorted { $0.name < $1.name }
  }

  private static func loadFromDir(_ dir: String, source: String) -> [WuhuSkill] {
    let fm = FileManager.default

    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return [] }

    var out: [WuhuSkill] = []
    scanForSkills(in: URL(fileURLWithPath: dir, isDirectory: true), source: source, out: &out)
    return out
  }

  private static func scanForSkills(in dir: URL, source: String, out: inout [WuhuSkill]) {
    let fm = FileManager.default
    let candidate = dir.appendingPathComponent("SKILL.md")
    if fm.fileExists(atPath: candidate.path) {
      if let skill = loadSkillFromFile(candidate.path, source: source) {
        out.append(skill)
      }
    }

    let children: [URL]
    do {
      children = try fm.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
        options: [.skipsHiddenFiles],
      )
    } catch {
      return
    }

    for child in children {
      let name = child.lastPathComponent
      if name == "node_modules" { continue }
      if name.hasPrefix(".") { continue }
      if child.path == candidate.path { continue }

      let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
      if values?.isDirectory == true {
        scanForSkills(in: child, source: source, out: &out)
      }
    }
  }

  private struct SkillFrontmatter: Sendable, Hashable {
    var name: String?
    var description: String?
    var disableModelInvocation: Bool
  }

  private static func loadSkillFromFile(_ filePath: String, source: String) -> WuhuSkill? {
    guard let raw = try? String(contentsOfFile: filePath, encoding: .utf8) else { return nil }
    let frontmatter = parseFrontmatter(raw)

    let description = (frontmatter.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !description.isEmpty else { return nil }

    let baseDir = (filePath as NSString).deletingLastPathComponent
    let parentDirName = (baseDir as NSString).lastPathComponent

    let name = {
      let candidate = (frontmatter.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if !candidate.isEmpty { return candidate }
      return parentDirName
    }()

    return WuhuSkill(
      name: name,
      description: description,
      filePath: filePath,
      baseDir: baseDir,
      source: source,
      disableModelInvocation: frontmatter.disableModelInvocation,
    )
  }

  private static func parseFrontmatter(_ raw: String) -> SkillFrontmatter {
    var lines = raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    guard let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
      return .init(name: nil, description: nil, disableModelInvocation: false)
    }
    lines.removeFirst()

    var fmLines: [Substring] = []
    while let line = lines.first {
      lines.removeFirst()
      if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" { break }
      fmLines.append(line)
    }

    var name: String?
    var description: String?
    var disableModelInvocation = false

    var i = 0
    while i < fmLines.count {
      let line = String(fmLines[i])
      i += 1

      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      if trimmed.hasPrefix("#") { continue }

      guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
      let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
      var value = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)

      if value == "|" || value == "|-" {
        var block: [String] = []
        while i < fmLines.count {
          let next = String(fmLines[i])
          if next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            block.append("")
            i += 1
            continue
          }
          if next.hasPrefix(" ") || next.hasPrefix("\t") {
            block.append(next.trimmingCharacters(in: .whitespacesAndNewlines))
            i += 1
            continue
          }
          break
        }
        value = block.joined(separator: "\n")
      } else if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2) ||
        (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2)
      {
        value = String(value.dropFirst().dropLast())
      }

      switch key {
      case "name":
        name = value
      case "description":
        description = value
      case "disable-model-invocation":
        let v = value.lowercased()
        disableModelInvocation = (v == "true" || v == "yes" || v == "1")
      default:
        continue
      }
    }

    return .init(name: name, description: description, disableModelInvocation: disableModelInvocation)
  }
}
