#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import protocol ExecutionOwner.ExecutionOwnerClient
import struct InferenceKit.AttemptTraceSink
import enum JSONValue.JSONValue
import struct WorkerProtocol.WorkerCall
import struct WorkerProtocol.WorkerProtocolError

public struct ParentExecutionEndpoint: Sendable {
  private let owner: any ExecutionOwnerClient
  private let sessions: ParentSessionEndpoint
  private let traces = ParentTraces()
  public init(owner: any ExecutionOwnerClient) {
    self.owner = owner
    sessions = .init(owner: owner)
  }

  public func invoke(_ call: WorkerCall) async throws -> JSONValue {
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
}
