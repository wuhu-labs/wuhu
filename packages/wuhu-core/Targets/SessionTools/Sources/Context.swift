import struct MachineContract.MachineID
import enum MachineContract.VFSOp
import SessionDomain
import SpaceCore
import SpaceFS
import SystemFiles

extension ToolExecutor {
  func deliverContext(
    _ session: SessionID,
    _ callID: ToolCallID,
    touching address: Address,
    state: ToolExecutionState,
  ) async throws {
    guard case let .machine(machine, folder) = address,
          let folders = await newFolders(machine, down: folder, recorded: state.folderRoots)
    else { return }
    var sections: [String] = []
    if !state.folderRoots.keys.contains(where: { $0.hasPrefix(Address.machine(machine, "/").rendered) }),
       let notes = try? await machineNotes(machine, for: session)
    {
      sections += notes.sections.map { agentsSection(from: $0.path, $0.text) }
      sections += [skillsListing(notes.skills.map { ($0.name, $0.description, $0.path) })].compactMap(\.self)
    }
    for (directory, root) in folders where root != nil {
      sections += await instructions(in: .machine(machine, directory))
    }
    let context = ScopeContext(
      folders: Dictionary(uniqueKeysWithValues: folders.map { directory, root in
        (Address.machine(machine, directory).rendered, root.map { Address.machine(machine, $0).rendered })
      }),
      text: sections.joined(separator: "\n\n"),
    )
    try await store.recordScopeContext(session, toolCallID: callID, context: context)
  }

  // The notes live in the machine's group; outside the session's group they
  // are named in full, the form that resolves for it.
  private func machineNotes(_ machine: MachineID, for session: SessionID) async throws -> InstructionScope {
    let group = try await space.machineGroup(machine)
    let notes = try await space.scope(at: "/_/machines/\(machine.rawValue)", in: group)
    return try await space.principal(of: session).group == group ? notes : notes.qualified(inGroup: group)
  }

  private func newFolders(
    _ machine: MachineID,
    down folder: String,
    recorded: [String: String?],
  ) async -> [(folder: String, root: String?)]? {
    func key(_ path: String) -> String { Address.machine(machine, path).rendered }
    func path(_ key: String) -> String { String(key.dropFirst("machines://\(machine.rawValue)".count)) }
    let below = folder == "/" ? key("/") : key(folder) + "/"
    guard recorded[key(folder)] == nil, !recorded.keys.contains(where: { $0.hasPrefix(below) }) else { return nil }
    var upward = [folder]
    var cursor = folder
    while let up = parent(of: cursor) {
      if let root = recorded[key(up)] {
        return await descending(machine, upward.reversed(), under: root.map(path))
      }
      upward.append(up)
      cursor = up
    }
    for index in upward.indices {
      guard await hasGit(machine, upward[index]) else { continue }
      return upward[...index].reversed().map { ($0, upward[index]) }
    }
    return upward.reversed().map { ($0, nil) }
  }

  private func descending(
    _ machine: MachineID,
    _ fresh: some Sequence<String>,
    under inherited: String?,
  ) async -> [(folder: String, root: String?)] {
    var root = inherited
    var folders: [(folder: String, root: String?)] = []
    for directory in fresh {
      if root == nil, await hasGit(machine, directory) { root = directory }
      folders.append((directory, root))
    }
    return folders
  }

  private func hasGit(_ machine: MachineID, _ directory: String) async -> Bool {
    (try? await machineStat(machine, path: joined(directory, ".git"))) != nil
  }

  private func instructions(in folder: Address) async -> [String] {
    var sections: [String] = []
    let agents = folder.appending("AGENTS.md")
    if let text = await readIfPresent(agents) {
      sections.append(agentsSection(from: agents.rendered, text))
    }
    if let skills = await skillsIndex(in: folder) {
      sections.append(skills)
    }
    return sections
  }

  private func skillsIndex(in folder: Address) async -> String? {
    guard let names = await directoryNames(in: folder.appending(skillsDirectory)) else { return nil }
    var skills: [(name: String, description: String, path: String)] = []
    for name in names.sorted() {
      let skill = folder.appending("\(skillsDirectory)/\(name)/SKILL.md")
      guard let markdown = await readIfPresent(skill) else { continue }
      let front = frontmatter(of: markdown)
      skills.append((front["name"] ?? name, front["description"] ?? "", skill.rendered))
    }
    return skillsListing(skills)
  }

  private func agentsSection(from path: String, _ text: String) -> String {
    "<AGENTS.md from=\"\(path)\">\n\(capped(text))\n</AGENTS.md>"
  }

  private func skillsListing(_ skills: [(name: String, description: String, path: String)]) -> String? {
    guard !skills.isEmpty else { return nil }
    let lines = skills.map { "- \($0.name)\($0.description.isEmpty ? "" : " — \($0.description)") (\($0.path))" }
    return "skills (read the path before using one):\n" + lines.joined(separator: "\n")
  }

  private func readIfPresent(_ address: Address) async -> String? {
    try? await readFile(address).1
  }

  private func directoryNames(in directory: Address) async -> [String]? {
    switch directory {
    case let .space(path, group, _):
      guard let (_, entries) = try? await space.fs(group).list(path) else { return nil }
      return entries.filter { $0.kind == .directory }.map(\.name)
    case let .machine(machine, path):
      guard case let .entries(entries) = try? await machineVFS(machine, .ls(path: path)) else { return nil }
      return entries.filter { $0.kind == .directory }.map(\.name)
    case let .system(path):
      guard let (_, entries) = try? await SystemFiles.vfs.list(path) else { return nil }
      return entries.filter { $0.kind == .directory }.map(\.name)
    }
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
