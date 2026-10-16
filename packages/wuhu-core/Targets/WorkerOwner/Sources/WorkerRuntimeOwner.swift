#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct InferenceKit.AttemptEventSink
import class InferenceKit.AttemptHub
import enum JSONValue.JSONValue
import struct SessionDomain.SessionID
import enum SessionDomain.ToolResultPayload
import struct SessionTools.ScriptLifecycle
import struct SpaceContract.ProviderUsage
import struct WorkerProtocol.WorkerCall
import struct WorkerProtocol.WorkerProtocolError

public struct WorkerRuntimeOwner: Sendable {
  public var scriptStarted: @Sendable (SessionID, String) async throws -> Void = { _, _ in }
  public var scriptEnded: @Sendable (SessionID, String) async -> Void = { _, _ in }
  public var stopScript: @Sendable (SessionID, String) async throws -> ToolResultPayload = { _, _ in throw WorkerProtocolError(.unavailable, message: "Cross-worker script control is unavailable") }
  let scriptLost: @Sendable (SessionID, String) async -> Void
  let attempts: AttemptHub
  let usage: @Sendable () async throws -> [String: ProviderUsage]
  let receiveUsage: @Sendable (String, ProviderUsage) async throws -> Void
  let allowsWarming: @Sendable (SessionID) async throws -> Bool
  let scheduleReminder: @Sendable (SessionID, Date?) async throws -> Void
  let scheduleWarming: @Sendable (SessionID, Int) async throws -> Void
  public init(
    attempts: AttemptHub,
    scriptLost: @escaping @Sendable (SessionID, String) async -> Void = { _, _ in },
    usage: @escaping @Sendable () async throws -> [String: ProviderUsage],
    receiveUsage: @escaping @Sendable (String, ProviderUsage) async throws -> Void,
    allowsWarming: @escaping @Sendable (SessionID) async throws -> Bool,
    scheduleReminder: @escaping @Sendable (SessionID, Date?) async throws -> Void = { _, _ in throw WorkerProtocolError(.unavailable, message: "Parent reminders are unavailable") },
    scheduleWarming: @escaping @Sendable (SessionID, Int) async throws -> Void,
  ) {
    self.scheduleReminder = scheduleReminder
    self.scriptLost = scriptLost
    self.attempts = attempts; self.usage = usage; self.receiveUsage = receiveUsage
    self.allowsWarming = allowsWarming; self.scheduleWarming = scheduleWarming
  }
}

struct ScriptActivity: Codable, Sendable { let session: SessionID; let script: String }
struct UsagePublication: Codable, Sendable { let provider: String; let usage: ProviderUsage }
struct ReminderRequest: Codable, Sendable { let session: SessionID; let due: Date? }
struct WarmingRequest: Codable, Sendable { let session: SessionID; let intervalSeconds: Int }

struct RuntimeAttempt: Codable, Equatable, Sendable { let id: UUID; let session: SessionID }

