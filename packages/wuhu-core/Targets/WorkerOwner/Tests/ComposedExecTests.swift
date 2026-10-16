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
import Dependencies
import ExecutionOwner
import Fetch
import FetchAsyncHTTPClient
import InferenceKit
import JSONValue
import NIOPosix
import SessionTools
import SpaceCore
import Synchronization
import Testing
@testable import WorkerOwner
import WorkerProtocol

enum ComposedScenario: String, CaseIterable, Sendable { case commit, carrierImport, listenerAdopt, replyRestore, readiness }

@Suite(.enabled(if: !carrierFixtureRequested), .serialized, .timeLimit(.minutes(2))) struct ComposedExecTests {
  @Test func preparationRefusalResumesBothResources() async throws {
    let directory = "/tmp/composed-" + UUID().uuidString
    try #require(mkdir(directory, 0o700) == 0)
    let path = directory + "/owner.sock"
    defer { _ = unlink(path); _ = rmdir(directory) }
    let execution = ParentExecutionHandoff(owner: InProcessExecutionOwnerClient(space: try Space.inMemory()))
    let listener = try await WorkerListener.bind(socket: path) { _ in .text("resumed-source") }
    let source = ParentExecSource(execution: execution, listener: listener)
    let result: Result<Void, any Error>
    do {
      let invalid = ParentExecCheckpoint.Identity(space: "", generation: carrierIdentity.generation, incarnation: carrierIdentity.incarnation, processID: 0, birth: "")
      await #expect(throws: WorkerProtocolError.self) { try await source.prepare(identity: invalid) }
      _ = try await execution.endpoint(credentials: WorkerCredentials(token: "fixture"), hello: ExecutionWorkerBootstrap.hello(release: "source"))
      try #require(try await Task.detached { try requestListener(path: path) }.value.hasSuffix("resumed-source"))
      result = .success(())
    } catch { result = .failure(error) }
    await listener.shutdown()
    await execution.shutdown()
    try result.get()
  }

  @Test func retainedReplyCrossesExecOnAdoptedEndpointExactlyOnce() async throws {
    try await exerciseComposedExec(.commit)
  }

  @Test(arguments: ComposedScenario.allCases.filter { $0 != .commit }) func failedStageLeavesSourceServing(scenario: ComposedScenario) async throws {
    try await exerciseComposedExec(scenario)
  }
}

