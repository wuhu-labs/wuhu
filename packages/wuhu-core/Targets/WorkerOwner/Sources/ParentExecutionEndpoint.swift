#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import protocol ExecutionOwner.ExecutionOwnerClient
import struct Fetch.Body
import struct InferenceKit.AttemptTraceSink
import enum JSONValue.JSONValue
import protocol SessionTools.ToolOwnerClient
import struct WorkerProtocol.WorkerCall
import struct WorkerProtocol.WorkerProtocolError

public struct ParentExecutionEndpoint: Sendable {
  private let spawn: ParentSpawnEndpoint?
  private let owner: any ExecutionOwnerClient
  private let runtime: ParentWorkerRuntime
  private let sessions: ParentSessionEndpoint
  private let tools: ParentToolEndpoint?
  private let scripts: ParentScriptEndpoint?
  private let traces = ParentTraces()
  private let machines = ParentMachines()
  private let identity = ParentScriptIdentity()
  private let streams = ParentScriptStreams()
  private let operations = OwnerOperations()
  public init(owner: any ExecutionOwnerClient, runtime: WorkerRuntimeOwner? = nil, spawn: ParentSpawnEndpoint? = nil) {
    self.spawn = spawn
    self.runtime = ParentWorkerRuntime(owner: runtime)
    self.owner = owner
    scripts = (owner as? any ToolOwnerClient).map { .init(owner: $0) }
    tools = (owner as? any ToolOwnerClient).map { .init(owner: $0) }
    sessions = .init(owner: owner)
  }

  public func stream(_ call: WorkerCall) async throws -> Body? {
    if call.operation == "machine.frames" {
      let request = try ownerDecode(StreamRequest.self, call.payload)
      return try await machines.stream(request.id)
    }
    if call.operation == "script.identity-body" {
      let request = try ownerDecode(StreamRequest.self, call.payload)
      return try await identity.body(request.id)
    }
    guard call.operation == "script.stream" else { return nil }
    let request = try ownerDecode(StreamRequest.self, call.payload)
    return try await streams.take(request.id)
  }

  public func upload(_ call: WorkerCall, body: Body) async throws -> Bool {
    guard call.operation == "script.identity-upload" else { return false }
    guard let scripts else { throw WorkerProtocolError(.invalidMessage, message: "Parent script owner is unavailable") }
    _ = try await operations.run(call) {
      try await identity.receive(call, body: body, owner: scripts.owner)
      return .bool(true)
    }
    return true
  }

  public func acknowledge(_ call: WorkerCall) async { await streams.acknowledge(call) }

  public func shutdown() async { await operations.stop(); await machines.stop(); await streams.stop(); await identity.stop(); await traces.stop(); await runtime.stop() }

  public func invoke(_ call: WorkerCall) async throws -> JSONValue {
    if call.operation == "owner.cancel" {
      let request = try ownerDecode(StreamRequest.self, call.payload)
      await operations.cancel(request.id)
      await streams.cancel(request.id)
      await identity.cancel(request.id)
      await machines.cancel(request.id)
      return .bool(true)
    }
    return try await operations.run(call) { try await perform(call) }
  }

