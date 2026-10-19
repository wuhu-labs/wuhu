import Dependencies
import Logging
import struct SpaceContract.ToolRostersOutput
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Credentials
import Fetch
import JSONValue
import MachineContract
import SessionDomain
import SpaceContract
import SpaceCore
import SpaceFS
import SpaceTools
import Synchronization

extension Hub {
  nonisolated private func context(_ session: SessionID) async throws -> SpaceToolContext {
    try await SpaceToolContext(space: space, principal: space.principal(of: session))
  }

  nonisolated public func principal(of session: SessionID) async throws -> Principal { try await space.principal(of: session) }
  nonisolated public func moduleSnapshot(for session: SessionID) async throws -> ScriptModuleSnapshot {
    let acting = try await principal(of: session).group
    return try await ScriptModuleSnapshot(revision: Rev(space.currentRevision()), acting: acting, readable: space.reads(acting))
  }

  nonisolated public func moduleBytes(path: String, shown: String, group: GroupID, snapshot: ScriptModuleSnapshot) async throws -> Data {
    guard snapshot.readable.contains(group), snapshot.revision != Rev(0) else { throw SpaceError.notFound(path) }
    let fs = await space.fs(group, at: snapshot.revision)
    guard try await fs.stat(path).size <= scriptModuleBytes else { throw ScriptError("\(shown) is larger than \(scriptModuleBytes >> 20) MiB") }
    return try await fs.read(path).1
  }

  nonisolated public func query(_ sql: String, parameters: [JSONValue], byteLimit: Int, session: SessionID) async throws -> Rows {
    try await space.query(sql, parameters: parameters, byteLimit: byteLimit, as: principal(of: session))
  }

  nonisolated public func observe(_ sql: String, parameters: [JSONValue], session: SessionID) async throws -> AsyncThrowingStream<Rows, any Error> {
    let principal = try await principal(of: session)
    _ = try Space.bound(parameters)
    try await space.validateQuery(sql, as: principal)
    return await space.observeQuery(sql, parameters: parameters, throttle: .zero, as: principal)
  }

  nonisolated public func watch(_ glob: String, from: Rev?, session: SessionID) async throws -> AsyncThrowingStream<JSONValue, any Error> {
    let watched = try await WatchedGlob(glob, as: principal(of: session), in: space)
    let events = await space.observeFS(glob: watched.pattern, from: from, group: watched.group)
    return parentWatchRelay(events, prefix: watched.prefix)
  }

  nonisolated public func dataOperation(_ operation: ScriptDataOperation, input: JSONValue, session: SessionID) async throws -> JSONValue {
    try await SpaceToolbox.all.first { $0.name == operation.rawValue }!.run(context(session), input: input)
  }

  nonisolated public func commitRows(_ path: String, edits: [RowEdit], session: SessionID) async throws -> JSONValue {
    let commit = try await context(session).commitRows(path, edits: edits)
    return .object(["rev": .integer(commit.rev.value), "ids": .array(commit.ids.map { .integer(Int($0)) })])
  }

  nonisolated public func readBytes(_ path: String, rev: Int?, byteLimit: Int, session: SessionID) async throws -> FileBytes {
    try await context(session).readBytes(path, rev: rev, byteLimit: byteLimit)
  }

  nonisolated public func writeBytes(_ path: String, data: Data, ifMatch: String?, session: SessionID) async throws -> FileVersion {
    try await context(session).writeBytes(path, data, ifMatch: ifMatch, createOnly: ifMatch == nil)
  }

  nonisolated public func checkout(_ path: String, rev: Int, ifMatch: String?, session: SessionID) async throws -> JSONValue {
    try await context(session).checkout(path, rev: rev, ifMatch: ifMatch, createOnly: ifMatch == nil)
  }

  nonisolated public func list(_ path: String, rev: Int?, hidden: Bool, byteLimit: Int, session: SessionID) async throws -> JSONValue {
    try await context(session).list(path, rev: rev, hidden: hidden, limit: 500, byteLimit: byteLimit)
  }

  nonisolated public func discovery(_ operation: ScriptDiscoveryOperation, session: SessionID) async throws -> JSONValue {
    switch operation {
    case .identity: return try await identityConfiguration()
    case .context:
      return try await context(session).discoveryContext(contentHost: scriptDiscovery.contentHost.withLock { $0 })
    case .groups: return try await JSONValueEncoder().encode(context(session).discoveryGroups())
    case .toolRosters:
      guard let rosters = scriptDiscovery.toolRosters.withLock({ $0 }) else {
        throw ToolRunError.failed(code: .unsupported, message: "The session roster is not configured on this script host.", hint: nil)
      }
      return try JSONValueEncoder().encode(rosters)
    }
  }

