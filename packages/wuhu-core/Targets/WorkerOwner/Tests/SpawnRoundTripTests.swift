#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ExecutionOwner
import Fetch
import SessionDomain
import SessionTools
import SpaceCore
import Testing
@testable import WorkerOwner
import WorkerProtocol

@Test func spawnKeepsDurableReplayReceiptInParent() async throws {
  let space = try Space.inMemory()
  let model = ModelSpecifier(provider: "offline", model: "small", effort: "none")
  let caller = try await space.sessions.createSession(group: .shared, title: "caller", kind: .agent, createdBy: "owner", model: model)
  let owner = InProcessToolOwnerClient(space: space, executionOwner: InProcessExecutionOwnerClient(space: space), resolveModelExecutor: { provider, model, effort in
    .kernel(.init(provider: provider, model: model, effort: effort ?? "none"))
  })
  let parent = ParentSpawnEndpoint { try await owner.spawn($0, $1, $2) }
  let endpoint = try OwnerByteEndpoint(invoke: parent.invoke).endpoint(token: "fixture", hello: .init(release: "parent"))
  let fetch = FetchClient { try await endpoint.handler($0) }
  let client = try WorkerClient(socket: "/tmp/fixture.sock", token: "fixture", control: fetch, bytes: fetch)
  _ = try await client.negotiate(.init(release: "worker"))
  let remote = RemoteSpawnClient(client: client)
  let order = SpawnOrder(title: "child", provider: model.provider, model: model.model)
  let first = try await remote.spawn(caller, .init("same-call"), order)
  let repeated = try await remote.spawn(caller, .init("same-call"), order)
  #expect(first.id == repeated.id)
  #expect(first.requestID == repeated.requestID)
  #expect(try await space.sessions.record(first.id).parent == caller)
}