private func exerciseComposedExec(_ scenario: ComposedScenario) async throws {
  let directory = "/tmp/composed-" + UUID().uuidString
  try #require(mkdir(directory, 0o700) == 0)
  let path = directory + "/owner.sock"
  defer { _ = unlink(path); _ = rmdir(directory) }
  let effects = Mutex<[Int]>([]), queuedCalls = Mutex(0)
  let runtime = WorkerRuntimeOwner(attempts: AttemptHub(), usage: { [:] }, receiveUsage: { _, _ in }, allowsWarming: { _ in false }, scheduleWarming: { _, interval in effects.withLock { $0.append(interval) } })
  let execution = ParentExecutionHandoff(owner: InProcessExecutionOwnerClient(space: try Space.inMemory()), runtime: runtime)
  let endpoint = try await execution.endpoint(credentials: WorkerCredentials(token: "composed-fixture"), hello: ExecutionWorkerBootstrap.hello(release: "source"))
  let listener = try await WorkerListener.bind(socket: path) { request in
    if request.url.path == "/" { queuedCalls.withLock { $0 += 1 }; return .text("source-listener") }
    return try await endpoint.handler(request)
  }
  let source = ParentExecSource(execution: execution, listener: listener)
  let http = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton))
  let fetch = FetchClient.asyncHTTPClient(http, timeout: .seconds(10))
  let client = try WorkerClient(socket: path, token: "composed-fixture", control: fetch, bytes: fetch)
  let result: Result<Void, any Error>
  do {
    _ = try await client.negotiate(ExecutionWorkerBootstrap.hello(release: "worker"))
    let effect = try #require(try await client.retaining(WorkerCall(operation: "runtime.schedule-warming", payload: ownerEncode(WarmingRequest(session: .init(UUID().uuidString), intervalSeconds: 7)))))
    let input = WorkerCall(id: effect.id, operation: "owner.input", payload: .string(effect.operation), receipt: effect.receipt)
    try await client.upload(input, body: .json(effect.payload))
    try #require(effects.withLock { $0 } == [7])
    let exported = try await source.prepare(identity: carrierIdentity)
    var before = stat()
    try #require(lstat(path, &before) == 0)
    let identity = exported.listener.identity
    let metadata: [String: String] = [
      "PATH": path, "SCENARIO": scenario.rawValue,
      "FD_DEVICE": String(identity.descriptorDevice), "FD_INODE": String(identity.descriptorInode),
      "PATH_DEVICE": String(identity.pathDevice), "PATH_INODE": String(identity.pathInode),
    ]
    for fd in [exported.carrier.descriptor, exported.listener.descriptor] {
      try #require(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
      try #require(try spawnCarrierTest(mode: "absent", descriptor: fd) == 0)
    }
    if scenario == .commit {
      let hello = String(decoding: try JSONEncoder().encode(ExecutionWorkerBootstrap.hello(release: "queued-worker")), as: UTF8.self)
      let queued = try sendListenerRequest(path: path, route: "/worker/hello", method: "POST", body: hello, headers: "Authorization: Bearer composed-fixture\r\nContent-Type: application/json\r\n")
      defer { _ = close(queued) }
      var event = pollfd(fd: queued, events: Int16(POLLIN), revents: 0)
      try #require(poll(&event, 1, 100) == 0)
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          try #require(try spawnCarrierTest(mode: "composed", descriptor: exported.carrier.descriptor, mapping: true, listenerEnvironment: metadata, listenerDescriptor: exported.listener.descriptor) == 0)
        }
        do {
          let queuedReply = try await Task.detached { try readListenerResponse(queued) }.value
          try #require(queuedReply.contains("\"release\":\"successor\""))
          try #require(queuedReply.components(separatedBy: "HTTP/1.1 200").count == 2)
          try await client.reconnect()
          let recovered: Bool = try await OwnerRPC(client: client).retainedCall(effect)
          try #require(recovered)
          await #expect(throws: WorkerProtocolError(.consumedReceipt, message: "Owner receipt was already consumed; effect cannot be readmitted")) { try await client.upload(input, body: .json(effect.payload)) }
          let ownership = try await source.finish()
          let committed = ownership.identity
          let commit = WorkerCall(operation: "worker.ready", payload: .array([committed.descriptorDevice, committed.descriptorInode, committed.pathDevice, committed.pathInode].map { .string(String($0)) }))
          let ack = try sendListenerRequest(path: path, route: "/worker/call", method: "POST", body: String(decoding: JSONEncoder().encode(commit), as: UTF8.self), headers: "Authorization: Bearer composed-fixture\r\nContent-Type: application/json\r\n")
          defer { _ = close(ack) }
          try await group.waitForAll()
        } catch { group.cancelAll(); throw error }
      }
      try #require(effects.withLock { $0 } == [7])
      try #require(queuedCalls.withLock { $0 } == 0)
    } else {
      let queued = try sendListenerRequest(path: path)
      defer { _ = close(queued) }
      var event = pollfd(fd: queued, events: Int16(POLLIN), revents: 0)
      try #require(poll(&event, 1, 100) == 0)
      try #require(try await Task.detached { try spawnCarrierTest(mode: "composed", descriptor: exported.carrier.descriptor, mapping: true, listenerEnvironment: metadata, listenerDescriptor: exported.listener.descriptor) }.value == 0)
      try #require(poll(&event, 1, 100) == 0)
      var after = stat()
      try #require(lstat(path, &after) == 0 && after.st_dev == before.st_dev && after.st_ino == before.st_ino)
      try await source.rollback()
      let reply = try await Task.detached { try readListenerResponse(queued) }.value
      try #require(reply.hasSuffix("source-listener"))
      try #require(reply.components(separatedBy: "HTTP/1.1 200").count == 2)
      try #require(queuedCalls.withLock { $0 } == 1)
      try await client.reconnect()
      let recovered: Bool = try await OwnerRPC(client: client).retainedCall(effect)
      try #require(recovered)
      await #expect(throws: WorkerProtocolError(.consumedReceipt, message: "Owner receipt was already consumed; effect cannot be readmitted")) { try await client.upload(input, body: .json(effect.payload)) }
      let fresh: Bool = try await OwnerRPC(client: client).call("runtime.schedule-warming", WarmingRequest(session: .init(UUID().uuidString), intervalSeconds: 8))
      try #require(fresh)
      try #require(effects.withLock { $0 } == [7, 8])
    }
    for fd in [exported.carrier.descriptor, exported.listener.descriptor] { try #require(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0) }
    result = .success(())
  } catch { result = .failure(error) }
  await listener.shutdown()
  await execution.shutdown()
  try await http.shutdown()
  try result.get()
  var after = stat()
  try #require(lstat(path, &after) == -1 && errno == ENOENT)
}

