import Foundation
import SessionDomain
import struct SpaceContract.GroupID
import SpaceFS

// One folder's instructions: its AGENTS.md, if any, and the skills under its
// `.agents/skills/`. The system, the space root and a session's home each
// make one, as do the space-wide and group layers; each renders as its own
// part of the system prompt.
public struct InstructionScope: Hashable, Sendable {
  public let sections: [SessionHome.Section]
  public let skills: [SessionHome.Skill]

  public init(sections: [SessionHome.Section], skills: [SessionHome.Skill]) {
    self.sections = sections
    self.skills = skills
  }

  public static let empty: InstructionScope = InstructionScope(sections: [], skills: [])

  /// The same scope with every path written in full for `group`.
  public func qualified(inGroup group: GroupID) -> InstructionScope {
    let address = { (path: String) in FSResolver.address(path, inGroup: group.rawValue) }
    return InstructionScope(
      sections: sections.map { .init(path: address($0.path), text: $0.text) },
      skills: skills.map { .init(name: $0.name, description: $0.description, path: address($0.path)) },
    )
  }

  /// The sections, then the skills list under `skillsHeading`; nothing when
  /// the scope is empty.
  public func rendered(skillsHeading: String) -> [String] {
    var parts = sections.map { section in
      "from \(section.path):\n\n\(section.text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
    if !skills.isEmpty {
      let lines = skills.map { "- \($0.name) — \($0.description) (\($0.path))" }
      parts.append(skillsHeading + "\n" + lines.joined(separator: "\n"))
    }
    return parts
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

    public init(name: String, description: String, path: String) {
      self.name = name
      self.description = description
      self.path = path
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
  /// `shared`'s AGENTS.md and skills, with full `wuhu://shared.localspace/`
  /// paths, for a session outside `shared` whose group keeps the space-wide
  /// layer; empty otherwise.
  public let spaceLayer: InstructionScope
  /// The group root's scope, hostless. In `shared` it is the space-wide layer.
  public let groupLayer: InstructionScope
  /// The session's own home: the tail of the session part.
  public let home: InstructionScope

  init(path: String, group: GroupID, spaceLayer: InstructionScope, groupLayer: InstructionScope, home: InstructionScope) {
    self.path = path
    self.group = group
    self.spaceLayer = spaceLayer
    self.groupLayer = groupLayer
    self.home = home
  }

  public var sections: [Section] { spaceLayer.sections + groupLayer.sections + home.sections }
  public var skills: [Skill] { spaceLayer.skills + groupLayer.skills + home.skills }
  public var chain: [String] { sections.map(\.path) }

  /// The space-wide layer's part of the prompt; empty in `shared`, in a group
  /// that opted out, and when `shared` has neither AGENTS.md nor skills.
  public var spaceLayerRendered: String {
    let parts = spaceLayer.rendered(
      skillsHeading: "Space-wide skills (call read on the full path before using one):",
    )
    guard !parts.isEmpty else { return "" }
    return (["The space-wide layer: `shared`'s AGENTS.md and skills, which apply across groups."] + parts)
      .joined(separator: "\n\n")
  }

  /// The group's AGENTS.md and skills; empty in a group that has neither.
  public var groupRendered: String {
    groupLayer.rendered(
      skillsHeading: group == .shared
        ? "Space skills (call read on the path before using one):"
        : "Group skills (call read on the path before using one):",
    )
    .joined(separator: "\n\n")
  }

  /// The home paragraph, the home AGENTS.md and the home skills: the end of
  /// the session part of the prompt.
  public var rendered: String {
    let order = if group == .shared {
      "the system, the space root, then yours"
    } else if spaceLayer == .empty {
      "the system, your group's root, then yours"
    } else {
      "the system, the space-wide layer, your group's root, then yours"
    }
    let paragraph = """
    Your home in the space is \(path)/. Keep your AGENTS.md (standing instructions) and any \
    notes you want to survive compaction there; a skill of yours is \(path)/\(Self.skillsFolder)/<name>/SKILL.md. \
    Instructions resolve top-down — \(order); nothing comes from the session that \
    created you. This prompt renders the space's files and your home's as of when this session started, and again \
    after each compaction or Start over: an edit in between, yours included, reaches it only then.
    """
    return ([paragraph] + home.rendered(skillsHeading: "Your skills (call read on the path before using one):"))
      .joined(separator: "\n\n")
  }
}

extension Space {
  // No ancestor's home is read: what a parent passes down goes in the brief
  // or a template. With a revision, every scope reads as of it (the frozen
  // prompt); revision 0 is the empty space before its first write. Whether
  // the group keeps the space-wide layer is frozen with the revision too.
  public func sessionHome(_ session: SessionID, at rev: Int? = nil) async throws -> SessionHome {
    let group = try await sessions.record(session).group
    let path = SessionHome.path(of: session)
    let frozen = rev == nil ? nil : try await sessions.promptSpaceLayer(session)
    let keepsSpaceLayer = if let frozen { frozen } else { try await spaceLayer(of: group) }
    let spaceLayer: InstructionScope = if group != .shared, keepsSpaceLayer {
      try await scope(at: "/", in: .shared, rev: rev).qualified(inGroup: .shared)
    } else {
      .empty
    }
    return SessionHome(
      path: path,
      group: group,
      spaceLayer: spaceLayer,
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
      skills.append(.init(name: entry.name, description: skillDescription(text), path: path))
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
