#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import JSONValue
import SessionDomain
import SessionTools
import SpaceCore
import Synchronization
import Testing
@testable import WorkerOwner
import WorkerProtocol

@Suite(.timeLimit(.minutes(1))) struct StreamContinuityTests {
  @Test func observeAndWatchKeepLogicalReadersAcrossLostPullReplies() async throws {
    let space = try Space.inMemory()
    let session = try await space.sessions.createSession(group: .shared, title: "continuity", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
    let parent = ParentExecutionEndpoint(owner: InProcessToolOwnerClient(space: space))
    let bytes = OwnerByteEndpoint(invoke: parent.invoke, upload: parent.upload, download: parent.stream, acknowledged: parent.acknowledge)
    let endpoint = try bytes.endpoint(token: "token", hello: ExecutionWorkerBootstrap.hello(release: "parent"))
    let dropped = Mutex<Set<UUID>>([])
    let fetch = FetchClient { request in
      let response = try await endpoint.handler(request)
      if request.url.path == "/worker/download", let raw = request.headers["X-Wuhu-Worker-Stream"], let data = Data(base64Encoded: raw) {
        let call = try JSONDecoder().decode(WorkerCall.self, from: data)
        if call.payload.stringValue == "script.stream-next", dropped.withLock({ $0.insert(call.id).inserted }) {
          try await response.body.discard()
          throw WorkerProtocolError(.unavailable, message: "Stream record reply lost")
        }
      }
      return response
    }
    let client = try WorkerClient(socket: "/private/owner.sock", token: "token", control: fetch, bytes: fetch)
    _ = try await client.negotiate(ExecutionWorkerBootstrap.hello(release: "worker"))
    let remote = RemoteExecutionOwner(client: client, tracesAttempts: false)
    let outcome: Result<Void, any Error>
    do {
      let observed = try await remote.observe("SELECT path FROM docs WHERE path LIKE '/events/%' ORDER BY path", parameters: [], session: session)
      var rows = observed.makeAsyncIterator()
      #expect(try await rows.next()?.rows.isEmpty == true)
      let watched = try await remote.watch("/events/*", from: nil, session: session)
      var events = watched.makeAsyncIterator()
      _ = try await space.fs(.shared).write("/events/first.md", Data("# First".utf8), ifMatch: nil)
      let first = try await space.currentRevision()
      #expect(try await rows.next()?.rows.count == 1)
      #expect(try await events.next()?.object?["rev"]?.intValue == first)
      _ = try await space.fs(.shared).write("/events/second.md", Data("# Second".utf8), ifMatch: nil)
      let second = try await space.currentRevision()
      #expect(try await rows.next()?.rows.count == 2)
      #expect(try await events.next()?.object?["rev"]?.intValue == second)
      let inventory: [WorkerStreamInventory] = try await OwnerRPC(client: client).call("script.stream-inventory", EmptyRequest())
      #expect(inventory.count == 2)
      #expect(inventory.first { $0.operation == "script.watch-open" }?.revision == second)
      for stream in inventory { await OwnerRPC(client: client).cancel(stream.id) }
      let after: [WorkerStreamInventory] = try await OwnerRPC(client: client).call("script.stream-inventory", EmptyRequest())
      #expect(after.isEmpty)
      #expect(await client.pendingReceipts().isEmpty)
      outcome = .success(())
    } catch { outcome = .failure(error) }
    await bytes.shutdown(); await parent.shutdown()
    try outcome.get()
  }

  @Test func watchOverflowFailsExplicitlyRatherThanSilentlyDropping() async throws {
    let produced = Mutex(0)
    let (filled, signal) = AsyncStream<Void>.makeStream()
    let source = AsyncThrowingStream<JSONValue, any Error>(unfolding: {
      let count = produced.withLock { $0 += 1; return $0 }
      if count == 257 { signal.finish() }
      return .integer(count - 1)
    })
    let bounded = boundedScriptWatch(source)
    for await _ in filled {}
    var count = 0
    var failed = false
    do {
      for try await value in bounded {
        #expect(value == .integer(count))
        count += 1
      }
    } catch let error as WorkerProtocolError { failed = error.code == .capacityExceeded }
    #expect(failed)
    #expect(count == 256)
    #expect(produced.withLock { $0 } == 257)
  }
}
