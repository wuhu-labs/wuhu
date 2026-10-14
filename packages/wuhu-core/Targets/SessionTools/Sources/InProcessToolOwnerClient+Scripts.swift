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

extension InProcessToolOwnerClient {
  private func context(_ session: SessionID) async throws -> SpaceToolContext {
    try await SpaceToolContext(space: space, principal: space.principal(of: session))
  }

  public func principal(of session: SessionID) async throws -> Principal { try await space.principal(of: session) }
  public func moduleSnapshot(for session: SessionID) async throws -> ScriptModuleSnapshot {
    let acting = try await principal(of: session).group
    return try await ScriptModuleSnapshot(revision: Rev(space.currentRevision()), acting: acting, readable: space.reads(acting))
  }

  public func moduleBytes(path: String, shown: String, group: GroupID, snapshot: ScriptModuleSnapshot) async throws -> Data {
    guard snapshot.readable.contains(group), snapshot.revision != Rev(0) else { throw SpaceError.notFound(path) }
    let fs = await space.fs(group, at: snapshot.revision)
    guard try await fs.stat(path).size <= scriptModuleBytes else { throw ScriptError("\(shown) is larger than \(scriptModuleBytes >> 20) MiB") }
    return try await fs.read(path).1
  }

  public func query(_ sql: String, parameters: [JSONValue], byteLimit: Int, session: SessionID) async throws -> Rows {
    try await space.query(sql, parameters: parameters, byteLimit: byteLimit, as: principal(of: session))
  }

  public func observe(_ sql: String, parameters: [JSONValue], session: SessionID) async throws -> AsyncThrowingStream<Rows, any Error> {
    let principal = try await principal(of: session)
    _ = try Space.bound(parameters)
    try await space.validateQuery(sql, as: principal)
    return await space.observeQuery(sql, parameters: parameters, throttle: .zero, as: principal)
  }

  public func watch(_ glob: String, from: Rev?, session: SessionID) async throws -> AsyncThrowingStream<JSONValue, any Error> {
    let watched = try await WatchedGlob(glob, as: principal(of: session), in: space)
    let events = await space.observeFS(glob: watched.pattern, from: from, group: watched.group)
    return parentWatchRelay(events, prefix: watched.prefix).events
  }

  public func dataOperation(_ operation: ScriptDataOperation, input: JSONValue, session: SessionID) async throws -> JSONValue {
    try await SpaceToolbox.all.first { $0.name == operation.rawValue }!.run(context(session), input: input)
  }

  public func commitRows(_ path: String, edits: [RowEdit], session: SessionID) async throws -> JSONValue {
    let commit = try await context(session).commitRows(path, edits: edits)
    return .object(["rev": .integer(commit.rev.value), "ids": .array(commit.ids.map { .integer(Int($0)) })])
  }

  public func readBytes(_ path: String, rev: Int?, byteLimit: Int, session: SessionID) async throws -> FileBytes {
    try await context(session).readBytes(path, rev: rev, byteLimit: byteLimit)
  }

  public func writeBytes(_ path: String, data: Data, ifMatch: String?, session: SessionID) async throws -> FileVersion {
    try await context(session).writeBytes(path, data, ifMatch: ifMatch, createOnly: ifMatch == nil)
  }

  public func checkout(_ path: String, rev: Int, ifMatch: String?, session: SessionID) async throws -> JSONValue {
    try await context(session).checkout(path, rev: rev, ifMatch: ifMatch, createOnly: ifMatch == nil)
  }

  public func list(_ path: String, rev: Int?, hidden: Bool, byteLimit: Int, session: SessionID) async throws -> JSONValue {
    try await context(session).list(path, rev: rev, hidden: hidden, limit: 500, byteLimit: byteLimit)
  }

  public func discoveryContext(session: SessionID, contentHost: String?) async throws -> JSONValue {
    try await context(session).discoveryContext(contentHost: contentHost)
  }

  public func discoveryGroups(session: SessionID) async throws -> JSONValue {
    try await JSONValueEncoder().encode(context(session).discoveryGroups())
  }

  public func channel(_ arguments: [JSONValue], session: SessionID) async -> JSONValue { await scriptChannel(arguments, space: space, session: session) }
  public func conversation(_ arguments: [JSONValue], reader: SessionID) async throws -> JSONValue { try await conversationPage(arguments, in: space, reader: reader) }
  public func directMessage(_ arguments: [JSONValue], reader: SessionID) async throws -> JSONValue { try await directMessagePage(arguments, in: space, reader: reader) }
  public func usableMachines(session: SessionID) async throws -> [MachineRecord] { try await space.machines(usableFrom: principal(of: session).group) }
  public func resolveMachine(_ reference: String, session: SessionID) async throws -> MachineRecord? { try await space.resolveMachine(reference, usableFrom: principal(of: session).group) }
  public func machineV2Members(group: GroupID) async throws -> [String] { try await space.machineV2Members(group: group) }
  public func ownExecs(session: SessionID) async throws -> [ExecStatus] { try await context(session).ownExecs() }
  public func ownExecStatus(_ id: String, session: SessionID) async throws -> ExecStatus { try await context(session).ownExecStatus(id) }
  public func ownExecToKill(_ id: String, session: SessionID) async throws -> ExecID { try await context(session).ownExecStatus(id).id }
  public func takeScriptExecOwners() async throws -> [ScriptExecOwner] { try await space.takeScriptExecOwners() }
  public func releaseScriptExecs(script: String) async throws { try await space.releaseScriptExecs(script: script) }
  public func notify(session: SessionID, notification: SystemNotification) async throws { _ = try await store.enqueue(session, input: .notification(notification)) }
}

final class InProcessIdentityConfiguration: Sendable {
  let value = Mutex<(@Sendable () async throws -> JSONValue)?>(nil)
}

extension InProcessToolOwnerClient {
  public func identityRequest(_ request: Request, session: SessionID) async -> ScriptIdentityReply {
    guard let identityFetch else {
      return .init(response: .failure(ScriptIdentityUnavailable(message: "the server fetch identity is unavailable")), protectedValues: [])
    }
    let protected = Mutex<[String]>([])
    let response: Result<Response, any Error>
    do { response = .success(try await identityFetch(request, session) { token in protected.withLock { $0.append(token) } }) }
    catch { response = .failure(error) }
    return .init(response: response, protectedValues: protected.withLock { $0 })
  }

  public func identityConfiguration() async throws -> JSONValue {
    guard let provider = identityConfigurationProvider.value.withLock({ $0 }) else {
      throw ToolRunError.failed(code: .unsupported, message: "The server identity is not configured on this script host.", hint: nil)
    }
    do { return try await provider() }
    catch { throw ToolRunError.failed(code: .unsupported, message: "The server issuer is unavailable; inspect wuhu identity for configuration or directory publication errors.", hint: nil) }
  }
}

func parentWatchRelay(_ source: AsyncStream<FSCommit>, prefix: String) -> (events: AsyncThrowingStream<JSONValue, any Error>, pump: Task<Void, Never>) {
  let (events, continuation) = AsyncThrowingStream<JSONValue, any Error>.makeStream()
  let pump = Task {
    for await event in source.mutations { continuation.yield(Wire.mutationJSON(event, prefix: prefix)) }
    continuation.finish()
  }
  continuation.onTermination = { _ in pump.cancel() }
  return (events, pump)
}
