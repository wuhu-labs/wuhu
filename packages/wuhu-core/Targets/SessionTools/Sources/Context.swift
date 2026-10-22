import Crypto
import struct Fetch.Method
import JSONValue
import struct MachineContract.MachineID
import struct MachineContract.MachineStatus
import enum MainHub.Address
import enum MainHub.Addressing
import enum MainHub.RosterTool
import SessionDomain
import SpaceClient
import struct SpaceContract.GroupID
import struct SpaceContract.ListOutput
import struct SpaceContract.ReadOutput
import struct SpaceCore.InstructionScope
import struct WuhuAI.ToolArguments
import struct WuhuAI.ToolCall

// A tool call that touches a machine folder the session has not seen yet is
// followed by that folder's instructions: the machine's notes the first time
// the machine is touched, and the AGENTS.md and skills of every repository
// folder from the git root down. The files are read through main's API as the
// session, so they are the files the session itself may read.
extension ToolExecutor {
  /// `call` with its machine named by id, and the machine folder it touches
  /// (nil when it touches none). The roster is read once, here: the operation
  /// and the context that follows it address the same box even if it is
  /// renamed or its name reassigned while the call runs. A name no machine
  /// carries is left for main to refuse.
  func resolvingMachine(_ session: SessionID, _ tool: RosterTool, _ call: ToolCall) async -> (call: ToolCall, touched: Address?) {
    guard case var .object(fields) = call.arguments.json else { return (call, nil) }
    let field: String
    let raw: String?
    switch tool {
    case .read, .write, .edit, .grep, .find: (field, raw) = ("path", fields["path"]?.stringValue)
    case .generateImage: (field, raw) = ("destination", fields["destination"]?.stringValue)
    case .exec:
      guard let machine = fields["machine"]?.stringValue, let cwd = fields["cwd"]?.stringValue else { return (call, nil) }
      (field, raw) = ("machine", "machines://\(machine)\(cwd)")
    default: return (call, nil)
    }
    guard let raw, let host = Addressing.machineHost(raw), let machine = await machineID(host, as: session) else { return (call, nil) }
    let rest = String(raw.dropFirst("machines://".count + host.count))
    guard let path = try? Addressing.normalize(rest.isEmpty ? "/" : rest) else { return (call, nil) }
    var resolved = call
    if host != machine.rawValue {
      fields[field] = .string(field == "machine" ? machine.rawValue : "machines://\(machine.rawValue)\(rest)")
      resolved = ToolCall(id: call.id, name: call.name, arguments: ToolArguments(.object(fields)))
    }
    let address = Address.machine(machine, path)
    switch tool {
    case .read, .write, .edit, .generateImage: return (resolved, address.folder)
    default: return (resolved, address)
    }
  }

  /// The machines the session may use, as main lists them.
  func machines(as session: SessionID) async throws -> [MachineStatus] {
    try await client(session).api(.get, "/v1/machine")
  }

  /// The usable machine `reference` names: its id, or the name a human gave the box.
  func machine(_ reference: String, as session: SessionID) async throws -> MachineStatus? {
    do { return try await client(session).api(.get, "/v1/machine/" + pathSegment(reference) + "/status") }
    catch let error as SpaceClient.ToolFailure where error.error.code == .notFound { return nil }
  }

  // A machines:// host is the id or the name a human gave the box.
  func machineID(_ host: String, as session: SessionID) async -> MachineID? {
    if MachineID.isValid(host) { return MachineID(rawValue: host) }
    return try? await machine(host, as: session)?.id
  }

  func deliverContext(_ session: SessionID, touching address: Address?, state: ToolExecutionState) async -> ScopeContext? {
    guard case let .machine(machine, folder)? = address, let main = try? await client(session) else { return nil }
    let files = ContextFiles(main: main)
    guard let folders = await files.newFolders(machine, down: folder, recorded: state.folderRoots) else { return nil }
    var delivery = ContextDelivery(alreadyLoaded: state.deliveredContext)
    var sections: [String] = []
    let instructions = ContextInstructions(read: { await files.readIfPresent($0) }, names: { await files.directoryNames(in: $0) })
    if !state.folderRoots.keys.contains(where: { $0.hasPrefix(Address.machine(machine, "/").rendered) }),
       let notes = await files.machineNotes(machine)
    {
      sections += await instructions.load(notes, style: .machineNotes, delivery: &delivery)
    }
    for (directory, root) in folders where root != nil {
      sections += await instructions.load(.machine(machine, directory), style: .repository, delivery: &delivery)
    }
    return ScopeContext(
      folders: Dictionary(uniqueKeysWithValues: folders.map { directory, root in
        (Address.machine(machine, directory).rendered, root.map { Address.machine(machine, $0).rendered })
      }),
      deliveredContext: delivery.delivered.isEmpty ? nil : delivery.delivered,
      text: sections.joined(separator: "\n\n"),
    )
  }
}

struct DiscoveryContext: Decodable {
  var group: GroupID
}

private struct ContextFiles: Sendable {
  let main: SpaceClient

  /// The machine's notes, named from the session's group.
  func machineNotes(_ machine: MachineID) async -> Address? {
    guard let machines: [MachineStatus] = try? await main.api(.get, "/v1/machine"),
          let group = machines.first(where: { $0.id == machine }).map({ GroupID(rawValue: $0.group) }),
          let context: DiscoveryContext = try? await main.api(.get, "/v1/context")
    else { return nil }
    return .space("/_/machines/\(machine.rawValue)", in: group == context.group ? nil : group)
  }

  func readIfPresent(_ address: Address) async -> String? {
    let output: ReadOutput? = try? await main.tool("read", .object(["path": .string(address.rendered)]))
    return output?.content
  }

  func directoryNames(in directory: Address) async -> [String]? {
    let output: ListOutput? = try? await main.tool("ls", .object(["path": .string(directory.rendered)]))
    return output?.entries.filter { $0.kind == .directory }.map(\.name)
  }

  // The folders `folder` adds to what the session has seen, root-first with
  // the git root each lives under; nil when it adds none.
  func newFolders(
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
    let entry: JSONValue? = try? await main.tool("stat", .object(["path": .string(Address.machine(machine, directory).appending(".git").rendered)]))
    return entry != nil
  }
}

private func parent(of path: String) -> String? {
  guard path != "/", let slash = path.lastIndex(of: "/") else { return nil }
  return slash == path.startIndex ? "/" : String(path[..<slash])
}

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
