#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

struct AgentSkill: Equatable, Sendable {
  let name: String
  let markdown: String
}

enum SkillCatalog {
  #if WUHU_EMBEDDED
    static let embedded: [AgentSkill]? = EmbeddedSkills.files
      .filter { $0.path.count == 2 && $0.path[1] == "SKILL.md" }
      .map { AgentSkill(name: $0.path[0], markdown: EmbeddedSkills.text(for: $0)) }
      .sorted { $0.name < $1.name }
  #else
    static let embedded: [AgentSkill]? = nil
  #endif

  static let marker = "<!-- installed by wuhu skill export -->\n"

  static let destinations = [".claude/skills", ".agents/skills"]
}

extension Executor {
  func skillExport() async throws {
    guard let skills = SkillCatalog.embedded, !skills.isEmpty else {
      throw CLIError(message: "no skills embedded in this build; use a Bazel-built wuhu binary")
    }
    guard let home = self.runner.environment["HOME"], !home.isEmpty else {
      throw CLIError(message: "HOME is not set")
    }
    let homeURL = URL(fileURLWithPath: home, isDirectory: true)
    let manager = FileManager.default
    var report = ""
    for destination in SkillCatalog.destinations {
      for skill in skills {
        let directory = homeURL
          .appendingPathComponent(destination, isDirectory: true)
          .appendingPathComponent(skill.name, isDirectory: true)
        let file = directory.appendingPathComponent("SKILL.md")
        let payload = skill.markdown + "\n" + SkillCatalog.marker
        if manager.fileExists(atPath: file.path) {
          let existing = try String(contentsOf: file, encoding: .utf8)
          if existing == payload {
            report += "unchanged \(file.path)\n"
            continue
          }
          guard existing.contains(SkillCatalog.marker) else {
            report += "skipped \(file.path) (not installed by wuhu skill export; remove it to reinstall)\n"
            continue
          }
          try Data(payload.utf8).write(to: file, options: .atomic)
          report += "updated \(file.path)\n"
          continue
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(payload.utf8).write(to: file, options: .atomic)
        report += "wrote \(file.path)\n"
      }
    }
    await self.runner.stdout(report)
  }
}
