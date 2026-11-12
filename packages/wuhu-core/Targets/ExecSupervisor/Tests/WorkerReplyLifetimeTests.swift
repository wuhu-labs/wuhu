#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import ExecSupervisor
import Fetch
import FetchTunnel
import struct OperationProtocol.OperationSnapshot
import struct OperationProtocol.StartRequest
import Synchronization
import Testing

extension ExecWorkerTests {
  enum ReplyGate: CaseIterable, Sendable { case handler, end }

  @Test(.timeLimit(.minutes(1)), arguments: ReplyGate.allCases)
  func adoptedWorkerKeepsItsLastAckLinkThroughResponseEnd(gated: ReplyGate) async throws {
    let home = try MachineHome(); defer { home.remove() }
    let worker = try worker(directory: home.operations)
    let link = AckLink()
    let gate = AckGate()
    let server = try Tunnel(over: TunnelTransport(receive: link.worker.receive, send: { bytes in
      if gated == .end && bytes[1] == 4 { try await gate.hold() }
      try await link.worker.send(bytes)
    }, abort: link.worker.abort), handler: { request in
      let response = try await worker.handler(request)
      if gated == .handler { try await gate.hold() }
      return response
    })
    let router = try Tunnel(over: link.router)
    await worker.accepted(.init(accepted: true, current: true), tunnel: server)
    let nonce = await worker.manifest.nonce
    func request(_ id: UUID, method: Fetch.Method = .get, body: Body? = nil, query: String = "") -> Request {
      var request = execRequest(id, query: query, method: method, body: body)
      request.headers["X-Wuhu-Supervisor-Nonce"] = nonce
      return request
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await worker.agent.run() }
      group.addTask { try? await server.run() }
      group.addTask { try? await router.run() }
      defer { group.cancelAll() }
      let id = UUID()
      // Receipt spawning re-enters this executable; an absent cwd fails before the test runner can be execed as the CLI trampoline.
      let start = request(id, method: .post, body: try .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/true"], "cwd": .string(home.path + "/absent"), "stdin": false])))
      try #require(try await worker.handler(start).status.code == 201)
      var snapshot = await worker.agent.inspect(id)
      while snapshot?.terminalToken == nil || snapshot?.finalOffsets.count != 2 {
        try Task.checkCancellation()
        await Task.yield()
        snapshot = await worker.agent.inspect(id)
      }
      let token = try #require(snapshot?.terminalToken)
      #expect(snapshot?.verdict?.error?.code == .spawnFailed)
      #expect(snapshot?.finalOffsets.values.allSatisfy { $0.rawValue == 0 } == true)
      let stdout = request(id, query: "?channel=stdout&after=0&terminalAck=\(token)")
      #expect(try await worker.handler(stdout).status.code == 200)
      await worker.accepted(.init(accepted: true, current: false), tunnel: server)
      #expect(!(await worker.shouldExit()), "the adopted worker still holds the receipt")
      let stderr = request(id, query: "?channel=stderr&after=0&terminalAck=\(token)")
      async let response = router.client(stderr)
      await gate.waitUntilHeld()
      #expect(!(await worker.agent.hasRetainedOperations()), "the last ack has released the operation")
      #expect(try WorkerDirectory.inventory(home.operations).retained.isEmpty)
      #expect(!link.completion.ended.withLock { $0 }, "response end has not crossed transport handover")
      let exits = await worker.shouldExit()
      #expect(!exits, "empty non-current worker must retain its in-flight final response")
      if exits { await server.abort() }
      gate.release.finish()
      do {
        let reply = try await response
        #expect(reply.status.code == 200)
        let acknowledged = try await reply.body.json(OperationSnapshot.self)
        #expect(acknowledged.operation == id && acknowledged.terminalToken == token)
        #expect(link.completion.ended.withLock { $0 }, "the complete 200 includes the end frame")
      } catch {
        Issue.record("final acknowledgement reply was lost: \(error)")
      }
      while !(await server.isIdle) && !exits { await Task.yield() }
      #expect(await worker.shouldExit(), "the adopted empty worker retires after end handover")
      await server.abort()
      await worker.agent.shutdown()
      group.cancelAll()
    }
  }
}

private final class AckGate: Sendable {
  let held: AsyncStream<Void>
  let arrival: AsyncStream<Void>.Continuation
  let released: AsyncStream<Void>
  let release: AsyncStream<Void>.Continuation
  init() {
    (held, arrival) = AsyncStream.makeStream()
    (released, release) = AsyncStream.makeStream()
  }

  func hold() async throws {
    arrival.finish()
    for await _ in released {}
    try Task.checkCancellation()
  }

  func waitUntilHeld() async { for await _ in held {} }
}

private final class AckLink: Sendable {
  let worker: TunnelTransport
  let router: TunnelTransport
  let completion = AckCompletion()
  init() {
    let (toWorker, workerInput) = AsyncThrowingStream<Bytes, any Error>.makeStream()
    let (toRouter, routerInput) = AsyncThrowingStream<Bytes, any Error>.makeStream()
    let workerReader = AckReader(toWorker), routerReader = AckReader(toRouter)
    let completion = self.completion
    router = TunnelTransport(receive: { try await routerReader.next() }, send: { workerInput.yield($0) }, abort: { workerInput.finish(); routerInput.finish() })
    worker = TunnelTransport(receive: { try await workerReader.next() }, send: { bytes in
      try Task.checkCancellation()
      if bytes[1] == 4 { completion.ended.withLock { $0 = true } }
      routerInput.yield(bytes)
    }, abort: { workerInput.finish(); routerInput.finish() })
  }
}

private actor AckReader {
  var iterator: AsyncThrowingStream<Bytes, any Error>.Iterator
  init(_ stream: AsyncThrowingStream<Bytes, any Error>) { iterator = stream.makeAsyncIterator() }
  func next() async throws -> Bytes? {
    var iterator = self.iterator
    let bytes = try await iterator.next(isolation: self)
    self.iterator = iterator
    return bytes
  }
}

private final class AckCompletion: Sendable { let ended = Mutex(false) }
