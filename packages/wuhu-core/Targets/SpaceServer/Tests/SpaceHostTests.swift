import Credentials
import Fetch
import Foundation
import Scratch
import Serve
import SpaceCore
@testable import SpaceServer
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import Testing

@Suite(.serialized) struct SpaceHostTests {
  @Test func separateHostsOwnSeparateStoresAndDiscovery() async throws {
    let previous = ProcessInfo.processInfo.environment["TEST_PROVIDER_API_KEY"]
    setenv("TEST_PROVIDER_API_KEY", "process-key", 1)
    defer {
      if let previous { setenv("TEST_PROVIDER_API_KEY", previous, 1) }
      else { unsetenv("TEST_PROVIDER_API_KEY") }
    }
    let base = try scratchURL("space-host")
    defer { try? FileManager.default.removeItem(at: base) }
    func open(_ name: String) async throws -> SpaceHost {
      try await SpaceHost.open(
        folder: base.appendingPathComponent(name),
        deployment: DeploymentRecord(origin: "https://\(name).example.test", tlsFingerprint: "test", certificate: .provided),
        configDirectory: base.appendingPathComponent(name + "/config"), allowEnvironmentCredentials: false,
        contentHostPattern: "{group}--\(name).example.test",
      )
    }
    let first = try await open("first")
    let second = try await open("second")
    #expect(first.id != second.id)
    for (host, key) in [(first, "first-key"), (second, "second-key")] {
      let folderName = host.id == first.id ? "first" : "second"
      let store = CredentialsStore(configDirectory: base.appendingPathComponent(folderName + "/config"), spaceID: host.id)
      try await store.save(CredentialsFile(providers: ["test-provider": .apiKey(key)]))
      #expect(try await host.credentials.resolve("test-provider") == .apiKey(key))
      let directory = SingleSpaceDirectory(host: host)
      #expect(directory.host(for: "arbitrary.test")?.id == host.id)
      let result = try await directory.handler(Request(url: URL(string: try #require(await host.space.deployment()?.origin) + "/v1/server")!))
      guard case let .response(response) = result else { Issue.record("expected response"); return }
      let text = try await response.body.text()
      #expect(text.contains(host.id))
      #expect(!text.contains(host.id == first.id ? second.id : first.id))
      try await host.shutdown()
    }
  }

  @Test func unknownDirectoryReturns421() async throws {
    struct EmptyDirectory: SpaceDirectory {
      func host(for requestHost: String?) -> SpaceHost? { nil }
    }
    let result = try await EmptyDirectory().handler(Request(url: URL(string: "https://unknown.test/")!))
    guard case let .response(response) = result else { Issue.record("expected response"); return }
    #expect(response.status == .misdirectedRequest)
  }

  @Test func deferredWebSocketHasSpaceLogContext() async throws {
    let handler = spaceScopedHandler(id: "spc_deferred") { _ in
      #expect(SpaceLogContext.spaceID == "spc_deferred")
      return .webSocket { _ in #expect(SpaceLogContext.spaceID == "spc_deferred") }
    }
    let result = try await handler(Request(url: URL(string: "https://socket.test/")!))
    #expect(SpaceLogContext.spaceID == nil)
    guard case let .webSocket(session) = result else { Issue.record("expected socket"); return }
    let (socket, peer) = WebSocket.pair()
    defer { peer.close() }
    await Task.detached { await session(socket) }.value
    #expect(SpaceLogContext.spaceID == nil)
  }

  @Test func shutdownBeforeRunPreventsStarting() async throws {
    let folder = try scratchURL("space-host-stopped")
    defer { try? FileManager.default.removeItem(at: folder) }
    let host = try await SpaceHost.open(folder: folder, deployment: DeploymentRecord(origin: "https://stopped.test", tlsFingerprint: "test", certificate: .provided), configDirectory: nil, allowEnvironmentCredentials: false)
    try await host.shutdown()
    await host.run()
    try await host.shutdown()
  }

  @Test func stoppingSocketsDrainsOnlyTheirOwnSessions() async {
    let first = HostSockets()
    let second = HostSockets()
    let (a, peerA) = WebSocket.pair()
    let (b, peerB) = WebSocket.pair()
    let (started, start) = AsyncStream<Void>.makeStream()
    let body: WebSocketSession = { socket in
      start.yield(())
      for await _ in socket.inbound {}
    }
    let firstRun = Task { await first.run(body, socket: a) }
    let secondRun = Task { await second.run(body, socket: b) }
    var arrivals = started.makeAsyncIterator()
    _ = await arrivals.next()
    _ = await arrivals.next()
    await first.shutdown()
    await firstRun.value
    var ended = peerA.inbound.makeAsyncIterator()
    #expect(await ended.next() == nil)
    await #expect(throws: Never.self) { try await peerB.send(.text("still live")) }
    await second.shutdown()
    await secondRun.value
    start.finish()
  }

  @Test func shutdownCancelsAndAwaitsAdmittedRequests() async throws {
    let requests = HostRequests()
    let sockets = HostSockets()
    let (started, start) = AsyncStream<Void>.makeStream()
    let (waiting, _) = AsyncStream<Void>.makeStream()
    let request = Request(url: URL(string: "https://request.test/")!)
    let run = Task {
      try await requests.run({ _ in
        start.yield(())
        for await _ in waiting {}
        throw CancellationError()
      }, request: request)
    }
    var arrivals = started.makeAsyncIterator()
    _ = await arrivals.next()
    await requests.shutdown(sockets: sockets)
    guard case .failure = await run.result else { Issue.record("request was not cancelled"); return }
    let after = try await requests.run({ _ in Issue.record("stopped host admitted request"); return .response(Response(status: .ok)) }, request: request)
    guard case let .response(response) = after else { Issue.record("expected response"); return }
    #expect(response.status == .serviceUnavailable)
    start.finish()
  }

  @Test func shutdownAbortsAnUncancellableBlockedSocketWrite() async {
    let sockets = HostSockets()
    let (started, start) = AsyncStream<Void>.makeStream()
    let (blocked, release) = AsyncStream<Void>.makeStream()
    let (inbound, close) = AsyncStream<WebSocketMessage>.makeStream()
    let socket = WebSocket(inbound: inbound, send: { _ in
      start.yield(())
      await Task.detached { for await _ in blocked {} }.value
    }, close: { close.finish() }, abort: { close.finish(); release.finish() })
    let session = Task { await sockets.run({ try? await $0.send(.text("blocked")) }, socket: socket) }
    var ready = started.makeAsyncIterator()
    _ = await ready.next()
    await sockets.shutdown()
    await session.value
    start.finish()
  }

  @Test func responseBodiesRemainOwnedAfterDispatchReturns() async throws {
    let requests = HostRequests()
    let sockets = HostSockets()
    let (source, continuation) = AsyncStream<Bytes>.makeStream()
    let result = try await requests.run({ _ in .response(Response(status: .ok, body: .stream(source))) }, request: Request(url: URL(string: "https://stream.test/")!))
    guard case let .response(response) = result else { Issue.record("expected response"); return }
    var body = response.body.asyncBytes().makeAsyncIterator()
    continuation.yield(Data("first".utf8))
    #expect(try await body.next() == Data("first".utf8))
    await requests.shutdown(sockets: sockets)
    do { #expect(try await body.next() == nil) }
    catch is CancellationError {}
    continuation.finish()
  }

  @Test func logsFollowTaskAndDoNotLeakOut() async {
    #expect(SpaceLogContext.metadataProvider.get().isEmpty)
    await SpaceLogContext.$spaceID.withValue("spc_test") {
      #expect(SpaceLogContext.metadataProvider.get()["space"] == "spc_test")
      let child = Task { SpaceLogContext.metadataProvider.get()["space"] }
      #expect(await child.value == "spc_test")
    }
    #expect(SpaceLogContext.metadataProvider.get().isEmpty)
  }
}