actor ParentWorkerRuntime {
  let owner: WorkerRuntimeOwner?
  private var ownsAttempts = true
  private var active: [UUID: SessionID] = [:]
  private var scripts: [String: SessionID] = [:]
  init(owner: WorkerRuntimeOwner?) { self.owner = owner }
  func invoke(_ call: WorkerCall) async throws -> JSONValue {
    try await ownerReply {
      guard let owner else { throw WorkerProtocolError(.unavailable, message: "Parent runtime effects are unavailable") }
      switch call.operation {
      case "runtime.script-started":
        let request = try ownerDecode(ScriptActivity.self, call.payload)
        guard scripts[request.script] == nil, scripts.count < 1024 else { throw WorkerProtocolError(.capacityExceeded, message: "Too many worker scripts") }
        try await owner.scriptStarted(request.session, request.script)
        scripts[request.script] = request.session
        return .bool(true)
      case "runtime.script-ended":
        let request = try ownerDecode(ScriptActivity.self, call.payload)
        guard scripts[request.script] == request.session else { throw WorkerProtocolError(.invalidMessage, message: "Unknown worker script") }
        scripts.removeValue(forKey: request.script)
        await owner.scriptEnded(request.session, request.script)
        return .bool(true)
      case "runtime.stop-script":
        let request = try ownerDecode(ScriptActivity.self, call.payload)
        return try await ownerEncode(owner.stopScript(request.session, request.script))
      case "runtime.attempt":
        let request = try ownerDecode(AttemptPublication.self, call.payload)
        let event = request.event.event
        switch event {
        case let .started(id):
          guard active[id] == nil, active.count < 4096 else { throw WorkerProtocolError(.capacityExceeded, message: "Too many worker attempts") }
          active[id] = request.session
        case let .delta(id, _):
          guard active[id] == request.session else { throw WorkerProtocolError(.invalidMessage, message: "Unknown worker attempt") }
        case let .finished(id, _):
          guard active.removeValue(forKey: id) == request.session else { throw WorkerProtocolError(.invalidMessage, message: "Unknown worker attempt") }
        }
        owner.attempts.publish(session: request.session, event)
        return .bool(true)
      case "runtime.usage": return try await ownerEncode(owner.usage())
      case "runtime.receive-usage":
        let request = try ownerDecode(UsagePublication.self, call.payload)
        try await owner.receiveUsage(request.provider, request.usage)
        return .bool(true)
      case "runtime.allows-warming":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        return try await .bool(owner.allowsWarming(request.id))
      case "runtime.schedule-reminder":
        let request = try ownerDecode(ReminderRequest.self, call.payload)
        try await owner.scheduleReminder(request.session, request.due)
        return .bool(true)
      case "runtime.schedule-warming":
        let request = try ownerDecode(WarmingRequest.self, call.payload)
        try await owner.scheduleWarming(request.session, request.intervalSeconds)
        return .bool(true)
      default: throw WorkerProtocolError(.invalidMessage, message: "Unknown parent runtime effect")
      }
    }
  }

  func checkpoint() throws -> [RuntimeAttempt] {
    guard scripts.isEmpty else { throw WorkerProtocolError(.unavailable, message: "Active runtime scripts cannot be transferred") }
    return active.map { .init(id: $0.key, session: $0.value) }
  }

  func restore(_ attempts: [RuntimeAttempt]) throws {
    guard active.isEmpty, scripts.isEmpty, attempts.count <= 4096,
          Set(attempts.map(\.id)).count == attempts.count else { throw WorkerProtocolError(.invalidConfiguration, message: "Invalid runtime attempt checkpoint") }
    active = Dictionary(uniqueKeysWithValues: attempts.map { ($0.id, $0.session) })
    ownsAttempts = false
  }

  func activateTransferred() {
    guard !ownsAttempts else { return }
    ownsAttempts = true
    for (id, session) in active where owner?.attempts.inFlight(session: session)[id] == nil {
      owner?.attempts.publish(session: session, .started(attemptID: id))
    }
  }

  func retireTransferred() { active.removeAll() }

  func stop() async {
    let lost = scripts
    scripts.removeAll()
    for (id, session) in lost {
      await owner?.scriptLost(session, id)
      await owner?.scriptEnded(session, id)
    }
    for (id, session) in active where ownsAttempts { owner?.attempts.publish(session: session, .finished(attemptID: id, outcome: .failed(reason: "Execution worker exited"))) }
    active.removeAll()
  }
}

extension RemoteExecutionOwner {
  public var scriptLifecycle: ScriptLifecycle {
    .init(started: { [rpc] session, script in
      try await Task { let _: Bool = try await rpc.call("runtime.script-started", ScriptActivity(session: session, script: script)) }.value
    }, ended: { [rpc] session, script in
      await Task { let _: Bool? = try? await rpc.call("runtime.script-ended", ScriptActivity(session: session, script: script)) }.value
    })
  }

  public func stopRuntimeScript(_ session: SessionID, script: String) async throws -> ToolResultPayload {
    try await rpc.client.requireCapability(ExecutionWorkerBootstrap.handoffCapability)
    return try await rpc.call("runtime.stop-script", ScriptActivity(session: session, script: script))
  }

  public var attemptEvents: AttemptEventSink {
    .init { [rpc, deferredAttemptTerminations] session, event in
      try await Task { try await deferredAttemptTerminations.publish(session: session, event: event, rpc: rpc) }.value
    }
  }

  public func publishActivity(_ activity: ExecutionWorkerActivity) async throws { try await deferredActivityReleases.publish(activity, rpc: rpc) }

  public func flushDeferredOwnerPublications() async throws {
    try await deferredAttemptTerminations.flush(using: rpc)
    try await deferredActivityReleases.flush(using: rpc)
  }

  public func runtimeUsage() async throws -> [String: ProviderUsage] { try await rpc.call("runtime.usage", EmptyRequest()) }
  public func recordRuntimeUsage(_ provider: String, usage: ProviderUsage) async throws {
    let _: Bool = try await rpc.call("runtime.receive-usage", UsagePublication(provider: provider, usage: usage))
  }

  public func allowsCacheWarming(_ session: SessionID) async throws -> Bool { try await rpc.call("runtime.allows-warming", SessionIDRequest(id: session)) }
  public func scheduleReminder(_ session: SessionID, at due: Date?) async throws {
    try await rpc.client.requireCapability(ExecutionWorkerBootstrap.remindersCapability)
    let _: Bool = try await rpc.call("runtime.schedule-reminder", ReminderRequest(session: session, due: due))
  }

  public func scheduleCacheWarming(_ session: SessionID, intervalSeconds: Int) async throws {
    let _: Bool = try await rpc.call("runtime.schedule-warming", WarmingRequest(session: session, intervalSeconds: intervalSeconds))
  }
}