func runComposedExecFixture(carrier: Int32, descriptor: Int32) async throws {
  let environment = ProcessInfo.processInfo.environment
  let path = try #require(environment["WUHU_LISTENER_TEST_PATH"])
  let scenario = try #require(environment["WUHU_LISTENER_TEST_SCENARIO"].flatMap(ComposedScenario.init(rawValue:)))
  func number(_ key: String) throws -> UInt64 { try #require(environment["WUHU_LISTENER_TEST_" + key].flatMap(UInt64.init)) }
  let identity = try WorkerListener.InheritedIdentity(descriptorDevice: number("FD_DEVICE"), descriptorInode: number("FD_INODE") + (scenario == .listenerAdopt ? 1 : 0), pathDevice: number("PATH_DEVICE"), pathInode: number("PATH_INODE"))
  let expected = scenario == .carrierImport ? ParentExecCheckpoint.Identity(space: "foreign", generation: carrierIdentity.generation, incarnation: carrierIdentity.incarnation, processID: carrierIdentity.processID, birth: carrierIdentity.birth) : carrierIdentity
  try #require(fcntl(descriptor, F_GETFD) & FD_CLOEXEC == 0)
  let effects = Mutex(0)
  let committed = AsyncStream<JSONValue>.makeStream()
  defer { committed.continuation.finish() }
  let runtime = WorkerRuntimeOwner(attempts: AttemptHub(), usage: { [:] }, receiveUsage: { _, _ in }, allowsWarming: { _ in false }, scheduleWarming: { _, _ in effects.withLock { $0 += 1 } })
  var successor: ParentExecSuccessor?
  do {
    let imported = try await ParentExecSuccessor.take(carrier: carrier, listener: descriptor, identity: expected, socket: path, listenerIdentity: identity, owner: InProcessExecutionOwnerClient(space: try Space.inMemory()), runtime: runtime, credentials: WorkerCredentials(token: "composed-fixture"), hello: ExecutionWorkerBootstrap.hello(release: "successor"), control: { call in
      committed.continuation.yield(call.payload)
      return .bool(true)
    }, stage: { stage in
      if (scenario == .replyRestore && stage == .restoringReplies) || (scenario == .readiness && stage == .ready) {
        throw WorkerProtocolError(.unavailable, message: "Injected composed handoff failure")
      }
      if stage == .adopted {
        try #require(fcntl(carrier, F_GETFD) == -1)
        try #require(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
        for fd in [carrier, descriptor] { try #require(try spawnCarrierTest(mode: "absent", descriptor: fd) == 0) }
      }
    })
    successor = imported
    try #require(scenario == .commit)
    let payload = try await withThrowingTaskGroup(of: JSONValue.self) { group in
      group.addTask {
        for await payload in committed.stream { return payload }
        throw WorkerProtocolError(.unavailable, message: "Commit channel ended")
      }
      group.addTask {
        @Dependency(\.continuousClock) var clock
        try await clock.sleep(for: .seconds(15))
        throw WorkerProtocolError(.unavailable, message: "Composed exec fixture timed out")
      }
      defer { group.cancelAll() }
      return try #require(try await group.next())
    }
    let fields = try ownerDecode([String].self, payload)
    let numbers = fields.compactMap(UInt64.init)
    try #require(numbers.count == 4)
    try await imported.listener.commitHandoff(.init(socket: path, identity: .init(descriptorDevice: numbers[0], descriptorInode: numbers[1], pathDevice: numbers[2], pathInode: numbers[3])))
    try #require(await imported.execution.bytes.journal.inventory().isEmpty)
  } catch let error as WorkerProtocolError where scenario != .commit {
    try #require(error.code == .invalidConfiguration || error.code == .unavailable)
    try #require(fcntl(carrier, F_GETFD) == -1)
    try #require(fcntl(descriptor, F_GETFD) == -1)
    for fd in [carrier, descriptor] { try #require(try spawnCarrierTest(mode: "absent", descriptor: fd) == 0) }
    var state = stat()
    try #require(lstat(path, &state) == 0 && UInt64(truncatingIfNeeded: state.st_ino) == identity.pathInode)
  }
  try #require(effects.withLock { $0 } == 0)
  await successor?.shutdown()
}
