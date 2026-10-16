#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import AsyncHTTPClient
import ExecutionOwner
import Fetch
import ServeNIO
import ServeTLS
import SessionTools
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

@Suite(.enabled(if: adminExecPlatformSupported), .sessionFixtures(timeLimit: .minutes(1))) struct AdminExecRollbackTests {
  @Test func probationWithLiveHandlerRecordsRollbackBlockedWithoutCancellingWorkAndKeepsServing() async throws {
    try await withSessionDeps {
      let fixture = try PersistenceFixture()
      defer { fixture.clean() }
      let space = try Space.inMemory()
      let id = try await space.identity().rawValue
      let session = try await space.sessions.createSession(group: .shared, title: "handler", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "missing", effort: "none"))
      let (entered, enter) = AsyncStream<Void>.makeStream()
      let (released, release) = AsyncStream<Void>.makeStream()
      let cancelled = Mutex(false)
      let worker = LazyExecutionWorker(executable: "unused", sessions: space.sessions, owner: InProcessExecutionOwnerClient(space: space), spawn: { _, _, _ in throw CancellationError() }, startConnection: { _, _, _ in
        enter.yield(())
        for await _ in released { break }
        cancelled.withLock { $0 = Task.isCancelled }
        throw CancellationError()
      })
      let liveHandler = Task { try await worker.executeHandler(.init(path: "/handler.js", session: session)) }
      var iterator = entered.makeAsyncIterator()
      _ = await iterator.next()
      let controller = try await AdminExecTesting.$current.withValue(.init(allowedUIDs: [UInt32(geteuid())], workerExecutable: nil)) {
        let controller = try await AdminExecController.begin(folder: URL(fileURLWithPath: fixture.base), placement: .worker())
        try await controller.validateSuccessor(placement: .worker())
        return controller
      }
      _ = try await controller.validateSpace(id, configDirectory: URL(fileURLWithPath: fixture.config), sessions: space.sessions)
      await controller.register(worker)
      let requests = HostRequests()
      let pauses = Mutex(0), resumes = Mutex(0)
      await controller.installRequests(pause: { pauses.withLock { $0 += 1 }; try await requests.pauseExec() }, resume: { resumes.withLock { $0 += 1 }; await requests.resumeExec() })
      let identity = try TLSIdentity.selfSigned(hosts: ["localhost", "127.0.0.1"])
      let bound = try await ServeNIOServer.bindExportable(port: 0, tls: identity, upgrading: { request in try await requests.run({ _ in .response(.text("still serving")) }, request: request) })
      try await controller.installPublic(bound.server, descriptor: bound.listener.descriptor)
      await controller.probationFailed()
      let files = try AdminExecFiles(folder: URL(fileURLWithPath: fixture.base), create: false)
      let reply = try #require(try files.read("reply.json", as: AdminExecController.Reply.self))
      #expect(reply.code == "rollbackBlocked" && reply.reason == "generationBusy")
      #expect(try files.read("intent.json", as: AdminExecController.Intent.self)?.phase == "rollbackBlocked")
      #expect(pauses.withLock { $0 } == 1 && resumes.withLock { $0 } == 1)
      #expect(!cancelled.withLock { $0 })
      var configuration = HTTPClient.Configuration()
      configuration.tlsConfiguration = .makeClientConfiguration()
      configuration.tlsConfiguration?.certificateVerification = .none
      let http = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
      let outcome: Result<Void, any Error>
      do {
        let response = try await http.execute(HTTPClientRequest(url: "https://127.0.0.1:\(try #require(bound.server.boundAddress.port))/"), timeout: .seconds(5))
        var body = try await response.body.collect(upTo: 1024)
        #expect(response.status.code == 200 && body.readString(length: body.readableBytes) == "still serving")
        #expect(pauses.withLock { $0 } == 1)
        outcome = .success(())
      } catch { outcome = .failure(error) }
      release.yield(())
      release.finish(); enter.finish()
      _ = await liveHandler.result
      #expect(!cancelled.withLock { $0 })
      await worker.shutdown()
      await bound.server.shutdown()
      try await controller.shutdown()
      try await http.shutdown()
      try outcome.get()
    }
  }
}
