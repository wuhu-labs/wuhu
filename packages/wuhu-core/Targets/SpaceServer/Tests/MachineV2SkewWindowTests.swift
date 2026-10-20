import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ComputerFiles
import Crypto
import Fetch
import FileSearch
import enum JSONValue.JSONValue
import MachineContract
import OperationProtocol
import OperationRuntime
import Scratch
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

/// What an agent of a given release advertises, of the kinds this server
/// speaks. dev.120 and dev.121 ship today's filesystem kinds but search through
/// find.v1/grep.v1, which search.v1 replaced; dev.119 predates the
/// filesystem kinds too.
enum SkewAgentRelease: String, CaseIterable, Sendable {
  case dev119 = "0.1.0-dev.119"
  case dev120 = "0.1.0-dev.120"
  case dev121 = "0.1.0-dev.121"

  var kinds: [KindDescriptor] {
    switch self {
    case .dev120, .dev121:
      [
        ComputerKindSchemas.read,
        ComputerKindSchemas.stat,
        ComputerKindSchemas.list,
        ComputerKindSchemas.write,
        ComputerKindSchemas.mkdir,
        ComputerKindSchemas.remove,
        ComputerKindSchemas.move,
      ]
    case .dev119:
      [ComputerKindSchemas.read]
    }
  }
}

private final class Starts: Sendable {
  let value = Mutex(0)
}

/// Runs a real agent behind a proxy that rewrites its description to `release`'s, and the server's normal hub in front.
private func withAgent(advertising release: SkewAgentRelease, _ body: (MachineHub, MachineID, Starts) async throws -> Void) async throws {
  let space = try Space.inMemory()
  let (record, _) = try await space.addMachineV2(name: "skew-v2", group: .shared)
  let agent = try OperationAgent(machine: record.id.rawValue, kinds: fileOperationKinds(), authorize: { _, _ in })
  let starts = Starts()
  let advertised = release.kinds
  let names = Set(advertised.map(\.name))
  let proxy = FetchClient { request in
    if request.method == .post, UUID(uuidString: request.url.lastPathComponent) != nil { starts.value.withLock { $0 += 1 } }
    let response = try await agent.handler(request)
    guard request.method == .get, request.url.lastPathComponent == record.id.rawValue, response.status == .ok else { return response }
    let description = try await response.body.json(MachineDescription.self)
    var headers = response.headers
    headers[.contentLength] = nil
    let kinds = advertised.filter { kind in description.kinds.contains { $0.name == kind.name } }
    #expect(kinds.count == names.count)
    return try .json(MachineDescription(instance: description.instance, acceptingStarts: description.acceptingStarts, limits: description.limits, kinds: kinds, availability: description.availability?.filter { names.contains($0.key) }), headers: headers)
  }
  let hub = MachineHub(space: space)
  let service = MachineV2Service(space: space, hub: MachineV2Hub(space: space), key: SymmetricKey(size: .bits256), failure: nil, fetch: { _ in proxy })
  await hub.configureV2(service)
  try await withThrowingTaskGroup(of: Void.self) { tasks in
    tasks.addTask { await agent.run() }
    defer { tasks.cancelAll() }
    try await body(hub, record.id, starts)
    await agent.shutdown()
  }
  await service.shutdown()
}

@Suite(.deterministicDependencies) struct MachineV2SkewWindowTests {
  /// A server one release ahead of its machines keeps every file tool working;
  /// search, which those agents do not speak as search.v1, is refused typed before anything starts.
  @Test(arguments: [SkewAgentRelease.dev120, .dev121])
  func previousReleaseKeepsFilesWorkingAndRefusesSearch(_ release: SkewAgentRelease) async throws {
    let folder = try ScratchFolder("v2-skew-\(release.rawValue)")
    let file = folder.url.appending(path: "notes.txt")
    try Data("needle one\nneedle two".utf8).write(to: file)
    try await withAgent(advertising: release) { hub, machine, starts in
      guard case let .file(_, bytes) = try await hub.vfs(machine: machine, op: .read(path: file.path)) else { Issue.record("read"); return }
      #expect(String(decoding: bytes.bytes, as: UTF8.self) == "needle one\nneedle two")
      guard case let .entry(entry) = try await hub.vfs(machine: machine, op: .stat(path: file.path)) else { Issue.record("stat"); return }
      guard case .written = try await hub.vfs(machine: machine, op: .write(path: file.path, data: .init(Array("needle three".utf8)), ifMatch: entry.token)) else { Issue.record("conditional write"); return }
      guard case .ok = try await hub.vfs(machine: machine, op: .mkdir(path: folder.url.appending(path: "sub").path)) else { Issue.record("mkdir"); return }
      guard case .ok = try await hub.vfs(machine: machine, op: .mv(from: file.path, to: folder.url.appending(path: "sub/moved.txt").path)) else { Issue.record("move"); return }
      guard case let .entries(entries) = try await hub.vfs(machine: machine, op: .ls(path: folder.url.appending(path: "sub").path)) else { Issue.record("list"); return }
      #expect(entries.map(\.name) == ["moved.txt"])
      try await expectSearchRefused(hub, machine, folder.path)
      guard case .ok = try await hub.vfs(machine: machine, op: .rm(path: folder.url.appending(path: "sub/moved.txt").path, ifMatch: nil)) else { Issue.record("remove"); return }
      #expect(starts.value.withLock { $0 } == 7)
    }
  }

  /// Older than the window: every call the server cannot express is refused, typed, before anything starts.
  @Test func agentOlderThanTheWindowIsRefusedBeforeStarting() async throws {
    let folder = try ScratchFolder("v2-skew-dev119")
    let file = folder.url.appending(path: "notes.txt")
    try Data("needle".utf8).write(to: file)
    try await withAgent(advertising: .dev119) { hub, machine, starts in
      let operations: [VFSOp] = [
        .stat(path: file.path), .ls(path: folder.path), .write(path: file.path, data: .init([1]), ifMatch: nil),
        .mkdir(path: folder.url.appending(path: "sub").path), .rm(path: file.path, ifMatch: nil), .mv(from: file.path, to: folder.url.appending(path: "b").path),
      ]
      for op in operations {
        do {
          _ = try await hub.vfs(machine: machine, op: op)
          Issue.record("dev.119 admitted \(op)")
        } catch let error as OperationError {
          #expect(error.code == .unknownKind)
          #expect(error.message.contains("agent too old, upgrade"))
        }
      }
      try await expectSearchRefused(hub, machine, folder.path)
      #expect(starts.value.withLock { $0 } == 0)
      guard case let .file(_, bytes) = try await hub.vfs(machine: machine, op: .read(path: file.path)) else { Issue.record("read"); return }
      #expect(String(decoding: bytes.bytes, as: UTF8.self) == "needle")
    }
  }
}

private func expectSearchRefused(_ hub: MachineHub, _ machine: MachineID, _ root: String) async throws {
  for mode in [SearchQuery.Mode.grep, .find] {
    do {
      _ = try await hub.search(machine: machine, query: SearchQuery(mode: mode, pattern: "needle", root: root, scope: "test"))
      Issue.record("an agent without search.v1 admitted \(mode)")
    } catch let error as OperationError {
      #expect(error.code == .kindUnavailable)
      #expect(error.details?.object?["reason"] == "agentTooOld")
    }
  }
}
