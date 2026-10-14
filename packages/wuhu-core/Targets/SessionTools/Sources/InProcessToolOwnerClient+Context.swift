import struct MachineContract.MachineID
import enum MachineContract.VFSOp
import SessionDomain
import SpaceCore
import SpaceFS
import SystemFiles

extension InProcessToolOwnerClient {
  func deliverContext(
    _ session: SessionID,
    _ callID: ToolCallID,
    touching address: Address,
    state: ToolExecutionState,
  ) async throws {
    guard case let .machine(machine, folder) = address,
          let folders = await newFolders(machine, down: folder, recorded: state.folderRoots)
    else { return }
    var delivery = ContextDelivery(alreadyLoaded: state.deliveredContext)
    var sections: [String] = []
    if !state.folderRoots.keys.contains(where: { $0.hasPrefix(Address.machine(machine, "/").rendered) }),
       let notes = try? await machineNotes(machine, for: session)
    {
      sections += await contextInstructions.load(notes, style: .machineNotes, delivery: &delivery)
    }
    for (directory, root) in folders where root != nil {
      sections += await contextInstructions.load(.machine(machine, directory), style: .repository, delivery: &delivery)
    }
    let context = ScopeContext(
      folders: Dictionary(uniqueKeysWithValues: folders.map { directory, root in
        (Address.machine(machine, directory).rendered, root.map { Address.machine(machine, $0).rendered })
      }),
      deliveredContext: delivery.delivered.isEmpty ? nil : delivery.delivered,
      text: sections.joined(separator: "\n\n"),
    )
    try await store.recordScopeContext(session, toolCallID: callID, context: context)
  }

  private func machineNotes(_ machine: MachineID, for session: SessionID) async throws -> Address {
    let group = try await space.machineGroup(machine)
    let qualified = try await space.principal(of: session).group != group
    return .space("/_/machines/\(machine.rawValue)", in: group, qualified: qualified)
  }

  private var contextInstructions: ContextInstructions {
    ContextInstructions(read: { await readIfPresent($0) }, names: { await directoryNames(in: $0) })
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
}
