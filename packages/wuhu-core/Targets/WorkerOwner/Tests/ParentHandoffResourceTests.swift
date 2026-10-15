#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ExecutionOwner
import Fetch
import InferenceKit
import JSONValue
import MachineChannel
import Scratch
import SessionDomain
import SessionTools
import SpaceCore
import struct SpaceTools.MachineSeam
import Synchronization
import Testing
@testable import WorkerOwner
import WorkerProtocol

@Suite(.timeLimit(.minutes(1))) struct ParentHandoffResourceTests {
  @Test func compactClaimAndTraceHandlesCannotDisappearDuringTransfer() async throws {
    let space = try Space.inMemory()
    let directory = try ScratchFolder("handoff-traces")
    let session = try await space.sessions.createSession(group: .shared, title: "claims", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
    let source = ParentExecutionHandoff(owner: InProcessExecutionOwnerClient(space: space, attemptLog: .init(directory: directory.url)))
    let client = try await client(source)
    let remote = RemoteExecutionOwner(client: client, tracesAttempts: true)
    let traceID = UUID()
    _ = try await remote.openAttemptTrace(traceID)
    await #expect(throws: WorkerProtocolError.self) { try await source.prepare() }
    await remote.closeAttemptTrace(traceID)
    try await source.prepare()
    try await source.resume()
    try await space.sessions.requestCommand(session, .compact(instructions: "keep"))
    _ = try #require(await remote.claimCompactRequest(session, generation: 0))
    await #expect(throws: WorkerProtocolError.self) { try await source.prepare() }
    await source.shutdown()
  }

  @Test func machineConnectionRefusesUntilExplicitlyClosed() async throws {
    let space = try Space.inMemory()
    let session = try await space.sessions.createSession(group: .shared, title: "frames", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
    let machine = try await space.addMachine(name: "fixture")
    let transport = HandoffFrames()
    let backend = ExecBackend(claim: { machine, caller, call in
      try await space.claimExec(machine: machine, caller: caller.rawValue, toolCallID: call)
    }, connect: { _ in transport }, status: { try await space.execRecord($0) }, mintScript: { machine, caller, script in
      try await space.mintScriptExec(machine: machine, session: caller.rawValue, script: script)
    }, kill: { _ in })
    let files = MachineSeam(vfs: { _, _ in .ok }, search: { _, _ in .paths(paths: [], cursor: nil) }, attached: { [machine.id] })
    let owner = InProcessToolOwnerClient(space: space, scriptMachines: .init(files: files, exec: backend))
    let source = ParentExecutionHandoff(owner: owner)
    let client = try await client(source)
    let remote = RemoteExecutionOwner(client: client, tracesAttempts: false, machines: true)
    let access = try #require(remote.scriptMachines(for: session))
    let claim = try await access.exec.claim(machine.id, session, .init("fixture"))
    let rpc = OwnerRPC(client: client)
    let connection: UUID = try await rpc.call("machine.connect", ExecAccessRequest(session: session, id: claim.record.id))
    await #expect(throws: WorkerProtocolError.self) { try await source.prepare() }
    #expect(!transport.closed.withLock { $0 })
    let _: Bool = try await rpc.call("machine.close", StreamRequest(id: connection))
    #expect(transport.closed.withLock { $0 })
    try await source.prepare()
    try await source.resume()
    await source.shutdown()
  }

  @Test func freezingRejectsControlsAndCustomLegsUntilEveryReaderWaitDrains() async throws {
    let admission = OwnerAdmission()
    let (entered, signal) = AsyncStream<Void>.makeStream()
    let (release, finish) = AsyncStream<Void>.makeStream()
    let reader = Task {
      try await admission.run { _ in
        try await admission.run(reusingRequest: true) { ticket in
          try await admission.reader(ticket)
          signal.yield(())
          for await _ in release {}
        }
      }
    }
    var iterator = entered.makeAsyncIterator()
    _ = await iterator.next()
    try await admission.freeze()
    await #expect(throws: WorkerProtocolError.self) { try await admission.run { _ in Issue.record("Frozen endpoint admitted a control or custom leg") } }
    finish.finish()
    await admission.drain()
    try await reader.value
    try await admission.resume()
    #expect(try await admission.run { _ in 7 } == 7)
  }

  @Test func effectTasksCannotReuseTheirTransportReaderAdmission() async throws {
    let admission = OwnerAdmission()
    let (entered, signal) = AsyncStream<Void>.makeStream()
    let (release, finish) = AsyncStream<Void>.makeStream()
    let pending = Task {
      try await admission.run { _ in
        try await admission.run(reusingRequest: true) { ticket in
          try await admission.reader(ticket)
          try await Task {
            try await admission.run(reusingRequest: true) { _ in
              signal.yield(())
              for await _ in release {}
            }
          }.value
        }
      }
    }
    var iterator = entered.makeAsyncIterator()
    _ = await iterator.next()
    await #expect(throws: WorkerProtocolError.self) { try await admission.freeze() }
    finish.finish()
    try await pending.value
    try await admission.freeze()
    try await admission.resume()
  }

  @Test func preparedAndRetiredHandlersCannotNegotiateOrRotateSharedCredentials() async throws {
    let owner = InProcessExecutionOwnerClient(space: try Space.inMemory())
    let source = ParentExecutionHandoff(owner: owner)
    let credentials = try WorkerCredentials(token: "original")
    let rotationHello = WorkerHello(capabilities: WorkerHello.baseline.union(["worker.credential-rotation.v1"]), release: "rotation")
    let endpoint = try await source.endpoint(credentials: credentials, hello: rotationHello)
    let hello = try ownerEncode(rotationHello)
    #expect(try await request(endpoint, path: "hello", token: "original", payload: hello).status == .ok)
    try await source.prepare()
    await #expect(throws: WorkerProtocolError.self) { try await source.endpoint(credentials: credentials, hello: rotationHello) }
    for path in ["hello", "credentials/stage", "credentials/confirm"] {
      let response = try await request(endpoint, path: path, token: "original", payload: path == "hello" ? hello : .object(["successor": .string("rogue")]))
      #expect(response.status == .badRequest)
      #expect(try await response.body.json(WorkerProtocolError.self).code == .unavailable)
    }
    #expect(await credentials.outgoingToken == "original")
    let restored = try await source.transfer(to: owner)
    await #expect(throws: WorkerProtocolError.self) { try await restored.endpoint(credentials: credentials, hello: rotationHello) }
    try await restored.resume()
    let replacement = try await restored.endpoint(credentials: credentials, hello: rotationHello)
    await #expect(throws: WorkerProtocolError.self) { try await source.endpoint(credentials: credentials, hello: rotationHello) }
    for path in ["hello", "credentials/stage"] {
      let response = try await request(endpoint, path: path, token: "original", payload: path == "hello" ? hello : .object(["successor": .string("rogue")]))
      #expect(response.status == .badRequest)
      #expect(try await response.body.json(WorkerProtocolError.self).code == .unavailable)
    }
    #expect(await credentials.outgoingToken == "original")
    #expect(try await request(replacement, path: "hello", token: "original", payload: hello).status == .ok)
    #expect(try await request(replacement, path: "credentials/stage", token: "original", payload: .object(["successor": .string("legitimate")])).status == .ok)
    let refused = try await request(endpoint, path: "credentials/confirm", token: "legitimate", payload: .null)
    #expect(refused.status == .badRequest)
    #expect(try await refused.body.json(WorkerProtocolError.self).code == .unavailable)
    #expect(await credentials.outgoingToken == "legitimate")
    await #expect(throws: WorkerProtocolError.self) { try await credentials.stage(successor: "other") }
    #expect(try await request(replacement, path: "credentials/confirm", token: "legitimate", payload: .null).status == .ok)
    await restored.shutdown()
    #expect(try await request(replacement, path: "hello", token: "legitimate", payload: hello).status == .badRequest)
  }

  private func request(_ endpoint: WorkerEndpoint, path: String, token: String, payload: JSONValue) async throws -> Response {
    try await endpoint.handler(Request(url: URL(string: "http://fixture.invalid/worker/" + path)!, method: .post, headers: .init(values: ["Authorization": "Bearer " + token]), body: .json(payload)))
  }

  private func client(_ handoff: ParentExecutionHandoff) async throws -> WorkerClient {
    let endpoint = try await handoff.endpoint(credentials: try WorkerCredentials(token: "fixture"), hello: ExecutionWorkerBootstrap.hello(release: "parent"))
    let fetch = FetchClient(fetch: endpoint.handler)
    let client = try WorkerClient(socket: "/private/handoff.sock", token: "fixture", control: fetch, bytes: fetch)
    _ = try await client.negotiate(ExecutionWorkerBootstrap.hello(release: "worker"))
    return client
  }
}

private final class HandoffFrames: FrameTransport {
  let inbound = AsyncStream<[UInt8]> { $0.finish() }
  let closed = Mutex(false)
  func send(_: [UInt8]) async throws {}
  func close() { closed.withLock { $0 = true } }
}
