#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import AsyncHTTPClient
import ExecutionOwner
import Fetch
import FetchAsyncHTTPClient
import JSONValue
import NIOPosix
import SpaceCore
@testable import SpaceServer
import Testing
import WorkerOwner
import WorkerProtocol

@Suite(.timeLimit(.minutes(1))) struct WorkerParentBindingTests {
  @Test func lateHelloFromRetiredRouteCannotAdmitReplacementAndDetachKeepsNewRoute() async throws {
    let directory = "/tmp/wpr-" + String(UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let hello = ExecutionWorkerBootstrap.hello(release: "fixture").retainingReplies(UUID())
    let original = try WorkerEndpoint(token: "fixture", hello: hello, invoke: { _ in .string("original") }, upload: { _, _ in }, download: { _ in .empty })
    let replacement = try WorkerEndpoint(token: "fixture", hello: hello, invoke: { _ in .string("replacement") }, upload: { _, _ in }, download: { _ in .empty })
    let (entered, signal) = AsyncStream<Void>.makeStream()
    let (release, finish) = AsyncStream<Void>.makeStream()
    defer { finish.finish() }
    let transport = try await WorkerOwnerTransport.bind(socket: directory + "/parent.sock", handler: { request in
      signal.yield(())
      for await _ in release { break }
      return try await original.handler(request)
    })
    let running = Task { await transport.run() }
    let http = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton))
    let client = try WorkerClient(socket: directory + "/parent.sock", token: "fixture", control: .asyncHTTPClient(http, timeout: nil), bytes: .asyncHTTPClient(http, timeout: nil))
    let oldHello = Task { try await client.negotiate(hello) }
    let outcome: Result<Void, any Error>
    do {
      var iterator = entered.makeAsyncIterator()
      _ = await iterator.next()
      try await transport.replace(handler: replacement.handler)
      finish.yield(())
      _ = try await oldHello.value
      let unauthorized = try WorkerClient(socket: directory + "/parent.sock", token: "wrong", control: .asyncHTTPClient(http, timeout: nil), bytes: .asyncHTTPClient(http, timeout: nil))
      await #expect(throws: WorkerProtocolError.self) { try await unauthorized.negotiate(hello) }
      do {
        _ = try await client.call(.init(operation: "probe"))
        Issue.record("Retired hello admitted the replacement")
      } catch let error as WorkerProtocolError { #expect(error.code == .unavailable) }
      _ = try await client.negotiate(hello)
      #expect(try await client.call(.init(operation: "probe")) == .string("replacement"))
      await transport.detach()
      try await until("current route rebounds") {
        (try? await client.call(.init(operation: "probe"))) == .string("replacement")
      }
      outcome = .success(())
    } catch { outcome = .failure(error) }
    finish.finish()
    _ = await oldHello.result
    await transport.stop()
    running.cancel()
    await running.value
    try? await http.shutdown()
    try outcome.get()
  }

  @Test(arguments: [false, true]) func concurrentShutdownCannotPublishOrResumeAReplacement(replace: Bool) async throws {
    let directory = "/tmp/wpr-" + String(UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: directory) }
    for _ in 0 ..< 16 {
      let owner = InProcessExecutionOwnerClient(space: try Space.inMemory())
      let handoff = ParentExecutionHandoff(owner: owner)
      let credentials = try WorkerCredentials(token: "fixture")
      let hello = ExecutionWorkerBootstrap.hello(release: "fixture")
      let endpoint = try await handoff.endpoint(credentials: credentials, hello: hello)
      let transport = try await WorkerOwnerTransport.bind(socket: directory + "/parent.sock", handler: endpoint.handler)
      let binding = WorkerParentBinding(handoff: handoff, transport: transport, credentials: credentials, hello: hello)
      let local = FetchClient(fetch: endpoint.handler)
      let client = try WorkerClient(socket: "/unused.sock", credentials: credentials, control: local, bytes: local)
      _ = try await client.negotiate(hello)
      await #expect(throws: WorkerProtocolError.self) { try await binding.replace(owner: owner, control: { _ in .bool(true) }) }
      try await binding.prepare()
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await binding.shutdown() }
        group.addTask {
          if replace { try? await binding.replace(owner: owner, control: { _ in .bool(true) }) }
          else { try? await binding.resume() }
        }
      }
      await #expect(throws: WorkerProtocolError.self) { try await binding.prepare() }
      await #expect(throws: WorkerProtocolError.self) { try await binding.resume() }
      await #expect(throws: WorkerProtocolError.self) { try await transport.replace(handler: endpoint.handler) }
      await #expect(throws: WorkerProtocolError.self) { try await client.reconnect() }
    }
  }
}