  nonisolated public func channel(_ arguments: [JSONValue], session: SessionID) async -> JSONValue { await scriptChannel(arguments, space: space, session: session) }
  nonisolated public func conversation(_ arguments: [JSONValue], reader: SessionID) async throws -> JSONValue { try await conversationPage(arguments, in: space, reader: reader) }
  nonisolated public func directMessage(_ arguments: [JSONValue], reader: SessionID) async throws -> JSONValue { try await directMessagePage(arguments, in: space, reader: reader) }
  nonisolated public func usableMachines(session: SessionID) async throws -> [MachineRecord] { try await space.machines(usableFrom: principal(of: session).group) }
  nonisolated public func resolveMachine(_ reference: String, session: SessionID) async throws -> MachineRecord? { try await space.resolveMachine(reference, usableFrom: principal(of: session).group) }
  nonisolated public func ownExecs(session: SessionID) async throws -> [ExecStatus] { try await context(session).ownExecs() }
  nonisolated public func ownExecStatus(_ id: String, session: SessionID) async throws -> ExecStatus { try await context(session).ownExecStatus(id) }
  nonisolated public func takeScriptExecOwners() async throws -> [ScriptExecOwner] { try await space.takeScriptExecOwners() }
  nonisolated public func releaseScriptExecs(script: String) async throws { try await space.releaseScriptExecs(script: script) }
  nonisolated public func notify(session: SessionID, notification: SystemNotification) async throws { _ = try await store.enqueue(session, input: .notification(notification)) }
}

final class ScriptDiscoveryConfiguration: Sendable {
  let value = Mutex<(@Sendable () async throws -> JSONValue)?>(nil)
  let contentHost = Mutex<String?>(nil)
  let toolRosters = Mutex<ToolRostersOutput?>(nil)
}

extension Hub {
  nonisolated public func configureScriptDiscovery(contentHost: String? = nil, toolRosters: ToolRostersOutput? = nil, identity: (@Sendable () async throws -> JSONValue)? = nil) {
    if let toolRosters { scriptDiscovery.toolRosters.withLock { $0 = toolRosters } }
    if let contentHost { scriptDiscovery.contentHost.withLock { $0 = contentHost } }
    if let identity { scriptDiscovery.value.withLock { $0 = identity } }
  }

  nonisolated public func announceScriptRestart() async {
    do {
      for owner in try await takeScriptExecOwners() {
        var text = "script.\(owner.script) was killed by a server restart"
        if !owner.live.isEmpty {
          let ids = owner.live.map(\.rawValue).joined(separator: ", ")
          text += "; the machine processes it left running (\(ids)) get killed about a minute after the restart, or when their machine reconnects if it is away then"
        }
        @Dependency(\.date) var date
        @Dependency(\.uuid) var uuid
        do {
          try await notify(session: SessionID(rawValue: owner.session), notification: SystemNotification(
            id: uuid(), timestamp: date.now, kind: .script, subscriptionID: .script(owner.script), content: .init(text: text),
          ))
        } catch {
          Logger(label: "wuhu.execution-boot").warning("Could not notify script owner: \(error)")
        }
      }
    } catch {
      Logger(label: "wuhu.execution-boot").error("Could not announce scripts stopped by restart: \(error)")
    }
  }

  nonisolated public func identityRequest(_ request: Request, session: SessionID) async -> ScriptIdentityReply {
    guard let identityFetch else {
      return .init(response: .failure(ScriptIdentityUnavailable(message: "the server fetch identity is unavailable")), protectedValues: [])
    }
    let protected = Mutex<[String]>([])
    let response: Result<Response, any Error>
    do { response = .success(try await identityFetch(request, session) { token in protected.withLock { $0.append(token) } }) }
    catch { response = .failure(error) }
    return .init(response: response, protectedValues: protected.withLock { $0 })
  }

  nonisolated func identityConfiguration() async throws -> JSONValue {
    guard let provider = scriptDiscovery.value.withLock({ $0 }) else {
      throw ToolRunError.failed(code: .unsupported, message: "The server identity is not configured on this script host.", hint: nil)
    }
    do { return try await provider() }
    catch { throw ToolRunError.failed(code: .unsupported, message: "The server issuer is unavailable; inspect wuhu identity for configuration or directory publication errors.", hint: nil) }
  }
}

func parentWatchRelay(_ source: AsyncStream<FSCommit>, prefix: String) -> AsyncThrowingStream<JSONValue, any Error> {
  let relay = ParentWatchRelay(source, prefix: prefix)
  return AsyncThrowingStream(unfolding: { await relay.next() })
}

private actor ParentWatchRelay {
  private var iterator: AsyncStream<FSCommit>.Iterator?
  private var pending: Array<JSONValue>.Iterator = [].makeIterator()
  private let prefix: String

  init(_ source: AsyncStream<FSCommit>, prefix: String) {
    iterator = source.makeAsyncIterator()
    self.prefix = prefix
  }

  func next() async -> JSONValue? {
    while true {
      if let event = pending.next() { return event }
      guard var iterator = self.iterator else { return nil }
      self.iterator = nil
      guard let commit = await iterator.next(isolation: self) else { return nil }
      self.iterator = iterator
      pending = commit.events.map { Wire.mutationJSON($0, prefix: prefix) }.makeIterator()
    }
  }
}
