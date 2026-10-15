import enum JSONValue.JSONValue
import struct SessionDomain.RequestID
import struct SessionDomain.SessionID
import struct SessionDomain.ToolCallID
import struct SessionTools.Spawned
import struct SessionTools.SpawnOrder
import struct WorkerProtocol.WorkerCall
import class WorkerProtocol.WorkerClient
import struct WorkerProtocol.WorkerProtocolError

public struct ParentSpawnEndpoint: Sendable {
  private let spawn: @Sendable (SessionID, ToolCallID, SpawnOrder) async throws -> Spawned
  public init(spawn: @escaping @Sendable (SessionID, ToolCallID, SpawnOrder) async throws -> Spawned) { self.spawn = spawn }
  public func invoke(_ call: WorkerCall) async throws -> JSONValue {
    guard call.operation == "tool.spawn" else { throw WorkerProtocolError(.invalidMessage, message: "Unknown spawn operation") }
    return try await ownerReply {
      let request = try ownerDecode(SpawnRequest.self, call.payload)
      return try ownerEncode(SpawnedSnapshot(await spawn(request.session, request.call, request.order.order)))
    }
  }
}

struct RemoteSpawnClient: Sendable {
  private let rpc: OwnerRPC
  init(client: WorkerClient) { rpc = .init(client: client) }
  func spawn(_ session: SessionID, _ call: ToolCallID, _ order: SpawnOrder) async throws -> Spawned {
    let result: SpawnedSnapshot = try await rpc.call("tool.spawn", SpawnRequest(session: session, call: call, order: .init(order)))
    return result.spawned
  }
}

struct SpawnRequest: Codable, Sendable {
  let session: SessionID
  let call: ToolCallID
  let order: SpawnOrderSnapshot
}

struct SpawnOrderSnapshot: Codable, Sendable {
  let executor: String?
  let title: String
  let kind: String?
  let topLevel: Bool
  let group: String?
  let provider: String?
  let model: String?
  let modelGroup: String?
  let effort: String?
  let tags: [String]?
  let template: String?
  let expectsReply: Bool
  let message: String?
  init(_ order: SpawnOrder) {
    executor = order.executor; title = order.title; kind = order.kind; topLevel = order.topLevel; group = order.group; provider = order.provider; model = order.model; modelGroup = order.modelGroup; effort = order.effort; tags = order.tags; template = order.template; expectsReply = order.expectsReply; message = order.message
  }

  var order: SpawnOrder {
    .init(executor: executor, title: title, kind: kind, topLevel: topLevel, group: group, provider: provider, model: model, modelGroup: modelGroup, effort: effort, tags: tags, template: template, expectsReply: expectsReply, message: message)
  }
}

struct SpawnedSnapshot: Codable, Sendable {
  let id: SessionID
  let title: String
  let requestID: RequestID?
  let unfinished: String?
  let modelGroup: String?
  let member: String?
  let provider: String?
  let model: String?
  init(_ result: Spawned) {
    id = result.id; title = result.title; requestID = result.requestID; unfinished = result.unfinished; modelGroup = result.modelGroup; member = result.member; provider = result.provider; model = result.model
  }

  var spawned: Spawned { .init(id: id, title: title, requestID: requestID, unfinished: unfinished, modelGroup: modelGroup, member: member, provider: provider, model: model) }
}
