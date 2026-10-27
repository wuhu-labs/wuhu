import Foundation
import SessionDomain
import struct SpaceContract.GroupID
import struct SpaceContract.PromptSession
import SpaceFS

// One folder's instructions: its AGENTS.md, if any, and the skills under its
// `.agents/skills/`. The system and a session's group root and home each make
// one; each renders as its own part of the system prompt.
public struct InstructionScope: Hashable, Sendable {
  public let sections: [SessionHome.Section]
  public let skills: [SessionHome.Skill]

  public init(sections: [SessionHome.Section], skills: [SessionHome.Skill]) {
    self.sections = sections
    self.skills = skills
  }

  public static let empty: InstructionScope = InstructionScope(sections: [], skills: [])

  /// The sections rendered for `renderer`'s session, then `listing` under
  /// `heading`; nothing when both are empty.
  public func rendered(listing: [SessionHome.Skill], under heading: String, by renderer: InstructionRenderer) async -> [String] {
    var parts: [String] = []
    for section in sections {
      let text = await renderer.render(section.text, path: section.path)
      parts.append("from \(section.path):\n\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    if !listing.isEmpty {
      parts.append(heading + "\n" + listing.map(\.listing).joined(separator: "\n"))
    }
    return parts
  }

  /// What each of `layers` (farthest first) lists for `session`: `wuhu_when`
  /// filters first, then a name a nearer layer lists hides the farther skill.
  public static func listings(_ layers: [InstructionScope], for session: PromptSession) -> [[SessionHome.Skill]] {
    var nearer: Set<String> = []
    return layers.reversed().map { layer in
      let shown = layer.skills.filter { $0.condition.shows(session) && !nearer.contains($0.name) }
      nearer.formUnion(shown.map(\.name))
      return shown
    }.reversed()
  }

  // A skill's one-line description is its frontmatter `description:` when the
  // file has one, else the first non-empty line after the `#` title.
  public static func skillDescription(_ text: String) -> String {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
    if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
      lines = lines.dropFirst()
      while let line = lines.first, line.trimmingCharacters(in: .whitespaces) != "---" {
        lines = lines.dropFirst()
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("description:") {
          return String(trimmed.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
        }
      }
      lines = lines.dropFirst()
    }
    var sawTitle = false
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { continue }
      if trimmed.hasPrefix("#") {
        if sawTitle { break }
        sawTitle = true
        continue
      }
      return trimmed
    }
    return ""
  }
}

public struct SessionHome: Hashable, Sendable {
  public struct Section: Hashable, Sendable {
    public let path: String
    public let text: String

    public init(path: String, text: String) {
      self.path = path
      self.text = text
    }
  }

  public struct Skill: Hashable, Sendable {
    public let name: String
    public let description: String
    public let path: String
    public let condition: SkillCondition

    public init(name: String, markdown: String, path: String) {
      self.name = name
      description = InstructionScope.skillDescription(markdown)
      self.path = path
      condition = SkillCondition(skill: markdown)
    }

    /// Its line in a skills listing.
    public var listing: String {
      guard case let .malformed(message) = condition else { return "- \(name) — \(description) (\(path))" }
      return "- \(name) — \(description) (\(path)) (wuhu_when error: \(message))"
    }
  }

  static let skillsFolder = ".agents/skills"
  public static let hiddenRootEntries: Set<String> = ["_", "users"]

  public static func path(of session: SessionID) -> String { session.homePath }

  /// A session writes only its own home, in its own group.
  public static func refuseForeignWrite(
    to path: SpacePath, in group: GroupID, by session: SessionID, home: GroupID,
  ) throws(SpaceError) {
    if let owner = path.homeOwner, owner != session.rawValue || group != home {
      throw .foreignHome(path: path.rawValue, owner: owner)
    }
  }

  public let path: String
  public let group: GroupID
  /// The group root's scope, hostless.
  public let groupLayer: InstructionScope
  /// The session's own home: the tail of the session part.
  public let home: InstructionScope

  public init(path: String, group: GroupID, groupLayer: InstructionScope, home: InstructionScope) {
    self.path = path
    self.group = group
    self.groupLayer = groupLayer
    self.home = home
  }

  public var sections: [Section] { groupLayer.sections + home.sections }
  public var skills: [Skill] { groupLayer.skills + home.skills }
  public var chain: [String] { sections.map(\.path) }

  /// The skills heading of the group's layer.
  public var groupSkillsHeading: String {
    group == .shared
      ? "Space skills (call read on the path before using one):"
      : "Group skills (call read on the path before using one):"
  }
}

extension Space {
  // No ancestor's home is read: what a parent passes down goes in the brief
  // or a template. With a revision, every scope reads as of it (the frozen
  // prompt); revision 0 is the empty space before its first write.
  public func sessionHome(_ session: SessionID, at rev: Int? = nil) async throws -> SessionHome {
    let group = try await sessions.record(session).group
    let path = SessionHome.path(of: session)
    return SessionHome(
      path: path,
      group: group,
      groupLayer: try await scope(at: "/", in: group, rev: rev),
      home: try await scope(at: path, in: group, rev: rev),
    )
  }

  public func scope(at folder: String, in group: GroupID, rev: Int? = nil) async throws -> InstructionScope {
    if rev == 0 { return .empty }
    return try await InstructionScope.load(folder, in: fs(group, at: rev.map(Rev.init)))
  }
}

extension InstructionScope {
  /// Reads `folder`'s AGENTS.md and `.agents/skills/*/SKILL.md` from `fs`.
  static func load(_ folder: String, in fs: any SpaceVFS) async throws -> InstructionScope {
    let prefix = folder == "/" ? "" : folder
    let agents = "\(prefix)/AGENTS.md"
    let sections = try await fs.textIfPresent(agents).map { [SessionHome.Section(path: agents, text: $0)] } ?? []
    let root = "\(prefix)/\(SessionHome.skillsFolder)"
    var skills: [SessionHome.Skill] = []
    for entry in try await fs.entriesIfPresent(root) where entry.kind == .directory {
      let path = "\(root)/\(entry.name)/SKILL.md"
      guard let text = try await fs.textIfPresent(path) else { continue }
      skills.append(.init(name: entry.name, markdown: text, path: path))
    }
    return InstructionScope(sections: sections, skills: skills)
  }
}

extension SpaceVFS {
  func textIfPresent(_ path: String) async throws -> String? {
    try await dataIfPresent(path).map { String(decoding: $0, as: UTF8.self) }
  }

  func entriesIfPresent(_ path: String) async throws -> [Entry] {
    do {
      return try await list(path).1
    } catch SpaceError.notFound, SpaceError.notADirectory {
      return []
    }
  }
}