  private func perform(_ call: WorkerCall) async throws -> JSONValue {
    if call.operation.hasPrefix("runtime.") {
      return try await runtime.invoke(call)
    }
    if call.operation.hasPrefix("machine.") {
      guard let scripts else { throw WorkerProtocolError(.invalidMessage, message: "Parent script owner is unavailable") }
      return try await machines.invoke(call, owner: scripts.owner)
    }
    if call.operation.hasPrefix("script.") {
      guard let scripts else { throw WorkerProtocolError(.invalidMessage, message: "Parent script owner is unavailable") }
      if call.operation == "script.identity-response" {
        return try await ownerReply {
          let request = try ownerDecode(StreamRequest.self, call.payload)
          return try ownerEncode(await identity.metadata(request.id))
        }
      }
      if call.operation == "script.stream-inventory" { return try await ownerReply { try ownerEncode(await streams.inventory()) } }
      if call.operation == "script.stream-next" {
        return try await ownerReply {
          let request = try ownerDecode(StreamRequest.self, call.payload)
          return try await ownerEncode(streams.next(request.id, call: call.id))
        }
      }
      if call.operation == "script.observe-open" || call.operation == "script.watch-open" {
        return try await ownerReply { try ownerEncode(await streams.open(call, owner: scripts.owner)) }
      }
      return try await scripts.invoke(call)
    }
    if call.operation == "tool.spawn", tools == nil, let spawn { return try await spawn.invoke(call) }
    if call.operation.hasPrefix("tool.") {
      guard let tools else { throw WorkerProtocolError(.invalidMessage, message: "Parent tool owner is unavailable") }
      return try await tools.invoke(call)
    }
    if call.operation.hasPrefix("session.") { return try await sessions.invoke(call) }
    return try await ownerReply {
      switch call.operation {
      case "inference.provider-credential":
        let request = try ownerDecode(ProviderRequest.self, call.payload)
        return try ownerEncode(await owner.providerCredential(request.provider).map(CredentialSnapshot.init))
      case "inference.provider-credential-binding":
        let request = try ownerDecode(ProviderRequest.self, call.payload)
        return try ownerEncode(await owner.providerCredentialBinding(request.provider).map(CredentialBindingSnapshot.init))
      case "inference.inference-token":
        let request = try ownerDecode(TokenRequest.self, call.payload)
        return try ownerEncode(await owner.inferenceToken(audience: request.audience, session: request.session))
      case "inference.inference-readiness":
        let request = try ownerDecode(AudienceRequest.self, call.payload)
        try await owner.inferenceReadiness(audience: request.audience)
        return .bool(true)
      case "inference.inference-binding-identity":
        let request = try ownerDecode(TokenRequest.self, call.payload)
        return try ownerEncode(await owner.inferenceBindingIdentity(audience: request.audience, session: request.session))
      case "inference.model-document": return try ownerEncode(await owner.modelDocument())
      case "inference.model-group-document": return try ownerEncode(await owner.modelGroupDocument())
      case "inference.prompt-home":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        return try ownerEncode(HomeSnapshot(await owner.promptHome(request.id)))
      case "inference.handles-by-principal": return try ownerEncode(await owner.handlesByPrincipal())
      case "inference.device-names": return try ownerEncode(await owner.deviceNames())
      case "inference.media-bytes":
        let request = try ownerDecode(MediaRequest.self, call.payload)
        return try ownerEncode(await owner.mediaBytes(request.reference.reference(), group: request.group))
      case "inference.metric":
        let request = try ownerDecode(MetricSnapshot.self, call.payload)
        await owner.recordMetric(try request.metric())
        return .bool(true)
      case "inference.trace-open":
        let request = try ownerDecode(TraceRequest.self, call.payload)
        guard owner.tracesAttempts else { throw WorkerProtocolError(.invalidMessage, message: "Attempt tracing is disabled") }
        try await traces.open(request.id, owner: owner)
        return .bool(true)
      case "inference.trace-append":
        let request = try ownerDecode(TraceAppendRequest.self, call.payload)
        try await traces.append(request.id, data: request.data)
        return .bool(true)
      case "inference.trace-close":
        let request = try ownerDecode(TraceRequest.self, call.payload)
        await traces.close(request.id)
        return .bool(true)
      default: throw WorkerProtocolError(.invalidMessage, message: "Unknown parent execution operation")
      }
    }
  }
}

private actor ParentTraces {
  private var sinks: [UUID: AttemptTraceSink] = [:]
  func open(_ id: UUID, owner: any ExecutionOwnerClient) async throws {
    guard sinks[id] == nil else { return }
    guard sinks.count < 1024 else { throw WorkerProtocolError(.capacityExceeded, message: "Too many open worker attempt traces") }
    sinks[id] = try await owner.openAttemptTrace(id)
  }

  func append(_ id: UUID, data: Data) async throws {
    guard let sink = sinks[id] else { throw WorkerProtocolError(.invalidMessage, message: "Unknown attempt trace") }
    await sink.append(data)
  }

  func close(_ id: UUID) { sinks[id] = nil }
  func stop() { sinks.removeAll() }
}
