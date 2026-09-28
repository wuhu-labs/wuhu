#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SpaceCore
import SpaceFS

/// The files compiled into this binary and addressed as `wuhu://system/…`:
/// the system AGENTS.md and the system skills. They are identical for every
/// session and every space on the same binary, never materialized into a
/// space, and read-only.
public enum SystemFiles {
  public static let origin: String = "wuhu://system"

  /// `/skills/monitor/SKILL.md` → `wuhu://system/skills/monitor/SKILL.md`.
  public static func address(_ path: String) -> String {
    origin + path
  }

  /// Every embedded file by its path under `wuhu://system`, `/AGENTS.md` and
  /// `/skills/<name>/…`. Empty in a SwiftPM build, which embeds nothing.
  static let files: [String: Data] = embedded

  public static let vfs: any SpaceVFS = SystemVFS(files: files)

  /// Part 2 of the system prompt, as one scope: the system AGENTS.md and the
  /// system skills, with their `wuhu://system/` addresses.
  public static let instructions: InstructionScope = {
    let sections = files["/AGENTS.md"].map {
      [SessionHome.Section(path: address("/AGENTS.md"), text: String(decoding: $0, as: UTF8.self))]
    } ?? []
    let skills = files.keys
      .compactMap { path -> (name: String, path: String)? in
        let components = path.split(separator: "/")
        guard components.count == 3, components[0] == "skills", components[2] == "SKILL.md" else { return nil }
        return (String(components[1]), path)
      }
      .sorted { $0.name < $1.name }
      .map { skill in
        SessionHome.Skill(
          name: skill.name,
          description: InstructionScope.skillDescription(String(decoding: files[skill.path]!, as: UTF8.self)),
          path: address(skill.path),
        )
      }
    return InstructionScope(sections: sections, skills: skills)
  }()

  static let skillsHeading: String = """
  System skills (call read on the path before using one). A skill with the same name in the space, a machine, \
  a repository or your home replaces the system one:
  """

  /// Part 2 of the system prompt.
  public static let rendered: String = instructions.rendered(skillsHeading: skillsHeading)
    .joined(separator: "\n\n")

  #if WUHU_EMBEDDED
    private static let embedded: [String: Data] = Dictionary(
      uniqueKeysWithValues: EmbeddedSystemFiles.files.map { file in
        ("/" + file.path.joined(separator: "/"), Data(EmbeddedSystemFiles.bytes(for: file)))
      },
    )
  #else
    private static let embedded: [String: Data] = [:]
  #endif
}

/// A read-only file system over the embedded files. Directories exist exactly
/// where some file lies below them; every mutation is refused.
struct SystemVFS: SpaceVFS {
  static let token: VersionToken = VersionToken(Data("system".utf8))

  private let files: [String: Data]
  private let directories: [String: Set<String>]

  init(files: [String: Data]) {
    self.files = files
    var directories: [String: Set<String>] = ["/": []]
    for path in files.keys {
      var components = path.split(separator: "/").map(String.init)
      while let name = components.popLast() {
        let parent = "/" + components.joined(separator: "/")
        directories[parent, default: []].insert(name)
      }
    }
    self.directories = directories
  }

  func read(_ path: String) async throws -> (VersionToken, Data) {
    let path = try Self.validated(path)
    guard let data = files[path] else {
      throw directories[path] == nil ? SpaceError.notFound(SystemFiles.address(path)) : SpaceError.notAFile(SystemFiles.address(path))
    }
    return (Self.token, data)
  }

  func write(_ path: String, _: Data, ifMatch _: VersionToken?) async throws -> VersionToken {
    throw SpaceError.systemReadOnly(SystemFiles.address(path))
  }

  func delete(_ path: String, ifMatch _: VersionToken?) async throws {
    throw SpaceError.systemReadOnly(SystemFiles.address(path))
  }

  func move(_ path: String, to _: String) async throws {
    throw SpaceError.systemReadOnly(SystemFiles.address(path))
  }

  func list(_ path: String) async throws -> (VersionToken, [Entry]) {
    let path = try Self.validated(path)
    guard let names = directories[path] else {
      throw files[path] == nil ? SpaceError.notFound(SystemFiles.address(path)) : SpaceError.notADirectory(SystemFiles.address(path))
    }
    let prefix = path == "/" ? "" : path
    return (Self.token, names.sorted().map { entry(prefix + "/" + $0) })
  }

  func stat(_ path: String) async throws -> Entry {
    let path = try Self.validated(path)
    guard files[path] != nil || directories[path] != nil else {
      throw SpaceError.notFound(SystemFiles.address(path))
    }
    return entry(path)
  }

  private func entry(_ path: String) -> Entry {
    let name = path.split(separator: "/").last.map(String.init) ?? "/"
    let epoch = Date(timeIntervalSince1970: 0)
    guard let data = files[path] else {
      return Entry(name: name, kind: .directory, size: 0, lineCount: nil, token: Self.token, mtime: epoch)
    }
    let lines = data.isEmpty ? 0 : data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).count
    return Entry(name: name, kind: .file, size: data.count, lineCount: lines, token: Self.token, mtime: epoch)
  }

  private static func validated(_ path: String) throws -> String {
    try SpacePath(validating: path).rawValue
  }
}
